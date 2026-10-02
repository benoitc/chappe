%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% RFC 3891 Replaces: the dialog index behind chappe_sip:find_dialog/3 and
%% chappe_sip:find_replaced/1.
%%
%% The test process owns a gen_udp socket and plays the far end of a real
%% dialog set up through the engine, then checks that the index finds that
%% dialog by its RFC 3891 orientation (to-tag = our local tag, from-tag =
%% the peer's tag), refuses the swapped or unknown identities, reports the
%% dialog state, and forgets the dialog on every way it can end.
%%
%% The removal tests suspend the index gen_server, so the only thing that can
%% clear the entry is the dialog fsm itself: that pins the fsm's own cleanup
%% rather than letting the monitor-based sweep mask a missing removal.
-module(chappe_sip_replaces_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("chappe_sip.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([
    uas_find_dialog/1,
    uas_find_replaced_live/1,
    find_replaced_rules/1,
    find_replaced_rejects/1,
    uac_orientation/1,
    removed_after_peer_bye/1,
    removed_after_local_bye/1,
    terminated_while_bye_in_flight/1,
    removed_after_owner_death/1,
    removed_after_fsm_crash/1,
    removed_after_engine_restart/1,
    response_rules/1,
    response_terminated_603/1,
    response_early_not_ours_481/1,
    response_live_481/1,
    uac_early_replaceable/1,
    uac_early_then_confirmed/1,
    supported_on_uas_2xx/1,
    require_replaces_accepted/1,
    replaces_non_invite_dialog_481/1
]).

-define(TAB, chappe_sip_dialog_index).

all() ->
    [uas_find_dialog, uas_find_replaced_live, find_replaced_rules,
     find_replaced_rejects, uac_orientation, removed_after_peer_bye,
     removed_after_local_bye, terminated_while_bye_in_flight,
     removed_after_owner_death, removed_after_fsm_crash,
     removed_after_engine_restart, response_rules, response_terminated_603,
     response_early_not_ours_481, response_live_481, uac_early_replaceable,
     uac_early_then_confirmed, supported_on_uas_2xx,
     require_replaces_accepted, replaces_non_invite_dialog_481].

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
    %% never leave the index server suspended for the next case
    try sys:resume(chappe_sip_dialog_index) catch _:_ -> ok end,
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% ---- cases ----

%% the UAS dialog is found by (call-id, local tag, remote tag) and by nothing
%% else
uas_find_dialog(_Config) ->
    {EP, Sock} = setup(),
    {Call, FT, TT, Dlg, _Owner} = establish(EP, Sock),
    ?assertEqual({ok, Dlg}, chappe_sip:find_dialog(Call, TT, FT)),
    %% swapped orientation, a wrong tag, an unknown call-id
    ?assertEqual({error, not_found}, chappe_sip:find_dialog(Call, FT, TT)),
    ?assertEqual({error, not_found}, chappe_sip:find_dialog(Call, TT, <<"x">>)),
    ?assertEqual({error, not_found}, chappe_sip:find_dialog(Call, <<"x">>, FT)),
    ?assertEqual({error, not_found},
                 chappe_sip:find_dialog(<<"nope@ct">>, TT, FT)),
    %% call-id and tags compare case-sensitively
    ?assertEqual({error, not_found},
                 chappe_sip:find_dialog(string:uppercase(Call), TT, FT)),
    hangup(Sock, Dlg, TT).

%% an INVITE carrying Replaces, received through the engine, resolves to the
%% dialog it names; the swapped tags do not
uas_find_replaced_live(_Config) ->
    {EP, Sock} = setup(),
    {Call, FT, TT, Dlg, _Owner} = establish(EP, Sock),
    Good = <<Call/binary, ";to-tag=", TT/binary, ";from-tag=", FT/binary>>,
    send(Sock, EP, invite(Sock, callid(), <<"r1">>, [{<<"Replaces">>, Good}])),
    receive
        {replaced, R1} ->
            ?assertEqual(
               {ok, Dlg, #{state => confirmed, role => uas,
                           early_only => false}}, R1)
    after 5000 -> ct:fail(no_replaced)
    end,
    _ = recv_status(Sock, 486),
    Swapped = <<Call/binary, ";to-tag=", FT/binary, ";from-tag=", TT/binary>>,
    send(Sock, EP, invite(Sock, callid(), <<"r2">>,
                          [{<<"Replaces">>, Swapped}])),
    receive
        {replaced, R2} -> ?assertEqual({error, not_found}, R2)
    after 5000 -> ct:fail(no_replaced)
    end,
    hangup(Sock, Dlg, TT).

