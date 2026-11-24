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
    forged_source_ignored/1,
    ping_pong/1,
    list_and_statistics/1,
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
    ws_frame_with_upgrade_response/1,
    ws_subprotocol_rejection_fails_connect/1,
    ws_peer_close_fails_pending_then_reconnects/1,
    ws_deadline_timeout_no_retransmit/1,
    wss_commands/1,
    warning_kept_in_reply/1,
    load_limit_reply/1,
    bad_param_is_an_error/1,
    udp_large_request/1,
    udp_too_large_refused/1,
    udp_emsgsize_is_too_large/1,
    tcp_large_reply_reassembled/1,
    tcp_oversized_length_drops_connection/1,
    tcp_runaway_cookie_drops_connection/1,
    tcp_unresolved_host_retries/1,
    ws_text_frame_reply/1,
    udp_resolve_interval_follows_move/1,
    udp_timeouts_re_resolve/1
]).

all() ->
    [
        forged_source_ignored,
        ping_pong,
        list_and_statistics,
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
        ws_frame_with_upgrade_response,
        ws_subprotocol_rejection_fails_connect,
        ws_peer_close_fails_pending_then_reconnects,
        ws_deadline_timeout_no_retransmit,
        wss_commands,
        warning_kept_in_reply,
        load_limit_reply,
        bad_param_is_an_error,
        udp_large_request,
        udp_too_large_refused,
        udp_emsgsize_is_too_large,
        tcp_large_reply_reassembled,
        tcp_oversized_length_drops_connection,
        tcp_runaway_cookie_drops_connection,
        tcp_unresolved_host_retries,
        ws_text_frame_reply,
        udp_resolve_interval_follows_move,
        udp_timeouts_re_resolve
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(chappe_rtpengine),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_rtpengine).

init_per_testcase(client_down, Config) ->
    Config;
init_per_testcase(Case, Config) when
    Case =:= udp_resolve_interval_follows_move;
    Case =:= udp_timeouts_re_resolve
->
    %% two fakes on one port at two addresses; the node name resolves
    %% to whichever address the test stores
    {ok, A, Port} = chappe_rtpengine_fake_server:start_at(
        handler(Case), {127, 0, 0, 1}, 0
    ),
    case second_fake(Port) of
        {ok, B, IPB} ->
            persistent_term:put({?MODULE, addr}, {127, 0, 0, 1}),
            Resolver = fun(<<"rtpengine.test">>) ->
                {ok, persistent_term:get({?MODULE, addr})}
            end,
            Node = list_to_atom("chappe_rtpengine_test_" ++ atom_to_list(Case)),
            Opts = maps:merge(
                #{
                    host => <<"rtpengine.test">>,
                    port => Port,
                    resolver => Resolver
                },
                opts(Case)
            ),
            ok = chappe_rtpengine:add_node(Node, Opts),
            [{node, Node}, {server, A}, {server_b, B}, {ip_b, IPB} | Config];
        error ->
            chappe_rtpengine_fake_server:stop(A),
            {skip, no_second_loopback_address}
    end;
init_per_testcase(forged_source_ignored, Config) ->
    %% the test plays rtpengine itself on a socket it owns
    {ok, Sock} = gen_udp:open(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Sock),
    Node = chappe_rtpengine_test_forged_source_ignored,
    ok = chappe_rtpengine:add_node(Node, #{
        host => {127, 0, 0, 1}, port => Port, timeout => 2000, attempts => 1
    }),
    [{node, Node}, {sock, Sock} | Config];
init_per_testcase(ws_frame_with_upgrade_response, Config) ->
    %% the test plays the server itself: the fake cannot glue a frame to
    %% its 101
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {packet, raw}]),
    {ok, Port} = inet:port(Listen),
    Self = self(),
    spawn_link(fun() -> upgrade_with_frame(Listen, Self) end),
    Node = chappe_rtpengine_test_ws_frame_with_upgrade_response,
    ok = chappe_rtpengine:add_node(Node, #{
        host => {127, 0, 0, 1}, port => Port, transport => ws
    }),
    [{node, Node}, {listen, Listen} | Config];
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
prefix_transport("udp_" ++ _) -> udp;
prefix_transport("wss_" ++ _) -> wss;
prefix_transport("ws_" ++ _) -> ws;
prefix_transport(_) -> udp.

