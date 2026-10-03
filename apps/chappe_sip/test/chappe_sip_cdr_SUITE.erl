%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Call detail records (chappe_sip_cdr) on the wire.
%%
%% The test process subscribes and drives raw UDP peers (one caller, one
%% callee) against the real engine. Every way an INVITE attempt can end
%% must emit exactly one stop, with the record's role, tags, timestamps
%% and normalized reason: a BYE either way, a reject, a CANCEL with and
%% without an early dialog, a killed or shut down dialog fsm, an engine
%% stop, the owner gone (UAS and UAC), a WebSocket connection lost, a
%% b2bua (two linked records) and a record-routing proxy.
-module(chappe_sip_cdr_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("chappe_sip.hrl").

-import(chappe_sip_core_peer, [
    open/0, port/1, send/3, recv/3, request/3, response/3, hdr/2, status/1,
    to_tag/1, from_tag/1, tag/0, sdp/0
]).

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2,
         end_per_testcase/2]).
-export([uas_bye_remote/1, uas_bye_local/1, uas_reject/1,
         uas_cancel_ringing/1, uas_cancel_early_dialog/1,
         uas_dialog_killed/1, uas_dialog_shutdown/1, uas_engine_stop/1,
         uas_owner_down/1, uac_answered/1, uac_failed/1, uac_cancelled/1,
         uac_owner_down/1, b2b_linked/1, ws_flow_lost/1,
         proxy_record_routed/1, proxy_rejected/1, subscriber_monitored/1,
         no_subscriber_no_record/1]).

all() ->
    [uas_bye_remote, uas_bye_local, uas_reject, uas_cancel_ringing,
     uas_cancel_early_dialog, uas_dialog_killed, uas_dialog_shutdown,
     uas_engine_stop, uas_owner_down, uac_answered, uac_failed,
     uac_cancelled, uac_owner_down, b2b_linked, ws_flow_lost,
     proxy_record_routed, proxy_rejected, subscriber_monitored,
     no_subscriber_no_record].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(_Case, Config) ->
    EP = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => chappe_sip_core_peer:contact(EP)}),
    ok = chappe_sip_cdr:subscribe(self()),
    [{ep, EP}, {sock, open()}, {callee, open()} | Config].

end_per_testcase(_Case, Config) ->
    _ = chappe_sip_cdr:unsubscribe(self()),
    chappe_sip_core_peer:close(?config(sock, Config)),
    chappe_sip_core_peer:close(?config(callee, Config)),
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% ---- UAS ----

