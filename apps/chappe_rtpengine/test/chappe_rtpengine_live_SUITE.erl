%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Runs the five commands against a real rtpengine. Skipped unless
%% RTPENGINE_HOST (and optionally RTPENGINE_PORT, default 2223) is set:
%%
%%   RTPENGINE_HOST=127.0.0.1 RTPENGINE_PORT=2223 \
%%       rebar3 ct --suite chappe_rtpengine_live_SUITE
-module(chappe_rtpengine_live_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    ping/1,
    offer_answer_query_delete/1,
    list_statistics_forwarding/1,
    media_subscription/1,
    tcp_transport/1,
    ws_transport/1,
    wss_transport/1
]).

all() ->
    [
        ping,
        offer_answer_query_delete,
        list_statistics_forwarding,
        media_subscription,
        tcp_transport,
        ws_transport,
        wss_transport
    ].

init_per_suite(Config) ->
    case os:getenv("RTPENGINE_HOST") of
        false ->
            {skip, "RTPENGINE_HOST not set"};
        Host ->
            Port =
                case os:getenv("RTPENGINE_PORT") of
                    false -> 2223;
                    P -> list_to_integer(P)
                end,
            {ok, _} = application:ensure_all_started(chappe_rtpengine),
            ok = chappe_rtpengine:add_node(chappe_rtpengine_live, #{
                host => Host, port => Port
            }),
            Config
    end.

end_per_suite(_Config) ->
    _ = chappe_rtpengine:remove_node(chappe_rtpengine_live),
    ok = application:stop(chappe_rtpengine).

ping(_Config) ->
    {ok, #{<<"result">> := <<"pong">>}} = chappe_rtpengine:ping(
        chappe_rtpengine_live
    ),
    ok.

offer_answer_query_delete(_Config) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    CallId = <<"chappe-rtpengine-live-", Suffix/binary>>,
    FromTag = <<"from-", Suffix/binary>>,
    ToTag = <<"to-", Suffix/binary>>,

    {ok, OfferReply} = chappe_rtpengine:offer(chappe_rtpengine_live, #{
        call_id => CallId,
        from_tag => FromTag,
        sdp => sdp(<<"198.51.100.1">>, 30000),
        ice => remove
    }),
    OfferSDP = chappe_rtpengine_ng:sdp(OfferReply),
    ?assertNotEqual(undefined, OfferSDP),
    %% rtpengine rewrote the media address to one of its own
    ?assertNotEqual(nomatch, binary:match(OfferSDP, <<"m=audio ">>)),

    {ok, AnswerReply} = chappe_rtpengine:answer(chappe_rtpengine_live, #{
        call_id => CallId,
        from_tag => FromTag,
        to_tag => ToTag,
        sdp => sdp(<<"198.51.100.2">>, 40000),
        ice => remove
    }),
    ?assertNotEqual(undefined, chappe_rtpengine_ng:sdp(AnswerReply)),

    {ok, QueryReply} = chappe_rtpengine:query(chappe_rtpengine_live, #{
        call_id => CallId
    }),
    ?assert(maps:is_key(<<"created">>, QueryReply)),

    {ok, _} = chappe_rtpengine:delete(chappe_rtpengine_live, #{
        call_id => CallId, from_tag => FromTag
    }),

    %% the session is gone now
    {error, _, _} = chappe_rtpengine:query(chappe_rtpengine_live, #{
        call_id => CallId
    }),
    ok.

