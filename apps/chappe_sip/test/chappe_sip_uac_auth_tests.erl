%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% chappe_sip_uac_auth, chappe_sip_subscription and the SDP hold rewrite:
%% the pure helpers the UAC and dialog fsms use.
-module(chappe_sip_uac_auth_tests).

-include_lib("eunit/include/eunit.hrl").

-define(A, chappe_sip_uac_auth).

chal(Realm, Extra) ->
    #{scheme => <<"Digest">>, params => maps:merge(#{<<"realm">> => Realm, <<"nonce">> => <<"n">>}, Extra)}.

credentials_test() ->
    C = chal(<<"r1">>, #{}),
    ?assertEqual(none, ?A:credentials_for(C, undefined)),
    ?assertEqual({<<"u">>, <<"p">>}, ?A:credentials_for(C, #{user => <<"u">>, pass => <<"p">>})),
    ?assertEqual(
        {<<"b">>, <<"q">>},
        ?A:credentials_for(C, [#{realm => <<"r2">>, user => <<"a">>, pass => <<"p">>},
                               #{realm => <<"r1">>, user => <<"b">>, pass => <<"q">>}])
    ),
    ?assertEqual(none, ?A:credentials_for(C, [#{realm => <<"r2">>, user => <<"a">>, pass => <<"p">>}])),
    ?assertEqual(none, ?A:credentials_for(C, fun(_) -> error(boom) end)),
    ?assertEqual({<<"f">>, <<"g">>}, ?A:credentials_for(C, fun(_) -> #{user => <<"f">>, pass => <<"g">>} end)).

merge_test() ->
    P = <<"Proxy-Authorization">>,
    W = <<"Authorization">>,
    C1 = chal(<<"r1">>, #{}),
    C2 = chal(<<"r2">>, #{}),
    ?assertEqual({error, no_auth}, ?A:merge(P, [], [])),
    {ok, Cs} = ?A:merge(P, [C1], []),
    %% a 401 after a 407: both answered
    {ok, [{P, C1}, {W, C2}]} = ?A:merge(W, [C2], Cs),
    %% the same realm again: refused, unless stale
    ?assertEqual({error, rejected}, ?A:merge(P, [C1], Cs)),
    Stale = chal(<<"r1">>, #{<<"stale">> => <<"TRUE">>, <<"nonce">> => <<"n2">>}),
    ?assertEqual({ok, [{P, Stale}]}, ?A:merge(P, [Stale], Cs)).

subscription_state_test() ->
    S = chappe_sip_subscription,
    ?assertEqual({ok, <<"active">>, false}, S:state_value(active, #{}, undefined)),
    ?assertEqual({ok, <<"pending;expires=30">>, false}, S:state_value(pending, #{expires => 30}, undefined)),
    ?assertEqual({ok, <<"terminated;reason=timeout">>, true}, S:state_value({terminated, timeout}, #{}, undefined)),
    ?assertEqual(error, S:state_value(bogus, #{}, undefined)),
    Sub = S:new(#{expires => 60, event => <<"presence">>, keep_body => true}, <<"<sip:me@h>">>),
    {ok, <<"active;expires=", _/binary>>, false} = S:state_value(active, #{}, Sub),
    ?assert(S:same_event(<<"presence">>, undefined)),
    ?assertNot(S:same_event(<<"dialog">>, <<"presence">>)),
    Sub1 = S:keep_body(#{content_type => <<"a/b">>, body => [<<"x">>]}, Sub),
    {_, Hdrs, <<"x">>} = S:final_notify(Sub1, <<"noresource">>, terminated),
    ?assertEqual(
        [{<<"Event">>, <<"presence">>},
         {<<"Subscription-State">>, <<"terminated;reason=noresource">>},
         {<<"Content-Type">>, <<"a/b">>}],
        Hdrs
    ),
    ?assertEqual(undefined, S:new(undefined, undefined)),
    ?assertEqual([], S:timer(undefined)).

sdp_hold_test() ->
    Sdp = <<"v=0\r\no=- 1 7 IN IP4 1.2.3.4\r\ns=-\r\nc=IN IP4 1.2.3.4\r\nt=0 0\r\n"
            "m=audio 4000 RTP/AVP 0\r\na=sendrecv\r\nm=video 0 RTP/AVP 96\r\n">>,
    Held = chappe_sip_sdp:hold(Sdp, true),
    ?assertNotEqual(nomatch, binary:match(Held, <<"m=audio 4000 RTP/AVP 0\r\na=sendonly\r\n">>)),
    %% a refused stream is left alone
    ?assertEqual(nomatch, binary:match(Held, <<"m=video 0 RTP/AVP 96\r\na=">>)),
    Unheld = chappe_sip_sdp:hold(Held, false),
    ?assertNotEqual(nomatch, binary:match(Unheld, <<"a=sendrecv">>)),
    ?assertNotEqual(nomatch, binary:match(chappe_sip_sdp:next_version(Sdp), <<"o=- 1 8 ">>)),
    ?assertEqual(<<"x">>, chappe_sip_sdp:next_version(<<"x">>)).