%% early-only against a confirmed dialog is reported so the caller can 486
find_replaced_rules(_Config) ->
    {EP, Sock} = setup(),
    {Call, FT, TT, Dlg, _Owner} = establish(EP, Sock),
    Base = <<Call/binary, ";to-tag=", TT/binary, ";from-tag=", FT/binary>>,
    ?assertEqual(
       {ok, Dlg, #{state => confirmed, role => uas, early_only => true}},
       chappe_sip:find_replaced(req(<<"INVITE">>,
                                    [{<<"Replaces">>,
                                      <<Base/binary, ";early-only">>}]))),
    %% header name in any case, params in any order
    ?assertMatch(
       {ok, Dlg, #{early_only := false}},
       chappe_sip:find_replaced(
         req(<<"INVITE">>,
             [{<<"replaces">>, <<Call/binary, ";from-tag=", FT/binary,
                                 ";to-tag=", TT/binary>>}]))),
    %% the same identity under a wrong tag is not this dialog
    ?assertEqual(
       {error, not_found},
       chappe_sip:find_replaced(
         req(<<"INVITE">>,
             [{<<"Replaces">>, <<Call/binary, ";to-tag=", TT/binary,
                                 ";from-tag=zz">>}]))),
    hangup(Sock, Dlg, TT).

%% RFC 3891 section 3: no header, a malformed header, two headers, or
%% Replaces on something other than INVITE
find_replaced_rejects(_Config) ->
    V = <<"c@h;to-tag=a;from-tag=b">>,
    ?assertEqual({error, no_replaces},
                 chappe_sip:find_replaced(req(<<"INVITE">>, []))),
    ?assertEqual({error, bad_request},
                 chappe_sip:find_replaced(
                   req(<<"INVITE">>, [{<<"Replaces">>, <<"c@h;to-tag=a">>}]))),
    ?assertEqual({error, bad_request},
                 chappe_sip:find_replaced(
                   req(<<"INVITE">>, [{<<"Replaces">>, V},
                                      {<<"Replaces">>, V}]))),
    ?assertEqual({error, bad_request},
                 chappe_sip:find_replaced(
                   req(<<"INVITE">>, [{<<"Replaces">>, <<V/binary, ",", V/binary>>}]))),
    ?assertEqual({error, bad_request},
                 chappe_sip:find_replaced(
                   req(<<"REFER">>, [{<<"Replaces">>, V}]))),
    %% a well-formed value naming nothing
    ?assertEqual({error, not_found},
                 chappe_sip:find_replaced(
                   req(<<"INVITE">>, [{<<"Replaces">>, V}]))).

%% a UAC dialog: our local tag is the From tag we sent, the remote tag is the
%% peer's To tag
uac_orientation(_Config) ->
    {EP, Sock} = setup(),
    {ok, UasPort} = inet:port(Sock),
    Test = self(),
    Uri = <<"sip:callee@127.0.0.1:", (integer_to_binary(UasPort))/binary>>,
    spawn_link(fun() ->
        R = chappe_sip:create_uac(Uri, #{contact => ctc(EP), local_sdp => sdp()}),
        Test ! {uac, R},
        receive stop -> ok end
    end),
    {Inv, Src} = recv(Sock, <<"INVITE">>),
    {ok, InvMsg} = chappe_sip_msg:parse(Inv),
    Call = chappe_sip_msg:call_id(InvMsg),
    LT = chappe_sip_msg:from_tag(InvMsg),
    PT = <<"peer", (binary:encode_hex(crypto:strong_rand_bytes(3)))/binary>>,
    send(Sock, Src, resp(Inv, 200, <<"OK">>, PT,
                         [{<<"Contact">>, peer_ctc(UasPort)}], sdp())),
    _ = recv(Sock, <<"ACK">>),
    Dlg = receive {uac, {ok, D}} -> D after 5000 -> ct:fail(no_uac) end,
    ?assertEqual({ok, Dlg}, chappe_sip:find_dialog(Call, LT, PT)),
    ?assertEqual({error, not_found}, chappe_sip:find_dialog(Call, PT, LT)),
    ?assertEqual(
       {ok, Dlg, #{state => confirmed, role => uac, early_only => false}},
       chappe_sip:find_replaced(
         req(<<"INVITE">>, [{<<"Replaces">>, <<Call/binary, ";to-tag=",
                                                LT/binary, ";from-tag=",
                                                PT/binary>>}]))),
    Self = self(),
    spawn_link(fun() -> Self ! {destroyed, chappe_sip_dialog:destroy(Dlg)} end),
    {Bye, BSrc} = recv(Sock, <<"BYE">>),
    send(Sock, BSrc, resp(Bye, 200, <<"OK">>, PT, [], <<>>)),
    receive {destroyed, ok} -> ok after 5000 -> ct:fail(no_destroy) end.

%% peer BYE: once the owner is told the dialog is gone, it is not findable
removed_after_peer_bye(_Config) ->
    {EP, Sock} = setup(),
    {Call, FT, TT, Dlg, _Owner} = establish(EP, Sock),
    ?assertEqual({ok, Dlg}, chappe_sip:find_dialog(Call, TT, FT)),
    ok = sys:suspend(chappe_sip_dialog_index),
    send(Sock, EP, bye(Sock, Call, FT, TT)),
    _ = recv_status(Sock, 200),
    receive {destroyed, Dlg} -> ok after 5000 -> ct:fail(no_destroy) end,
    ?assertEqual({error, not_found}, chappe_sip:find_dialog(Call, TT, FT)),
    ?assertNot(ets:member(?TAB, {Call, TT, FT})),
    ok = sys:resume(chappe_sip_dialog_index).

%% app BYE: when destroy/1 returns, the dialog is not findable
removed_after_local_bye(_Config) ->
    {EP, Sock} = setup(),
    {Call, FT, TT, Dlg, _Owner} = establish(EP, Sock),
    ok = sys:suspend(chappe_sip_dialog_index),
    Self = self(),
    spawn_link(fun() -> Self ! {destroy_done, chappe_sip_dialog:destroy(Dlg)} end),
    {Bye, BSrc} = recv(Sock, <<"BYE">>),
    send(Sock, BSrc, resp(Bye, 200, <<"OK">>, TT, [], <<>>)),
    receive {destroy_done, ok} -> ok after 5000 -> ct:fail(no_destroy) end,
    ?assertEqual({error, not_found}, chappe_sip:find_dialog(Call, TT, FT)),
    ?assertNot(ets:member(?TAB, {Call, TT, FT})),
    ok = sys:resume(chappe_sip_dialog_index).

%% while our BYE is unanswered the dialog is terminated (RFC 3891: 603)
terminated_while_bye_in_flight(_Config) ->
    {EP, Sock} = setup(),
    {Call, FT, TT, Dlg, _Owner} = establish(EP, Sock),
    Self = self(),
    spawn_link(fun() -> Self ! {destroy_done, chappe_sip_dialog:destroy(Dlg)} end),
    {Bye, BSrc} = recv(Sock, <<"BYE">>),
    Val = <<Call/binary, ";to-tag=", TT/binary, ";from-tag=", FT/binary>>,
    ?assertMatch(
       {ok, Dlg, #{state := terminated}},
       chappe_sip:find_replaced(req(<<"INVITE">>, [{<<"Replaces">>, Val}]))),
    send(Sock, BSrc, resp(Bye, 200, <<"OK">>, TT, [], <<>>)),
    receive {destroy_done, ok} -> ok after 5000 -> ct:fail(no_destroy) end,
    ?assertEqual({error, not_found}, chappe_sip:find_dialog(Call, TT, FT)).

%% the owner dies: the fsm BYEs and forgets the dialog on its own
removed_after_owner_death(_Config) ->
    {EP, Sock} = setup(),
    {Call, FT, TT, Dlg, Owner} = establish(EP, Sock),
    MRef = chappe_sip_dialog:monitor(Dlg),
    ok = sys:suspend(chappe_sip_dialog_index),
    Owner ! exit_owner,
    {Bye, BSrc} = recv(Sock, <<"BYE">>),
    send(Sock, BSrc, resp(Bye, 200, <<"OK">>, TT, [], <<>>)),
    receive {'DOWN', MRef, process, _, _} -> ok
    after 5000 -> ct:fail(fsm_alive) end,
    ?assertNot(ets:member(?TAB, {Call, TT, FT})),
    ?assertEqual({error, not_found}, chappe_sip:find_dialog(Call, TT, FT)),
    ok = sys:resume(chappe_sip_dialog_index).

%% the fsm is killed (no terminate/3): the index monitor sweeps the entry
removed_after_fsm_crash(_Config) ->
    {EP, Sock} = setup(),
    {Call, FT, TT, Dlg, _Owner} = establish(EP, Sock),
    ?assert(ets:member(?TAB, {Call, TT, FT})),
    exit(element(2, Dlg), kill),
    ?assertEqual(ok, wait_gone({Call, TT, FT}, 40)),
    ?assertEqual({error, not_found}, chappe_sip:find_dialog(Call, TT, FT)).

%% a controlled engine restart tears dialogs down and empties their entries
removed_after_engine_restart(_Config) ->
    {EP, Sock} = setup(),
    {Call, FT, TT, Dlg, _Owner} = establish(EP, Sock),
    ?assertEqual({ok, Dlg}, chappe_sip:find_dialog(Call, TT, FT)),
    ok = chappe_sip_engine:restart_engine(),
    receive {destroyed, Dlg} -> ok after 5000 -> ct:fail(no_teardown) end,
    ?assertEqual(ok, wait_gone({Call, TT, FT}, 40)),
    ?assertEqual({error, not_found}, chappe_sip:find_dialog(Call, TT, FT)).

%% ---- replaces_response/1: the RFC 3891 section 3 answer ----

%% one Replaces naming a confirmed dialog is accepted; early-only on it is
%% 486; no match is 481; two headers, a malformed one, one on a non-INVITE,
%% or one with Join is 400; none at all is no_replaces
%% req: R3891-01 R3891-02 R3891-04 R3891-11 R3891-15
response_rules(_Config) ->
    {EP, Sock} = setup(),
    {Call, FT, TT, Dlg, _Owner} = establish(EP, Sock),
    V = <<Call/binary, ";to-tag=", TT/binary, ";from-tag=", FT/binary>>,
    R = fun(Method, Hs) -> chappe_sip:replaces_response(req(Method, Hs)) end,
    ?assertEqual(no_replaces, R(<<"INVITE">>, [])),
    ?assertMatch({accept, Dlg, #{state := confirmed, role := uas}},
                 R(<<"INVITE">>, [{<<"Replaces">>, V}])),
    ?assertEqual({reject, 486},
                 R(<<"INVITE">>, [{<<"Replaces">>, <<V/binary, ";early-only">>}])),
    ?assertEqual({reject, 481},
                 R(<<"INVITE">>, [{<<"Replaces">>, <<"nope@ct;to-tag=a;from-tag=b">>}])),
    ?assertEqual({reject, 400},
                 R(<<"INVITE">>, [{<<"Replaces">>, V}, {<<"Replaces">>, V}])),
    ?assertEqual({reject, 400},
                 R(<<"INVITE">>, [{<<"Replaces">>, <<Call/binary, ";to-tag=", TT/binary>>}])),
    ?assertEqual({reject, 400}, R(<<"REFER">>, [{<<"Replaces">>, V}])),
    ?assertEqual({reject, 400},
                 R(<<"INVITE">>, [{<<"Replaces">>, V},
                                  {<<"Join">>, V}])),
    hangup(Sock, Dlg, TT).

%% a dialog whose BYE is in flight is terminated: 603
%% req: R3891-06
response_terminated_603(_Config) ->
    {EP, Sock} = setup(),
    {Call, FT, TT, Dlg, _Owner} = establish(EP, Sock),
    Self = self(),
    spawn_link(fun() -> Self ! {destroy_done, chappe_sip_dialog:destroy(Dlg)} end),
    {Bye, BSrc} = recv(Sock, <<"BYE">>),
    V = <<Call/binary, ";to-tag=", TT/binary, ";from-tag=", FT/binary>>,
    ?assertEqual({reject, 603},
                 chappe_sip:replaces_response(req(<<"INVITE">>, [{<<"Replaces">>, V}]))),
    send(Sock, BSrc, resp(Bye, 200, <<"OK">>, TT, [], <<>>)),
    receive {destroy_done, ok} -> ok after 5000 -> ct:fail(no_destroy) end.

%% an early dialog we did not originate (we are its UAS) is not replaceable:
%% 481, early-only or not
%% req: R3891-12
response_early_not_ours_481(_Config) ->
    {EP, Sock} = setup(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, D} = chappe_sip:create_uas(Req, Res, #{status => 180,
                                                     reason => <<"Ringing">>}),
        Test ! {dialog, D, self()},
        receive stop -> ok after 30000 -> ok end
    end),
    Call = callid(),
    FT = <<"ft", (binary:encode_hex(crypto:strong_rand_bytes(3)))/binary>>,
    send(Sock, EP, invite(Sock, Call, FT, [])),
    R180 = recv_status(Sock, 180),
    {ok, M} = chappe_sip_msg:parse(R180),
    TT = chappe_sip_msg:to_tag(M),
    receive {dialog, _, _} -> ok after 5000 -> ct:fail(no_dialog) end,
    V = <<Call/binary, ";to-tag=", TT/binary, ";from-tag=", FT/binary>>,
    ok = wait_found(V, 40),
    ?assertEqual({reject, 481},
                 chappe_sip:replaces_response(req(<<"INVITE">>, [{<<"Replaces">>, V}]))),
    ?assertEqual({reject, 481},
                 chappe_sip:replaces_response(
                   req(<<"INVITE">>, [{<<"Replaces">>, <<V/binary, ";early-only">>}]))).

%% the status goes on the wire as the handler sends it
%% req: R3891-04
response_live_481(_Config) ->
    {EP, Sock} = setup(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {reject, Status} = chappe_sip:replaces_response(Req),
        chappe_sip_res:send(Res, Status)
    end),
    send(Sock, EP, invite(Sock, callid(), <<"lv">>,
                          [{<<"Replaces">>, <<"gone@ct;to-tag=a;from-tag=b">>}])),
    _ = recv_status(Sock, 481).

%% a Replaces naming a dialog a SUBSCRIBE formed, or the subscription an
%% out-of-dialog REFER formed, names no INVITE dialog: 481 on the wire
%% req: R3891-05
replaces_non_invite_dialog_481(_Config) ->
    {EP, Sock} = setup(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Verdict = chappe_sip:replaces_response(Req),
        Test ! {verdict, Verdict},
        {reject, Status} = Verdict,
        chappe_sip_res:send(Res, Status)
    end),
    ok = chappe_sip:subscribe(fun(Req, Res) ->
        {ok, D} = chappe_sip:create_uas(Req, Res, #{expires => 600}),
        Test ! {subscription, D},
        receive stop -> ok after 10000 -> ok end
    end),
    ok = chappe_sip:refer(fun(Req, Res) ->
        {ok, Refer} = chappe_sip_refer:accept(Req, Res, #{owner => Test}),
        Test ! {refer, Refer},
        receive stop -> ok after 10000 -> ok end
    end),
    LP = lport(Sock),
    Ask = fun(Method, Hdrs) ->
        Call = callid(),
        FT = <<"nd", (binary:encode_hex(crypto:strong_rand_bytes(3)))/binary>>,
        send(Sock, EP, chappe_sip_core_peer:request(
                         Method, <<"sip:app@127.0.0.1">>,
                         #{port => LP, call_id => Call, from_tag => FT,
                           headers => Hdrs})),
        R200 = recv_status(Sock, 200),
        {ok, M} = chappe_sip_msg:parse(R200),
        <<Call/binary, ";to-tag=", (chappe_sip_msg:to_tag(M))/binary,
          ";from-tag=", FT/binary>>
    end,
    Sub = Ask(<<"SUBSCRIBE">>, [{<<"Event">>, <<"conference">>},
                                {<<"Expires">>, <<"600">>}]),
    receive {subscription, _} -> ok after 5000 -> ct:fail(no_subscription) end,
    Ref = Ask(<<"REFER">>, [{<<"Refer-To">>, <<"<sip:carol@127.0.0.1>">>}]),
    receive {refer, _} -> ok after 5000 -> ct:fail(no_refer) end,
    {Notify, NSrc} = recv(Sock, <<"NOTIFY">>),
    send(Sock, NSrc, resp(Notify, 200, <<"OK">>, <<"x">>, [], <<>>)),
    [begin
         send(Sock, EP, invite(Sock, callid(), <<"nd">>, [{<<"Replaces">>, V}])),
         receive {verdict, Verdict} -> ?assertEqual({reject, 481}, Verdict)
         after 5000 -> ct:fail(no_verdict)
         end,
         _ = recv_status(Sock, 481)
     end || V <- [Sub, Ref]].

%% our own early (ringing) dialog is indexed and replaceable, early-only or
%% not; destroying it sends a CANCEL carrying the given headers
%% req: R3891-12 R3891-16 R3326-01
uac_early_replaceable(_Config) ->
    {EP, Sock} = setup(),
    _ = EP,
    {ok, UasPort} = inet:port(Sock),
    Uri = <<"sip:callee@127.0.0.1:", (integer_to_binary(UasPort))/binary>>,
    {ok, Ref} = chappe_sip_uac:start(Uri, #{local_sdp => sdp()}),
    {Inv, Src} = recv(Sock, <<"INVITE">>),
    {ok, InvMsg} = chappe_sip_msg:parse(Inv),
    ?assertMatch({_, _}, binary:match(chappe_sip_msg:get(<<"supported">>, InvMsg),
                                      <<"replaces">>)),
    Call = chappe_sip_msg:call_id(InvMsg),
    LT = chappe_sip_msg:from_tag(InvMsg),
    PT = <<"early", (binary:encode_hex(crypto:strong_rand_bytes(3)))/binary>>,
    send(Sock, Src, resp(Inv, 180, <<"Ringing">>, PT,
                         [{<<"Contact">>, peer_ctc(UasPort)}], <<>>)),
    V = <<Call/binary, ";to-tag=", LT/binary, ";from-tag=", PT/binary>>,
    ok = wait_found(V, 40),
    {accept, Early, Info} =
        chappe_sip:replaces_response(req(<<"INVITE">>, [{<<"Replaces">>, V}])),
    ?assertEqual(#{state => early, role => uac, early_only => false}, Info),
    ?assertMatch({accept, Early, #{early_only := true}},
                 chappe_sip:replaces_response(
                   req(<<"INVITE">>, [{<<"Replaces">>, <<V/binary, ";early-only">>}]))),
    Reason = <<"SIP;cause=200">>,
    ok = chappe_sip_dialog:destroy(Early, #{headers => [{<<"Reason">>, Reason}]}),
    {Can, CSrc} = recv(Sock, <<"CANCEL">>),
    {ok, CanMsg} = chappe_sip_msg:parse(Can),
    ?assertEqual(Reason, chappe_sip_msg:get(<<"reason">>, CanMsg)),
    send(Sock, CSrc, resp(Can, 200, <<"OK">>, PT, [], <<>>)),
    send(Sock, Src, resp(Inv, 487, <<"Request Terminated">>, PT, [], <<>>)),
    ?assertMatch({error, #chappe_sip_error{status = 487}},
                 chappe_sip_uac:await(Ref, 5000)),
    ?assertEqual(ok, wait_gone({Call, LT, PT}, 40)).

%% once answered, the same identity names the confirmed dialog
%% req: R3891-11
uac_early_then_confirmed(_Config) ->
    {_EP, Sock} = setup(),
    {ok, UasPort} = inet:port(Sock),
    Uri = <<"sip:callee@127.0.0.1:", (integer_to_binary(UasPort))/binary>>,
    Test = self(),
    spawn_link(fun() ->
        Test ! {uac, chappe_sip:create_uac(Uri, #{local_sdp => sdp(),
                                                   owner => Test})},
        receive stop -> ok end
    end),
    {Inv, Src} = recv(Sock, <<"INVITE">>),
    {ok, InvMsg} = chappe_sip_msg:parse(Inv),
    Call = chappe_sip_msg:call_id(InvMsg),
    LT = chappe_sip_msg:from_tag(InvMsg),
    PT = <<"conf", (binary:encode_hex(crypto:strong_rand_bytes(3)))/binary>>,
    send(Sock, Src, resp(Inv, 180, <<"Ringing">>, PT,
                         [{<<"Contact">>, peer_ctc(UasPort)}], <<>>)),
    V = <<Call/binary, ";to-tag=", LT/binary, ";from-tag=", PT/binary>>,
    ok = wait_found(V, 40),
    send(Sock, Src, resp(Inv, 200, <<"OK">>, PT,
                         [{<<"Contact">>, peer_ctc(UasPort)}], sdp())),
    _ = recv(Sock, <<"ACK">>),
    Dlg = receive {uac, {ok, D}} -> D after 5000 -> ct:fail(no_uac) end,
    ?assertEqual({accept, Dlg, #{state => confirmed, role => uac,
                                 early_only => false}},
                 chappe_sip:replaces_response(req(<<"INVITE">>, [{<<"Replaces">>, V}]))),
    spawn_link(fun() -> Test ! {destroyed, chappe_sip_dialog:destroy(Dlg)} end),
    {Bye, BSrc} = recv(Sock, <<"BYE">>),
    send(Sock, BSrc, resp(Bye, 200, <<"OK">>, PT, [], <<>>)),
    receive {destroyed, ok} -> ok after 5000 -> ct:fail(no_destroy) end.

%% the 2xx that forms an INVITE dialog lists replaces in Supported
%% req: R3891-16
supported_on_uas_2xx(_Config) ->
    {EP, Sock} = setup(),
    Call = callid(),
    send(Sock, EP, invite(Sock, Call, <<"sup">>, [])),
    R200 = recv_status(Sock, 200),
    {ok, M} = chappe_sip_msg:parse(R200),
    ?assertMatch({_, _}, binary:match(chappe_sip_msg:get(<<"supported">>, M),
                                      <<"replaces">>)),
    TT = chappe_sip_msg:to_tag(M),
    send(Sock, EP, ack(Sock, Call, <<"sup">>, TT)),
    Dlg = receive {dialog, D, _} -> D after 5000 -> ct:fail(no_dialog) end,
    hangup(Sock, Dlg, TT).

%% Require: replaces is understood, so it is no 420
%% req: R3891-24
require_replaces_accepted(_Config) ->
    {EP, Sock} = setup(),
    Call = callid(),
    send(Sock, EP, invite(Sock, Call, <<"req">>, [{<<"Require">>, <<"replaces">>}])),
    R200 = recv_status(Sock, 200),
    {ok, M} = chappe_sip_msg:parse(R200),
    TT = chappe_sip_msg:to_tag(M),
    send(Sock, EP, ack(Sock, Call, <<"req">>, TT)),
    Dlg = receive {dialog, D, _} -> D after 5000 -> ct:fail(no_dialog) end,
    hangup(Sock, Dlg, TT).

%% ---- helpers ----

%% the entry a Replaces value names shows up (the fsm indexes itself)
wait_found(V, 0) ->
    ct:fail({not_indexed, V});
wait_found(V, N) ->
    case chappe_sip:find_replaced(req(<<"INVITE">>, [{<<"Replaces">>, V}])) of
        {ok, _, _} -> ok;
        _ -> timer:sleep(50), wait_found(V, N - 1)
    end.

setup() ->
    EP = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:",
                                         (integer_to_binary(EP))/binary>>}),
    Test = self(),
    ok = chappe_sip:invite(handler(Test)),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
    {EP, Sock}.

%% a plain INVITE forms a dialog owned by the handler process; an INVITE
%% carrying Replaces reports find_replaced/1 and is refused
handler(Test) ->
    fun(Req, Res) ->
        case chappe_sip_req:get(<<"replaces">>, Req) of
            undefined ->
                {ok, Dlg} = chappe_sip:create_uas(Req, Res,
                                                  #{local_sdp => sdp()}),
                Test ! {dialog, Dlg, self()},
                owner_loop(Test, Dlg);
            _ ->
                Test ! {replaced, chappe_sip:find_replaced(Req)},
                chappe_sip_res:send(Res, 486, #{})
        end
    end.

owner_loop(Test, Dlg) ->
    receive
        {chappe_sip_dialog, Dlg, destroy, _} -> Test ! {destroyed, Dlg};
        exit_owner -> ok;
        _ -> owner_loop(Test, Dlg)
    end.

establish(EP, Sock) ->
    Call = callid(),
    FT = <<"ft", (binary:encode_hex(crypto:strong_rand_bytes(3)))/binary>>,
    send(Sock, EP, invite(Sock, Call, FT, [])),
    R200 = recv_status(Sock, 200),
    {ok, M} = chappe_sip_msg:parse(R200),
    TT = chappe_sip_msg:to_tag(M),
    send(Sock, EP, ack(Sock, Call, FT, TT)),
    {Dlg, Owner} = receive {dialog, D, O} -> {D, O}
                   after 5000 -> ct:fail(no_dialog) end,
    {Call, FT, TT, Dlg, Owner}.

%% app BYE, answered by the peer (the test process owns the peer socket, so
%% destroy/1 runs elsewhere)
hangup(Sock, Dlg, TT) ->
    Self = self(),
    spawn_link(fun() -> Self ! {hung_up, chappe_sip_dialog:destroy(Dlg)} end),
    {Bye, BSrc} = recv(Sock, <<"BYE">>),
    send(Sock, BSrc, resp(Bye, 200, <<"OK">>, TT, [], <<>>)),
    receive {hung_up, ok} -> ok after 5000 -> ct:fail(no_hangup) end.

wait_gone(_Key, 0) -> still_there;
wait_gone(Key, N) ->
    case ets:member(?TAB, Key) of
        false -> ok;
        true -> timer:sleep(50), wait_gone(Key, N - 1)
    end.

%% a request handle built from raw bytes, as a handler would see it
req(Method, Headers) ->
    Hs = [[Nm, <<": ">>, V, <<"\r\n">>] || {Nm, V} <- Headers],
    Bin = iolist_to_binary(
            [Method, <<" sip:app@127.0.0.1 SIP/2.0\r\n"
                       "Via: SIP/2.0/UDP 127.0.0.1:5999;branch=z9hG4bKx\r\n"
                       "From: <sip:x@127.0.0.1>;tag=nf\r\n"
                       "To: <sip:app@127.0.0.1>\r\n"
                       "Call-ID: fresh@ct\r\nCSeq: 1 ">>, Method, <<"\r\n">>,
             Hs, <<"Content-Length: 0\r\n\r\n">>]),
    {ok, Msg} = chappe_sip_msg:parse(Bin),
    chappe_sip_req:new(Msg, undefined, #{}).

ctc(P) -> <<"sip:chappe@127.0.0.1:", (integer_to_binary(P))/binary>>.
peer_ctc(P) -> <<"sip:peer@127.0.0.1:", (integer_to_binary(P))/binary>>.
callid() ->
    <<"rp-", (binary:encode_hex(crypto:strong_rand_bytes(4)))/binary, "@ct">>.
branch() ->
    <<"z9hG4bK", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>.
sdp() ->
    <<"v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
      "t=0 0\r\nm=audio 40000 RTP/AVP 0\r\na=sendrecv\r\n">>.
lport(Sock) -> {ok, P} = inet:port(Sock), P.
send(Sock, Dst, Bin) -> ok = gen_udp:send(Sock, {127,0,0,1}, Dst, Bin).

recv(Sock, Method) ->
    L = byte_size(Method),
    receive
        {udp, Sock, _, Src, <<M:L/binary, " ", _/binary>> = Bin}
          when M =:= Method ->
            {Bin, Src}
    after 6000 -> ct:fail({no_req, Method})
    end.

recv_status(Sock, Code) ->
    CB = integer_to_binary(Code),
    receive
        {udp, Sock, _, _, <<"SIP/2.0 ", CB:3/binary, _/binary>> = Bin} -> Bin
    after 6000 -> ct:fail({no_status, Code})
    end.

invite(Sock, Call, FT, Extra) ->
    P = integer_to_binary(lport(Sock)),
    S = sdp(),
    L = integer_to_binary(byte_size(S)),
    Hs = iolist_to_binary([[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Extra]),
    <<"INVITE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=",
      (branch())/binary, "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary,
      "\r\nTo: <sip:app@127.0.0.1>\r\n"
      "Contact: <sip:caller@127.0.0.1:", P/binary, ">\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 INVITE\r\n", Hs/binary,
      "Content-Type: application/sdp\r\n"
      "Content-Length: ", L/binary, "\r\n\r\n", S/binary>>.

ack(Sock, Call, FT, TT) ->
    P = integer_to_binary(lport(Sock)),
    <<"ACK sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary,
      "\r\nTo: <sip:app@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 ACK\r\nContent-Length: 0\r\n\r\n">>.

bye(Sock, Call, FT, TT) ->
    P = integer_to_binary(lport(Sock)),
    <<"BYE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=",
      (branch())/binary, "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary,
      "\r\nTo: <sip:app@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 2 BYE\r\nContent-Length: 0\r\n\r\n">>.

%% a response to an inbound request, echoing Via/From/To/Call-ID/CSeq
resp(ReqBin, Status, Reason, ToTag, ExtraHeaders, Body) ->
    {ok, Msg} = chappe_sip_msg:parse(ReqBin),
    Vias = chappe_sip_msg:get_all(<<"via">>, Msg),
    From = chappe_sip_msg:get(<<"from">>, Msg),
    To0 = chappe_sip_msg:get(<<"to">>, Msg),
    To = case chappe_sip_msg:to_tag(Msg) of
             undefined -> <<To0/binary, ";tag=", ToTag/binary>>;
             _ -> To0
         end,
    Call = chappe_sip_msg:call_id(Msg),
    CSeq = chappe_sip_msg:get(<<"cseq">>, Msg),
    ViaLines = [[<<"Via: ">>, V, <<"\r\n">>] || V <- Vias],
    Extra = [[N, <<": ">>, Val, <<"\r\n">>] || {N, Val} <- ExtraHeaders],
    CT = case Body of
             <<>> -> [];
             _ -> <<"Content-Type: application/sdp\r\n">>
         end,
    CL = integer_to_binary(byte_size(Body)),
    iolist_to_binary(
      [<<"SIP/2.0 ">>, integer_to_binary(Status), <<" ">>, Reason, <<"\r\n">>,
       ViaLines, <<"From: ">>, From, <<"\r\n">>, <<"To: ">>, To, <<"\r\n">>,
       <<"Call-ID: ">>, Call, <<"\r\n">>, <<"CSeq: ">>, CSeq, <<"\r\n">>, Extra,
       CT, <<"Content-Length: ">>, CL, <<"\r\n\r\n">>, Body]).
