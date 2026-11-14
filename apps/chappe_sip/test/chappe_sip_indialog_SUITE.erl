%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Dialog-layer compliance over real SIP on loopback: what the dialog fsm
%% answers to in-dialog requests nobody claimed, offer/answer tracking
%% across re-INVITE, UPDATE and ACK, request glare and overlap, 491 retry
%% on our own re-INVITE, and the default answers for REFER, unknown and
%% unsupported methods.
%%
%% The test process plays the far end on a raw UDP socket
%% (chappe_sip_raw_peer) and owns the dialog, so every status code and
%% header chappe puts on the wire is asserted exactly.
-module(chappe_sip_indialog_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("chappe_sip.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    reinvite_offer_unclaimed/1,
    reinvite_offer_no_local_sdp/1,
    reinvite_offerless/1,
    update_offer_unclaimed/1,
    update_offer_no_local_sdp/1,
    claimed_reinvite_tracks_sdp/1,
    reinvite_glare_491/1,
    reinvite_overlap_500/1,
    update_overlap_500/1,
    update_glare_491/1,
    update_while_offer_received_500/1,
    uac_491_surfaced/1,
    reinvite_reject_acked_once/1,
    uac_491_retry_not_owner/1,
    uac_491_retry_owner/1,
    refer_unclaimed_603/1,
    unknown_method_501/1,
    unsupported_method_405/1,
    options_indialog/1,
    bye_with_reason/1,
    bye_reason_received/1,
    uac_cancel_with_reason/1,
    uas_cancel_reason_received/1,
    early_dialog_update_and_bye/1,
    local_sdp_fun/1
]).

-define(P, chappe_sip_raw_peer).

all() ->
    [
        reinvite_offer_unclaimed,
        reinvite_offer_no_local_sdp,
        reinvite_offerless,
        update_offer_unclaimed,
        update_offer_no_local_sdp,
        claimed_reinvite_tracks_sdp,
        reinvite_glare_491,
        reinvite_overlap_500,
        update_overlap_500,
        update_glare_491,
        update_while_offer_received_500,
        uac_491_surfaced,
        reinvite_reject_acked_once,
        uac_491_retry_not_owner,
        uac_491_retry_owner,
        refer_unclaimed_603,
        unknown_method_501,
        unsupported_method_405,
        options_indialog,
        bye_with_reason,
        bye_reason_received,
        uac_cancel_with_reason,
        uas_cancel_reason_received,
        early_dialog_update_and_bye,
        local_sdp_fun
    ].

init_per_suite(Config) ->
    application:set_env(
        chappe_sip, engine_mod, chappe_sip_nif, [{persistent, true}]
    ),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(_Case, Config) ->
    EP = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>
    }),
    [{ep, EP} | Config].

end_per_testcase(_Case, _Config) ->
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% ---- offer/answer on unclaimed re-INVITE and UPDATE ----

