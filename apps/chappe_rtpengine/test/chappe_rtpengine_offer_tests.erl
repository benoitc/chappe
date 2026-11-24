%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_rtpengine_offer_tests).

-include_lib("eunit/include/eunit.hrl").

-define(OK, {ok, #{<<"result">> => <<"ok">>}}).
-define(ERR, {error, <<"failed">>, #{}}).

reoffer_tags_test_() ->
    F = fun chappe_rtpengine_offer:reoffer_tags/4,
    [
        %% caller re-offers with the established to-tag
        ?_assertEqual(
            #{from_tag => <<"a">>, to_tag => <<"b">>},
            F(caller, #{}, <<"a">>, <<"b">>)
        ),
        %% no to-tag yet: from-tag only
        ?_assertEqual(
            #{from_tag => <<"a">>}, F(caller, #{}, <<"a">>, undefined)
        ),
        %% a via_branch opens a branch: no to-tag on the wire
        ?_assertEqual(
            #{from_tag => <<"a">>},
            F(caller, #{via_branch => <<"z9">>}, <<"a">>, <<"b">>)
        ),
        %% the callee offers: the tags swap
        ?_assertEqual(
            #{from_tag => <<"b">>, to_tag => <<"a">>},
            F(callee, #{}, <<"a">>, <<"b">>)
        ),
        ?_assertError(function_clause, F(other, #{}, <<"a">>, <<"b">>))
    ].

answer_tags_test_() ->
    F = fun chappe_rtpengine_offer:answer_tags/4,
    [
        %% first answer: the params' to-tag is the branch
        ?_assertEqual(
            {#{from_tag => <<"a">>, to_tag => <<"b">>}, <<"b">>},
            F(caller, #{to_tag => <<"b">>}, <<"a">>, undefined)
        ),
        %% a later answer reuses the stored to-tag
        ?_assertEqual(
            {#{from_tag => <<"a">>, to_tag => <<"b">>}, <<"b">>},
            F(caller, #{}, <<"a">>, <<"b">>)
        ),
        %% a fork branch overrides the stored to-tag
        ?_assertEqual(
            {#{from_tag => <<"a">>, to_tag => <<"c">>}, <<"c">>},
            F(caller, #{to_tag => <<"c">>}, <<"a">>, <<"b">>)
        ),
        %% answering a callee re-offer: swapped, no branch
        ?_assertEqual(
            {#{from_tag => <<"b">>, to_tag => <<"a">>}, none},
            F(callee, #{to_tag => <<"c">>}, <<"a">>, <<"b">>)
        )
    ].

pinned_state_test_() ->
    P = fun chappe_rtpengine_offer:pinned_state/1,
    [
        ?_assertEqual(offering, P(offer)),
        ?_assertEqual(publishing, P(publish)),
        ?_assertEqual(reoffering, P(reoffer)),
        ?_assertEqual(
            answering, P({answer_sent, answering, <<"b">>, false, u})
        ),
        ?_assertEqual(any, P({answer_sent, established, <<"b">>, false, u})),
        ?_assertEqual(any, P(query)),
        ?_assertEqual(any, P(aux)),
        ?_assertEqual(any, P({held, self()})),
        ?_assertEqual(any, P(released)),
        ?_assertEqual(any, P(branch_delete)),
        ?_assertEqual(any, P(delete))
    ].

negotiated_test_() ->
    N = fun chappe_rtpengine_offer:negotiated/3,
    First = {answer_sent, answering, <<"b">>, true, undefined},
    Later = {answer_sent, established, <<"c">>, false, <<"b">>},
    [
        ?_assertEqual({offered, []}, N(offer, ?OK, offering)),
        ?_assertEqual({idle, []}, N(offer, ?ERR, offering)),
        ?_assertEqual({idle, []}, N(offer, {error, timeout}, offering)),
        ?_assertEqual({established, []}, N(publish, ?OK, publishing)),
        ?_assertEqual({idle, []}, N(publish, ?ERR, publishing)),
        ?_assertEqual(
            {offered, [{reoffer, true}]}, N(reoffer, ?OK, reoffering)
        ),
        ?_assertEqual(
            {established, [{reoffer_initiator, caller}]},
            N(reoffer, ?ERR, reoffering)
        ),
        ?_assertEqual(
            {established, [
                {settle, <<"b">>, true},
                {reoffer_initiator, caller},
                {reoffer, false}
            ]},
            N(First, ?OK, answering)
        ),
        %% a failed answer restores the previous to-tag
        ?_assertEqual(
            {offered, [{to_tag, undefined}]}, N(First, ?ERR, answering)
        ),
        ?_assertEqual(
            {keep, [{settle, <<"c">>, false}]}, N(Later, ?OK, established)
        ),
        ?_assertEqual({keep, []}, N(Later, ?ERR, established)),
        %% the session checks the pinned state first; any other is a bug
        ?_assertError(function_clause, N(offer, ?OK, deleting))
    ].

params_test_() ->
    P = fun chappe_rtpengine_offer:params/5,
    [
        %% call-id and the stored from-tag go on, the ref as metadata
        ?_assertEqual(
            #{
                call_id => <<"c">>,
                from_tag => <<"a">>,
                metadata => <<"call_ref:x%7Cy%25">>
            },
            P(offer, #{}, <<"c">>, <<"a">>, <<"x|y%">>)
        ),
        %% the caller's from-tag and metadata win
        ?_assertEqual(
            #{call_id => <<"c">>, from_tag => <<"b">>, metadata => <<"m">>},
            P(
                answer,
                #{from_tag => <<"b">>, metadata => <<"m">>},
                <<"c">>,
                <<"a">>,
                <<"r">>
            )
        ),
        %% metadata only on offer, answer and publish
        ?_assertEqual(
            #{call_id => <<"c">>, from_tag => <<"a">>},
            P(query, #{}, <<"c">>, <<"a">>, <<"r">>)
        ),
        %% no from-tag injection on subscriptions
        ?_assertEqual(
            #{call_id => <<"c">>},
            P(subscribe_request, #{}, <<"c">>, <<"a">>, undefined)
        ),
        ?_assertEqual(
            #{call_id => <<"c">>}, P(query, #{}, <<"c">>, undefined, undefined)
        )
    ].

resolve_party_test_() ->
    R = fun chappe_rtpengine_offer:resolve_party/4,
    [
        ?_assertEqual(
            {ok, #{flags => [all]}}, R(block_media, #{}, <<"a">>, <<"b">>)
        ),
        ?_assertEqual({ok, #{}}, R(play_media, #{}, <<"a">>, <<"b">>)),
        ?_assertEqual(
            {ok, #{flags => [all]}},
            R(play_media, #{party => all}, <<"a">>, <<"b">>)
        ),
        ?_assertEqual(
            {ok, #{from_tag => <<"a">>}},
            R(play_media, #{party => caller}, <<"a">>, <<"b">>)
        ),
        ?_assertEqual(
            {ok, #{from_tag => <<"b">>, flags => [directional]}},
            R(silence_media, #{party => callee}, <<"a">>, <<"b">>)
        ),
        ?_assertEqual(
            {ok, #{from_tags => [<<"b">>]}},
            R(subscribe_request, #{party => callee}, <<"a">>, <<"b">>)
        ),
        ?_assertEqual(
            {error, no_to_tag},
            R(play_media, #{party => callee}, <<"a">>, undefined)
        ),
        ?_assertEqual(
            {error, no_from_tag},
            R(play_media, #{party => caller}, undefined, undefined)
        ),
        ?_assertEqual(
            {error, {bad_party, nobody}},
            R(play_media, #{party => nobody}, <<"a">>, <<"b">>)
        )
    ].
