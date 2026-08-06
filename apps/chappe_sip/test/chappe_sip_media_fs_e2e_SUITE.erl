%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc chappe_sip_media FreeSWITCH backend end-to-end against a real FreeSWITCH.
%%
%% Opt-in: runs only when INTEROP=1 is set, so it stays out of the fast
%% `rebar3 ct' run. It brings up FreeSWITCH in docker (Event Socket reachable,
%% a minimal "enki_wait" dialplan) and drives the real ESL control path through
%% chappe_sip_media: connect + status roundtrip, then create a live channel and join
%% it to a conference with chappe_sip_media:conference/3, asserting membership on the
%% node.
%%
%% Prerequisites: docker running. The image (safarov/freeswitch by default,
%% override with FREESWITCH_IMAGE) is pulled on first `docker compose up'.
%%
%% Run: INTEROP=1 rebar3 ct --suite test/chappe_sip_media_fs_e2e_SUITE
-module(chappe_sip_media_fs_e2e_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([status_roundtrip/1, conference_join/1]).

-define(NODE, fs_e2e).
-define(ESL_PORT, 8021).

all() ->
    case os:getenv("INTEROP") of
        false -> {skip, "interop suite disabled; set INTEROP=1 to run"};
        _ -> [status_roundtrip, conference_join]
    end.

init_per_suite(Config) ->
    %% When FS_HOST is set, FreeSWITCH is already running (the containerised run
    %% starts it as a sibling service) and we just connect. Otherwise we bring
    %% the container up and down ourselves over the published port.
    case ensure_freeswitch() of
        {skip, _} = Skip ->
            Skip;
        {ok, Extra} ->
            application:set_env(chappe_sip, engine_mod, chappe_sip_engine_fake,
                                [{persistent, true}]),
            {ok, _} = application:ensure_all_started(chappe_sip),
            ok = chappe_sip_media:configure(
                #{freeswitch =>
                      #{nodes => [#{name => ?NODE, host => fs_host(),
                                    port => fs_port(),
                                    password => <<"ClueCon">>}]}}),
            case wait_esl(90) of
                {ok, Conn} ->
                    [{conn, Conn} | Extra] ++ Config;
                error ->
                    teardown(Extra),
                    ok = application:stop(chappe_sip),
                    {skip, "FreeSWITCH ESL did not become ready in time"}
            end
    end.

end_per_suite(Config) ->
    teardown(Config),
    _ = application:stop(chappe_sip),
    _ = application:stop(chappe_esl),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

ensure_freeswitch() ->
    case os:getenv("FS_HOST") of
        false ->
            case docker_ready() of
                {skip, _} = Skip ->
                    Skip;
                ok ->
                    File = compose_file(compose_dir()),
                    _ = sh("docker compose -f " ++ shell_quote(File) ++
                           " up -d 2>&1"),
                    {ok, [{compose, File}]}
            end;
        _Host ->
            {ok, []}
    end.

teardown(Config) ->
    case ?config(compose, Config) of
        undefined -> ok;
        File -> _ = compose_down(File)
    end,
    ok.

fs_host() ->
    case os:getenv("FS_HOST") of
        false -> "127.0.0.1";
        Host -> Host
    end.

fs_port() ->
    case os:getenv("FS_PORT") of
        false -> ?ESL_PORT;
        P -> list_to_integer(P)
    end.

%% ---- tests ----

status_roundtrip(Config) ->
    Conn = ?config(conn, Config),
    {ok, Body} = chappe_esl:api(Conn, "status"),
    ?assert(binary:match(Body, <<"UP">>) =/= nomatch).

conference_join(Config) ->
    Conn = ?config(conn, Config),
    Uuid = new_uuid(),
    Room = <<"enki-e2e-room">>,
    %% create a live, parked channel with a known uuid via a loopback originate
    Cmd = "originate {origination_uuid=" ++ binary_to_list(Uuid) ++
          "}loopback/enki_wait/default &park()",
    {ok, _Job} = chappe_esl:bgapi(Conn, Cmd),
    ?assert(poll_uuid_up(Conn, Uuid, 50)),
    %% join it to a conference through the facade, assert it shows up
    {ok, S} = chappe_sip_media:session(#{call_id => Uuid},
                                 #{capability => conference, node => ?NODE,
                                   uuid => Uuid}),
    ok = chappe_sip_media:conference(S, Room, #{}),
    ?assert(poll_member(Conn, Room, Uuid, 50)),
    %% cleanup the channel
    _ = chappe_esl:api(Conn, "uuid_kill " ++ binary_to_list(Uuid)),
    ok.

%% ---- helpers ----

new_uuid() ->
    binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).

wait_esl(0) ->
    error;
wait_esl(N) ->
    case chappe_sip_media_esl_mgr:conn(?NODE) of
        {ok, Conn} ->
            case chappe_esl:api(Conn, "status") of
                {ok, _} -> {ok, Conn};
                _ -> timer:sleep(1000), wait_esl(N - 1)
            end;
        {error, _} ->
            timer:sleep(1000), wait_esl(N - 1)
    end.

poll_uuid_up(_Conn, _Uuid, 0) ->
    false;
poll_uuid_up(Conn, Uuid, N) ->
    case chappe_esl:api(Conn, "uuid_exists " ++ binary_to_list(Uuid)) of
        {ok, <<"true", _/binary>>} -> true;
        _ -> timer:sleep(200), poll_uuid_up(Conn, Uuid, N - 1)
    end.

poll_member(_Conn, _Room, _Uuid, 0) ->
    false;
poll_member(Conn, Room, Uuid, N) ->
    Cmd = "conference " ++ binary_to_list(Room) ++ " list",
    case chappe_esl:api(Conn, Cmd) of
        {ok, Body} ->
            case binary:match(Body, Uuid) of
                nomatch -> timer:sleep(200), poll_member(Conn, Room, Uuid, N - 1);
                _ -> true
            end;
        _ ->
            timer:sleep(200), poll_member(Conn, Room, Uuid, N - 1)
    end.

compose_dir() ->
    case os:getenv("CHAPPE_SIP_INTEROP_DIR") of
        false ->
            Parts = filename:split(code:lib_dir(chappe_sip)),
            Root = filename:join(
                     lists:takewhile(fun(P) -> P =/= "_build" end, Parts)),
            filename:join([Root, "interop", "freeswitch"]);
        D ->
            filename:join(D, "freeswitch")
    end.

compose_file(Dir) ->
    filename:join(Dir, "docker-compose.yml").

compose_down(File) ->
    sh("docker compose -f " ++ shell_quote(File) ++ " down -v 2>&1").

docker_ready() ->
    case os:find_executable("docker") of
        false ->
            {skip, "docker not found on PATH"};
        _ ->
            case sh("docker info >/dev/null 2>&1 && echo ok") of
                "ok" -> ok;
                _ -> {skip, "docker daemon not running"}
            end
    end.

sh(Cmd) ->
    string:trim(os:cmd(Cmd)).

shell_quote(S) ->
    "'" ++ lists:flatten(string:replace(S, "'", "'\\''", all)) ++ "'".
