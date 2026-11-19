%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Replacing the NIF library.
%%
%% A new version of chappe_sip_nif loaded while the old code still holds
%% the shim is an in-place upgrade, which the shim always refuses: the load
%% fails and the old code stays, with or without a running engine. The way
%% to replace the library is to stop the engine, delete and purge the
%% module, then load the new one, which then starts an engine, answers a
%% request and stops.
%%
%% The case runs in a peer node: it replaces chappe_sip_nif, which the
%% other suites (and cover) on this node keep using.
-module(chappe_sip_nif_upgrade_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    replace_after_purge/1,
    owner_death_after_purge/1,
    same_path_reload/1,
    replace_refused_while_running/1
]).
%% run in the peer
-export([
    replace_scenario/1,
    owner_death_scenario/0,
    same_path_scenario/0,
    replace_refused_scenario/0
]).

all() ->
    [
        replace_after_purge,
        owner_death_after_purge,
        same_path_reload,
        replace_refused_while_running
    ].

%% an upgrade is refused with and without a running engine; stop, delete,
%% purge and load gives a working new library
replace_after_purge(Config) ->
    in_peer(replace_scenario, [?config(priv_dir, Config)]).

%% the owner of an engine dies after the module was purged: the last
%% reference to the engine goes, and with it the library, which must not
%% be closed under the stack thread still returning through it
owner_death_after_purge(_Config) ->
    in_peer(owner_death_scenario, []).

%% replace/0 loads the same library file again while an engine of the old
%% instance is still referenced, which shares the old instance's statics:
%% the old instance's unload, once that engine goes, must leave them (the
%% blocklist lock, sofia) to the new one
same_path_reload(_Config) ->
    in_peer(same_path_scenario, []).

%% replace/0 refuses while an engine runs, then works once it stopped
replace_refused_while_running(_Config) ->
    in_peer(replace_refused_scenario, []).