%% 127.0.0.2 answers on Linux; macOS only configures 127.0.0.1, so
%% fall back to the IPv6 loopback (which also moves the node across
%% address families).
second_fake(Port) ->
    second_fake(Port, [{127, 0, 0, 2}, {0, 0, 0, 0, 0, 0, 0, 1}]).

second_fake(_Port, []) ->
    error;
second_fake(Port, [IP | Rest]) ->
    Handler = fun chappe_rtpengine_fake_server:default_handler/2,
    case chappe_rtpengine_fake_server:start_at(Handler, IP, Port) of
        {ok, Pid, Port} -> {ok, Pid, IP};
        {error, _} -> second_fake(Port, Rest)
    end.

%% SNI must carry a name, not an address, so the wss cases dial by
%% hostname
host(tcp_unresolved_host_retries) ->
    <<"chappe-no-such-host.invalid">>;
host(Case) ->
    case transport_of(Case) of
        wss -> <<"localhost">>;
        _ -> {127, 0, 0, 1}
    end.

end_per_testcase(client_down, _Config) ->
    ok;
end_per_testcase(Case, Config) when
    Case =:= udp_resolve_interval_follows_move;
    Case =:= udp_timeouts_re_resolve
->
    chappe_rtpengine_fake_server:stop(?config(server_b, Config)),
    _ = persistent_term:erase({?MODULE, addr}),
    end_per_testcase(default, Config);
end_per_testcase(forged_source_ignored, Config) ->
    _ = chappe_rtpengine:remove_node(?config(node, Config)),
    gen_udp:close(?config(sock, Config));
end_per_testcase(ws_frame_with_upgrade_response, Config) ->
    _ = chappe_rtpengine:remove_node(?config(node, Config)),
    gen_tcp:close(?config(listen, Config));
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
handler(warning_kept_in_reply) ->
    fun(_N, _Cmd) ->
        {reply, #{
            <<"result">> => <<"ok">>,
            <<"warning">> => <<"Unknown flag ignored">>
        }}
    end;
handler(load_limit_reply) ->
    fun(_N, _Cmd) ->
        {reply, #{
            <<"result">> => <<"load limit">>,
            <<"message">> => <<"Parallel session limit reached">>
        }}
    end;
handler(tcp_oversized_length_drops_connection) ->
    %% a reply announcing a 5 MB string, beyond the 4 MiB stream cap
    fun(_N, _Cmd) -> {reply_raw, <<"d3:sdp5000000:v=0">>} end;
handler(tcp_runaway_cookie_drops_connection) ->
    %% bytes that never contain the cookie separator
    fun(_N, _Cmd) -> {raw, binary:copy(<<"x">>, 4096)} end;
handler(udp_timeouts_re_resolve) ->
    %% the old address went silent
    fun(_N, _Cmd) -> drop end;
handler(ws_text_frame_reply) ->
    fun(_N, _Cmd) -> {reply_text, #{<<"result">> => <<"pong">>}} end;
handler(_Case) ->
    fun chappe_rtpengine_fake_server:default_handler/2.

opts(retransmit_recovers) ->
    #{timeout => 100, attempts => 3};
opts(request_timeout) ->
    #{timeout => 100, attempts => 3};
opts(ws_deadline_timeout_no_retransmit) ->
    #{transport => ws, timeout => 100, attempts => 3};
opts(udp_resolve_interval_follows_move) ->
    #{resolve_interval_ms => 100, resolve_after_timeouts => 100};
opts(udp_timeouts_re_resolve) ->
    #{
        resolve_interval_ms => infinity,
        resolve_after_timeouts => 2,
        timeout => 50,
        attempts => 2
    };
opts(udp_too_large_refused) ->
    #{max_datagram => 1000};
opts(udp_emsgsize_is_too_large) ->
    %% above what IPv4 can carry: the socket refuses the send
    #{max_datagram => 100000};
opts(tcp_oversized_length_drops_connection) ->
    #{transport => tcp, timeout => 2000, attempts => 1};