%% list/2 finds a call the node runs, statistics/1 reads its counters,
%% and a session's forwarding commands reach the daemon.
list_statistics_forwarding(_Config) ->
    Node = chappe_rtpengine_live,
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    CallId = <<"chappe-rtpengine-list-", Suffix/binary>>,
    {ok, Sess} = chappe_rtpengine:start_session(#{
        call_id => CallId, node => Node
    }),
    {ok, _} = chappe_rtpengine_session:offer(Sess, #{
        from_tag => <<"from-", Suffix/binary>>,
        sdp => sdp(<<"198.51.100.1">>, 30000),
        ice => remove
    }),
    {ok, _} = chappe_rtpengine_session:answer(Sess, #{
        to_tag => <<"to-", Suffix/binary>>,
        sdp => sdp(<<"198.51.100.2">>, 40000),
        ice => remove
    }),
    {ok, Calls} = chappe_rtpengine:list(Node, #{limit => 1000}),
    ?assert(lists:member(CallId, Calls)),
    {ok, Stats} = chappe_rtpengine:statistics(Node),
    #{<<"currentstatistics">> := #{<<"sessionstotal">> := Total}} = Stats,
    ?assert(Total >= 1),
    Fwd = chappe_rtpengine_cmd:start_forwarding(Sess, #{}),
    ct:pal("start forwarding: ~p", [Fwd]),
    ?assertMatch({ok, _}, Fwd),
    ?assertMatch({ok, _}, chappe_rtpengine_cmd:stop_forwarding(Sess)),
    ok = chappe_rtpengine_session:stop(Sess),
    ok.

%% Needs RTPENGINE_TCP_PORT pointing at a --listen-tcp-ng listener.
tcp_transport(_Config) ->
    case os:getenv("RTPENGINE_TCP_PORT") of
        false ->
            throw({skip, "RTPENGINE_TCP_PORT not set"});
        PortStr ->
            Host = os:getenv("RTPENGINE_HOST"),
            ok = chappe_rtpengine:add_node(chappe_rtpengine_live_tcp, #{
                host => Host,
                port => list_to_integer(PortStr),
                transport => tcp
            }),
            {ok, #{<<"result">> := <<"pong">>}} =
                chappe_rtpengine:ping(chappe_rtpengine_live_tcp),
            Suffix = integer_to_binary(erlang:unique_integer([positive])),
            CallId = <<"chappe-rtpengine-tcp-", Suffix/binary>>,
            FromTag = <<"from-", Suffix/binary>>,
            {ok, OfferReply} = chappe_rtpengine:offer(
                chappe_rtpengine_live_tcp, #{
                    call_id => CallId,
                    from_tag => FromTag,
                    sdp => sdp(<<"198.51.100.1">>, 30000),
                    ice => remove
                }
            ),
            ?assertNotEqual(undefined, chappe_rtpengine_ng:sdp(OfferReply)),
            {ok, _} = chappe_rtpengine:delete(chappe_rtpengine_live_tcp, #{
                call_id => CallId, from_tag => FromTag
            }),
            _ = chappe_rtpengine:remove_node(chappe_rtpengine_live_tcp),
            ok
    end.

%% Needs RTPENGINE_HTTP_PORT pointing at a --listen-http listener; NG
%% rides a WebSocket with the ng.rtpengine.com subprotocol.
ws_transport(_Config) ->
    case os:getenv("RTPENGINE_HTTP_PORT") of
        false ->
            throw({skip, "RTPENGINE_HTTP_PORT not set"});
        PortStr ->
            Host = os:getenv("RTPENGINE_HOST"),
            ok = chappe_rtpengine:add_node(chappe_rtpengine_live_ws, #{
                host => Host,
                port => list_to_integer(PortStr),
                transport => ws
            }),
            {ok, #{<<"result">> := <<"pong">>}} =
                chappe_rtpengine:ping(chappe_rtpengine_live_ws),
            Suffix = integer_to_binary(erlang:unique_integer([positive])),
            CallId = <<"chappe-rtpengine-ws-", Suffix/binary>>,
            FromTag = <<"from-", Suffix/binary>>,
            {ok, OfferReply} = chappe_rtpengine:offer(
                chappe_rtpengine_live_ws, #{
                    call_id => CallId,
                    from_tag => FromTag,
                    sdp => sdp(<<"198.51.100.1">>, 30000),
                    ice => remove
                }
            ),
            ?assertNotEqual(undefined, chappe_rtpengine_ng:sdp(OfferReply)),
            {ok, _} = chappe_rtpengine:delete(chappe_rtpengine_live_ws, #{
                call_id => CallId, from_tag => FromTag
            }),
            _ = chappe_rtpengine:remove_node(chappe_rtpengine_live_ws),
            ok
    end.

