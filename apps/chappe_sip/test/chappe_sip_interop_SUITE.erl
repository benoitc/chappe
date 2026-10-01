%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Interop against real SIP stacks. Opt-in: runs only when INTEROP=1 is set,
%% so it stays out of the fast `rebar3 ct` run. It drives external tooling
%% (a real JsSIP UA over WebSocket, a Kamailio container over UDP) at
%% chappe_sip and asserts the two interoperate on the wire.
%%
%% Prerequisites (see interop/README.md):
%%   - node + `npm install` in interop/ (JsSIP cases)
%%   - docker running, with the Kamailio image pulled (Kamailio cases):
%%       docker pull ghcr.io/kamailio/kamailio-ci:5.8
%%
%% Run: INTEROP=1 rebar3 ct --suite test/chappe_sip_interop_SUITE
-module(chappe_sip_interop_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([jssip_register/1, jssip_call/1, kamailio_options/1]).

-define(KAM_IMAGE, "ghcr.io/kamailio/kamailio-ci:5.8").

all() ->
    case os:getenv("INTEROP") of
        false -> {skip, "interop suite disabled; set INTEROP=1 to run"};
        _ -> [jssip_register, jssip_call, kamailio_options]
    end.

init_per_suite(Config) ->
    Dir = interop_dir(),
    HasNodeMods = filelib:is_dir(filename:join(Dir, "node_modules")),
    Node = os:find_executable("node"),
    case {HasNodeMods, Node} of
        {false, _} ->
            {skip, "run `npm install` in interop/ before INTEROP=1"};
        {_, false} ->
            {skip, "node not found on PATH"};
        {true, _} ->
            application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                                [{persistent, true}]),
            {ok, _} = application:ensure_all_started(chappe_sip),
            [{interop_dir, Dir}, {node, Node} | Config]
    end.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(kamailio_options, Config) ->
    Img = case os:getenv("KAMAILIO_IMAGE") of
              false -> ?KAM_IMAGE;
              I -> I
          end,
    case docker_image_ready(Img) of
        ok ->
            CN = "chappe-kam-" ++
                 integer_to_list(erlang:unique_integer([positive])),
            [{kam_image, Img}, {kam_container, CN} | Config];
        {skip, R} ->
            {skip, R}
    end;
init_per_testcase(jssip_call, Config) ->
    Dir = ?config(interop_dir, Config),
    case filelib:is_dir(filename:join([Dir, "node_modules", "@roamhq", "wrtc"])) of
        true -> Config;
        false -> {skip, "install @roamhq/wrtc in interop/ for the media call"}
    end;
init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(kamailio_options, Config) ->
    _ = os:cmd("docker rm -f " ++ ?config(kam_container, Config) ++
               " >/dev/null 2>&1"),
    cleanup();
end_per_testcase(_Case, _Config) ->
    cleanup().

cleanup() ->
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    _ = chappe_sip_registry:clear(),
    ok.