%% RFC 3261 14.2 and RFC 3264 8: a re-INVITE with an offer that the app did
%% not claim is answered with the current local SDP (session unchanged),
%% and the offer becomes the remote SDP.
%% req: R3261-238 R3261-239 R3264-086
reinvite_offer_unclaimed(Config) ->
    {Peer, Dlg} = establish(Config, #{local_sdp => ?P:sdp(<<"app">>)}),
    {N, P1} = ?P:request(Peer, <<"INVITE">>, [], ?P:sdp(<<"caller2">>)),
    R = ?P:recv_final(P1, N, <<"INVITE">>),
    ?assertEqual(200, ?P:status(R)),
    ?assertEqual(?P:sdp(<<"app">>), ?P:body(R)),
    ?assertEqual(<<"application/sdp">>, ?P:header(<<"content-type">>, R)),
    ?assertNotEqual(undefined, ?P:header(<<"contact">>, R)),
    ok = ?P:ack(P1, N, <<>>),
    ?assertEqual(?P:sdp(<<"caller2">>), chappe_sip_dialog:remote_sdp(Dlg)),
    hangup(P1, Dlg).

%% RFC 3261 14.2: no local SDP to answer with, so the offer is not
%% acceptable: 488.
%% req: R3261-240
reinvite_offer_no_local_sdp(Config) ->
    {Peer, Dlg} = establish(Config, #{}),
    {N, P1} = ?P:request(Peer, <<"INVITE">>, [], ?P:sdp(<<"caller2">>)),
    R = ?P:recv_final(P1, N, <<"INVITE">>),
    ?assertEqual(488, ?P:status(R)),
    ?assertEqual(?P:sdp(<<"caller">>), chappe_sip_dialog:remote_sdp(Dlg)),
    hangup(P1, Dlg).

%% RFC 3261 14.2 / 13.2.1: an offerless re-INVITE gets our SDP as the
%% offer in the 2xx; the answer comes in the ACK and becomes remote SDP.
%% req: R3261-210 R3261-191
reinvite_offerless(Config) ->
    {Peer, Dlg} = establish(Config, #{local_sdp => ?P:sdp(<<"app">>)}),
    {N, P1} = ?P:request(Peer, <<"INVITE">>, [], <<>>),
    R = ?P:recv_final(P1, N, <<"INVITE">>),
    ?assertEqual(200, ?P:status(R)),
    ?assertEqual(?P:sdp(<<"app">>), ?P:body(R)),
    ok = ?P:ack(P1, N, ?P:sdp(<<"ackans">>)),
    ok = wait_remote_sdp(Dlg, ?P:sdp(<<"ackans">>), 40),
    hangup(P1, Dlg).

%% RFC 3311 5.2: an UPDATE with an offer is answered in its 2xx.
%% req: R3311-009 R3311-010
update_offer_unclaimed(Config) ->
    {Peer, Dlg} = establish(Config, #{local_sdp => ?P:sdp(<<"app">>)}),
    {N, P1} = ?P:request(Peer, <<"UPDATE">>, [], ?P:sdp(<<"upd">>)),
    R = ?P:recv_final(P1, N, <<"UPDATE">>),
    ?assertEqual(200, ?P:status(R)),
    ?assertEqual(?P:sdp(<<"app">>), ?P:body(R)),
    ?assertEqual(?P:sdp(<<"upd">>), chappe_sip_dialog:remote_sdp(Dlg)),
    %% an UPDATE without an offer changes nothing and carries no body
    {N2, P2} = ?P:request(P1, <<"UPDATE">>, [], <<>>),
    R2 = ?P:recv_final(P2, N2, <<"UPDATE">>),
    ?assertEqual(200, ?P:status(R2)),
    ?assertEqual(<<>>, ?P:body(R2)),
    hangup(P2, Dlg).

%% RFC 3311 5.2: an offer that cannot be answered is refused 488.
%% req: R3311-013
update_offer_no_local_sdp(Config) ->
    {Peer, Dlg} = establish(Config, #{}),
    {N, P1} = ?P:request(Peer, <<"UPDATE">>, [], ?P:sdp(<<"upd">>)),
    ?assertEqual(488, ?P:status(?P:recv_final(P1, N, <<"UPDATE">>))),
    hangup(P1, Dlg).

%% A claimed re-INVITE: the app's 2xx answer becomes the local SDP and the
%% offer the remote SDP (RFC 3264 8).
%% req: R3261-239
claimed_reinvite_tracks_sdp(Config) ->
    {Peer, Dlg} = establish(Config, #{
        local_sdp => ?P:sdp(<<"app">>), handled_events => [modify]
    }),
    {N, P1} = ?P:request(Peer, <<"INVITE">>, [], ?P:sdp(<<"caller2">>)),
    Res = claimed(Dlg, modify),
    ok = chappe_sip_res:send(Res, 200, #{
        body => ?P:sdp(<<"app2">>),
        headers => [{<<"Content-Type">>, <<"application/sdp">>}]
    }),
    R = ?P:recv_final(P1, N, <<"INVITE">>),
    ?assertEqual(200, ?P:status(R)),
    ok = ?P:ack(P1, N, <<>>),
    ok = wait_remote_sdp(Dlg, ?P:sdp(<<"caller2">>), 40),
    %% the next unclaimed offer is answered with the app's new SDP
    ok = chappe_sip_dialog:set_handled(Dlg, []),
    {N2, P2} = ?P:request(P1, <<"UPDATE">>, [], ?P:sdp(<<"upd">>)),
    R2 = ?P:recv_final(P2, N2, <<"UPDATE">>),
    ?assertEqual(?P:sdp(<<"app2">>), ?P:body(R2)),
    hangup(P2, Dlg).

%% ---- glare and overlap ----

%% RFC 3261 14.2: an INVITE arriving while our own re-INVITE is pending
%% gets 491.
%% req: R3261-237
reinvite_glare_491(Config) ->
    {Peer, Dlg} = establish(Config, #{local_sdp => ?P:sdp(<<"app">>)}),
    Self = self(),
    spawn_link(fun() -> Self ! {modified, chappe_sip_dialog:modify(Dlg, hold)} end),
    {Ours, _, Src} = ?P:recv_request(Peer, <<"INVITE">>),
    {N, P1} = ?P:request(Peer, <<"INVITE">>, [], ?P:sdp(<<"caller2">>)),
    ?assertEqual(491, ?P:status(?P:recv_final(P1, N, <<"INVITE">>))),
    ok = ?P:reply(P1, Ours, Src, 200, ?P:sdp(<<"held">>)),
    _ = ?P:recv_request(P1, <<"ACK">>),
    receive
        {modified, R} -> ?assertEqual({ok, ?P:sdp(<<"held">>)}, R)
    after 5000 -> ct:fail(no_modify)
    end,
    hangup(P1, Dlg).

%% RFC 3261 14.2: a second INVITE before we answered the first gets 500
%% with a Retry-After of 0 to 10 seconds.
%% req: R3261-236
reinvite_overlap_500(Config) ->
    {Peer, Dlg} = establish(Config, #{
        local_sdp => ?P:sdp(<<"app">>), handled_events => [modify]
    }),
    {N1, P1} = ?P:request(Peer, <<"INVITE">>, [], ?P:sdp(<<"c2">>)),
    Res = claimed(Dlg, modify),
    {N2, P2} = ?P:request(P1, <<"INVITE">>, [], ?P:sdp(<<"c3">>)),
    R2 = ?P:recv_final(P2, N2, <<"INVITE">>),
    ?assertEqual(500, ?P:status(R2)),
    assert_retry_after(R2),
    ok = chappe_sip_res:send(Res, 200, #{
        body => ?P:sdp(<<"app">>),
        headers => [{<<"Content-Type">>, <<"application/sdp">>}]
    }),
    ?assertEqual(200, ?P:status(?P:recv_final(P2, N1, <<"INVITE">>))),
    ok = ?P:ack(P2, N1, <<>>),
    %% answered: a new INVITE is accepted again
    ok = chappe_sip_dialog:set_handled(Dlg, []),
    {N3, P3} = ?P:request(P2, <<"INVITE">>, [], ?P:sdp(<<"c4">>)),
    ?assertEqual(200, ?P:status(?P:recv_final(P3, N3, <<"INVITE">>))),
    ok = ?P:ack(P3, N3, <<>>),
    hangup(P3, Dlg).

%% RFC 3311 5.2: an UPDATE before we answered the previous one: 500 with
%% Retry-After.
%% req: R3311-005
update_overlap_500(Config) ->
    {Peer, Dlg} = establish(Config, #{
        local_sdp => ?P:sdp(<<"app">>), handled_events => [update]
    }),
    {N1, P1} = ?P:request(Peer, <<"UPDATE">>, [], <<>>),
    Res = claimed(Dlg, update),
    {N2, P2} = ?P:request(P1, <<"UPDATE">>, [], <<>>),
    R2 = ?P:recv_final(P2, N2, <<"UPDATE">>),
    ?assertEqual(500, ?P:status(R2)),
    assert_retry_after(R2),
    ok = chappe_sip_res:send(Res, 200),
    ?assertEqual(200, ?P:status(?P:recv_final(P2, N1, <<"UPDATE">>))),
    hangup(P2, Dlg).

%% RFC 3311 5.2: an UPDATE offer while our own offer is unanswered gets 491
%% (our re-INVITE, then our UPDATE).
%% req: R3311-006
update_glare_491(Config) ->
    {Peer, Dlg} = establish(Config, #{local_sdp => ?P:sdp(<<"app">>)}),
    Self = self(),
    spawn_link(fun() -> Self ! {modified, chappe_sip_dialog:modify(Dlg, hold)} end),
    {Ours, _, Src} = ?P:recv_request(Peer, <<"INVITE">>),
    {N, P1} = ?P:request(Peer, <<"UPDATE">>, [], ?P:sdp(<<"u1">>)),
    ?assertEqual(491, ?P:status(?P:recv_final(P1, N, <<"UPDATE">>))),
    ok = ?P:reply(P1, Ours, Src, 200, ?P:sdp(<<"held">>)),
    receive {modified, {ok, _}} -> ok after 5000 -> ct:fail(no_modify) end,
    spawn_link(fun() ->
        Self !
            {updated,
                chappe_sip_dialog:request(Dlg, #{
                    method => <<"UPDATE">>,
                    content_type => <<"application/sdp">>,
                    body => ?P:sdp(<<"app3">>)
                })}
    end),
    {OurUpd, _, USrc} = ?P:recv_request(P1, <<"UPDATE">>),
    {N2, P2} = ?P:request(P1, <<"UPDATE">>, [], ?P:sdp(<<"u2">>)),
    ?assertEqual(491, ?P:status(?P:recv_final(P2, N2, <<"UPDATE">>))),
    ok = ?P:reply(P2, OurUpd, USrc, 200, ?P:sdp(<<"u3">>)),
    receive {updated, {ok, _}} -> ok after 5000 -> ct:fail(no_update) end,
    %% the 2xx to our UPDATE offer carried the answer
    ?assertEqual(?P:sdp(<<"u3">>), chappe_sip_dialog:remote_sdp(Dlg)),
    hangup(P2, Dlg).

%% RFC 3311 5.2: an UPDATE offer while an offer we received is still
%% unanswered: 500 with Retry-After.
%% req: R3311-007 R3311-008
update_while_offer_received_500(Config) ->
    {Peer, Dlg} = establish(Config, #{
        local_sdp => ?P:sdp(<<"app">>), handled_events => [modify]
    }),
    {N1, P1} = ?P:request(Peer, <<"INVITE">>, [], ?P:sdp(<<"c2">>)),
    Res = claimed(Dlg, modify),
    {N2, P2} = ?P:request(P1, <<"UPDATE">>, [], ?P:sdp(<<"u1">>)),
    R2 = ?P:recv_final(P2, N2, <<"UPDATE">>),
    ?assertEqual(500, ?P:status(R2)),
    assert_retry_after(R2),
    ok = chappe_sip_res:send(Res, 200, #{
        body => ?P:sdp(<<"app">>),
        headers => [{<<"Content-Type">>, <<"application/sdp">>}]
    }),
    _ = ?P:recv_final(P2, N1, <<"INVITE">>),
    ok = ?P:ack(P2, N1, <<>>),
    hangup(P2, Dlg).