opts(tcp_runaway_cookie_drops_connection) ->
    #{transport => tcp, timeout => 2000, attempts => 1};
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

%% req: RNG-01
ping_pong(Config) ->
    Node = ?config(node, Config),
    {ok, Reply} = chappe_rtpengine:ping(Node),
    ?assertEqual(<<"pong">>, maps:get(<<"result">>, Reply)),
    #{sent := 1, replies := 1, retransmits := 0} = chappe_rtpengine:stats(Node),
    ok.

%% req: RNG-01 RNG-04 RNG-10
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

%% list/1,2 return the call-ids (limit on the wire), statistics/1 the
%% statistics dictionary; a bad limit is refused before anything is sent.
list_and_statistics(Config) ->
    Node = ?config(node, Config),
    Server = ?config(server, Config),
    ?assertEqual(
        {ok, [<<"c1">>, <<"c2">>, <<"c3">>]}, chappe_rtpengine:list(Node)
    ),
    ?assertEqual({ok, [<<"c1">>]}, chappe_rtpengine:list(Node, #{limit => 1})),
    ?assertEqual(
        {ok, #{<<"currentstatistics">> => #{<<"sessionstotal">> => 3}}},
        chappe_rtpengine:statistics(Node)
    ),
    ?assertEqual(
        {error, {bad_option, limit}}, chappe_rtpengine:list(Node, #{limit => 0})
    ),
    [{_, L1}, {_, L2}, {_, St}] = chappe_rtpengine_fake_server:received(Server),
    ?assertEqual(#{<<"command">> => <<"list">>}, L1),
    ?assertEqual(#{<<"command">> => <<"list">>, <<"limit">> => 1}, L2),
    ?assertEqual(#{<<"command">> => <<"statistics">>}, St),
    ok.

%% req: RNG-07
node_error_reply(Config) ->
    Node = ?config(node, Config),
    {error, <<"Unknown call-id">>, _} =
        chappe_rtpengine:query(Node, #{call_id => <<"nope">>}),
    ok.

%% req: RNG-05
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

%% req: RNG-05
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

%% req: RNG-07
malformed_reply(Config) ->
    Node = ?config(node, Config),
    {error, {bad_reply, <<"not bencode">>}} = chappe_rtpengine:ping(Node),
    ok.

%% a reply with the right cookie from any other address or port is not
%% rtpengine's: it is dropped, and the real reply still wins
forged_source_ignored(Config) ->
    Node = ?config(node, Config),
    Sock = ?config(sock, Config),
    Self = self(),
    spawn_link(fun() -> Self ! {pinged, chappe_rtpengine:ping(Node)} end),
    {ok, {IP, CPort, Req}} = gen_udp:recv(Sock, 0, 2000),
    [Cookie, _] = binary:split(Req, <<" ">>),
    {ok, Forger} = gen_udp:open(0, [binary, {ip, {127, 0, 0, 1}}]),
    Forged = <<Cookie/binary, " d6:result5:error12:error-reason6:forgede">>,
    ok = gen_udp:send(Forger, IP, CPort, Forged),
    wait_until(fun() ->
        maps:get(bad_sources, chappe_rtpengine:stats(Node), 0) =:= 1
    end),
    ok = gen_udp:send(Sock, IP, CPort, <<Cookie/binary, " d6:result4:ponge">>),
    receive
        {pinged, Result} -> {ok, _} = Result
    after 3000 -> error(no_reply)
    end,
    gen_udp:close(Forger),
    ok.

%% req: RNG-04
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

%% req: RNG-04
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
%% req: RNG-05
duplicate_request_served_from_cache(Config) ->
    Port = ?config(fake_port, Config),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}]),
    Body = chappe_rtpengine_bencode:encode_to_binary(#{
        <<"command">> => <<"ping">>
    }),
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

%% req: RNG-02 RNG-06
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
        binary:match(
            chappe_rtpengine_ng:sdp(OfferReply), <<"a=rtpengine:fake">>
        )
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

%% req: RNG-02
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

%% A frame the server sends in the same write as its 101 still reaches the
%% client: erlang_ws before 0.5.0 lost it. Its cookie is unknown, so the
%% stats show it arrived.
ws_frame_with_upgrade_response(Config) ->
    Node = ?config(node, Config),
    wait_until(
        fun() ->
            #{unknown_cookies := N} = chappe_rtpengine:stats(Node),
            N =:= 1
        end,
        100
    ).

upgrade_with_frame(Listen, Parent) ->
    {ok, Sock} = gen_tcp:accept(Listen),
    {ok, Req} = gen_tcp:recv(Sock, 0, 5000),
    {match, [Key]} = re:run(
        Req,
        "sec-websocket-key: *([^\\r]+)",
        [caseless, {capture, all_but_first, binary}]
    ),
    Accept = base64:encode(
        crypto:hash(sha, <<Key/binary, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>)
    ),
    Reply = <<"stale d6:result4:ponge">>,
    ok = gen_tcp:send(Sock, [
        <<"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n">>,
        <<"Connection: Upgrade\r\nSec-WebSocket-Accept: ">>,
        Accept,
        <<"\r\nSec-WebSocket-Protocol: ng.rtpengine.com\r\n\r\n">>,
        <<1:1, 0:3, 2:4, 0:1, (byte_size(Reply)):7>>,
        Reply
    ]),
    Mon = monitor(process, Parent),
    receive
        {'DOWN', Mon, process, Parent, _} -> gen_tcp:close(Sock)
    end.

%% req: RNG-01
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
        binary:match(
            chappe_rtpengine_ng:sdp(OfferReply), <<"a=rtpengine:fake">>
        )
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

%% req: RNG-06
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
        binary:match(
            chappe_rtpengine_ng:sdp(OfferReply), <<"a=rtpengine:fake">>
        )
    ),
    {ok, _} = chappe_rtpengine:delete(Node, #{
        call_id => <<"wss-call-1">>, from_tag => <<"ft">>
    }),
    #{replies := 3, retransmits := 0} = chappe_rtpengine:stats(Node),
    ok.

sdp_of_size(Size) ->
    Head = sdp(),
    Pad = Size - byte_size(Head),
    Line = <<"a=x-pad:", (binary:copy(<<"p">>, 60))/binary, "\r\n">>,
    Lines = binary:copy(Line, Pad div byte_size(Line) + 1),
    <<Head/binary, (binary:part(Lines, 0, Pad))/binary>>.

%% The reply map keeps rtpengine's warning next to the result.
%% req: RNG-07
warning_kept_in_reply(Config) ->
    Node = ?config(node, Config),
    {ok, Reply} = chappe_rtpengine:ping(Node),
    ?assertEqual(<<"Unknown flag ignored">>, maps:get(<<"warning">>, Reply)),
    ok.

%% req: RNG-07
load_limit_reply(Config) ->
    Node = ?config(node, Config),
    {error, load_limit, Reply} = chappe_rtpengine:ping(Node),
    ?assertEqual(
        <<"Parallel session limit reached">>, maps:get(<<"message">>, Reply)
    ),
    ok.

%% A value bencode cannot carry is refused before anything is sent.
%% req: RNG-10
bad_param_is_an_error(Config) ->
    Node = ?config(node, Config),
    Server = ?config(server, Config),
    {error, {bad_param, ptime, 20.5}} = chappe_rtpengine:offer(Node, #{
        call_id => <<"c">>, from_tag => <<"f">>, sdp => sdp(), ptime => 20.5
    }),
    {error, {bad_param, ptime, 20.5}} =
        chappe_rtpengine_client:cmd_async(Node, offer, #{ptime => 20.5}),
    ?assertEqual([], chappe_rtpengine_fake_server:received(Server)),
    ok.

%% A 30 KB offer goes out as one datagram and its echoed reply comes
%% back whole: send and receive buffers are sized for it.
%% req: RNG-03
udp_large_request(Config) ->
    Node = ?config(node, Config),
    Sdp = sdp_of_size(30000),
    {ok, Reply} = chappe_rtpengine:offer(Node, #{
        call_id => <<"big">>, from_tag => <<"f">>, sdp => Sdp
    }),
    ?assertEqual(
        <<Sdp/binary, "a=rtpengine:fake\r\n">>, chappe_rtpengine_ng:sdp(Reply)
    ),
    ok.

%% req: RNG-03
udp_too_large_refused(Config) ->
    Node = ?config(node, Config),
    Server = ?config(server, Config),
    {error, too_large} = chappe_rtpengine:offer(Node, #{
        call_id => <<"big">>, from_tag => <<"f">>, sdp => sdp_of_size(2000)
    }),
    ?assertEqual([], chappe_rtpengine_fake_server:received(Server)),
    #{sent := 0} = chappe_rtpengine:stats(Node),
    ok.

