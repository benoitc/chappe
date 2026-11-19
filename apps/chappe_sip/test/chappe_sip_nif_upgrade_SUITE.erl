%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Upgrading the NIF library in place.
%%
%% A new version of chappe_sip_nif whose on_load loads another copy of the
%% shim is an upgrade: the BEAM calls the new image's upgrade callback with
%% the old image's private data. The new image must refuse while the old
%% one runs an engine, and once that engine is stopped it must come up on
%% its own: its resource type, atoms and sofia state, so a start, a request
%% and a stop work with the new code.
%%
%% The case runs in a peer node: it replaces chappe_sip_nif, which the
%% other suites (and cover) on this node keep using.
-module(chappe_sip_nif_upgrade_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([upgrade_after_stop/1]).
%% run in the peer
-export([upgrade_scenario/1]).

all() ->
    [upgrade_after_stop].

%% refused while an engine runs, accepted once it stopped, then the new
%% image starts an engine, answers a request and stops
upgrade_after_stop(Config) ->
    Dir = ?config(priv_dir, Config),
    Paths = lists:append([["-pa", P] || P <- code:get_path()]),
    {ok, Peer, _Node} = peer:start_link(#{connection => standard_io, args => Paths}),
    try
        ?assertEqual(ok, peer:call(Peer, ?MODULE, upgrade_scenario, [Dir], 60000))
    after
        peer:stop(Peer)
    end.

upgrade_scenario(Dir) ->
    {module, chappe_sip_nif} = code:ensure_loaded(chappe_sip_nif),
    Next = upgraded_module(copy_nif(Dir)),

    P0 = chappe_sip_test_port:pick(),
    {ok, E0} = chappe_sip_nif:start(#{contact => contact(P0)}, self()),
    ?assertEqual({error, on_load_failure}, load(Next)),
    %% the refused load left the running image in place
    ?assertEqual(ok, round_trip(E0, P0)),
    ok = chappe_sip_nif:stop(E0),

    ?assertEqual({module, chappe_sip_nif}, load(Next)),
    %% unloads the old image
    true = code:soft_purge(chappe_sip_nif),

    P1 = chappe_sip_test_port:pick(),
    {ok, E1} = chappe_sip_nif:start(#{contact => contact(P1)}, self()),
    ?assertEqual(ok, round_trip(E1, P1)),
    ?assertEqual(ok, chappe_sip_nif:stop(E1)),
    ok.

load(Bin) ->
    code:load_binary(chappe_sip_nif, "chappe_sip_nif_next.beam", Bin).

%% the built shim under another name, so the next load_nif opens a second
%% image of it rather than the one already loaded
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
