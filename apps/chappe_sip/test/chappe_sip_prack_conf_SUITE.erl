%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% RFC 3262 reliable provisionals and PRACK, on the wire.
%%
%% As a UAS the app answers with chappe_sip_res:send_reliable/2 and a raw
%% gen_udp caller (chappe_sip_core_peer) checks RSeq, retransmissions and
%% the PRACK answers (section 3). As a UAC the app originates with
%% chappe_sip_uac:start/2 and the raw peer plays the UAS, sending reliable
%% provisionals and reading the PRACKs chappe sends back (section 4), with
%% offer/answer in the reliable 1xx and the PRACK (section 5).
-module(chappe_sip_prack_conf_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-import(chappe_sip_core_peer, [
    open/0,
    port/1,
    send/3,
    recv/3,
    recv_none/3,
    collect/3,
    request/3,
    response/3,
    hdr/2,
    hdrs/2,
    status/1,
    uri/1,
    cseq/1,
    to_tag/1,
    from_tag/1,
    body/1,
    top_via/1,
    via_branch/1,
    tag/0,
    sdp/0, sdp/1
]).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    uas_100_never_reliable/1,
    uas_rseq_sequence/1,
    uas_prack_unknown_rack_481/1,
    uas_no_reliable_after_final/1,
    uas_prack_offer_answered/1,
    b2b_prack_offer_refused/1,
    uas_offerless_reliable_offer/1,
    uac_100_reliable_ignored/1,
    uac_prack_in_early_dialog/1,
    uac_retransmission_dropped/1,
    uac_rseq_in_order/1,
    uac_answer_in_prack/1,
    uac_require_100rel_invite_only/1
]).

all() ->
    [
        uas_100_never_reliable,
        uas_rseq_sequence,
        uas_prack_unknown_rack_481,
        uas_no_reliable_after_final,
        uas_prack_offer_answered,
        b2b_prack_offer_refused,
        uas_offerless_reliable_offer,
        uac_100_reliable_ignored,
        uac_prack_in_early_dialog,
        uac_retransmission_dropped,
        uac_rseq_in_order,
        uac_answer_in_prack,
        uac_require_100rel_invite_only
    ].

init_per_suite(Config) ->
    application:set_env(
        chappe_sip,
        engine_mod,
        chappe_sip_nif,
        [{persistent, true}]
    ),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(_Case, Config) ->
    EP = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => chappe_sip_core_peer:contact(EP)}),
    Sock = open(),
    [{ep, EP}, {sock, Sock} | Config].

end_per_testcase(_Case, Config) ->
    chappe_sip_core_peer:close(?config(sock, Config)),
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

-define(APP, <<"sip:app@127.0.0.1">>).
-define(SDP_CT, {<<"Content-Type">>, <<"application/sdp">>}).

%% ---- chappe as UAS (section 3) ----

%% An INVITE that requires 100rel: the 100 Trying the stack sends at once
%% carries neither RSeq nor Require: 100rel; the 183 the app sends reliably
%% does (3).
%% req: R3262-004
uas_100_never_reliable(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Tag = tag(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        ok = chappe_sip_res:send_reliable(
            Res, #{
                status => 183,
                to_tag => Tag,
                body => sdp(),
                headers => [?SDP_CT]
            }
        ),
        {ok, _} = chappe_sip_res:await_prack(Res, 5000),
        {ok, _} = answer(Req, Res, Tag)
    end),
    Inv = invite(Sock, [{<<"Require">>, <<"100rel">>}]),
    send(Sock, EP, Inv),
    {R100, _} = recv(Sock, {status, 100}, 3000),
    ?assertEqual(undefined, hdr(<<"rseq">>, R100)),
    ?assertNot(lists:member(<<"100rel">>, tokens(hdrs(<<"require">>, R100)))),
    {R183, _} = recv(Sock, {status, 183}, 3000),
    ?assertNotEqual(undefined, hdr(<<"rseq">>, R183)),
    finish_uas(Sock, EP, Inv, R183).

