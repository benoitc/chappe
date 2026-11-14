%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Transfers a B2BUA carries out itself (transfer => auto), over real SIP
%% on loopback through a fake rtpengine.
%%
%% A gen_udp caller (leg A) calls the app, which bridges it to a gen_udp
%% callee (leg B) with media anchored and relays the call. One leg sends a
%% REFER; the B2BUA calls the target on that leg's side, so the other leg
%% keeps its media, and reports to the referrer with NOTIFYs. The flows
%% are RFC 5589's: blind (6), consultation hold (7) and attended (7.3).
-module(chappe_sip_b2b_transfer_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([blind_from_b/1, blind_target_fails/1, offnet_refused/1,
         policy_rejects/1, policy_sees_untrusted_referred_by/1,
         direct_media_refused/1, transfer_limit/1, bye_method_refused/1,
         one_transfer_at_a_time/1, transfer_crash_call_goes_on/1,
         call_end_stops_transfer/1, multiple_refer_unsupported/1]).

all() ->
    [blind_from_b, blind_target_fails, offnet_refused, policy_rejects,
     policy_sees_untrusted_referred_by, direct_media_refused, transfer_limit,
     bye_method_refused, one_transfer_at_a_time, transfer_crash_call_goes_on,
     call_end_stops_transfer, multiple_refer_unsupported].

-define(UA, chappe_sip_test_ua).

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

end_per_testcase(_Case, _Config) ->
    _ = case whereis(xfer_test_rtpe) of
            undefined -> ok;
            Rtpe -> unregister(xfer_test_rtpe), chappe_sip_test_rtpe:stop(Rtpe)
        end,
    _ = [unregister(xfer_test) || whereis(xfer_test) =/= undefined],
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% ---- blind transfer (RFC 5589 6) ----

%% The callee (Bob, the transferor) REFERs the caller (Alice, the
%% transferee) to Carol. The B2BUA answers the REFER 200, never 202, sends
%% NOTIFY 100 Trying, calls Carol with Alice's media through rtpengine
%% (Alice sees no re-INVITE), sends Bob the final NOTIFY 200 with
%% terminated;reason=noresource, and only then hangs Bob up.
%% req: R7647-04 R3515-10 R3515-13 R3515-14 R3515-18 R3515-23
%% req: R5589-01 R5589-02 R5589-03 R5589-04
blind_from_b(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    target(NP, answer),
    caller(EP, fun(Sock, _D) ->
        ok = ?UA:no_req(Sock, <<"INVITE">>, 4000),
        tell(caller_no_reinvite)
    end),
    #{b2b := {_, Ref}} = got(legs),
    ?assertEqual(200, ?UA:status(got(refer_answer))),
    N1 = got(notify),
    ?assertEqual(<<"SIP/2.0 100 Trying\r\n">>, ?UA:body(N1)),
    ?assertMatch(<<"message/sipfrag", _/binary>>,
                 ?UA:hdr(N1, <<"content-type">>)),
    ?assertMatch(<<"refer", _/binary>>, ?UA:hdr(N1, <<"event">>)),
    ?assertMatch(<<"active", _/binary>>, ?UA:hdr(N1, <<"subscription-state">>)),
    Inv = got(target_invite),
    ?assert(chappe_sip_test_rtpe:marked(?UA:body(Inv), offer)),
    N2 = got(notify),
    ?assertEqual(<<"SIP/2.0 200 OK\r\n">>, ?UA:body(N2)),
    ?assertEqual(<<"terminated;reason=noresource">>,
                 ?UA:hdr(N2, <<"subscription-state">>)),
    %% the BYE comes after the final NOTIFY
    _ = got(bye),
    ok = ?UA:expect(caller_no_reinvite, 6000),
    ok = expect_event(Ref, {transfer, b}),
    ok = expect_event(Ref, {replaced, b}),
    ok = expect_event(Ref, {transferred, b}).

%% Carol is busy: Bob's final NOTIFY carries 486, Bob keeps the call and
%% gets no BYE, and Alice saw nothing.
%% req: R5589-02 R5589-05
blind_target_fails(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    target(NP, busy),
    caller(EP, fun(Sock, _D) ->
        ok = ?UA:no_req(Sock, <<"INVITE">>, 3000),
        tell(caller_no_reinvite)
    end),
    #{b2b := {_, Ref} = B2b} = got(legs),
    ?assertEqual(200, ?UA:status(got(refer_answer))),
    _ = got(notify),
    N2 = got(notify),
    ?assertEqual(<<"SIP/2.0 486 Busy Here\r\n">>, ?UA:body(N2)),
    ok = expect_event(Ref, {transfer_failed, b}),
    ok = ?UA:expect(caller_no_reinvite, 6000),
    no_message(bye, 500),
    ?assertMatch(#{media := anchor}, chappe_sip_b2b:info(B2b)).

%% ---- policy and safety ----

%% Without a policy fun a target off this node's domains (another host, a
%% tel: number) is refused 403 before anything is called: a REFER cannot
%% place a call the referrer could not make itself.
%% req: R3515-04 R5589-06
offnet_refused(_Config) ->
    {EP, CP} = setup(#{}),
    callee_refers(CP, EP, <<"<sip:carol@203.0.113.9>">>, []),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    ?assertEqual(403, ?UA:status(got(refer_answer))),
    no_message(notify, 1000).

%% A policy fun decides, with the code it gives.
policy_rejects(_Config) ->
    Policy = fun(#{target := _}) -> {reject, 603} end,
    {EP, CP} = setup(#{transfer_opts => #{policy => Policy}}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    ?assertEqual(603, ?UA:status(got(refer_answer))),
    no_message(notify, 1000).

%% The policy sees the REFER's From (the identity its dialog was formed
%% with) apart from the Referred-By it claims, which nothing checked
%% (RFC 3892 6): a Referred-By naming someone else changes nothing.
%% req: R5589-07
policy_sees_untrusted_referred_by(_Config) ->
    Test = self(),
    Policy = fun(Info) -> Test ! {policy_info, Info}, false end,
    {EP, CP} = setup(#{transfer_opts => #{policy => Policy}}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP),
                  [{<<"Referred-By">>, <<"<sip:ceo@example.com>">>}]),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    #{referrer := Referrer, referred_by := Claimed, leg := b, kind := blind} =
        got(policy_info),
    ?assertMatch(<<"<sip:callee@", _/binary>>, Referrer),
    ?assertEqual(<<"<sip:ceo@example.com>">>, Claimed),
    ?assertEqual(403, ?UA:status(got(refer_answer))).

%% A direct-media call cannot take a new party behind the anchor: 488,
%% and the call goes on.
direct_media_refused(_Config) ->
    {EP, CP} = setup_opts(#{media => direct, notify => self(),
                            transfer => auto}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    ?assertEqual(488, ?UA:status(got(refer_answer))).

%% A call makes at most max_transfers transfers: a loop of REFERs ends.
%% req: R5589-08
transfer_limit(_Config) ->
    {EP, CP} = setup(#{transfer_opts => #{max_transfers => 0}}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    ?assertEqual(403, ?UA:status(got(refer_answer))).

%% A REFER for a BYE on a call is not a transfer.
%% req: R5368-02
bye_method_refused(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    Uri = <<"<sip:new@127.0.0.1:", (integer_to_binary(NP))/binary,
            ";method=BYE>">>,
    callee_refers(CP, EP, Uri, []),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    ?assertEqual(403, ?UA:status(got(refer_answer))).

%% A second REFER while the first one rings is answered 500 with
%% Retry-After; the first goes on.
%% req: R5589-08
one_transfer_at_a_time(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), [], 2),
    target(NP, ring),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    Answers = lists:sort([{?UA:status(R), R} || R <- [got(refer_answer),
                                                      got(refer_answer)]]),
    ?assertMatch([{200, _}, {500, _}], Answers),
    [_, {500, R2}] = Answers,
    ?assertNotEqual(undefined, ?UA:hdr(R2, <<"retry-after">>)).

%% chappe-erlang-patterns: the transfer process crashes while the target
%% rings; the call goes on and takes a new transfer.
transfer_crash_call_goes_on(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    target(NP, ring),
    caller(EP, fun(_Sock, _D) -> ok end),
    #{b2b := B2b} = got(legs),
    ?assertEqual(200, ?UA:status(got(refer_answer))),
    _ = got(target_invite),
    [T] = transfers(),
    exit(T, kill),
    timer:sleep(200),
    ?assertMatch(#{media := anchor}, chappe_sip_b2b:info(B2b)),
    ?assertEqual([], transfers()).

%% chappe-erlang-patterns: the call ends (its relay, the transfer's
%% owner, goes) while the target rings: the transfer stops with it.
call_end_stops_transfer(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    target(NP, ring),
    caller(EP, fun(_Sock, _D) -> ok end),
    #{b2b := B2b} = got(legs),
    _ = got(target_invite),
    [T] = transfers(),
    Mon = erlang:monitor(process, T),
    ok = chappe_sip_b2b:hangup(B2b, #{}),
    receive {'DOWN', Mon, process, T, _} -> ok
    after 5000 -> ct:fail(transfer_outlived_call)
    end.

%% RFC 5368: a REFER with several targets needs multiple-refer, which a
%% B2BUA call does not support: 420 with Unsupported, nothing called.
%% req: R5368-01
multiple_refer_unsupported(_Config) ->
    {EP, CP} = setup(#{}),
    callee_refers(CP, EP, <<"<cid:list@example.com>">>,
                  [{<<"Require">>, <<"multiple-refer">>}]),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    R = got(refer_answer),
    ?assertEqual(420, ?UA:status(R)),
    ?assertEqual(<<"multiple-refer">>, ?UA:hdr(R, <<"unsupported">>)).

%% ---- helpers ----

setup(Opts) ->
    setup_opts(maps:merge(#{media => anchor, notify => self(),
                            transfer => auto}, Opts)).

%% the app bridges every INVITE to the callee port and relays
setup_opts(Opts) ->
    rtpe(),
    EP = ?UA:pick(),
    CP = ?UA:pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:",
                                         (integer_to_binary(EP))/binary>>}),
    Test = self(),
    register(xfer_test, Test),
    Callee = <<"sip:callee@127.0.0.1:", (integer_to_binary(CP))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        case chappe_sip:create_b2bua(Req, Res, Callee, Opts) of
            {ok, Legs} ->
                Test ! {legs, Legs},
                Test ! b2b_up,
                Test ! {relay_done, chappe_sip_b2b:relay(Legs)};
            Err ->
                Test ! {b2b_result, Err}
        end
    end),
    {EP, CP}.

rtpe() ->
    register(xfer_test_rtpe, chappe_sip_test_rtpe:start(spawn(fun sink/0))),
    ok.

sink() -> receive _ -> sink() end.

%% a peer may outlive its case: what it says then goes nowhere
tell(Msg) ->
    case whereis(xfer_test) of
        undefined -> ok;
        Pid -> Pid ! Msg
    end.

refer_to(Port) ->
    <<"<sip:carol@127.0.0.1:", (integer_to_binary(Port))/binary, ">">>.

%% The callee (Bob): answers the INVITE, then sends N REFERs to Uri and
%% serves the dialog: each REFER's final is refer_answer, each NOTIFY is
%% answered 200 (notify), a BYE 200 (bye).
callee_refers(CP, EP, ReferTo, Hdrs) ->
    callee_refers(CP, EP, ReferTo, Hdrs, 1).

callee_refers(CP, EP, ReferTo, Hdrs, N) ->
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Tag = ?UA:tag(),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag, [contact(Sock)],
                                     ?UA:sdp(<<"callee">>))),
        {_Ack, _} = ?UA:recv_req(Sock, <<"ACK">>),
        D0 = ?UA:dialog_from_invite(Sock, Inv, Tag, Src),
        lists:foldl(
          fun(_, D) ->
              {Refer, D1} = ?UA:in_dialog(D, <<"REFER">>,
                                          [{<<"Refer-To">>, ReferTo} | Hdrs],
                                          <<>>),
              ?UA:send(Sock, EP, Refer),
              D1
          end, D0, lists:seq(1, N)),
        serve(Sock, Tag)
    end).

%% answer what the B2BUA sends a peer, and tell the test
serve(Sock, Tag) ->
    receive
        {udp, Sock, _, Src, <<"SIP/2.0 1", _/binary>>} when is_integer(Src) ->
            serve(Sock, Tag);
        {udp, Sock, _, _, <<"SIP/2.0 ", _/binary>> = R} ->
            case maps:get(method, ?UA:cseq(R)) of
                <<"REFER">> -> tell({refer_answer, R});
                _ -> ok
            end,
            serve(Sock, Tag);
        {udp, Sock, _, Src, <<"NOTIFY ", _/binary>> = N} ->
            ?UA:send(Sock, Src, ?UA:resp(N, 200, <<"OK">>, Tag, [], <<>>)),
            tell({notify, N}),
            serve(Sock, Tag);
        {udp, Sock, _, Src, <<"BYE ", _/binary>> = B} ->
            ?UA:send(Sock, Src, ?UA:resp(B, 200, <<"OK">>, Tag, [], <<>>)),
            tell({bye, B}),
            serve(Sock, Tag);
        {udp, Sock, _, _, _} ->
            serve(Sock, Tag)
    end.

%% The transfer target (Carol): answer, busy or ring for ever.
target(Port, How) ->
    ?UA:peer(Port, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({target_invite, Inv}),
        Tag = ?UA:tag(),
        case How of
            answer ->
                ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag,
                                             [contact(Sock)],
                                             ?UA:sdp(<<"carol">>))),
                {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
                serve(Sock, Tag);
            busy ->
                ?UA:send(Sock, Src, ?UA:resp(Inv, 486, <<"Busy Here">>, Tag,
                                             [], <<>>)),
                serve(Sock, Tag);
            ring ->
                ?UA:send(Sock, Src, ?UA:resp(Inv, 180, <<"Ringing">>, Tag,
                                             [contact(Sock)], <<>>)),
                serve(Sock, Tag)
        end
    end).

%% The caller (Alice): INVITEs the app, ACKs its 2xx, then runs Fun.
caller(EP, Fun) ->
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(),
                                     from_tag => ?UA:tag()}),
        ?UA:send(Sock, EP, Inv),
        R = ?UA:recv_status(Sock, 200),
        D = ?UA:dialog_from_2xx(Sock, Inv, R),
        ?UA:ack(D, EP),
        Fun(Sock, D),
        timer:sleep(infinity)
    end),
    ok = ?UA:expect(b2b_up).

contact(Sock) ->
    {<<"Contact">>, <<"<sip:peer@127.0.0.1:",
                      (integer_to_binary(?UA:lport(Sock)))/binary, ">">>}.

got(Tag) ->
    receive {Tag, V} -> V after 10000 -> ct:fail({missing, Tag}) end.

no_message(Tag, Ms) ->
    receive {Tag, V} -> ct:fail({unexpected, Tag, V}) after Ms -> ok end.

%% the next event of the call with this tag and leg
expect_event(Ref, {Tag, Leg}) ->
    receive
        {chappe_sip_b2b, Ref, {Tag, Leg}} -> ok;
        {chappe_sip_b2b, Ref, {Tag, Leg, _}} -> ok
    after 10000 -> ct:fail({no_event, Tag, Leg})
    end.

transfers() ->
    [P || {_, P, _, _} <- supervisor:which_children(chappe_sip_b2b_transfers),
          is_pid(P)].