%% req: RNG-03
udp_emsgsize_is_too_large(Config) ->
    Node = ?config(node, Config),
    {error, too_large} = chappe_rtpengine:offer(Node, #{
        call_id => <<"big">>, from_tag => <<"f">>, sdp => sdp_of_size(70000)
    }),
    ok.

%% A 1 MB reply arrives over many TCP segments and is reassembled.
%% req: RNG-02
tcp_large_reply_reassembled(Config) ->
    Node = ?config(node, Config),
    Sdp = sdp_of_size(1000000),
    {ok, Reply} = chappe_rtpengine:offer(Node, #{
        call_id => <<"big">>, from_tag => <<"f">>, sdp => Sdp
    }),
    ?assertEqual(
        <<Sdp/binary, "a=rtpengine:fake\r\n">>, chappe_rtpengine_ng:sdp(Reply)
    ),
    ok.

%% A reply announcing more than the 4 MiB stream cap drops the
%% connection at once instead of buffering toward it.
%% req: RNG-02
tcp_oversized_length_drops_connection(Config) ->
    Node = ?config(node, Config),
    {error, closed} = chappe_rtpengine:ping(Node),
    #{reconnects := 1} = chappe_rtpengine:stats(Node),
    ok.

%% A stream that never sends the cookie separator is cut off.
%% req: RNG-02
tcp_runaway_cookie_drops_connection(Config) ->
    Node = ?config(node, Config),
    {error, closed} = chappe_rtpengine:ping(Node),
    ok.

