%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Client behavior against a fake rtpengine: correlation, retries,
%% timeouts, error and malformed replies, duplicate datagrams, and
%% the tcp/ws/wss transports.
-module(chappe_rtpengine_client_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    ping_pong/1,
    offer_answer_query_delete/1,
    node_error_reply/1,
    retransmit_recovers/1,
    request_timeout/1,
    malformed_reply/1,
    duplicate_reply_ignored/1,
    concurrent_requests_correlate/1,
    client_down/1,
    duplicate_request_served_from_cache/1,
    tcp_commands/1,
    tcp_split_reply_reassembled/1,
    tcp_close_fails_pending_then_reconnects/1,
    ws_commands/1,
    ws_subprotocol_rejection_fails_connect/1,
    ws_peer_close_fails_pending_then_reconnects/1,
    ws_deadline_timeout_no_retransmit/1,
    wss_commands/1
]).

all() ->
    [
        ping_pong,
        offer_answer_query_delete,
        node_error_reply,
        retransmit_recovers,
        request_timeout,
        malformed_reply,
        duplicate_reply_ignored,
        concurrent_requests_correlate,
        client_down,
        duplicate_request_served_from_cache,
        tcp_commands,
        tcp_split_reply_reassembled,
        tcp_close_fails_pending_then_reconnects,
        ws_commands,
        ws_subprotocol_rejection_fails_connect,
        ws_peer_close_fails_pending_then_reconnects,
        ws_deadline_timeout_no_retransmit,
        wss_commands
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(chappe_rtpengine),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_rtpengine).

init_per_testcase(client_down, Config) ->
    Config;