%% The app answers, the caller hangs up: attempt, start, then one stop
%% {bye, remote} with the tags and the timestamps in order.
uas_bye_remote(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {Inv, _D, R200} = answered_call(Sock, EP),
    #{id := Id} = A = cdr(attempt),
    ?assertMatch(#{role := uas, call_id := _, request_uri := _}, A),
    ?assertEqual(from_tag(Inv), maps:get(remote_tag, A)),
    S = cdr(start),
    ?assertEqual(Id, maps:get(id, S)),
    send(Sock, EP, bye(Sock, Inv, R200)),
    {_, _} = recv(Sock, {status, 200, <<"BYE">>}, 3000),
    R = stop_once(Id),
    ?assertMatch(#{reason := {bye, remote}, final_status := 200}, R),
    ?assertEqual(to_tag(R200), maps:get(local_tag, R)),
    #{attempt_at := T0, answered_at := T1, ended_at := T2} = R,
    ?assert(T0 =< T1 andalso T1 =< T2).

%% The app hangs up: {bye, local}.
uas_bye_local(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {_Inv, D, _R200} = answered_call(Sock, EP),
    #{id := Id} = cdr(attempt),
    Bye = async(fun() -> chappe_sip_dialog:destroy(D) end),
    {ByeReq, _} = recv(Sock, {method, <<"BYE">>}, 3000),
    send(Sock, EP, response(ByeReq, 200, #{})),
    ok = await(Bye),
    ?assertMatch(#{reason := {bye, local}}, stop_once(Id)).

%% The app rejects the INVITE: no start, a stop {final, 486}.
uas_reject(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    ok = chappe_sip:invite(fun(_Req, Res) ->
        ok = chappe_sip_res:send(Res, 180),
        chappe_sip_res:send(Res, 486)
    end),
    send(Sock, EP, invite(Sock)),
    {_, _} = recv(Sock, {status, 486}, 3000),
    #{id := Id} = cdr(attempt),
    R = stop_once(Id),
    ?assertMatch(#{reason := {final, 486}, final_status := 486,
                   answered_at := undefined}, R),
    ?assertNotEqual(undefined, maps:get(ringing_at, R)),
    no_event(start, Id).

%% The caller CANCELs a ringing INVITE the handler holds: cancel.
uas_cancel_ringing(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    ok = chappe_sip:invite(fun(_Req, Res) ->
        ok = chappe_sip_res:send(Res, 180),
        receive stop -> ok after 5000 -> ok end
    end),
    Inv = invite(Sock),
    send(Sock, EP, Inv),
    {_, _} = recv(Sock, {status, 180}, 3000),
    #{id := Id} = cdr(attempt),
    send(Sock, EP, cancel_for(Inv)),
    {_, _} = recv(Sock, {status, 487, <<"INVITE">>}, 3000),
    ?assertMatch(#{reason := cancel, final_status := 487}, stop_once(Id)).

%% A CANCEL of an INVITE answered 180 by create_uas ends that early
%% dialog: its owner gets destroy with reason cancel, and the record one
%% stop with cancel.
uas_cancel_early_dialog(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, D} = chappe_sip:create_uas(Req, Res, #{status => 180,
                                                    owner => Test}),
        Test ! {dialog, D},
        receive stop -> ok after 5000 -> ok end
    end),
    Inv = invite(Sock),
    send(Sock, EP, Inv),
    {_, _} = recv(Sock, {status, 180}, 3000),
    D = receive {dialog, D0} -> D0 after 3000 -> ct:fail(no_dialog) end,
    #{id := Id} = cdr(attempt),
    send(Sock, EP, cancel_for(Inv)),
    {_, _} = recv(Sock, {status, 487, <<"INVITE">>}, 3000),
    receive {chappe_sip_dialog, D, destroy, cancel} -> ok
    after 3000 -> ct:fail(no_destroy)
    end,
    ?assertMatch(#{reason := cancel}, stop_once(Id)).

%% A dialog fsm killed mid-call (its terminate never runs) still ends its
%% record, once: {process_down, killed}.
uas_dialog_killed(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {_Inv, D, _R200} = answered_call(Sock, EP),
    #{id := Id} = cdr(attempt),
    exit(chappe_sip_dialog:pid(D), kill),
    ?assertMatch(#{reason := {process_down, killed}}, stop_once(Id)).

%% Shut down by its supervisor: {process_down, shutdown}.
uas_dialog_shutdown(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {_Inv, D, _R200} = answered_call(Sock, EP),
    #{id := Id} = cdr(attempt),
    ok = supervisor:terminate_child(chappe_sip_dialog_sup,
                                    chappe_sip_dialog:pid(D)),
    ?assertMatch(#{reason := {process_down, shutdown}}, stop_once(Id)).

%% chappe_sip:stop/0 tells the dialogs their SIP state is gone, as a
%% restart does: the owner gets destroy engine_restart, the record a stop
%% engine_restart.
uas_engine_stop(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {_Inv, D, _R200} = answered_call(Sock, EP),
    #{id := Id} = cdr(attempt),
    ok = chappe_sip:stop(),
    receive {chappe_sip_dialog, D, destroy, engine_restart} -> ok
    after 3000 -> ct:fail(no_destroy)
    end,
    ?assertMatch(#{reason := engine_restart}, stop_once(Id)).

%% The owner of an answered call exits: the dialog BYEs, owner_down.
uas_owner_down(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Owner = spawn(fun() -> receive stop -> ok end end),
    {_Inv, _D, _R200} = answered_call(Sock, EP, Owner),
    #{id := Id} = cdr(attempt),
    Owner ! stop,
    {ByeReq, _} = recv(Sock, {method, <<"BYE">>}, 3000),
    send(Sock, EP, response(ByeReq, 200, #{})),
    ?assertMatch(#{reason := owner_down}, stop_once(Id)).

%% ---- UAC ----

%% An INVITE we send, answered then hung up by us: role uac, our From tag
%% as local tag, the callee's To tag as remote tag, {bye, local}.
uac_answered(Config) ->
    {EP, Callee} = {?config(ep, Config), ?config(callee, Config)},
    Test = self(),
    Call = async(fun() ->
        chappe_sip:create_uac(callee(Callee), #{local_sdp => sdp(),
                                                owner => Test})
    end),
    {Inv, _} = recv(Callee, {method, <<"INVITE">>}, 3000),
    #{id := Id} = A = cdr(attempt),
    ?assertMatch(#{role := uac}, A),
    ?assertEqual(from_tag(Inv), maps:get(local_tag, A)),
    send(Callee, EP, response(Inv, 180, #{to_tag => <<"cle">>})),
    send(Callee, EP, answer(Callee, Inv, <<"cle">>)),
    {ok, D} = await(Call),
    {_, _} = recv(Callee, {method, <<"ACK">>}, 3000),
    S = cdr(start),
    ?assertEqual(<<"cle">>, maps:get(remote_tag, S)),
    Bye = async(fun() -> chappe_sip_dialog:destroy(D) end),
    {ByeReq, _} = recv(Callee, {method, <<"BYE">>}, 3000),
    send(Callee, EP, response(ByeReq, 200, #{})),
    ok = await(Bye),
    R = stop_once(Id),
    ?assertMatch(#{reason := {bye, local}, final_status := 200}, R),
    ?assertNotEqual(undefined, maps:get(ringing_at, R)).

%% A 486 to our INVITE: {final, 486}.
uac_failed(Config) ->
    {EP, Callee} = {?config(ep, Config), ?config(callee, Config)},
    Call = async(fun() -> chappe_sip:create_uac(callee(Callee), #{}) end),
    {Inv, _} = recv(Callee, {method, <<"INVITE">>}, 3000),
    send(Callee, EP, response(Inv, 486, #{to_tag => tag()})),
    ?assertMatch({error, #chappe_sip_error{status = 486}}, await(Call)),
    #{id := Id} = cdr(attempt),
    ?assertMatch(#{reason := {final, 486}}, stop_once(Id)).

%% We CANCEL our INVITE and the callee answers 487: cancel.
uac_cancelled(Config) ->
    {EP, Callee} = {?config(ep, Config), ?config(callee, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Callee), #{local_sdp => sdp()}),
    {Inv, _} = recv(Callee, {method, <<"INVITE">>}, 3000),
    send(Callee, EP, response(Inv, 180, #{to_tag => <<"cc">>})),
    #{id := Id} = cdr(attempt),
    timer:sleep(200),
    ok = chappe_sip_uac:cancel(Ref),
    {Cancel, _} = recv(Callee, {method, <<"CANCEL">>}, 3000),
    send(Callee, EP, response(Cancel, 200, #{})),
    send(Callee, EP, response(Inv, 487, #{to_tag => <<"cc">>})),
    ?assertMatch(#{reason := cancel, final_status := 487}, stop_once(Id)).

%% The process that started a ringing INVITE exits: the UAC fsm watches
%% it and CANCELs the INVITE; the record stops with owner_down. The 180
%% has no To tag, so no early dialog watches the owner in its place.
uac_owner_down(Config) ->
    {EP, Callee} = {?config(ep, Config), ?config(callee, Config)},
    Uri = callee(Callee),
    Owner = spawn(fun() ->
        {ok, _} = chappe_sip_uac:start(Uri, #{local_sdp => sdp()}),
        receive stop -> ok end
    end),
    {Inv, _} = recv(Callee, {method, <<"INVITE">>}, 3000),
    send(Callee, EP, response(Inv, 180, #{})),
    #{id := Id} = cdr(attempt),
    timer:sleep(200),
    Owner ! stop,
    {Cancel, _} = recv(Callee, {method, <<"CANCEL">>}, 3000),
    send(Callee, EP, response(Cancel, 200, #{})),
    send(Callee, EP, response(Inv, 487, #{to_tag => <<"od">>})),
    ?assertMatch(#{reason := owner_down}, stop_once(Id)).

%% ---- b2bua ----

%% A b2bua call: a b2b_a and a b2b_b record naming each other, both
%% answered, both ended once by the caller's BYE.
b2b_linked(Config) ->
    {EP, Sock, Callee} = {?config(ep, Config), ?config(sock, Config),
                          ?config(callee, Config)},
    Uri = callee(Callee),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(Req, Res, Uri, #{}),
        chappe_sip_b2b:relay(Legs)
    end),
    Inv = invite(Sock),
    send(Sock, EP, Inv),
    {BInv, _} = recv(Callee, {method, <<"INVITE">>}, 3000),
    send(Callee, EP, answer(Callee, BInv, <<"bt">>)),
    {_, _} = recv(Callee, {method, <<"ACK">>}, 3000),
    {R200, _} = recv(Sock, {status, 200, <<"INVITE">>}, 3000),
    send(Sock, EP, chappe_sip_core_peer:ack_for(R200, #{port => port(Sock)})),
    Attempts = [cdr(attempt), cdr(attempt)],
    [#{id := AId}] = [R || #{call_id := C} = R <- Attempts,
                           C =:= hdr(<<"call-id">>, Inv)],
    [#{id := BId}] = [R || #{id := I} = R <- Attempts, I =/= AId],
    send(Sock, EP, bye(Sock, Inv, R200)),
    {ByeB, _} = recv(Callee, {method, <<"BYE">>}, 3000),
    send(Callee, EP, response(ByeB, 200, #{})),
    Stops = [stop_of(AId), stop_of(BId)],
    [A, B] = Stops,
    ?assertMatch(#{role := b2b_a, link := BId, reason := {bye, remote}}, A),
    ?assertMatch(#{role := b2b_b, link := AId, reason := {bye, local}}, B),
    ?assertNotEqual(undefined, maps:get(answered_at, A)),
    ?assertNotEqual(undefined, maps:get(answered_at, B)),
    no_event(stop, AId),
    no_event(stop, BId).

%% ---- WebSocket ----

%% The WS connection of an answered call closes: the dialog is torn down
%% with reason flow_lost (owner and record).
ws_flow_lost(_Config) ->
    WP = chappe_sip_test_port:pick(),
    ok = chappe_sip:ws_listen(#{port => WP}),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, D} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp(),
                                                    owner => Test}),
        Test ! {dialog, D}
    end),
    Url = <<"ws://127.0.0.1:", (integer_to_binary(WP))/binary, "/ws">>,
    {ok, C} = ws:connect(Url, #{handler => chappe_sip_ws_test_client,
                                handler_opts => #{notify => self()},
                                subprotocols => [<<"sip">>]}),
    ws:send(C, {text, ws_invite()}),
    R200 = recv_ws(200),
    ws:send(C, {text, ws_ack(to_tag(R200))}),
    D = receive {dialog, D0} -> D0 after 3000 -> ct:fail(no_dialog) end,
    #{id := Id} = cdr(attempt),
    ws:close(C, 1000),
    receive {chappe_sip_dialog, D, destroy, flow_lost} -> ok
    after 5000 -> ct:fail(no_destroy)
    end,
    ?assertMatch(#{reason := flow_lost, transport := _}, stop_once(Id)).

%% ---- proxy ----

%% A record-routed proxied call: role proxy, answered, and ended once by
%% the BYE passing through.
proxy_record_routed(Config) ->
    {EP, Sock, Callee} = {?config(ep, Config), ?config(sock, Config),
                          ?config(callee, Config)},
    Uri = callee(Callee),
    ok = chappe_sip:invite(fun(Req, _Res) ->
        chappe_sip:proxy_request(Req, [Uri], #{record_route => true})
    end),
    Inv = invite(Sock),
    send(Sock, EP, Inv),
    {PInv, PSrc} = recv(Callee, {method, <<"INVITE">>}, 3000),
    RR = hdr(<<"record-route">>, PInv),
    send(Callee, PSrc, response(PInv, 200, #{
        to_tag => <<"px">>, body => sdp(),
        headers => [{<<"Contact">>, <<"<", Uri/binary, ">">>},
                    {<<"Record-Route">>, RR}]})),
    {R200, _} = recv(Sock, {status, 200, <<"INVITE">>}, 3000),
    #{id := Id} = A = cdr(attempt),
    ?assertMatch(#{role := proxy}, cdr(start)),
    ?assertMatch(#{role := uas}, A),
    Bye = request(<<"BYE">>, Uri, #{
        port => port(Sock), call_id => hdr(<<"call-id">>, Inv),
        from_tag => from_tag(Inv), to_tag => to_tag(R200), cseq => 2,
        headers => [{<<"Route">>, RR}]}),
    send(Sock, EP, Bye),
    {PBye, BSrc} = recv(Callee, {method, <<"BYE">>}, 3000),
    send(Callee, BSrc, response(PBye, 200, #{})),
    {_, _} = recv(Sock, {status, 200, <<"BYE">>}, 3000),
    ?assertMatch(#{role := proxy, reason := {bye, remote}}, stop_once(Id)).

%% A proxied INVITE rejected downstream: {final, 486}.
proxy_rejected(Config) ->
    {EP, Sock, Callee} = {?config(ep, Config), ?config(sock, Config),
                          ?config(callee, Config)},
    Uri = callee(Callee),
    ok = chappe_sip:invite(fun(Req, _Res) ->
        chappe_sip:proxy_request(Req, [Uri], #{})
    end),
    send(Sock, EP, invite(Sock)),
    {PInv, PSrc} = recv(Callee, {method, <<"INVITE">>}, 3000),
    send(Callee, PSrc, response(PInv, 486, #{to_tag => tag()})),
    {_, _} = recv(Sock, {status, 486}, 3000),
    #{id := Id} = cdr(attempt),
    ?assertMatch(#{role := proxy, reason := {final, 486}}, stop_once(Id)).

%% ---- subscribers ----

%% A subscriber that exits is dropped: with none left the stack keeps no
%% record.
subscriber_monitored(_Config) ->
    ok = chappe_sip_cdr:unsubscribe(self()),
    Sub = spawn(fun() -> receive stop -> ok end end),
    ok = chappe_sip_cdr:subscribe(Sub),
    ?assert(chappe_sip_cdr:active()),
    MRef = erlang:monitor(process, Sub),
    Sub ! stop,
    receive {'DOWN', MRef, _, _, _} -> ok end,
    ok = wait_until(fun() -> not chappe_sip_cdr:active() end),
    ok = chappe_sip_cdr:subscribe(self()).

%% With no subscriber an INVITE opens no record.
no_subscriber_no_record(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    ok = chappe_sip_cdr:unsubscribe(self()),
    ok = chappe_sip:invite(fun(_Req, Res) -> chappe_sip_res:send(Res, 486) end),
    send(Sock, EP, invite(Sock)),
    {_, _} = recv(Sock, {status, 486}, 3000),
    ?assertEqual([], chappe_sip_cdr:open_records()),
    receive {chappe_sip_cdr, _, _} = E -> ct:fail({unexpected, E})
    after 300 -> ok
    end.

%% ---- helpers ----

cdr(Event) ->
    receive {chappe_sip_cdr, Event, R} -> R
    after 5000 -> ct:fail({no_cdr, Event})
    end.

stop_of(Id) ->
    receive {chappe_sip_cdr, stop, #{id := Id} = R} -> R
    after 8000 -> ct:fail({no_stop, Id})
    end.

%% the record's stop, and no second one
stop_once(Id) ->
    R = stop_of(Id),
    no_event(stop, Id),
    R.

no_event(Event, Id) ->
    receive {chappe_sip_cdr, Event, #{id := Id}} = E -> ct:fail({twice, E})
    after 500 -> ok
    end.

answered_call(Sock, EP) ->
    answered_call(Sock, EP, self()).

%% INVITE from the caller, answered 200 by create_uas, ACKed
answered_call(Sock, EP, Owner) ->
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, D} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp(),
                                                    owner => Owner}),
        Test ! {dialog, D}
    end),
    Inv = invite(Sock),
    send(Sock, EP, Inv),
    {R200, _} = recv(Sock, {status, 200}, 3000),
    send(Sock, EP, chappe_sip_core_peer:ack_for(R200, #{port => port(Sock)})),
    D = receive {dialog, D0} -> D0 after 3000 -> ct:fail(no_dialog) end,
    {Inv, D, R200}.

invite(Sock) ->
    request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
            #{port => port(Sock), body => sdp()}).

bye(Sock, Inv, R200) ->
    request(<<"BYE">>, <<"sip:app@127.0.0.1">>,
            #{port => port(Sock), call_id => hdr(<<"call-id">>, Inv),
              from_tag => from_tag(Inv), to_tag => to_tag(R200), cseq => 2}).

cancel_for(InvBin) ->
    Inv = chappe_sip_core_peer:parse(InvBin),
    iolist_to_binary(
      [<<"CANCEL ">>, chappe_sip_msg:uri(Inv), " SIP/2.0\r\n",
       "Via: ", chappe_sip_core_peer:top_via(Inv), "\r\n",
       "Max-Forwards: 70\r\n",
       "From: ", hdr(<<"from">>, Inv), "\r\n",
       "To: ", hdr(<<"to">>, Inv), "\r\n",
       "Call-ID: ", hdr(<<"call-id">>, Inv), "\r\n",
       "CSeq: 1 CANCEL\r\nContent-Length: 0\r\n\r\n"]).

callee(Sock) ->
    <<"sip:callee@127.0.0.1:", (integer_to_binary(port(Sock)))/binary>>.

answer(Callee, Inv, ToTag) ->
    response(Inv, 200, #{
        to_tag => ToTag, body => sdp(),
        headers => [{<<"Contact">>, <<"<", (callee(Callee))/binary, ">">>}]}).

async(F) ->
    Test = self(),
    Ref = make_ref(),
    spawn_link(fun() -> Test ! {Ref, F()} end),
    Ref.

await(Ref) ->
    receive {Ref, R} -> R after 10000 -> ct:fail(no_result) end.

wait_until(F) -> wait_until(F, 50).

wait_until(_F, 0) -> {error, timeout};
wait_until(F, N) ->
    case F() of
        true -> ok;
        false -> timer:sleep(20), wait_until(F, N - 1)
    end.

recv_ws(Code) ->
    CB = integer_to_binary(Code),
    receive
        {ws_in, <<"SIP/2.0 ", C:3/binary, _/binary>> = Bin} when C =:= CB ->
            Bin;
        {ws_in, _Other} ->
            recv_ws(Code)
    after 6000 -> ct:fail({no_ws_status, Code})
    end.

ws_invite() ->
    S = sdp(),
    L = integer_to_binary(byte_size(S)),
    <<"INVITE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/WS df7jal23ls0d.invalid;branch=z9hG4bKcdrinv\r\n"
      "Max-Forwards: 70\r\n"
      "From: Alice <sip:alice@127.0.0.1>;tag=cdrinv\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Contact: <sip:alice@df7jal23ls0d.invalid;transport=ws>\r\n"
      "Call-ID: cdrcall@ct\r\nCSeq: 1 INVITE\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: ", L/binary, "\r\n\r\n", S/binary>>.

ws_ack(TT) ->
    <<"ACK sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/WS df7jal23ls0d.invalid;branch=z9hG4bKcdrack\r\n"
      "Max-Forwards: 70\r\n"
      "From: Alice <sip:alice@127.0.0.1>;tag=cdrinv\r\n"
      "To: <sip:app@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: cdrcall@ct\r\nCSeq: 1 ACK\r\nContent-Length: 0\r\n\r\n">>.