%% A real JsSIP UA registers over WebSocket; the binding lands in the store
%% while the UA is connected (the flow drop on exit purges it, RFC 5626), so
%% observe it during the driver's hold window.
jssip_register(Config) ->
    WP = pick(),
    EP = pick(),
    ok = chappe_sip:start(#{contact => contact(EP), ws => #{port => WP}}),
    ok = chappe_sip:register(chappe_sip:registrar()),
    Aor = <<"sip:alice@127.0.0.1">>,
    Self = self(),
    _ = spawn(fun() ->
        Self ! {node_out, run_node(Config, "jssip_register.js",
                                   [{"WS_URL", ws_url(WP)},
                                    {"SIP_URI", binary_to_list(Aor)},
                                    {"EXPIRES", "60"},
                                    {"HOLD_MS", "4000"},
                                    {"TIMEOUT_MS", "8000"}])}
    end),
    ok = poll_present(Aor, 60),
    Out = receive {node_out, O} -> O after 15000 -> ct:fail(node_timeout) end,
    ct:pal("jssip_register:~n~s", [Out]),
    match = re:run(Out, "RESULT registered", [{capture, none}]),
    ok.

%% Two real JsSIP UAs (caller + callee) place a WebRTC media call bridged by
%% chappe as a B2BUA over WebSocket. The caller's session reaching `confirmed`
%% proves INVITE/200/ACK traversed chappe and the WebRTC SDP passed through
%% intact (setRemoteDescription of the answer succeeded).
jssip_call(Config) ->
    WP = pick(),
    EP = pick(),
    ok = chappe_sip:start(#{contact => contact(EP), ws => #{port => WP}}),
    ok = chappe_sip:register(chappe_sip:registrar()),
    Callee = <<"sip:callee@127.0.0.1">>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        case chappe_sip:location_flow(Callee) of
            {ok, Uri, Flow} ->
                case chappe_sip:create_b2bua(Req, Res, Uri, #{flow => Flow}) of
                    {ok, Legs} -> chappe_sip_b2b:relay(Legs);
                    {error, _} -> chappe_sip_res:send(Res, 480)
                end;
            {error, _} ->
                chappe_sip_res:send(Res, 480)
        end
    end),
    Out = run_node(Config, "jssip_call.js",
                   [{"WS_URL", ws_url(WP)},
                    {"CALLER_URI", "sip:caller@127.0.0.1"},
                    {"CALLEE_URI", binary_to_list(Callee)},
                    {"TIMEOUT_MS", "20000"}]),
    ct:pal("jssip_call:~n~s", [Out]),
    match = re:run(Out, "RESULT established", [{capture, none}]),
    ok.

%% Kamailio pings chappe with OPTIONS (dispatcher); chappe answers 200 and
%% Kamailio marks the destination Active. Proves both wire directions:
%% Kamailio emits OPTIONS chappe parses, chappe emits 200 Kamailio accepts.
kamailio_options(Config) ->
    EP = pick(),
    Test = self(),
    ok = chappe_sip:start(#{contact => contact(EP)}),
    ok = chappe_sip:options(fun(_Req, Res) ->
        Test ! options_ping,
        _ = chappe_sip_res:send(Res, 200),
        ok
    end),
    Img = ?config(kam_image, Config),
    CN = ?config(kam_container, Config),
    DList = filename:join(?config(priv_dir, Config), "dispatcher.list"),
    ok = file:write_file(DList, io_lib:format(
           "1 sip:host.docker.internal:~w 0 0~n", [EP])),
    Cfg = filename:join([?config(interop_dir, Config),
                         "kamailio", "kamailio.cfg"]),
    _ = os:cmd(lists:flatten(io_lib:format(
          "docker run -d --name ~s "
          "--add-host=host.docker.internal:host-gateway "
          "-v ~s:/etc/kamailio/kamailio.cfg:ro "
          "-v ~s:/etc/kamailio/dispatcher.list:ro ~s >/dev/null 2>&1",
          [CN, shell_quote(Cfg), shell_quote(DList), Img]))),
    %% chappe must receive an OPTIONS ping from Kamailio.
    receive options_ping -> ok
    after 30000 -> ct:fail(no_options_from_kamailio) end,
    %% Kamailio must mark chappe Active (it accepted chappe's 200).
    true = poll_active(CN, 20),
    ok.

%% ---- helpers ----

run_node(Config, Script, Env) ->
    Node = ?config(node, Config),
    Dir = ?config(interop_dir, Config),
    Prefix = [K ++ "=" ++ shell_quote(V) ++ " " || {K, V} <- Env],
    Cmd = lists:flatten(["cd ", shell_quote(Dir), " && ", Prefix,
                         shell_quote(Node), " ", Script, " 2>&1"]),
    os:cmd(Cmd).

poll_present(_Aor, 0) -> ct:fail(no_binding);
poll_present(Aor, N) ->
    case chappe_sip:location(Aor) of
        [_ | _] -> ok;
        [] -> timer:sleep(100), poll_present(Aor, N - 1)
    end.

poll_active(_CN, 0) -> false;
poll_active(CN, N) ->
    Out = os:cmd("docker exec " ++ CN ++
                 " kamcmd -s unix:/tmp/kamailio_ctl dispatcher.list 2>/dev/null"),
    case re:run(Out, "FLAGS:\\s*A", [{capture, none}]) of
        match -> true;
        nomatch -> timer:sleep(1000), poll_active(CN, N - 1)
    end.

docker_image_ready(Img) ->
    case os:find_executable("docker") of
        false -> {skip, "docker not found on PATH"};
        _ ->
            case sh("docker info >/dev/null 2>&1 && echo ok") of
                "ok" ->
                    case sh("docker image inspect " ++ shell_quote(Img) ++
                            " >/dev/null 2>&1 && echo ok") of
                        "ok" -> ok;
                        _ -> {skip, "pull the Kamailio image first: docker pull "
                                    ++ Img}
                    end;
                _ -> {skip, "docker daemon not running"}
            end
    end.

sh(Cmd) -> string:trim(os:cmd(Cmd)).

shell_quote(S) ->
    "'" ++ lists:flatten(string:replace(S, "'", "'\\''", all)) ++ "'".

%% interop/ sits next to this suite's source (apps/chappe_sip/test), which
%% holds from the umbrella root as well as from the app directory.
interop_dir() ->
    case os:getenv("CHAPPE_SIP_INTEROP_DIR") of
        false ->
            Src = proplists:get_value(source, ?MODULE:module_info(compile)),
            filename:join(filename:dirname(filename:dirname(Src)),
                          "interop");
        D -> D
    end.

contact(Port) ->
    <<"sip:127.0.0.1:", (integer_to_binary(Port))/binary>>.

ws_url(Port) ->
    "ws://127.0.0.1:" ++ integer_to_list(Port) ++ "/ws".

pick() -> chappe_sip_test_port:pick().