init_per_testcase(Case, Config) ->
    {ok, Server, Port} = start_fake(Case),
    Node = list_to_atom("chappe_rtpengine_test_" ++ atom_to_list(Case)),
    Opts = maps:merge(#{host => host(Case), port => Port}, opts(Case)),
    ok = chappe_rtpengine:add_node(Node, Opts),
    [{node, Node}, {server, Server}, {fake_port, Port} | Config].

start_fake(ws_subprotocol_rejection_fails_connect = Case) ->
    %% a server that completes the upgrade without granting any
    %% subprotocol
    chappe_rtpengine_fake_server:start_ws(handler(Case), #{subprotocols => none});
start_fake(Case) ->
    case transport_of(Case) of
        udp -> chappe_rtpengine_fake_server:start(handler(Case));
        tcp -> chappe_rtpengine_fake_server:start_tcp(handler(Case));
        ws -> chappe_rtpengine_fake_server:start_ws(handler(Case));
        wss -> chappe_rtpengine_fake_server:start_wss(handler(Case))
    end.

transport_of(Case) ->
    prefix_transport(atom_to_list(Case)).

prefix_transport("tcp_" ++ _) -> tcp;
prefix_transport("wss_" ++ _) -> wss;
prefix_transport("ws_" ++ _) -> ws;
prefix_transport(_) -> udp.

%% SNI must carry a name, not an address, so the wss cases dial by
%% hostname
host(Case) ->
    case transport_of(Case) of
        wss -> <<"localhost">>;
        _ -> {127, 0, 0, 1}
    end.

end_per_testcase(client_down, _Config) ->
    ok;
end_per_testcase(_Case, Config) ->
    _ = chappe_rtpengine:remove_node(?config(node, Config)),
    chappe_rtpengine_fake_server:stop(?config(server, Config)),
    ok.

%% per-case fake behavior

handler(node_error_reply) ->
    fun(_N, _Cmd) ->
        {reply, #{
            <<"result">> => <<"error">>,
            <<"error-reason">> => <<"Unknown call-id">>
        }}
    end;
handler(retransmit_recovers) ->
    %% drop the first two datagrams; the third attempt gets an answer
    fun
        (N, _Cmd) when N < 2 -> drop;
        (_N, Cmd) -> chappe_rtpengine_fake_server:default_handler(0, Cmd)
    end;
handler(request_timeout) ->
    fun(_N, _Cmd) -> drop end;
handler(malformed_reply) ->
    fun(_N, _Cmd) -> {reply_raw, <<"not bencode">>} end;
handler(duplicate_reply_ignored) ->
    fun(_N, _Cmd) -> {reply_dup, #{<<"result">> => <<"pong">>}} end;
handler(duplicate_request_served_from_cache) ->
    %% the reply carries the handler invocation count, so a cached
    %% reply is distinguishable from a fresh handler run
    fun(N, _Cmd) ->
        {reply, #{<<"result">> => <<"pong">>, <<"n">> => N}}
    end;
handler(tcp_split_reply_reassembled) ->
    fun(_N, _Cmd) -> {reply_split, #{<<"result">> => <<"pong">>}} end;
handler(tcp_close_fails_pending_then_reconnects) ->
    fun(_N, _Cmd) -> close end;
handler(ws_peer_close_fails_pending_then_reconnects) ->
    fun(_N, _Cmd) -> close end;
handler(ws_deadline_timeout_no_retransmit) ->
    fun(_N, _Cmd) -> drop end;
handler(_Case) ->
    fun chappe_rtpengine_fake_server:default_handler/2.

opts(retransmit_recovers) ->
    #{timeout => 100, attempts => 3};
opts(request_timeout) ->
    #{timeout => 100, attempts => 3};
opts(ws_deadline_timeout_no_retransmit) ->
    #{transport => ws, timeout => 100, attempts => 3};
opts(Case) ->
    case transport_of(Case) of
        udp -> #{};
        tcp -> #{transport => tcp};
        ws -> #{transport => ws};
        wss -> #{transport => wss, tls_opts => [{verify, verify_none}]}
    end.

sdp() ->
    <<
        "v=0\r\n"
        "o=- 1545997027 1 IN IP4 198.51.100.1\r\n"
        "s=call\r\n"
        "c=IN IP4 198.51.100.1\r\n"
        "t=0 0\r\n"
        "m=audio 30000 RTP/AVP 0 8 101\r\n"
        "a=rtpmap:0 PCMU/8000\r\n"
        "a=rtpmap:8 PCMA/8000\r\n"
        "a=rtpmap:101 telephone-event/8000\r\n"
        "a=sendrecv\r\n"
    >>.

%% cases

ping_pong(Config) ->
    Node = ?config(node, Config),
    {ok, Reply} = chappe_rtpengine:ping(Node),
    ?assertEqual(<<"pong">>, maps:get(<<"result">>, Reply)),
    #{sent := 1, replies := 1, retransmits := 0} = chappe_rtpengine:stats(Node),
    ok.

offer_answer_query_delete(Config) ->
    Node = ?config(node, Config),
    Server = ?config(server, Config),
    CallId = <<"call-1@test">>,
    FromTag = <<"from-tag-1">>,
    ToTag = <<"to-tag-1">>,

    {ok, OfferReply} = chappe_rtpengine:offer(Node, #{
        call_id => CallId,
        from_tag => FromTag,
        sdp => sdp(),
        ice => remove,
        flags => [trust_address]
    }),
    OfferSDP = chappe_rtpengine_ng:sdp(OfferReply),
    ?assertNotEqual(nomatch, binary:match(OfferSDP, <<"a=rtpengine:fake">>)),

    {ok, AnswerReply} = chappe_rtpengine:answer(Node, #{
        call_id => CallId,
        from_tag => FromTag,
        to_tag => ToTag,
        sdp => sdp()
    }),
    ?assertNotEqual(undefined, chappe_rtpengine_ng:sdp(AnswerReply)),

    {ok, QueryReply} = chappe_rtpengine:query(Node, #{call_id => CallId}),
    ?assertEqual(1700000000, maps:get(<<"created">>, QueryReply)),

    {ok, _} = chappe_rtpengine:delete(Node, #{
        call_id => CallId, from_tag => FromTag
    }),

    %% the fake saw the four commands, each with a distinct cookie, and
    %% the offer carried the mapped NG keys
    Received = chappe_rtpengine_fake_server:received(Server),
    Commands = [maps:get(<<"command">>, Cmd) || {_Cookie, Cmd} <- Received],
    ?assertEqual(
        [<<"offer">>, <<"answer">>, <<"query">>, <<"delete">>], Commands
    ),
    Cookies = [Cookie || {Cookie, _} <- Received],
    ?assertEqual(4, length(lists:usort(Cookies))),
    {_, Offer} = hd(Received),
    ?assertEqual(<<"remove">>, maps:get(<<"ICE">>, Offer)),
    ?assertEqual([<<"trust-address">>], maps:get(<<"flags">>, Offer)),
    ok.

node_error_reply(Config) ->
    Node = ?config(node, Config),
    {error, <<"Unknown call-id">>, _} =
        chappe_rtpengine:query(Node, #{call_id => <<"nope">>}),
    ok.

retransmit_recovers(Config) ->
    Node = ?config(node, Config),
    Server = ?config(server, Config),
    {ok, _} = chappe_rtpengine:ping(Node),
    %% all three datagrams carried the same cookie (idempotent retry)
    Received = chappe_rtpengine_fake_server:received(Server),
    ?assertEqual(3, length(Received)),
    ?assertEqual(1, length(lists:usort([C || {C, _} <- Received]))),
    #{retransmits := 2, replies := 1, timeouts := 0} =
        chappe_rtpengine:stats(Node),
    ok.

request_timeout(Config) ->
    Node = ?config(node, Config),
    Server = ?config(server, Config),
    T0 = erlang:monotonic_time(millisecond),
    {error, timeout} = chappe_rtpengine:ping(Node),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ?assert(Elapsed >= 300),
    ?assertEqual(3, length(chappe_rtpengine_fake_server:received(Server))),
    #{timeouts := 1, retransmits := 2} = chappe_rtpengine:stats(Node),
    ok.

malformed_reply(Config) ->
    Node = ?config(node, Config),
    {error, {bad_reply, <<"not bencode">>}} = chappe_rtpengine:ping(Node),
    ok.

duplicate_reply_ignored(Config) ->
    Node = ?config(node, Config),
    {ok, _} = chappe_rtpengine:ping(Node),
    %% second copy of the reply hits an already-satisfied cookie; the
    %% client drops it and keeps serving
    wait_until(fun() ->
        maps:get(unknown_cookies, chappe_rtpengine:stats(Node)) =:= 1
    end),
    {ok, _} = chappe_rtpengine:ping(Node),
    ok.

concurrent_requests_correlate(Config) ->
    Node = ?config(node, Config),
    Parent = self(),
    Pids = [
        spawn_link(fun() ->
            CallId = <<"call-", (integer_to_binary(I))/binary>>,
            {ok, Reply} = chappe_rtpengine:offer(Node, #{
                call_id => CallId,
                from_tag => <<"ft">>,
                sdp => sdp()
            }),
            %% each caller must get the reply for its own call-id
            CallId = maps:get(<<"call-id-echo">>, Reply),
            Parent ! {done, self()}
        end)
     || I <- lists:seq(1, 20)
    ],
    [
        receive
            {done, Pid} -> ok
        after 5000 -> error({worker_timeout, Pid})
        end
     || Pid <- Pids
    ],
    ok.

client_down(_Config) ->
    {error, client_down} = chappe_rtpengine:ping(chappe_rtpengine_no_such_node),
    ok.

%% rtpengine serves duplicate cookies from its reply cache without
%% reprocessing; the fake models that. A byte-identical retransmit
%% must yield the original reply, and a fresh cookie a fresh one.
duplicate_request_served_from_cache(Config) ->
    Port = ?config(fake_port, Config),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}]),
    Body = chappe_rtpengine_bencode:encode_to_binary(#{<<"command">> => <<"ping">>}),
    Datagram = <<"cache-cookie-1 ", Body/binary>>,

    ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, Datagram),
    ?assertEqual(0, reply_n(Sock)),
    %% same cookie again: cached reply, handler not re-invoked
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, Datagram),
    ?assertEqual(0, reply_n(Sock)),
    %% a new cookie reaches the handler
    ok = gen_udp:send(
        Sock, {127, 0, 0, 1}, Port, <<"cache-cookie-2 ", Body/binary>>
    ),
    ?assertEqual(1, reply_n(Sock)),
    gen_udp:close(Sock),
    ok.