%% Needs RTPENGINE_HTTPS_PORT pointing at a --listen-https listener
%% with a self-signed certificate (the interop stack generates one),
%% so verification is off and SNI is disabled (the host is an IP).
wss_transport(_Config) ->
    case os:getenv("RTPENGINE_HTTPS_PORT") of
        false ->
            throw({skip, "RTPENGINE_HTTPS_PORT not set"});
        PortStr ->
            Host = os:getenv("RTPENGINE_HOST"),
            ok = chappe_rtpengine:add_node(chappe_rtpengine_live_wss, #{
                host => Host,
                port => list_to_integer(PortStr),
                transport => wss,
                tls_opts => [
                    {verify, verify_none},
                    {server_name_indication, disable}
                ]
            }),
            {ok, #{<<"result">> := <<"pong">>}} =
                chappe_rtpengine:ping(chappe_rtpengine_live_wss),
            Suffix = integer_to_binary(erlang:unique_integer([positive])),
            CallId = <<"chappe-rtpengine-wss-", Suffix/binary>>,
            FromTag = <<"from-", Suffix/binary>>,
            {ok, OfferReply} = chappe_rtpengine:offer(
                chappe_rtpengine_live_wss, #{
                    call_id => CallId,
                    from_tag => FromTag,
                    sdp => sdp(<<"198.51.100.1">>, 30000),
                    ice => remove
                }
            ),
            ?assertNotEqual(undefined, chappe_rtpengine_ng:sdp(OfferReply)),
            {ok, _} = chappe_rtpengine:delete(chappe_rtpengine_live_wss, #{
                call_id => CallId, from_tag => FromTag
            }),
            _ = chappe_rtpengine:remove_node(chappe_rtpengine_live_wss),
            ok
    end.

media_subscription(_Config) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    CallId = <<"chappe-rtpengine-sub-", Suffix/binary>>,
    FromTag = <<"from-", Suffix/binary>>,
    ToTag = <<"to-", Suffix/binary>>,

    {ok, _} = chappe_rtpengine:offer(chappe_rtpengine_live, #{
        call_id => CallId,
        from_tag => FromTag,
        sdp => sdp(<<"198.51.100.1">>, 30000),
        ice => remove
    }),
    {ok, _} = chappe_rtpengine:answer(chappe_rtpengine_live, #{
        call_id => CallId,
        from_tag => FromTag,
        to_tag => ToTag,
        sdp => sdp(<<"198.51.100.2">>, 40000),
        ice => remove
    }),

    SubReply =
        case
            chappe_rtpengine:cmd(chappe_rtpengine_live, subscribe_request, #{
                call_id => CallId,
                flags => [all]
            })
        of
            {error, <<"Unrecognized command">>, _} ->
                %% rtpengine built without transcoding compiles out
                %% publish/subscribe; clean up and skip
                {ok, _} = chappe_rtpengine:delete(chappe_rtpengine_live, #{
                    call_id => CallId, from_tag => FromTag
                }),
                throw({skip, "rtpengine built without subscribe support"});
            {ok, Reply} ->
                Reply
        end,
    SubTag = maps:get(<<"to-tag">>, SubReply),
    SubSDP = chappe_rtpengine_ng:sdp(SubReply),
    ?assertNotEqual(undefined, SubSDP),
    ?assertNotEqual(nomatch, binary:match(SubSDP, <<"m=audio ">>)),

    {ok, _} = chappe_rtpengine:cmd(chappe_rtpengine_live, subscribe_answer, #{
        call_id => CallId,
        to_tag => SubTag,
        sdp => sdp(<<"198.51.100.3">>, 50000)
    }),
    {ok, _} = chappe_rtpengine:cmd(chappe_rtpengine_live, unsubscribe, #{
        call_id => CallId,
        to_tag => SubTag
    }),
    {ok, _} = chappe_rtpengine:delete(chappe_rtpengine_live, #{
        call_id => CallId, from_tag => FromTag
    }),
    ok.

sdp(IP, Port) ->
    PortBin = integer_to_binary(Port),
    <<
        "v=0\r\n"
        "o=- 1545997027 1 IN IP4 ",
        IP/binary,
        "\r\n"
        "s=call\r\n"
        "c=IN IP4 ",
        IP/binary,
        "\r\n"
        "t=0 0\r\n"
        "m=audio ",
        PortBin/binary,
        " RTP/AVP 0 8 101\r\n"
        "a=rtpmap:0 PCMU/8000\r\n"
        "a=rtpmap:8 PCMA/8000\r\n"
        "a=rtpmap:101 telephone-event/8000\r\n"
        "a=sendrecv\r\n"
    >>.