%% Two reliable provisionals sent back to back: the first RSeq is in
%% 1..2**31-1, the second is held until the first is PRACKed and then goes
%% out with RSeq one higher. A matching PRACK gets 200 and stops the
%% retransmissions of the response it acknowledges; the same RAck again
%% is not answered 2xx, the response is off the unacknowledged list (3).
%% req: R3262-011 R3262-016 R3262-017 R3262-020 R3262-022
uas_rseq_sequence(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Tag = tag(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        ok = chappe_sip_res:send_reliable(Res, #{status => 180, to_tag => Tag}),
        ok = chappe_sip_res:send_reliable(
            Res, #{
                status => 183,
                to_tag => Tag,
                body => sdp(),
                headers => [?SDP_CT]
            }
        ),
        {ok, _} = chappe_sip_res:await_prack(Res, 8000),
        {ok, _} = chappe_sip_res:await_prack(Res, 8000),
        Test ! uas_two_pracks,
        {ok, _} = answer(Req, Res, Tag)
    end),
    Inv = invite(Sock, [{<<"Supported">>, <<"100rel">>}]),
    send(Sock, EP, Inv),
    {R180, _} = recv(Sock, {status, 180}, 3000),
    RSeq1 = binary_to_integer(hdr(<<"rseq">>, R180)),
    ?assert(RSeq1 >= 1 andalso RSeq1 =< (1 bsl 31) - 1),
    %% unacknowledged: the 180 is retransmitted (T1 = 500 ms), and the 183
    %% queued behind it is not sent
    Held = collect(Sock, any, 1300),
    ?assert(length([B || {_, B} <- Held, status(B) =:= 180]) >= 1),
    ?assertEqual([], [B || {_, B} <- Held, status(B) =:= 183]),
    send(Sock, EP, prack(Sock, Inv, R180, 2)),
    {PR, _} = recv(Sock, {status, 200, <<"PRACK">>}, 3000),
    ?assertEqual(200, status(PR)),
    {R183, _} = recv(Sock, {status, 183}, 3000),
    ?assertEqual(RSeq1 + 1, binary_to_integer(hdr(<<"rseq">>, R183))),
    %% the PRACKed 180 is not retransmitted any more (the next would have
    %% been due 1 s then 2 s after the last)
    After = collect(Sock, any, 2500),
    ?assertEqual([], [B || {_, B} <- After, status(B) =:= 180]),
    %% the same RAck again, a new PRACK transaction: nothing is pending
    %% under that RSeq
    send(Sock, EP, prack(Sock, Inv, R180, 3)),
    {Again, _} = recv(Sock, resp_to(<<"PRACK">>), 3000),
    ?assertEqual(481, status(Again)),
    send(Sock, EP, prack(Sock, Inv, R183, 4)),
    {_, _} = recv(Sock, {status, 200, <<"PRACK">>}, 3000),
    receive
        uas_two_pracks -> ok
    after 5000 -> ct:fail(no_pracks)
    end,
    {R200, _} = recv(Sock, {status, 200, <<"INVITE">>}, 3000),
    send(Sock, EP, chappe_sip_core_peer:ack_for(R200, #{port => port(Sock)})).

%% A PRACK whose RAck names no unacknowledged reliable provisional gets
%% 481; the right one then gets 200 (3).
%% req: R3262-015 R3262-016
uas_prack_unknown_rack_481(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Tag = tag(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        ok = chappe_sip_res:send_reliable(
            Res, #{
                status => 183,
                to_tag => Tag,
                body => sdp(),
                headers => [?SDP_CT]
            }
        ),
        {ok, _} = chappe_sip_res:await_prack(Res, 8000),
        {ok, _} = answer(Req, Res, Tag)
    end),
    Inv = invite(Sock, [{<<"Supported">>, <<"100rel">>}]),
    send(Sock, EP, Inv),
    {R183, _} = recv(Sock, {status, 183}, 3000),
    RSeq = binary_to_integer(hdr(<<"rseq">>, R183)),
    Bad = prack(Sock, Inv, R183, 2, RSeq + 5),
    send(Sock, EP, Bad),
    {R481, _} = recv(Sock, resp_to(<<"PRACK">>), 3000),
    ?assertEqual(481, status(R481)),
    send(Sock, EP, prack(Sock, Inv, R183, 3)),
    {R200P, _} = recv(Sock, resp_to(<<"PRACK">>), 3000),
    ?assertEqual(200, status(R200P)),
    {R200, _} = recv(Sock, {status, 200, <<"INVITE">>}, 3000),
    send(Sock, EP, chappe_sip_core_peer:ack_for(R200, #{port => port(Sock)})).

%% Once the final response is out, a new reliable provisional is refused
%% and nothing reaches the wire (3).
%% req: R3262-027
uas_no_reliable_after_final(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:invite(fun(_Req, Res) ->
        ok = chappe_sip_res:send(Res, 486, #{to_tag => <<"busy">>}),
        Test !
            {late,
                chappe_sip_res:send_reliable(
                    Res, #{
                        status => 183,
                        to_tag => <<"busy">>,
                        body => sdp(),
                        headers => [?SDP_CT]
                    }
                )}
    end),
    Inv = invite(Sock, [{<<"Require">>, <<"100rel">>}]),
    send(Sock, EP, Inv),
    {R486, _} = recv(Sock, {status, 486}, 3000),
    send(Sock, EP, ack_non2xx(Inv, R486)),
    receive
        {late, L} -> ?assertEqual({error, already_final}, L)
    after 3000 -> ct:fail(no_late_result)
    end,
    ok = recv_none(Sock, fun(B) -> is_1xx(B) end, 1500).

%% A PRACK carrying an offer is answered in its 2xx (5). The offer/answer
%% exchanges of INVITE / reliable 1xx and PRACK / 2xx both complete.
%% req: R3262-047 R3262-050
uas_prack_offer_answered(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Tag = tag(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        ok = chappe_sip_res:send_reliable(
            Res, #{
                status => 183,
                to_tag => Tag,
                body => sdp(41000),
                headers => [?SDP_CT]
            }
        ),
        case chappe_sip_res:await_prack(Res, 5000) of
            {offer, Prack, PRes} ->
                Test ! {prack_offer, body(Prack)},
                ok = chappe_sip_res:send(PRes, 200, #{
                    body => sdp(41002),
                    headers => [?SDP_CT]
                });
            Other ->
                Test ! {prack_offer, Other}
        end,
        {ok, _} = answer(Req, Res, Tag)
    end),
    Inv = invite(Sock, [{<<"Supported">>, <<"100rel">>}]),
    send(Sock, EP, Inv),
    {R183, _} = recv(Sock, {status, 183}, 3000),
    ?assertEqual(sdp(41000), body(R183)),
    send(Sock, EP, prack(Sock, Inv, R183, 2, undefined, sdp(40002))),
    {PR, _} = recv(Sock, resp_to(<<"PRACK">>), 3000),
    ?assertEqual(200, status(PR)),
    ?assertEqual(sdp(41002), body(PR)),
    ?assertEqual(<<"application/sdp">>, hdr(<<"content-type">>, PR)),
    receive
        {prack_offer, O} -> ?assertEqual(sdp(40002), O)
    after 3000 -> ct:fail(no_prack_offer)
    end,
    {R200, _} = recv(Sock, {status, 200, <<"INVITE">>}, 3000),
    send(Sock, EP, chappe_sip_core_peer:ack_for(R200, #{port => port(Sock)})).

%% An INVITE without an offer: a reliable 1xx without SDP is not sent, the
%% first reliable 1xx that goes out carries the offer, and the PRACK
%% bringing the answer is answered 200 by the stack with no body (5).
%% req: R3262-044 R3262-050
uas_offerless_reliable_offer(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Tag = tag(),
    Test = self(),
    C = <<"<", (chappe_sip_core_peer:contact(EP))/binary, ">">>,
    ok = chappe_sip:invite(fun(_Req, Res) ->
        _ = chappe_sip_res:send_reliable(Res, #{status => 180, to_tag => Tag}),
        ok = chappe_sip_res:send_reliable(
            Res, #{
                status => 183,
                to_tag => Tag,
                body => sdp(41000),
                headers => [?SDP_CT, {<<"Contact">>, C}]
            }
        ),
        Test ! {prack, chappe_sip_res:await_prack(Res, 5000)},
        ok = chappe_sip_res:send(Res, 200, #{
            to_tag => Tag,
            body => sdp(41000),
            headers => [
                ?SDP_CT,
                {<<"Contact">>, C}
            ]
        })
    end),
    Inv = request(
        <<"INVITE">>,
        ?APP,
        #{
            port => port(Sock),
            headers => [{<<"Supported">>, <<"100rel">>}]
        }
    ),
    send(Sock, EP, Inv),
    {R1xx, _} = recv(
        Sock,
        fun(B) -> is_1xx(B) andalso status(B) > 100 end,
        3000
    ),
    ?assertEqual(183, status(R1xx)),
    ?assertEqual(sdp(41000), body(R1xx)),
    ?assertNotEqual(undefined, hdr(<<"rseq">>, R1xx)),
    send(Sock, EP, prack(Sock, Inv, R1xx, 2, undefined, sdp(40002))),
    {PR, _} = recv(Sock, resp_to(<<"PRACK">>), 3000),
    ?assertEqual(200, status(PR)),
    ?assertEqual(<<>>, body(PR)),
    receive
        {prack, {ok, Raw}} -> ?assertEqual(sdp(40002), body(Raw))
    after 3000 -> ct:fail(no_prack)
    end,
    {R200, _} = recv(Sock, {status, 200, <<"INVITE">>}, 3000),
    send(Sock, EP, chappe_sip_core_peer:ack_for(R200, #{port => port(Sock)})).

%% The B2BUA does not carry an offer in A's PRACK to a ringing B: the
%% PRACK is answered 488 (never left pending) and the call goes on.
b2b_prack_offer_refused(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    B = open(),
    Callee = <<"sip:callee@127.0.0.1:", (integer_to_binary(port(B)))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, _} = chappe_sip:create_b2bua(Req, Res, Callee, #{})
    end),
    Inv = invite(Sock, [{<<"Supported">>, <<"100rel">>}]),
    send(Sock, EP, Inv),
    {BInv, _} = recv(B, {method, <<"INVITE">>}, 3000),
    BTag = tag(),
    send(B, EP, rel1xx(B, BInv, 183, BTag, 1, sdp(42000))),
    {BPr, _} = recv(B, {method, <<"PRACK">>}, 3000),
    send(B, EP, response(BPr, 200, #{})),
    {R183, _} = recv(Sock, {status, 183}, 3000),
    send(Sock, EP, prack(Sock, Inv, R183, 2, undefined, sdp(40002))),
    {PR, _} = recv(Sock, resp_to(<<"PRACK">>), 3000),
    ?assertEqual(488, status(PR)),
    send(
        B,
        EP,
        response(
            BInv,
            200,
            #{
                to_tag => BTag,
                body => sdp(42000),
                headers => [
                    {<<"Contact">>, <<"<", (early_contact(B))/binary, ">">>}
                ]
            }
        )
    ),
    {_, _} = recv(B, {method, <<"ACK">>}, 3000),
    {R200, _} = recv(Sock, {status, 200, <<"INVITE">>}, 3000),
    send(Sock, EP, chappe_sip_core_peer:ack_for(R200, #{port => port(Sock)})),
    chappe_sip_core_peer:close(B).

%% ---- chappe as UAC (section 4) ----

%% A 100 Trying that claims to be reliable (Require: 100rel, RSeq) is
%% not PRACKed; the reliable 183 after it is (4).
%% req: R3262-031
uac_100_reliable_ignored(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, _} = chappe_sip_uac:start(callee(Sock), #{
        rel100 => supported,
        local_sdp => sdp()
    }),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    Tag = tag(),
    send(
        Sock,
        EP,
        response(Inv, 100, #{
            headers => [
                {<<"Require">>, <<"100rel">>},
                {<<"RSeq">>, <<"1">>}
            ]
        })
    ),
    ok = recv_none(Sock, {method, <<"PRACK">>}, 1000),
    send(Sock, EP, rel1xx(Sock, Inv, 183, Tag, 2, sdp(42000))),
    {Pr, _} = recv(Sock, {method, <<"PRACK">>}, 3000),
    ?assertEqual(<<"2 1 INVITE">>, hdr(<<"rack">>, Pr)),
    complete_uac(Sock, EP, Inv, Pr, Tag, <<>>).

%% The reliable 183 forms the early dialog the PRACK belongs to: the
%% PRACK goes to the 183's Contact with the 183's To tag, our From tag,
%% the INVITE's Call-ID, the next CSeq and RAck naming RSeq and the
%% INVITE's CSeq (4, 7.2). It carries no Require: 100rel (4).
%% req: R3262-032 R3262-028
uac_prack_in_early_dialog(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, _} = chappe_sip_uac:start(callee(Sock), #{
        rel100 => require,
        local_sdp => sdp()
    }),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ?assert(lists:member(<<"100rel">>, tokens(hdrs(<<"require">>, Inv)))),
    Tag = tag(),
    send(Sock, EP, rel1xx(Sock, Inv, 183, Tag, 77, sdp(42000))),
    {Pr, _} = recv(Sock, {method, <<"PRACK">>}, 3000),
    ?assertEqual(early_contact(Sock), uri(Pr)),
    ?assertEqual(Tag, to_tag(Pr)),
    ?assertEqual(from_tag(Inv), from_tag(Pr)),
    ?assertEqual(hdr(<<"call-id">>, Inv), hdr(<<"call-id">>, Pr)),
    {N, <<"INVITE">>} = cseq(Inv),
    ?assertMatch({M, <<"PRACK">>} when M > N, cseq(Pr)),
    ?assertEqual(
        <<"77 ", (integer_to_binary(N))/binary, " INVITE">>,
        hdr(<<"rack">>, Pr)
    ),
    ?assertNot(lists:member(<<"100rel">>, tokens(hdrs(<<"require">>, Pr)))),
    complete_uac(Sock, EP, Inv, Pr, Tag, <<>>).

%% A retransmitted reliable 183 is dropped: one PRACK transaction (its
%% own retransmissions share a branch) and one provisional for the app (4).
%% req: R3262-036
uac_retransmission_dropped(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{
        rel100 => supported,
        local_sdp => sdp()
    }),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    Tag = tag(),
    R183 = rel1xx(Sock, Inv, 183, Tag, 5, sdp(42000)),
    send(Sock, EP, R183),
    timer:sleep(200),
    send(Sock, EP, R183),
    timer:sleep(200),
    send(Sock, EP, R183),
    Pracks = [B || {_, B} <- collect(Sock, {method, <<"PRACK">>}, 1500)],
    ?assert(length(Pracks) >= 1),
    ?assertEqual(
        1, length(lists:usort([via_branch(top_via(P)) || P <- Pracks]))
    ),
    [Pr | _] = Pracks,
    complete_uac(Sock, EP, Inv, Pr, Tag, <<>>),
    ?assertEqual([183], provisionals(Ref)).

%% RSeq ordering: the first reliable 1xx sets the sequence and is PRACKed;
%% one that skips a number is neither PRACKed nor handed to the app; the
%% next in order is; an old one is a retransmission, dropped until the
%% final response (4).
%% req: R3262-037 R3262-038 R3262-039 R3262-040
uac_rseq_in_order(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{
        rel100 => supported,
        local_sdp => sdp()
    }),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    Tag = tag(),
    send(Sock, EP, rel1xx(Sock, Inv, 183, Tag, 10, sdp(42000))),
    {P10, _} = recv(Sock, {method, <<"PRACK">>}, 3000),
    ?assertMatch(<<"10 ", _/binary>>, hdr(<<"rack">>, P10)),
    send(Sock, EP, response(P10, 200, #{})),
    %% a gap: 12 after 10
    send(Sock, EP, rel1xx(Sock, Inv, 181, Tag, 12, <<>>)),
    ok = recv_none(Sock, {method, <<"PRACK">>}, 1000),
    %% in order
    send(Sock, EP, rel1xx(Sock, Inv, 180, Tag, 11, <<>>)),
    {P11, _} = recv(Sock, {method, <<"PRACK">>}, 3000),
    ?assertMatch(<<"11 ", _/binary>>, hdr(<<"rack">>, P11)),
    send(Sock, EP, response(P11, 200, #{})),
    %% an old RSeq under a new status: not acknowledged again
    send(Sock, EP, rel1xx(Sock, Inv, 182, Tag, 10, <<>>)),
    ok = recv_none(Sock, {method, <<"PRACK">>}, 1000),
    R200 = response(Inv, 200, #{
        to_tag => Tag,
        body => sdp(42000),
        headers => [{<<"Contact">>, <<"<", (early_contact(Sock))/binary, ">">>}]
    }),
    send(Sock, EP, R200),
    {_Ack, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    ?assertEqual([183, 180], provisionals(Ref)).

%% An INVITE without an offer: the reliable 183 brings it and the PRACK
%% carries the app's answer; the 2xx then has no new offer and the ACK no
%% body (5).
%% req: R3262-045 R3262-050
uac_answer_in_prack(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Test = self(),
    Answer = sdp(43000),
    {ok, Ref} = chappe_sip_uac:start(
        callee(Sock),
        #{
            rel100 => supported,
            answer => fun(Offer) ->
                Test ! {offer, Offer},
                {ok, Answer}
            end
        }
    ),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ?assertEqual(<<>>, body(Inv)),
    Tag = tag(),
    send(Sock, EP, rel1xx(Sock, Inv, 183, Tag, 1, sdp(42000))),
    {Pr, _} = recv(Sock, {method, <<"PRACK">>}, 3000),
    ?assertEqual(Answer, body(Pr)),
    ?assertEqual(<<"application/sdp">>, hdr(<<"content-type">>, Pr)),
    receive
        {offer, O} -> ?assertEqual(sdp(42000), O)
    after 1000 -> ct:fail(no_offer)
    end,
    {Ack, _} = complete_uac(Sock, EP, Inv, Pr, Tag, sdp(42000)),
    ?assertEqual(<<>>, body(Ack)),
    receive
        {chappe_sip_uac, _, {ok, D}} ->
            ?assertEqual(sdp(42000), chappe_sip_dialog:remote_sdp(D))
    after 3000 -> ct:fail(no_dialog)
    end,
    _ = Ref.

%% rel100 => require puts Require: 100rel on an INVITE only; any other
%% request goes out without it (4).
%% req: R3262-028
uac_require_100rel_invite_only(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    [
        begin
            {ok, _} = chappe_sip:request(callee(Sock), #{
                method => M,
                rel100 => require
            }),
            {R, _} = recv(Sock, {method, M}, 3000),
            ?assertNot(
                lists:member(<<"100rel">>, tokens(hdrs(<<"require">>, R)))
            ),
            send(Sock, EP, response(R, 200, #{to_tag => tag()}))
        end
     || M <- [<<"OPTIONS">>, <<"MESSAGE">>]
    ],
    ok.

%% ---- helpers ----

%% the caller's INVITE from the peer, with an SDP offer
invite(Sock, Hdrs) ->
    request(<<"INVITE">>, ?APP, #{
        port => port(Sock),
        body => sdp(),
        headers => Hdrs
    }).

%% a PRACK for the reliable R1xx of Inv, CSeq N; RAck from R1xx unless
%% RSeq is given
prack(Sock, Inv, R1xx, N) ->
    prack(Sock, Inv, R1xx, N, undefined).

prack(Sock, Inv, R1xx, N, RSeq) ->
    prack(Sock, Inv, R1xx, N, RSeq, <<>>).

prack(Sock, Inv, R1xx, N, RSeq0, Body) ->
    RSeq =
        case RSeq0 of
            undefined -> hdr(<<"rseq">>, R1xx);
            R -> integer_to_binary(R)
        end,
    {IN, _} = cseq(Inv),
    request(
        <<"PRACK">>,
        ?APP,
        #{
            port => port(Sock),
            call_id => hdr(<<"call-id">>, Inv),
            from_tag => from_tag(Inv),
            to_tag => to_tag(R1xx),
            cseq => N,
            body => Body,
            headers => [
                {<<"RAck">>,
                    <<RSeq/binary, " ", (integer_to_binary(IN))/binary,
                        " INVITE">>}
            ]
        }
    ).

%% the handler's final answer: a dialog on the early dialog's tag
answer(Req, Res, Tag) ->
    chappe_sip:create_uas(Req, Res, #{
        local_sdp => sdp(41000),
        local_tag => Tag
    }).

%% PRACK the reliable R1xx, then take the 2xx and ACK it
finish_uas(Sock, EP, Inv, R1xx) ->
    send(Sock, EP, prack(Sock, Inv, R1xx, 2)),
    {_, _} = recv(Sock, {status, 200, <<"PRACK">>}, 3000),
    {R200, _} = recv(Sock, {status, 200, <<"INVITE">>}, 3000),
    send(Sock, EP, chappe_sip_core_peer:ack_for(R200, #{port => port(Sock)})).

ack_non2xx(Inv, Resp) ->
    {N, _} = cseq(Inv),
    iolist_to_binary(
        [
            <<"ACK ">>,
            uri(Inv),
            " SIP/2.0\r\n",
            "Via: ",
            top_via(Inv),
            "\r\n",
            "Max-Forwards: 70\r\n",
            "From: ",
            hdr(<<"from">>, Inv),
            "\r\n",
            "To: ",
            hdr(<<"to">>, Resp),
            "\r\n",
            "Call-ID: ",
            hdr(<<"call-id">>, Inv),
            "\r\n",
            "CSeq: ",
            integer_to_binary(N),
            " ACK\r\n",
            "Content-Length: 0\r\n\r\n"
        ]
    ).

%% the peer's URI as a callee, and the Contact of its early dialog
callee(Sock) ->
    <<"sip:callee@127.0.0.1:", (integer_to_binary(port(Sock)))/binary>>.

early_contact(Sock) ->
    <<"sip:early@127.0.0.1:", (integer_to_binary(port(Sock)))/binary>>.

%% a reliable provisional from the peer as UAS
rel1xx(Sock, Inv, Status, Tag, RSeq, Body) ->
    response(
        Inv,
        Status,
        #{
            to_tag => Tag,
            body => Body,
            headers => [
                {<<"Require">>, <<"100rel">>},
                {<<"RSeq">>, integer_to_binary(RSeq)},
                {<<"Contact">>, <<"<", (early_contact(Sock))/binary, ">">>}
            ]
        }
    ).

%% answer the PRACK, send the 2xx (with Body) and take the ACK
complete_uac(Sock, EP, Inv, Pr, Tag, Body) ->
    send(Sock, EP, response(Pr, 200, #{})),
    send(
        Sock,
        EP,
        response(
            Inv,
            200,
            #{
                to_tag => Tag,
                body => Body,
                headers => [
                    {<<"Contact">>, <<"<", (early_contact(Sock))/binary, ">">>}
                ]
            }
        )
    ),
    recv(Sock, {method, <<"ACK">>}, 3000).

%% the statuses of the provisionals the app was given, in order
provisionals(Ref) ->
    lists:reverse(provisionals(Ref, [])).

provisionals(Ref, Acc) ->
    receive
        {chappe_sip_uac, Ref, {provisional, M}} ->
            provisionals(Ref, [chappe_sip_msg:status(M) | Acc])
    after 0 -> Acc
    end.

is_1xx(<<"SIP/2.0 1", _/binary>>) -> true;
is_1xx(_) -> false.

%% any response to a Method request
resp_to(Method) ->
    fun
        (<<"SIP/2.0 ", _/binary>> = B) -> element(2, cseq(B)) =:= Method;
        (_) -> false
    end.

tokens(Values) ->
    [string:trim(T) || V <- Values, T <- binary:split(V, <<",">>, [global])].