reply_n(Sock) ->
    receive
        {udp, Sock, _IP, _Port, Packet} ->
            [_Cookie, ReplyBody] = binary:split(Packet, <<" ">>),
            {ok, Reply} = chappe_rtpengine_bencode:decode(ReplyBody),
            maps:get(<<"n">>, Reply)
    after 2000 -> error(no_reply)
    end.

tcp_commands(Config) ->
    Node = ?config(node, Config),
    Server = ?config(server, Config),
    {ok, #{<<"result">> := <<"pong">>}} = chappe_rtpengine:ping(Node),
    CallId = <<"tcp-call-1">>,
    {ok, OfferReply} = chappe_rtpengine:offer(Node, #{
        call_id => CallId, from_tag => <<"ft">>, sdp => sdp()
    }),
    ?assertNotEqual(
        nomatch,
        binary:match(chappe_rtpengine_ng:sdp(OfferReply), <<"a=rtpengine:fake">>)
    ),
    {ok, _} = chappe_rtpengine:query(Node, #{call_id => CallId}),
    {ok, _} = chappe_rtpengine:delete(Node, #{
        call_id => CallId, from_tag => <<"ft">>
    }),
    Commands = [
        maps:get(<<"command">>, Cmd)
     || {_, Cmd} <- chappe_rtpengine_fake_server:received(Server)
    ],
    ?assertEqual(
        [<<"ping">>, <<"offer">>, <<"query">>, <<"delete">>], Commands
    ),
    #{replies := 4, retransmits := 0} = chappe_rtpengine:stats(Node),
    ok.