%% ---- our re-INVITE refused with 491 ----

%% RFC 3261 14.1: a 491 surfaces as an error and leaves the session as it
%% was (a later unclaimed offer is answered with the pre-hold SDP).
%% req: R3261-233
uac_491_surfaced(Config) ->
    {Peer, Dlg} = establish(Config, #{local_sdp => ?P:sdp(<<"app">>)}),
    Self = self(),
    spawn_link(fun() -> Self ! {modified, chappe_sip_dialog:modify(Dlg, hold)} end),
    {Ours, _, Src} = ?P:recv_request(Peer, <<"INVITE">>),
    ok = ?P:reply(Peer, Ours, Src, 491, <<>>),
    receive
        {modified, R} ->
            ?assertMatch({error, #chappe_sip_error{status = 491}}, R)
    after 5000 -> ct:fail(no_modify)
    end,
    ?P:no_request(Peer, <<"INVITE">>, 2500),
    {N, P1} = ?P:request(Peer, <<"INVITE">>, [], ?P:sdp(<<"c2">>)),
    R2 = ?P:recv_final(P1, N, <<"INVITE">>),
    ?assertEqual(?P:sdp(<<"app">>), ?P:body(R2)),
    ok = ?P:ack(P1, N, <<>>),
    hangup(P1, Dlg).

%% A non-2xx to our re-INVITE is ACKed by the INVITE client transaction,
%% on the INVITE's branch (RFC 3261 17.1.1.3); the dialog must not send a
%% second, 2xx-style ACK. Checked for a plain rejection and for the 491 we
%% retry after.
%% req: R3261-280 R3261-290 R3261-291
reinvite_reject_acked_once(Config) ->
    lists:foreach(
        fun({Status, Opts}) ->
            {Peer, Dlg} = establish(Config, #{local_sdp => ?P:sdp(<<"app">>)}),
            Self = self(),
            spawn_link(fun() ->
                Self ! {modified, chappe_sip_dialog:modify(Dlg, hold, Opts)}
            end),
            {Ours, M, Src} = ?P:recv_request(Peer, <<"INVITE">>),
            ok = ?P:reply(Peer, Ours, Src, Status, <<>>),
            Acks = acks(Peer, 1500),
            ct:pal("~p: ACK branches ~p", [Status, Acks]),
            ?assertEqual([via_branch(M)], Acks),
            case Status of
                491 ->
                    {Again, _, Src2} = ?P:recv_request(Peer, <<"INVITE">>),
                    ok = ?P:reply(Peer, Again, Src2, 488, <<>>);
                _ ->
                    ok
            end,
            receive
                {modified, _} -> ok
            after 8000 -> ct:fail(no_modify)
            end,
            hangup(Peer, Dlg)
        end,
        [{488, #{}}, {491, #{retry_on_glare => true}}]
    ).

acks(#{sock := S} = Peer, T) ->
    receive
        {udp, S, _, _, <<"ACK ", _/binary>> = Bin} ->
            {ok, M} = chappe_sip_msg:parse(Bin),
            [via_branch(M) | acks(Peer, T)]
    after T -> []
    end.

via_branch(M) ->
    {match, [B]} = re:run(
        chappe_sip_msg:get(<<"via">>, M), "branch=([^;,\\s]+)",
        [{capture, all_but_first, binary}]
    ),
    B.

%% RFC 3261 14.1: asked to, we retry once after 0 to 2 s when we do not own
%% the Call-ID (a UAS dialog).
%% req: R3261-234 R3261-235
uac_491_retry_not_owner(Config) ->
    {Peer, Dlg} = establish(Config, #{local_sdp => ?P:sdp(<<"app">>)}),
    Self = self(),
    spawn_link(fun() ->
        Self !
            {modified,
                chappe_sip_dialog:modify(Dlg, hold, #{retry_on_glare => true})}
    end),
    {Ours, M1, Src} = ?P:recv_request(Peer, <<"INVITE">>),
    ok = ?P:reply(Peer, Ours, Src, 491, <<>>),
    T0 = erlang:monotonic_time(millisecond),
    {Again, M2, Src2} = ?P:recv_request(Peer, <<"INVITE">>),
    Waited = erlang:monotonic_time(millisecond) - T0,
    ct:pal("retry after ~p ms", [Waited]),
    ?assert(Waited =< 2000 + 1000),
    ?assert(cseq(M2) > cseq(M1)),
    ok = ?P:reply(Peer, Again, Src2, 200, ?P:sdp(<<"held">>)),
    receive
        {modified, R} -> ?assertEqual({ok, ?P:sdp(<<"held">>)}, R)
    after 5000 -> ct:fail(no_modify)
    end,
    hangup(Peer, Dlg).

%% RFC 3261 14.1: the Call-ID owner (our UAC dialog) waits 2.1 to 4 s, and
%% retries once only: a second 491 surfaces.
%% req: R3261-234 R3261-235
uac_491_retry_owner(Config) ->
    EP = ?config(ep, Config),
    Peer0 = ?P:open(EP),
    Uri = <<"sip:callee@127.0.0.1:", (integer_to_binary(?P:port(Peer0)))/binary>>,
    Self = self(),
    spawn_link(fun() ->
        {ok, D} = chappe_sip:create_uac(Uri, #{
            local_sdp => ?P:sdp(<<"app">>), owner => Self
        }),
        Self ! {uac, D},
        receive stop -> ok end
    end),
    {Inv, _, ISrc} = ?P:recv_request(Peer0, <<"INVITE">>),
    Peer = Peer0#{ft => <<"calleetag">>},
    ok = ?P:reply(Peer, Inv, ISrc, 200, ?P:sdp(<<"callee">>)),
    _ = ?P:recv_request(Peer, <<"ACK">>),
    Dlg = receive {uac, D} -> D after 5000 -> ct:fail(no_uac) end,
    spawn_link(fun() ->
        Self !
            {modified,
                chappe_sip_dialog:modify(Dlg, hold, #{retry_on_glare => true})}
    end),
    {Ours, _, Src} = ?P:recv_request(Peer, <<"INVITE">>),
    ok = ?P:reply(Peer, Ours, Src, 491, <<>>),
    T0 = erlang:monotonic_time(millisecond),
    {Again, _, Src2} = ?P:recv_request(Peer, <<"INVITE">>),
    Waited = erlang:monotonic_time(millisecond) - T0,
    ct:pal("owner retry after ~p ms", [Waited]),
    ?assert(Waited >= 2100),
    ?assert(Waited =< 4000 + 1000),
    ok = ?P:reply(Peer, Again, Src2, 491, <<>>),
    receive
        {modified, R} ->
            ?assertMatch({error, #chappe_sip_error{status = 491}}, R)
    after 5000 -> ct:fail(no_modify)
    end,
    ?P:no_request(Peer, <<"INVITE">>, 4500),
    spawn_link(fun() -> Self ! {bye, chappe_sip_dialog:destroy(Dlg)} end),
    {Bye, _, BSrc} = ?P:recv_request(Peer, <<"BYE">>),
    ok = ?P:reply(Peer, Bye, BSrc, 200, <<>>),
    receive {bye, ok} -> ok after 5000 -> ct:fail(no_bye) end.

%% ---- default answers ----

%% An in-dialog REFER no handler claims is declined (RFC 3515 2.4.2 lets a
%% UA refuse a REFER; 603 tells the referrer it was not accepted).
%% req: R3515-07
refer_unclaimed_603(Config) ->
    {Peer, Dlg} = establish(Config, #{local_sdp => ?P:sdp(<<"app">>)}),
    {N, P1} = ?P:request(
        Peer, <<"REFER">>, [{<<"Refer-To">>, <<"<sip:x@127.0.0.1>">>}], <<>>
    ),
    ?assertEqual(603, ?P:status(?P:recv_final(P1, N, <<"REFER">>))),
    hangup(P1, Dlg).

%% RFC 3261 8.2.1: a method we do not recognise gets 501, with Allow.
%% req: R3261-21.5.2-1 R3261-073 R3261-070
unknown_method_501(Config) ->
    {Peer, Dlg} = establish(Config, #{local_sdp => ?P:sdp(<<"app">>)}),
    {N, P1} = ?P:request(Peer, <<"FOO">>, [], <<>>),
    R = ?P:recv_final(P1, N, <<"FOO">>),
    ?assertEqual(501, ?P:status(R)),
    assert_allow(R),
    hangup(P1, Dlg).

%% RFC 3261 8.2.1 / 21.4.6: a method we know but do not accept in a dialog
%% gets 405 carrying Allow.
%% req: R3261-071 R3261-072 R3261-073 R3261-426 R3261-070 R3261-485
unsupported_method_405(Config) ->
    {Peer, Dlg} = establish(Config, #{local_sdp => ?P:sdp(<<"app">>)}),
    {N, P1} = ?P:request(Peer, <<"PUBLISH">>, [], <<>>),
    R = ?P:recv_final(P1, N, <<"PUBLISH">>),
    ?assertEqual(405, ?P:status(R)),
    assert_allow(R),
    ?assertEqual(nomatch, binary:match(allow(R), <<"PUBLISH">>)),
    hangup(P1, Dlg).

%% create_uas/3 local_sdp as a fun of the caller's offer.
local_sdp_fun(Config) ->
    {Peer, Dlg} = establish_raw(Config, #{
        local_sdp => fun(Offer) ->
            <<(?P:sdp(<<"app">>))/binary,
              (integer_to_binary(byte_size(Offer)))/binary>>
        end
    }),
    {R, P1} = Peer,
    Want = <<(?P:sdp(<<"app">>))/binary,
             (integer_to_binary(byte_size(?P:sdp(<<"caller">>))))/binary>>,
    ?assertEqual(Want, ?P:body(R)),
    ?assertEqual(Want, chappe_sip_dialog:local_sdp(Dlg)),
    hangup(P1, Dlg).

%% RFC 3261 11.2: an in-dialog OPTIONS is answered 200 with Allow, Accept
%% and Supported (which lists replaces, RFC 3891 6.1).
%% req: R3261-O-001 R3261-O-007 R3891-16
options_indialog(Config) ->
    {Peer, Dlg} = establish(Config, #{local_sdp => ?P:sdp(<<"app">>)}),
    {N, P1} = ?P:request(Peer, <<"OPTIONS">>, [], <<>>),
    R = ?P:recv_final(P1, N, <<"OPTIONS">>),
    ?assertEqual(200, ?P:status(R)),
    assert_allow(R),
    ?assertEqual(<<"application/sdp">>, ?P:header(<<"accept">>, R)),
    ?assertMatch({_, _}, binary:match(?P:header(<<"supported">>, R), <<"replaces">>)),
    hangup(P1, Dlg).

%% ---- Reason on BYE (RFC 3326) ----

%% destroy/2 puts the caller's headers (a Reason) on the BYE.
%% req: R3326-01
bye_with_reason(Config) ->
    {Peer, Dlg} = establish(Config, #{local_sdp => ?P:sdp(<<"app">>)}),
    Self = self(),
    Reason = <<"Q.850;cause=16;text=\"Normal call clearing\"">>,
    spawn_link(fun() ->
        Self !
            {bye,
                chappe_sip_dialog:destroy(Dlg, #{
                    headers => [{<<"Reason">>, Reason}]
                })}
    end),
    {Bye, M, Src} = ?P:recv_request(Peer, <<"BYE">>),
    ?assertEqual(Reason, ?P:header(<<"reason">>, M)),
    ok = ?P:reply(Peer, Bye, Src, 200, <<>>),
    receive {bye, ok} -> ok after 5000 -> ct:fail(no_bye) end.

%% A received BYE's Reason reaches the owner on the destroy event.
%% req: R3326-01
bye_reason_received(Config) ->
    {Peer, Dlg} = establish(Config, #{local_sdp => ?P:sdp(<<"app">>)}),
    Reason = <<"SIP;cause=200;text=\"Call completed elsewhere\"">>,
    {N, P1} = ?P:request(Peer, <<"BYE">>, [{<<"Reason">>, Reason}], <<>>),
    ?assertEqual(200, ?P:status(?P:recv_final(P1, N, <<"BYE">>))),
    receive
        {chappe_sip_dialog, Dlg, destroy, Req} ->
            ?assertEqual(Reason, chappe_sip_req:get(<<"reason">>, Req))
    after 5000 -> ct:fail(no_destroy)
    end.

%% ---- Reason on CANCEL (RFC 3326) ----

%% chappe_sip_uac:cancel/2 puts the caller's headers (a Reason) on the
%% CANCEL.
%% req: R3326-01
uac_cancel_with_reason(Config) ->
    EP = ?config(ep, Config),
    Peer0 = ?P:open(EP),
    Uri = <<"sip:callee@127.0.0.1:", (integer_to_binary(?P:port(Peer0)))/binary>>,
    {ok, Ref} = chappe_sip_uac:start(Uri, #{local_sdp => ?P:sdp(<<"app">>)}),
    {Inv, _, Src} = ?P:recv_request(Peer0, <<"INVITE">>),
    Peer = Peer0#{ft => <<"calleetag">>},
    ok = ?P:reply(Peer, Inv, Src, 180, <<>>),
    Reason = <<"SIP;cause=200;text=\"Call completed elsewhere\"">>,
    ok = chappe_sip_uac:cancel(Ref, #{headers => [{<<"Reason">>, Reason}]}),
    {Can, CM, CSrc} = ?P:recv_request(Peer, <<"CANCEL">>),
    ?assertEqual(Reason, ?P:header(<<"reason">>, CM)),
    ok = ?P:reply(Peer, Can, CSrc, 200, <<>>),
    ok = ?P:reply(Peer, Inv, Src, 487, <<>>),
    ?assertMatch(
        {error, #chappe_sip_error{status = 487}}, chappe_sip_uac:await(Ref, 5000)
    ).

%% A received CANCEL reaches the INVITE handler with the CANCEL request, so
%% its Reason is readable.
%% req: R3326-01
uas_cancel_reason_received(Config) ->
    EP = ?config(ep, Config),
    Test = self(),
    ok = chappe_sip:invite(fun(_Req, Res) ->
        ok = chappe_sip_res:send(Res, 180),
        receive
            {chappe_sip_cancel, _, CReq} ->
                Test ! {cancelled, chappe_sip_req:get(<<"reason">>, CReq)},
                chappe_sip_res:send(Res, 487)
        after 5000 -> Test ! no_cancel
        end
    end),
    Peer = ?P:invite(?P:open(EP), <<"caller">>, #{}),
    ok = recv_status(Peer, 1, <<"INVITE">>, 180),
    Reason = <<"Q.850;cause=31">>,
    ok = ?P:cancel(Peer, [{<<"Reason">>, Reason}]),
    ?assertEqual(200, ?P:status(?P:recv_final(Peer, 1, <<"CANCEL">>))),
    receive
        {cancelled, Got} -> ?assertEqual(Reason, Got);
        no_cancel -> ct:fail(no_cancel)
    after 6000 -> ct:fail(no_cancel)
    end,
    ?assertEqual(487, ?P:status(?P:recv_final(Peer, 1, <<"INVITE">>))).

%% ---- early dialogs (RFC 3261 12.1, 15; RFC 3311 5.1) ----

%% Our 183 forms an early dialog with the caller. In it the caller's
%% UPDATE offer is answered with our session and our own UPDATE goes out
%% and is answered; the caller's BYE then ends the early dialog: 200 to
%% the BYE and 487 to its INVITE.
%% req: R3311-001 R3261-250 R3261-259 R3261-260
early_dialog_update_and_bye(Config) ->
    EP = ?config(ep, Config),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, D} = chappe_sip:create_uas(Req, Res, #{
            status => 183, local_sdp => ?P:sdp(<<"app">>), owner => Test
        }),
        Test ! {dialog, D},
        receive stop -> ok after 60000 -> ok end
    end),
    Peer0 = ?P:invite(?P:open(EP), <<"caller">>, #{}),
    R183 = recv_provisional(Peer0, 183),
    Peer = Peer0#{tt => chappe_sip_msg:to_tag(R183)},
    Dlg = receive {dialog, D} -> D after 5000 -> ct:fail(no_dialog) end,
    {N1, P1} = ?P:request(Peer, <<"UPDATE">>, [], ?P:sdp(<<"u1">>)),
    R1 = ?P:recv_final(P1, N1, <<"UPDATE">>),
    ?assertEqual(200, ?P:status(R1)),
    ?assertEqual(?P:sdp(<<"app">>), ?P:body(R1)),
    spawn_link(fun() ->
        Test !
            {updated,
                chappe_sip_dialog:request(Dlg, #{
                    method => <<"UPDATE">>,
                    content_type => <<"application/sdp">>,
                    body => ?P:sdp(<<"app2">>)
                })}
    end),
    {Upd, UMsg, Src} = ?P:recv_request(P1, <<"UPDATE">>),
    ?assertEqual(
        chappe_sip_msg:to_tag(R183), chappe_sip_msg:from_tag(UMsg)
    ),
    ok = ?P:reply(P1, Upd, Src, 200, ?P:sdp(<<"u2">>)),
    receive
        {updated, {ok, M}} -> ?assertEqual(200, chappe_sip_msg:status(M))
    after 5000 -> ct:fail(no_update)
    end,
    {N3, P3} = ?P:request(P1, <<"BYE">>, [], <<>>),
    ?assertEqual(200, ?P:status(?P:recv_final(P3, N3, <<"BYE">>))),
    ?assertEqual(487, ?P:status(?P:recv_final(P3, 1, <<"INVITE">>))),
    receive
        {chappe_sip_dialog, Dlg, destroy, _} -> ok
    after 5000 -> ct:fail(no_destroy)
    end,
    ?P:close(P3).

%% ---- helpers ----

recv_provisional(Peer, Want) ->
    R = ?P:recv_response(Peer, 1, <<"INVITE">>),
    case ?P:status(R) of
        Want -> R;
        S when S < Want -> recv_provisional(Peer, Want);
        S -> ct:fail({status, S, expected, Want})
    end.

recv_status(Peer, N, Method, Want) ->
    case ?P:status(?P:recv_response(Peer, N, Method)) of
        Want -> ok;
        S when S < 200 -> recv_status(Peer, N, Method, Want);
        S -> ct:fail({status, S, expected, Want})
    end.

%% The peer calls the app, which answers with Opts; the test process owns
%% the dialog.
establish(Config, Opts) ->
    EP = ?config(ep, Config),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, D} = chappe_sip:create_uas(Req, Res, Opts#{owner => Test}),
        Test ! {dialog, D},
        receive stop -> ok after 60000 -> ok end
    end),
    Peer0 = ?P:invite(?P:open(EP), <<"caller">>, #{}),
    R = ?P:recv_final(Peer0, 1, <<"INVITE">>),
    200 = ?P:status(R),
    Peer = Peer0#{tt => chappe_sip_msg:to_tag(R)},
    ok = ?P:ack(Peer, 1, <<>>),
    Dlg = receive {dialog, D} -> D after 5000 -> ct:fail(no_dialog) end,
    {Peer, Dlg}.

%% establish/2, returning the 2xx too: {{R200, Peer}, Dlg}
establish_raw(Config, Opts) ->
    EP = ?config(ep, Config),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, D} = chappe_sip:create_uas(Req, Res, Opts#{owner => Test}),
        Test ! {dialog, D},
        receive stop -> ok after 60000 -> ok end
    end),
    Peer0 = ?P:invite(?P:open(EP), <<"caller">>, #{}),
    R = ?P:recv_final(Peer0, 1, <<"INVITE">>),
    200 = ?P:status(R),
    Peer = Peer0#{tt => chappe_sip_msg:to_tag(R)},
    ok = ?P:ack(Peer, 1, <<>>),
    Dlg = receive {dialog, D} -> D after 5000 -> ct:fail(no_dialog) end,
    {{R, Peer}, Dlg}.

hangup(Peer, Dlg) ->
    Self = self(),
    spawn_link(fun() -> Self ! {hung_up, chappe_sip_dialog:destroy(Dlg)} end),
    {Bye, _, Src} = ?P:recv_request(Peer, <<"BYE">>),
    ok = ?P:reply(Peer, Bye, Src, 200, <<>>),
    receive {hung_up, ok} -> ok after 5000 -> ct:fail(no_hangup) end,
    ?P:close(Peer).

claimed(Dlg, Event) ->
    receive
        {chappe_sip_dialog, Dlg, Event, _Req, Res} -> Res
    after 5000 -> ct:fail({not_claimed, Event})
    end.

wait_remote_sdp(Dlg, Want, 0) ->
    ?assertEqual(Want, chappe_sip_dialog:remote_sdp(Dlg));
wait_remote_sdp(Dlg, Want, N) ->
    case chappe_sip_dialog:remote_sdp(Dlg) of
        Want ->
            ok;
        _ ->
            timer:sleep(50),
            wait_remote_sdp(Dlg, Want, N - 1)
    end.

assert_retry_after(R) ->
    RA = ?P:header(<<"retry-after">>, R),
    ?assertNotEqual(undefined, RA),
    Secs = binary_to_integer(hd(binary:split(RA, [<<";">>, <<" ">>]))),
    ?assert(Secs >= 0 andalso Secs =< 10).

allow(R) ->
    iolist_to_binary(lists:join(<<",">>, ?P:headers(<<"allow">>, R))).

assert_allow(R) ->
    A = allow(R),
    [
        ?assertMatch({_, _}, binary:match(A, M))
     || M <- [<<"INVITE">>, <<"ACK">>, <<"BYE">>, <<"CANCEL">>, <<"UPDATE">>]
    ],
    ok.

cseq(M) ->
    {ok, #{seq := N}} = chappe_sip_msg:cseq(M),
    N.
