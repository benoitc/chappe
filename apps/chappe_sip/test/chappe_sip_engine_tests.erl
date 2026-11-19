%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The engine's pure parts: the start option checks, the TLS listener URI,
%% the native route of a flow and the method of an outgoing request.
-module(chappe_sip_engine_tests).

-include_lib("eunit/include/eunit.hrl").

-define(O, chappe_sip_engine_opts).
-define(B, chappe_sip_engine_backend).

%% start options

tls_checks_test_() ->
    [
        ?_assertMatch({ok, _}, ?O:start_opts(#{})),
        ?_assertMatch({ok, _}, ?O:start_opts(#{tls => #{verify => peer}})),
        ?_assertEqual(
            {error, {tls, insecure_verify_none}},
            ?O:start_opts(#{tls => #{verify => none}})
        ),
        ?_assertMatch(
            {ok, _},
            ?O:start_opts(#{tls => #{verify => none, allow_insecure => true}})
        ),
        ?_assertEqual(
            {error, {tls, {bad_verify_clients, yes}}},
            ?O:start_opts(#{tls => #{verify_clients => yes}})
        ),
        ?_assertEqual(
            {error, {tls, {bad_verify, sometimes}}},
            ?O:start_opts(#{tls => #{verify => sometimes}})
        ),
        ?_assertEqual(
            {error, {tls, bad_options}}, ?O:start_opts(#{tls => [verify]})
        )
    ].

sip_timers_test_() ->
    {ok, Opts} = ?O:start_opts(#{sip_timers => #{t1 => 200, t2 => 4000}}),
    Bad = #{t1 => 500, t2 => 400},
    [
        ?_assertEqual(200, maps:get(sip_t1, Opts)),
        ?_assertEqual(4000, maps:get(sip_t2, Opts)),
        ?_assertNot(maps:is_key(sip_t4, Opts)),
        ?_assertNot(maps:is_key(sip_timers, Opts)),
        ?_assertEqual(
            {error, {sip_timers, Bad}}, ?O:start_opts(#{sip_timers => Bad})
        ),
        ?_assertEqual(
            {error, {sip_timers, #{t3 => 1}}},
            ?O:start_opts(#{sip_timers => #{t3 => 1}})
        ),
        ?_assertEqual(
            {error, {sip_timers, #{t1 => 9}}},
            ?O:start_opts(#{sip_timers => #{t1 => 9}})
        ),
        ?_assertEqual(
            {error, {sip_timers, 500}}, ?O:start_opts(#{sip_timers => 500})
        )
    ].

ranges_test_() ->
    [
        ?_assertMatch(
            {ok, #{tcp_keepalive_ms := 1000}},
            ?O:start_opts(#{tcp_keepalive_ms => 1000})
        ),
        ?_assertEqual(
            {error, {tcp_keepalive_ms, 999}},
            ?O:start_opts(#{tcp_keepalive_ms => 999})
        ),
        ?_assertMatch(
            {ok, #{udp_mtu := 65535}}, ?O:start_opts(#{udp_mtu => 65535})
        ),
        ?_assertEqual(
            {error, {udp_mtu, 575}}, ?O:start_opts(#{udp_mtu => 575})
        ),
        ?_assertEqual(
            {error, {udp_mtu, <<"1500">>}},
            ?O:start_opts(#{udp_mtu => <<"1500">>})
        )
    ].

outbound_test_() ->
    P = <<"sip:proxy.example.com">>,
    [
        ?_assertMatch(
            {ok, #{outbound_proxy := P}}, ?O:start_opts(#{outbound_proxy => P})
        ),
        ?_assertMatch(
            {ok, _}, ?O:start_opts(#{outbound_proxy => <<"sips:p.example">>})
        ),
        ?_assertEqual(
            {error, {outbound_proxy, <<"http://p.example">>}},
            ?O:start_opts(#{outbound_proxy => <<"http://p.example">>})
        ),
        ?_assertEqual(
            {error, {outbound_proxy, <<"sip:p", 0, ".example">>}},
            ?O:start_opts(#{outbound_proxy => <<"sip:p", 0, ".example">>})
        ),
        ?_assertEqual(
            {error, {outbound_proxy, p}}, ?O:start_opts(#{outbound_proxy => p})
        ),
        ?_assertEqual(
            {error, {outbound_route, {with_outbound_proxy, P}}},
            ?O:start_opts(#{outbound_proxy => P, outbound_route => P})
        ),
        ?_assertMatch(
            {ok, #{outbound_route := _}}, ?O:start_opts(#{outbound_route => P})
        ),
        ?_assertMatch(
            {error, {outbound_route, _}},
            ?O:start_opts(#{outbound_route => <<"mailto:x">>})
        )
    ].

size_and_capture_test_() ->
    [
        ?_assertMatch({ok, #{max_message_size := 262144}}, ?O:start_opts(#{})),
        ?_assertMatch(
            {ok, #{max_message_size := 1024}},
            ?O:start_opts(#{max_message_size => 1024})
        ),
        ?_assertNot(
            maps:is_key(capture, element(2, ?O:start_opts(#{capture => x})))
        ),
        ?_assertMatch({error, _}, ?O:start_opts(#{hep => bad}))
    ].

%% the TLS listener URI

tls_uri_test_() ->
    Primary = <<"sip:192.0.2.7:5060">>,
    Tls = fun(C) -> #{tls => #{contact => C}} end,
    [
        ?_assertEqual(undefined, ?O:tls_uri(#{}, Primary)),
        ?_assertEqual(undefined, ?O:tls_uri(#{tls => #{}}, Primary)),
        ?_assertEqual(
            <<"sips:192.0.2.7:5061">>,
            ?O:tls_uri(Tls(<<"sips:0.0.0.0:5061">>), Primary)
        ),
        ?_assertEqual(
            <<"sips:192.0.2.7:5061">>,
            ?O:tls_uri(Tls(<<"sips:[::]:5061">>), <<"<", Primary/binary, ">">>)
        ),
        ?_assertEqual(
            <<"sips:0.0.0.0:5061">>,
            ?O:tls_uri(Tls(<<"sips:0.0.0.0:5061">>), undefined)
        ),
        ?_assertEqual(
            <<"sips:tls.example.com">>,
            ?O:tls_uri(Tls(<<"<sips:tls.example.com>">>), Primary)
        ),
        ?_assertEqual(
            <<"sips:198.51.100.1:5061">>,
            ?O:tls_uri(Tls(<<"sips:198.51.100.1:5061;transport=tls">>), Primary)
        ),
        ?_assertEqual(undefined, ?O:tls_uri(Tls(<<"not a uri">>), Primary))
    ].

%% the native route of a flow

native_route_test_() ->
    [
        ?_assertEqual(7, ?B:native_route({conn, 7})),
        ?_assertEqual(
            <<"sip:192.0.2.1:5060;transport=udp">>,
            ?B:native_route({udp, <<"192.0.2.1">>, 5060})
        ),
        ?_assertEqual(
            <<"sip:[2001:db8::1]:5062;transport=udp">>,
            ?B:native_route({udp, <<"2001:db8::1">>, 5062})
        ),
        ?_assertEqual(
            <<"sip:192.0.2.1:5060;transport=udp">>,
            ?B:native_route({udp, <<"192.0.2.1">>, 5060, <<"lan">>})
        ),
        ?_assertEqual(
            <<"sip:next.example">>, ?B:native_route(<<"sip:next.example">>)
        ),
        ?_assertEqual(undefined, ?B:native_route(undefined))
    ].

%% the method of an outgoing request

raw_method_test_() ->
    Long = binary:copy(<<"A">>, 32),
    [
        ?_assertEqual(<<"INVITE">>, ?B:raw_method(<<"INVITE sip:b SIP/2.0">>)),
        ?_assertEqual(Long, ?B:raw_method(<<Long/binary, " sip:b">>)),
        ?_assertEqual(undefined, ?B:raw_method(<<"A", Long/binary, " sip:b">>)),
        ?_assertEqual(undefined, ?B:raw_method(<<" sip:b">>)),
        ?_assertEqual(undefined, ?B:raw_method(<<"NOSPACE">>)),
        ?_assertEqual(undefined, ?B:raw_method(<<>>))
    ].