tcp_split_reply_reassembled(Config) ->
    Node = ?config(node, Config),
    %% the reply arrives in two TCP chunks; the stream parser buffers
    %% until the bencode document is complete
    {ok, #{<<"result">> := <<"pong">>}} = chappe_rtpengine:ping(Node),
    ok.

tcp_close_fails_pending_then_reconnects(Config) ->
    Node = ?config(node, Config),
    Server = ?config(server, Config),
    %% the fake closes the connection on the first request
    {error, closed} = chappe_rtpengine:ping(Node),
    %% while disconnected, requests fail fast
    {error, {send_failed, not_connected}} = chappe_rtpengine:ping(Node),
    %% after the reconnect interval the client is back
    chappe_rtpengine_fake_server:set_handler(
        Server, fun chappe_rtpengine_fake_server:default_handler/2
    ),
    wait_until(
        fun() ->
            case chappe_rtpengine:ping(Node) of
                {ok, _} -> true;
                _ -> false
            end
        end,
        200
    ),
    #{reconnects := Reconnects} = chappe_rtpengine:stats(Node),
    ?assert(Reconnects >= 1),
    ok.

ws_commands(Config) ->
    Node = ?config(node, Config),
    Server = ?config(server, Config),
    {ok, #{<<"result">> := <<"pong">>}} = chappe_rtpengine:ping(Node),
    CallId = <<"ws-call-1">>,
    {ok, OfferReply} = chappe_rtpengine:offer(Node, #{
        call_id => CallId, from_tag => <<"ft">>, sdp => sdp()
    }),
    ?assertNotEqual(
        nomatch,
        binary:match(chappe_rtpengine_ng:sdp(OfferReply), <<"a=rtpengine:fake">>)
    ),
    {ok, _} = chappe_rtpengine:query(Node, #{call_id => CallId}),
    {ok, _} = chappe_rtpengine:delete(Node, #{
        call_id => CallId, from_tag => <<"ft">>
    }),
    Commands = [
        maps:get(<<"command">>, Cmd)
     || {_, Cmd} <- chappe_rtpengine_fake_server:received(Server)
    ],
    ?assertEqual(
        [<<"ping">>, <<"offer">>, <<"query">>, <<"delete">>], Commands
    ),
    #{replies := 4, retransmits := 0} = chappe_rtpengine:stats(Node),
    ok.

ws_subprotocol_rejection_fails_connect(Config) ->
    Node = ?config(node, Config),
    %% the server never granted ng.rtpengine.com, so the connect
    %% failed closed and the client never became connected
    {error, {send_failed, not_connected}} = chappe_rtpengine:ping(Node),
    ok.

ws_peer_close_fails_pending_then_reconnects(Config) ->
    Node = ?config(node, Config),
    Server = ?config(server, Config),
    %% the fake closes the connection on the first request
    {error, closed} = chappe_rtpengine:ping(Node),
    %% while disconnected, requests fail fast
    {error, {send_failed, not_connected}} = chappe_rtpengine:ping(Node),
    %% after the reconnect interval the client is back
    chappe_rtpengine_fake_server:set_handler(
        Server, fun chappe_rtpengine_fake_server:default_handler/2
    ),
    wait_until(
        fun() ->
            case chappe_rtpengine:ping(Node) of
                {ok, _} -> true;
                _ -> false
            end
        end,
        200
    ),
    #{reconnects := Reconnects} = chappe_rtpengine:stats(Node),
    ?assert(Reconnects >= 1),
    ok.

ws_deadline_timeout_no_retransmit(Config) ->
    Node = ?config(node, Config),
    Server = ?config(server, Config),
    T0 = erlang:monotonic_time(millisecond),
    {error, timeout} = chappe_rtpengine:ping(Node),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    %% the deadline is still attempts * timeout, but nothing is resent
    ?assert(Elapsed >= 300),
    ?assertEqual(1, length(chappe_rtpengine_fake_server:received(Server))),
    #{timeouts := 1, retransmits := 0} = chappe_rtpengine:stats(Node),
    ok.

wss_commands(Config) ->
    Node = ?config(node, Config),
    {ok, #{<<"result">> := <<"pong">>}} = chappe_rtpengine:ping(Node),
    {ok, OfferReply} = chappe_rtpengine:offer(Node, #{
        call_id => <<"wss-call-1">>, from_tag => <<"ft">>, sdp => sdp()
    }),
    ?assertNotEqual(
        nomatch,
        binary:match(chappe_rtpengine_ng:sdp(OfferReply), <<"a=rtpengine:fake">>)
    ),
    {ok, _} = chappe_rtpengine:delete(Node, #{
        call_id => <<"wss-call-1">>, from_tag => <<"ft">>
    }),
    #{replies := 3, retransmits := 0} = chappe_rtpengine:stats(Node),
    ok.

wait_until(Fun) ->
    wait_until(Fun, 50).

wait_until(_Fun, 0) ->
    error(wait_until_timeout);
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_until(Fun, N - 1)
    end.