%% The host is resolved on every connect attempt, so a name that does
%% not resolve yet is retried like a refused connection.
%% req: RNG-13
tcp_unresolved_host_retries(Config) ->
    Node = ?config(node, Config),
    {error, {send_failed, not_connected}} = chappe_rtpengine:ping(Node),
    ok.

%% rtpengine's HTTP interface may answer in a text frame.
%% req: RNG-01
ws_text_frame_reply(Config) ->
    Node = ?config(node, Config),
    {ok, #{<<"result">> := <<"pong">>}} = chappe_rtpengine:ping(Node),
    ok.

%% A UDP node has no connect to hook: its name is looked up again on a
%% timer and the client follows the new address.
%% req: RNG-13
udp_resolve_interval_follows_move(Config) ->
    Node = ?config(node, Config),
    A = ?config(server, Config),
    B = ?config(server_b, Config),
    {ok, _} = chappe_rtpengine:ping(Node),
    persistent_term:put({?MODULE, addr}, ?config(ip_b, Config)),
    ok = wait_until(fun() ->
        maps:get(address_changes, chappe_rtpengine:stats(Node)) =:= 1
    end),
    {ok, _} = chappe_rtpengine:ping(Node),
    ?assertEqual(1, length(chappe_rtpengine_fake_server:received(A))),
    ?assertEqual(1, length(chappe_rtpengine_fake_server:received(B))),
    ok.

%% With the periodic lookup off, resolve_after_timeouts timeouts in a
%% row trigger a lookup; fewer do not.
%% req: RNG-13
udp_timeouts_re_resolve(Config) ->
    Node = ?config(node, Config),
    B = ?config(server_b, Config),
    persistent_term:put({?MODULE, addr}, ?config(ip_b, Config)),
    {error, timeout} = chappe_rtpengine:ping(Node),
    timer:sleep(100),
    #{address_changes := 0} = chappe_rtpengine:stats(Node),
    {error, timeout} = chappe_rtpengine:ping(Node),
    ok = wait_until(fun() ->
        maps:get(address_changes, chappe_rtpengine:stats(Node)) =:= 1
    end),
    {ok, _} = chappe_rtpengine:ping(Node),
    ?assertEqual(1, length(chappe_rtpengine_fake_server:received(B))),
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