in_peer(F, Args) ->
    Paths = lists:append([["-pa", P] || P <- code:get_path()]),
    {ok, Peer, _Node} = peer:start_link(#{connection => standard_io, args => Paths}),
    try
        ?assertEqual(ok, peer:call(Peer, ?MODULE, F, Args, 60000))
    after
        peer:stop(Peer)
    end.

replace_scenario(Dir) ->
    {module, chappe_sip_nif} = code:ensure_loaded(chappe_sip_nif),
    Next = upgraded_module(copy_nif(Dir)),

    %% no engine: an upgrade is still refused
    ?assertEqual({error, on_load_failure}, load(Next)),

    P0 = chappe_sip_test_port:pick(),
    {ok, E0} = chappe_sip_nif:start(#{contact => contact(P0)}, self()),
    ?assertEqual({error, on_load_failure}, load(Next)),
    %% the refused load left the running library in place
    ?assertEqual(ok, round_trip(E0, P0)),
    ok = chappe_sip_nif:stop(E0),

    %% stop, delete, purge (unloads the old library), then load
    true = code:delete(chappe_sip_nif),
    true = code:soft_purge(chappe_sip_nif),
    ?assertEqual({module, chappe_sip_nif}, load(Next)),

    P1 = chappe_sip_test_port:pick(),
    {ok, E1} = chappe_sip_nif:start(#{contact => contact(P1)}, self()),
    ?assertEqual(ok, round_trip(E1, P1)),
    ?assertEqual(ok, chappe_sip_nif:stop(E1)),
    ok.

owner_death_scenario() ->
    {module, chappe_sip_nif} = code:ensure_loaded(chappe_sip_nif),
    {Owner, P} = engine_holder(running),
    true = code:delete(chappe_sip_nif),
    true = code:soft_purge(chappe_sip_nif),
    exit(Owner, kill),
    %% the stop runs on the engine's own threads; give it time to finish
    timer:sleep(1000),
    {module, chappe_sip_nif} = code:load_file(chappe_sip_nif),
    ?assertEqual(ok, wait_start_ok(P, 50)).

same_path_scenario() ->
    {module, chappe_sip_nif} = code:ensure_loaded(chappe_sip_nif),
    {Holder, _} = engine_holder(stopped),
    %% the documented way, the same files
    ?assertEqual({module, chappe_sip_nif}, chappe_sip_nif:replace()),
    ?assertEqual(none, chappe_sip_nif:engine_state()),
    %% the old instance's engine goes, and its unload runs
    exit(Holder, kill),
    timer:sleep(500),
    ok = chappe_sip_nif:block(<<"127.0.0.1">>, 60000),
    P = chappe_sip_test_port:pick(),
    {ok, E} = chappe_sip_nif:start(#{contact => contact(P)}, self()),
    #{discarded := D0} = chappe_sip_nif:stats(),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    {ok, Local} = inet:port(Sock),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, P, options_msg(Local)),
    receive
        {chappe_sip_engine, E, {request, _, _, _, _}} -> error(not_blocked)
    after 1000 -> ok
    end,
    #{discarded := D1} = chappe_sip_nif:stats(),
    ?assert(D1 > D0),
    gen_udp:close(Sock),
    ?assertEqual(ok, chappe_sip_nif:stop(E)).

replace_refused_scenario() ->
    {module, chappe_sip_nif} = code:ensure_loaded(chappe_sip_nif),
    P = chappe_sip_test_port:pick(),
    {ok, E} = chappe_sip_nif:start(#{contact => contact(P)}, self()),
    ?assertEqual(running, chappe_sip_nif:engine_state()),
    ?assertEqual({error, running}, chappe_sip_nif:replace()),
    %% still the same module and library
    ?assertEqual(ok, round_trip(E, P)),
    ok = chappe_sip_nif:stop(E),
    ?assertEqual(none, chappe_sip_nif:engine_state()),
    ?assertEqual({module, chappe_sip_nif}, chappe_sip_nif:replace()),
    P1 = chappe_sip_test_port:pick(),
    {ok, E1} = chappe_sip_nif:start(#{contact => contact(P1)}, self()),
    ?assertEqual(ok, round_trip(E1, P1)),
    ?assertEqual(ok, chappe_sip_nif:stop(E1)).

%% a process that owns an engine and keeps its reference, running or
%% stopped
engine_holder(How) ->
    Self = self(),
    P = chappe_sip_test_port:pick(),
    Pid = spawn(fun() ->
        {ok, E} = chappe_sip_nif:start(#{contact => contact(P)}, self()),
        case How of
            running -> ok;
            stopped -> ok = chappe_sip_nif:stop(E)
        end,
        Self ! {holding, self()},
        receive
            never -> E
        end
    end),
    receive
        {holding, Pid} -> {Pid, P}
    after 10000 -> error(no_holder)
    end.

%% a start after the dead owner's engine stopped: the singleton is free
%% once its stack thread is done
wait_start_ok(_P, 0) ->
    error(start_refused);
wait_start_ok(P, N) ->
    case chappe_sip_nif:start(#{contact => contact(P)}, self()) of
        {ok, E} ->
            ok = round_trip(E, P),
            chappe_sip_nif:stop(E);
        {error, stopping} ->
            timer:sleep(100),
            wait_start_ok(P, N - 1)
    end.

load(Bin) ->
    code:load_binary(chappe_sip_nif, "chappe_sip_nif_next.beam", Bin).

%% the built shim under another name, as a release ships a new library
copy_nif(Dir) ->
    Src = filename:join([code:priv_dir(chappe_sip), "lib", "chappe_sip_engine_nif.so"]),
    Base = filename:join(Dir, "chappe_sip_engine_nif_next"),
    {ok, _} = file:copy(Src, Base ++ ".so"),
    Base.

%% chappe_sip_nif with on_load pointed at Path
upgraded_module(Path) ->
    Beam = code:which(chappe_sip_nif),
    {ok, {_, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(Beam, [abstract_code]),
    Src = lists:flatten(io_lib:format("init() -> erlang:load_nif(~p, 0).", [Path])),
    {ok, Toks, _} = erl_scan:string(Src),
    {ok, Init} = erl_parse:parse_form(Toks),
    Forms1 = [
        case F of
            {function, _, init, 0, _} -> Init;
            _ -> F
        end
     || F <- Forms
    ],
    {ok, chappe_sip_nif, Bin} = compile:forms(Forms1, [binary, return_errors]),
    Bin.

%% an OPTIONS from a UDP socket, answered 200 through the engine
round_trip(E, Port) ->
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    {ok, Local} = inet:port(Sock),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, options_msg(Local)),
    Txn =
        receive
            {chappe_sip_engine, E, {request, T, _, _, <<"OPTIONS ", _/binary>>}} -> T
        after 5000 -> error(no_request)
        end,
    ok = chappe_sip_nif:respond(E, Txn, 200, <<"OK">>, <<>>, <<>>, <<>>),
    receive
        {udp, Sock, _, _, <<"SIP/2.0 200 OK", _/binary>>} ->
            gen_udp:close(Sock)
    after 5000 -> error(no_response)
    end.

contact(Port) ->
    <<"sip:127.0.0.1:", (integer_to_binary(Port))/binary>>.

options_msg(Local) ->
    P = integer_to_binary(Local),
    <<
        "OPTIONS sip:up@127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/UDP 127.0.0.1:",
        P/binary,
        ";rport;branch=z9hG4bKup",
        P/binary,
        "\r\n"
        "Max-Forwards: 70\r\n"
        "From: <sip:ct@127.0.0.1>;tag=up\r\n"
        "To: <sip:up@127.0.0.1>\r\n"
        "Call-ID: up-",
        P/binary,
        "@127.0.0.1\r\n"
        "CSeq: 1 OPTIONS\r\n"
        "Content-Length: 0\r\n\r\n"
    >>.
