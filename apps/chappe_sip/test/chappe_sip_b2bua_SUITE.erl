%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% B2BUA.
%%
%% A gen_udp "caller" (UAC) calls the app; the app bridges to a gen_udp
%% "callee" (UAS). Both peers own their own sockets.
-module(chappe_sip_b2bua_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("chappe_sip.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([b2b_success_bye/1, b2b_callee_busy/1, b2b_caller_cancel/1,
         b2b_survives_deadline/1, b2b_rings_past_deadline/1,
         b2b_timer_c_408/1, b2b_timer_c_restarted/1]).
-export([fork_one_answers/1, fork_busy_then_answer/1, fork_all_fail_best/1,
         fork_timer_c/1, fork_late_2xx/1, pass_failure_timer_c/1,
         start_failure_answered/1, start_failure_not_passed/1]).
-export([fork_branch_opts/1, serial_branch_opts/1]).

all() ->
    [b2b_success_bye, b2b_callee_busy, b2b_caller_cancel,
     b2b_survives_deadline, b2b_rings_past_deadline, b2b_timer_c_408,
     b2b_timer_c_restarted, fork_one_answers, fork_busy_then_answer,
     fork_all_fail_best, fork_timer_c, fork_late_2xx, pass_failure_timer_c,
     start_failure_answered, start_failure_not_passed, fork_branch_opts,
     serial_branch_opts].

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
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    application:unset_env(chappe_sip, handler_deadline_ms),
    application:unset_env(chappe_sip, timer_c_ms),
    ok.

%% caller INVITE -> app b2bua -> callee; 180 relayed, 200 bridged, ACK both
%% ways; caller BYE tears down both legs.
b2b_success_bye(_Config) ->
    {EnginePort, CalleePort} = setup(),
    Test = self(),
    CalleeUri = <<"sip:callee@127.0.0.1:", (integer_to_binary(CalleePort))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(Req, Res, CalleeUri, #{}),
        Test ! b2b_up,
        {done, Why} = chappe_sip_b2b:relay(Legs),
        Test ! {relay_done, Why}
    end),
    %% callee peer
    callee(CalleePort, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        {_, _} = binary:match(Inv, <<"v=0">>),         % offer relayed
        %% B sees the caller's name and address, under B's own From tag
        {ok, InvMsg} = chappe_sip_msg:parse(Inv),
        {ok, #{display := <<"Caller">>, uri := <<"sip:caller@", _/binary>>,
               params := #{<<"tag">> := BTag}}} =
            chappe_sip_hdr:name_addr(chappe_sip_msg:get(<<"from">>, InvMsg)),
        true = BTag =/= <<"cft">>,
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        ToTag = tag(),
        send(Sock, Src, resp(Inv, 200, <<"OK">>, ToTag,
                             [{<<"Contact">>, ctc(CalleePort)}], sdp(<<"callee">>))),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        Test ! callee_acked,
        {Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>)),
        Test ! callee_byed
    end),
    %% caller peer drives the A leg and asserts
    caller(fun(Sock) ->
        Call = callid(),
        FT = <<"cft">>,
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, FT)),
        _R180 = recv_status(Sock, 180),
        R200 = recv_status(Sock, 200),
        {_, _} = binary:match(R200, <<"callee">>),      % callee answer bridged
        TT = to_tag(R200),
        send(Sock, EnginePort, ack(Sock, EnginePort, Call, FT, TT)),
        Test ! caller_acked,
        %% let the media flow, then hang up
        timer:sleep(200),
        send(Sock, EnginePort, bye(Sock, EnginePort, Call, FT, TT)),
        _ = recv_status(Sock, 200),
        Test ! caller_byed
    end),
    ok = expect(b2b_up),
    ok = expect(callee_acked),
    ok = expect(caller_acked),
    ok = expect(caller_byed),
    ok = expect(callee_byed),
    ok = expect({relay_done, a_bye}).

%% a b2bua call held longer than handler_deadline_ms must survive: the worker
%% owns the dialog and blocks in relay/1, so its handler deadline is disarmed.
%% With the bug it is killed mid-call and neither BYE nor relay_done arrive.
b2b_survives_deadline(_Config) ->
    application:set_env(chappe_sip, handler_deadline_ms, 300),
    {EnginePort, CalleePort} = setup(),
    Test = self(),
    CalleeUri = <<"sip:callee@127.0.0.1:", (integer_to_binary(CalleePort))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(Req, Res, CalleeUri, #{}),
        Test ! b2b_up,
        {done, Why} = chappe_sip_b2b:relay(Legs),
        Test ! {relay_done, Why}
    end),
    callee(CalleePort, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        ToTag = tag(),
        send(Sock, Src, resp(Inv, 200, <<"OK">>, ToTag,
                             [{<<"Contact">>, ctc(CalleePort)}], sdp(<<"callee">>))),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        Test ! callee_acked,
        {Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>)),
        Test ! callee_byed
    end),
    caller(fun(Sock) ->
        Call = callid(),
        FT = <<"cftd">>,
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, FT)),
        R200 = recv_status(Sock, 200),
        TT = to_tag(R200),
        send(Sock, EnginePort, ack(Sock, EnginePort, Call, FT, TT)),
        Test ! caller_acked,
        %% hold the call well past the 300ms handler deadline, then hang up
        timer:sleep(900),
        send(Sock, EnginePort, bye(Sock, EnginePort, Call, FT, TT)),
        _ = recv_status(Sock, 200),
        Test ! caller_byed
    end),
    ok = expect(b2b_up),
    ok = expect(callee_acked),
    ok = expect(caller_acked),
    ok = expect(caller_byed),
    ok = expect(callee_byed),
    ok = expect({relay_done, a_bye}).

%% B rings longer than the handler deadline before it answers: the worker
%% waits on the B-leg UAC, which owns the call, so its deadline is disarmed
%% and A gets the 200, not a 500.
b2b_rings_past_deadline(_Config) ->
    application:set_env(chappe_sip, handler_deadline_ms, 600),
    {EnginePort, CalleePort} = setup(),
    Test = self(),
    CalleeUri = <<"sip:callee@127.0.0.1:", (integer_to_binary(CalleePort))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(Req, Res, CalleeUri, #{}),
        Test ! b2b_up,
        {done, _} = chappe_sip_b2b:relay(Legs)
    end),
    callee(CalleePort, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        ToTag = tag(),
        [begin
             send(Sock, Src, resp(Inv, 180, <<"Ringing">>, ToTag, [], <<>>)),
             timer:sleep(400)
         end || _ <- lists:seq(1, 4)],
        send(Sock, Src, resp(Inv, 200, <<"OK">>, ToTag,
                             [{<<"Contact">>, ctc(CalleePort)}], sdp(<<"callee">>))),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        {Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>))
    end),
    caller(fun(Sock) ->
        Call = callid(),
        FT = <<"cftr">>,
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, FT)),
        R = recv_final(Sock),
        Test ! {caller_final, status_of(R)},
        TT = to_tag(R),
        send(Sock, EnginePort, ack(Sock, EnginePort, Call, FT, TT)),
        send(Sock, EnginePort, bye(Sock, EnginePort, Call, FT, TT)),
        _ = recv_status(Sock, 200)
    end),
    ok = expect(b2b_up),
    ok = expect({caller_final, 200}).

%% Timer C on the B leg (RFC 3261 16.8): B sends one 180 and then nothing;
%% when Timer C fires B is CANCELled and A gets a 408.
%% req: R3261-P-019
b2b_timer_c_408(_Config) ->
    {EnginePort, CalleePort} = setup(),
    Test = self(),
    CalleeUri = <<"sip:callee@127.0.0.1:", (integer_to_binary(CalleePort))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        R = chappe_sip:create_b2bua(Req, Res, CalleeUri, #{timer_c => 500}),
        Test ! {b2b_result, R}
    end),
    callee(CalleePort, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        {Cancel, CSrc} = recv(Sock, <<"CANCEL">>),
        send(Sock, CSrc, resp(Cancel, 200, <<"OK">>, tag(), [], <<>>)),
        send(Sock, Src, resp(Inv, 487, <<"Request Terminated">>, tag(), [], <<>>)),
        Test ! callee_cancelled
    end),
    caller(fun(Sock) ->
        Call = callid(),
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, <<"cftc">>)),
        R = recv_final(Sock),
        send(Sock, EnginePort, ack_status(Sock, EnginePort, Call, <<"cftc">>, R)),
        Test ! {caller_final, status_of(R)}
    end),
    ok = expect(callee_cancelled),
    ok = expect({caller_final, 408}),
    receive {b2b_result, {error, timeout}} -> ok
    after 5000 -> ct:fail(no_b2b_timeout)
    end.

%% Each provisional restarts Timer C: B rings for three times the timer
%% with a 180 every 300 ms and still connects.
%% req: R3261-P-018
b2b_timer_c_restarted(_Config) ->
    application:set_env(chappe_sip, timer_c_ms, 600),
    {EnginePort, CalleePort} = setup(),
    Test = self(),
    CalleeUri = <<"sip:callee@127.0.0.1:", (integer_to_binary(CalleePort))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(Req, Res, CalleeUri, #{}),
        {done, _} = chappe_sip_b2b:relay(Legs)
    end),
    callee(CalleePort, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        ToTag = tag(),
        [begin
             send(Sock, Src, resp(Inv, 180, <<"Ringing">>, ToTag, [], <<>>)),
             timer:sleep(300)
         end || _ <- lists:seq(1, 6)],
        send(Sock, Src, resp(Inv, 200, <<"OK">>, ToTag,
                             [{<<"Contact">>, ctc(CalleePort)}], sdp(<<"callee">>))),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        {Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>))
    end),
    caller(fun(Sock) ->
        Call = callid(),
        FT = <<"cftk">>,
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, FT)),
        R = recv_final(Sock),
        Test ! {caller_final, status_of(R)},
        TT = to_tag(R),
        send(Sock, EnginePort, ack(Sock, EnginePort, Call, FT, TT)),
        send(Sock, EnginePort, bye(Sock, EnginePort, Call, FT, TT)),
        _ = recv_status(Sock, 200)
    end),
    ok = expect({caller_final, 200}).

%% callee 486 -> caller gets 486 (pass_failure default true)
b2b_callee_busy(_Config) ->
    {EnginePort, CalleePort} = setup(),
    Test = self(),
    CalleeUri = <<"sip:callee@127.0.0.1:", (integer_to_binary(CalleePort))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        R = chappe_sip:create_b2bua(Req, Res, CalleeUri, #{}),
        Test ! {b2b_result, R}
    end),
    callee(CalleePort, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 486, <<"Busy Here">>, tag(), [], <<>>))
    end),
    caller(fun(Sock) ->
        Call = callid(),
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, <<"cft2">>)),
        R = recv_status(Sock, 486),
        send(Sock, EnginePort, ack_status(Sock, EnginePort, Call, <<"cft2">>, R)),
        Test ! caller_got_486
    end),
    ok = expect(caller_got_486),
    receive
        {b2b_result, {error, #chappe_sip_error{status = 486}}} -> ok
    after 5000 -> ct:fail(no_b2b_failure)
    end.

%% caller CANCEL while callee rings -> callee gets CANCEL, caller gets 487
b2b_caller_cancel(_Config) ->
    {EnginePort, CalleePort} = setup(),
    Test = self(),
    CalleeUri = <<"sip:callee@127.0.0.1:", (integer_to_binary(CalleePort))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        R = chappe_sip:create_b2bua(Req, Res, CalleeUri, #{}),
        Test ! {b2b_result, R}
    end),
    callee(CalleePort, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        Test ! callee_ringing,
        {Cancel, CSrc} = recv(Sock, <<"CANCEL">>),
        send(Sock, CSrc, resp(Cancel, 200, <<"OK">>, tag(), [], <<>>)),
        send(Sock, Src, resp(Inv, 487, <<"Request Terminated">>, tag(), [], <<>>)),
        Test ! callee_cancelled
    end),
    caller(fun(Sock) ->
        Call = callid(),
        FT = <<"cft3">>,
        Br = branch(),
        send(Sock, EnginePort, invite_br(Sock, Call, FT, Br)),
        _ = recv_status(Sock, 180),
        Test ! caller_ringing,
        %% CANCEL must reuse the INVITE's branch (RFC 3261 9.1)
        send(Sock, EnginePort, cancel_br(Sock, Call, FT, Br)),
        R = recv_status(Sock, 487),
        send(Sock, EnginePort, ack_status(Sock, EnginePort, Call, FT, R)),
        Test ! caller_got_487
    end),
    ok = expect(callee_ringing),
    ok = expect(caller_ringing),
    ok = expect(callee_cancelled),
    ok = expect(caller_got_487),
    receive
        {b2b_result, {error, cancelled}} -> ok
    after 5000 -> ct:fail(no_cancel_result)
    end.

%% ---- parallel forking ----

%% Two callees ring at once; the second answers. A sees one To-tag on the
%% 180 and the 200, the first callee gets a CANCEL with an RFC 3326
%% Reason, and the call runs with the second.
%% req: R3261-P-031
fork_one_answers(_Config) ->
    {EnginePort, C1} = setup(),
    C2 = pick(),
    Test = self(),
    ok = fork_app(Test, [uri(C1), uri(C2)], #{}),
    callee(C1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        {Cancel, CSrc} = recv(Sock, <<"CANCEL">>),
        Test ! {c1_cancel, Cancel},
        send(Sock, CSrc, resp(Cancel, 200, <<"OK">>, tag(), [], <<>>)),
        send(Sock, Src, resp(Inv, 487, <<"Request Terminated">>, tag(), [], <<>>))
    end),
    callee(C2, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        timer:sleep(300),
        ToTag = tag(),
        send(Sock, Src, resp(Inv, 200, <<"OK">>, ToTag,
                             [{<<"Contact">>, ctc(C2)}], sdp(<<"callee2">>))),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        Test ! c2_acked,
        {Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>)),
        Test ! c2_byed
    end),
    caller(fun(Sock) ->
        Call = callid(),
        FT = <<"fk1">>,
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, FT)),
        R180 = recv_status(Sock, 180),
        R200 = recv_status(Sock, 200),
        Test ! {caller_tags, to_tag(R180), to_tag(R200), R200},
        TT = to_tag(R200),
        send(Sock, EnginePort, ack(Sock, EnginePort, Call, FT, TT)),
        timer:sleep(200),
        send(Sock, EnginePort, bye(Sock, EnginePort, Call, FT, TT)),
        _ = recv_status(Sock, 200)
    end),
    receive
        {caller_tags, T180, T200, R200} ->
            ?assertEqual(T180, T200),
            ?assertNotEqual(nomatch, binary:match(R200, <<"callee2">>))
    after 6000 -> ct:fail(no_caller_tags)
    end,
    receive
        {c1_cancel, Cancel} ->
            ?assertNotEqual(nomatch,
                            binary:match(Cancel, <<"Call completed elsewhere">>))
    after 6000 -> ct:fail(no_cancel)
    end,
    ok = expect(c2_acked),
    ok = expect(c2_byed),
    ok = expect({relay_done, a_bye}).

%% One callee is busy, the other answers: the busy one is not the end.
fork_busy_then_answer(_Config) ->
    {EnginePort, C1} = setup(),
    C2 = pick(),
    Test = self(),
    ok = fork_app(Test, [uri(C1), uri(C2)], #{}),
    callee(C1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 486, <<"Busy Here">>, tag(), [], <<>>))
    end),
    callee(C2, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        timer:sleep(300),
        ToTag = tag(),
        send(Sock, Src, resp(Inv, 200, <<"OK">>, ToTag,
                             [{<<"Contact">>, ctc(C2)}], sdp(<<"callee2">>))),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        {Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>))
    end),
    caller(fun(Sock) ->
        Call = callid(),
        FT = <<"fk2">>,
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, FT)),
        R = recv_final(Sock),
        Test ! {caller_final, status_of(R)},
        TT = to_tag(R),
        send(Sock, EnginePort, ack(Sock, EnginePort, Call, FT, TT)),
        send(Sock, EnginePort, bye(Sock, EnginePort, Call, FT, TT)),
        _ = recv_status(Sock, 200)
    end),
    ok = expect({caller_final, 200}),
    ok = expect({relay_done, a_bye}).

%% Every branch fails: A gets the best final (RFC 3261 16.7 step 6), the
%% lowest class, so a 486 beats a 503 that came after it.
%% req: R3261-P-020
fork_all_fail_best(_Config) ->
    {EnginePort, C1} = setup(),
    C2 = pick(),
    Test = self(),
    ok = fork_app(Test, [uri(C1), uri(C2)], #{}),
    callee(C1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 486, <<"Busy Here">>, tag(), [], <<>>))
    end),
    callee(C2, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        timer:sleep(300),
        send(Sock, Src, resp(Inv, 503, <<"Service Unavailable">>, tag(), [], <<>>))
    end),
    caller(fun(Sock) ->
        Call = callid(),
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, <<"fk3">>)),
        R = recv_final(Sock),
        send(Sock, EnginePort, ack_status(Sock, EnginePort, Call, <<"fk3">>, R)),
        Test ! {caller_final, status_of(R)}
    end),
    ok = expect({caller_final, 486}),
    receive
        {fork_result, {error, #chappe_sip_error{status = 486}}} -> ok
    after 5000 -> ct:fail(no_fork_failure)
    end.

%% Timer C covers the whole fork: both branches ring, neither answers; both
%% are CANCELled and A gets a 408.
%% req: R3261-P-019
fork_timer_c(_Config) ->
    {EnginePort, C1} = setup(),
    C2 = pick(),
    Test = self(),
    ok = fork_app(Test, [uri(C1), uri(C2)], #{timer_c => 500}),
    Ring = fun(Name) ->
        fun(Sock) ->
            {Inv, Src} = recv(Sock, <<"INVITE">>),
            send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
            {Cancel, CSrc} = recv(Sock, <<"CANCEL">>),
            send(Sock, CSrc, resp(Cancel, 200, <<"OK">>, tag(), [], <<>>)),
            send(Sock, Src, resp(Inv, 487, <<"Request Terminated">>, tag(), [], <<>>)),
            Test ! {cancelled, Name}
        end
    end,
    callee(C1, Ring(c1)),
    callee(C2, Ring(c2)),
    caller(fun(Sock) ->
        Call = callid(),
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, <<"fk4">>)),
        R = recv_final(Sock),
        send(Sock, EnginePort, ack_status(Sock, EnginePort, Call, <<"fk4">>, R)),
        Test ! {caller_final, status_of(R)}
    end),
    ok = expect({cancelled, c1}),
    ok = expect({cancelled, c2}),
    ok = expect({caller_final, 408}),
    receive {fork_result, {error, timeout}} -> ok
    after 5000 -> ct:fail(no_fork_timeout)
    end.

%% A 2xx from a branch that lost the race (it answered as our CANCEL went
%% out) is ACKed and BYEd, with the Reason of the CANCEL.
fork_late_2xx(_Config) ->
    {EnginePort, C1} = setup(),
    C2 = pick(),
    Test = self(),
    ok = fork_app(Test, [uri(C1), uri(C2)], #{}),
    callee(C1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        timer:sleep(200),
        ToTag = tag(),
        send(Sock, Src, resp(Inv, 200, <<"OK">>, ToTag,
                             [{<<"Contact">>, ctc(C1)}], sdp(<<"callee1">>))),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        {Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>))
    end),
    callee(C2, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        {Cancel, CSrc} = recv(Sock, <<"CANCEL">>),
        %% answered before the CANCEL arrived
        ToTag = tag(),
        send(Sock, Src, resp(Inv, 200, <<"OK">>, ToTag,
                             [{<<"Contact">>, ctc(C2)}], sdp(<<"callee2">>))),
        send(Sock, CSrc, resp(Cancel, 200, <<"OK">>, ToTag, [], <<>>)),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        Test ! c2_acked,
        {Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>)),
        Test ! {c2_bye, Bye}
    end),
    caller(fun(Sock) ->
        Call = callid(),
        FT = <<"fk5">>,
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, FT)),
        R = recv_final(Sock),
        Test ! {caller_final, status_of(R), R},
        TT = to_tag(R),
        send(Sock, EnginePort, ack(Sock, EnginePort, Call, FT, TT)),
        timer:sleep(500),
        send(Sock, EnginePort, bye(Sock, EnginePort, Call, FT, TT)),
        _ = recv_status(Sock, 200)
    end),
    receive
        {caller_final, 200, R} ->
            ?assertNotEqual(nomatch, binary:match(R, <<"callee1">>))
    after 6000 -> ct:fail(no_caller_final)
    end,
    ok = expect(c2_acked),
    receive
        {c2_bye, Bye} ->
            ?assertNotEqual(nomatch,
                            binary:match(Bye, <<"Call completed elsewhere">>))
    after 6000 -> ct:fail(no_late_bye)
    end,
    ok = expect({relay_done, a_bye}).

%% ---- pass_failure => false ----

%% Timer C with pass_failure => false: B is CANCELled, A is not answered,
%% and the app answers A itself.
%% req: R3261-P-019
pass_failure_timer_c(_Config) ->
    {EnginePort, CalleePort} = setup(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        R = chappe_sip:create_b2bua(Req, Res, uri(CalleePort),
                                    #{timer_c => 500, pass_failure => false}),
        Test ! {b2b_result, R},
        _ = chappe_sip_res:send(Res, 480, #{reason => <<"Temporarily Unavailable">>})
    end),
    callee(CalleePort, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        {Cancel, CSrc} = recv(Sock, <<"CANCEL">>),
        send(Sock, CSrc, resp(Cancel, 200, <<"OK">>, tag(), [], <<>>)),
        send(Sock, Src, resp(Inv, 487, <<"Request Terminated">>, tag(), [], <<>>))
    end),
    caller(fun(Sock) ->
        Call = callid(),
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, <<"pf1">>)),
        R = recv_final(Sock),
        send(Sock, EnginePort, ack_status(Sock, EnginePort, Call, <<"pf1">>, R)),
        Test ! {caller_final, status_of(R)}
    end),
    ok = expect({caller_final, 480}),
    receive {b2b_result, {error, timeout}} -> ok
    after 5000 -> ct:fail(no_b2b_timeout)
    end.

%% The last target cannot be called at all: A gets its 500 right away,
%% while the handler still runs.
start_failure_answered(_Config) ->
    {EnginePort, _} = setup(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        R = chappe_sip:create_b2bua(Req, Res, bad_uri(), #{}),
        Test ! {b2b_result, R},
        timer:sleep(3000)
    end),
    caller(fun(Sock) ->
        Call = callid(),
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, <<"sf1">>)),
        R = recv_final(Sock, 1500),
        send(Sock, EnginePort, ack_status(Sock, EnginePort, Call, <<"sf1">>, R)),
        Test ! {caller_final, status_of(R)}
    end),
    ok = expect({caller_final, 500}),
    receive {b2b_result, {error, _}} -> ok
    after 5000 -> ct:fail(no_b2b_error)
    end.

%% The same with pass_failure => false: A is left to the app.
start_failure_not_passed(_Config) ->
    {EnginePort, _} = setup(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        R = chappe_sip:create_b2bua(Req, Res, bad_uri(), #{pass_failure => false}),
        Test ! {b2b_result, R},
        _ = chappe_sip_res:send(Res, 404, #{reason => <<"Not Found">>})
    end),
    caller(fun(Sock) ->
        Call = callid(),
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, <<"sf2">>)),
        R = recv_final(Sock),
        send(Sock, EnginePort, ack_status(Sock, EnginePort, Call, <<"sf2">>, R)),
        Test ! {caller_final, status_of(R)}
    end),
    ok = expect({caller_final, 404}),
    receive {b2b_result, {error, _}} -> ok
    after 5000 -> ct:fail(no_b2b_error)
    end.

%% Each branch of a fork takes its own options: its headers reach only
%% its INVITE (after the call-wide b_headers), its flow says where that
%% INVITE goes, and the result names the branch that answered.
fork_branch_opts(_Config) ->
    {EnginePort, C1} = setup(),
    C2 = pick(),
    Unused = pick(),
    Test = self(),
    B2Opts = #{headers => [{<<"X-Branch">>, <<"two">>}],
               flow => {udp, <<"127.0.0.1">>, C2}},
    Dests = [{uri(C1), #{headers => [{<<"X-Branch">>, <<"one">>}]}},
             {uri(Unused), B2Opts}],
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(
            Req, Res, {parallel, Dests},
            #{b_headers => [{<<"X-Call">>, <<"all">>}]}),
        Test ! {winner, maps:get(winner, Legs)},
        #{b2b := B2b} = Legs,
        spawn(fun() -> Test ! {info, chappe_sip_b2b:info(B2b)} end),
        {done, Why} = chappe_sip_b2b:relay(Legs),
        Test ! {relay_done, Why}
    end),
    callee(C1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        Test ! {c1_invite, Inv},
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        {Cancel, CSrc} = recv(Sock, <<"CANCEL">>),
        send(Sock, CSrc, resp(Cancel, 200, <<"OK">>, tag(), [], <<>>)),
        send(Sock, Src, resp(Inv, 487, <<"Request Terminated">>, tag(), [], <<>>))
    end),
    %% the second branch's Request-URI names a port nobody listens on: its
    %% flow takes the INVITE to C2
    callee(C2, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        Test ! {c2_invite, Inv},
        timer:sleep(300),
        ToTag = tag(),
        send(Sock, Src, resp(Inv, 200, <<"OK">>, ToTag,
                             [{<<"Contact">>, ctc(C2)}], sdp(<<"callee2">>))),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        {Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>))
    end),
    caller(fun(Sock) ->
        Call = callid(),
        FT = <<"fb1">>,
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, FT)),
        R200 = recv_status(Sock, 200),
        TT = to_tag(R200),
        send(Sock, EnginePort, ack(Sock, EnginePort, Call, FT, TT)),
        timer:sleep(200),
        send(Sock, EnginePort, bye(Sock, EnginePort, Call, FT, TT)),
        _ = recv_status(Sock, 200)
    end),
    Inv1 = got(c1_invite),
    Inv2 = got(c2_invite),
    ?assertEqual([<<"one">>], header_values(<<"x-branch">>, Inv1)),
    ?assertEqual([<<"two">>], header_values(<<"x-branch">>, Inv2)),
    ?assertEqual([<<"all">>], header_values(<<"x-call">>, Inv1)),
    ?assertEqual([<<"all">>], header_values(<<"x-call">>, Inv2)),
    Winner = #{uri => uri(Unused), index => 2, opts => B2Opts},
    ?assertEqual(Winner, got(winner)),
    ?assertMatch(#{winner := Winner}, got(info)),
    ok = expect({relay_done, a_bye}).

%% A list of targets takes {Uri, Opts} entries too: the second target
%% gets its own headers once the first fails with 503, and wins.
serial_branch_opts(_Config) ->
    {EnginePort, C1} = setup(),
    C2 = pick(),
    Test = self(),
    Dests = [{uri(C1), #{headers => [{<<"X-Step">>, <<"one">>}]}},
             {uri(C2), #{headers => [{<<"X-Step">>, <<"two">>}]}}],
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(Req, Res, Dests, #{}),
        Test ! {winner, maps:get(winner, Legs)},
        {done, Why} = chappe_sip_b2b:relay(Legs),
        Test ! {relay_done, Why}
    end),
    callee(C1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        Test ! {c1_invite, Inv},
        send(Sock, Src, resp(Inv, 503, <<"Service Unavailable">>, tag(), [], <<>>))
    end),
    callee(C2, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        Test ! {c2_invite, Inv},
        ToTag = tag(),
        send(Sock, Src, resp(Inv, 200, <<"OK">>, ToTag,
                             [{<<"Contact">>, ctc(C2)}], sdp(<<"callee2">>))),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        {Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>))
    end),
    caller(fun(Sock) ->
        Call = callid(),
        FT = <<"sb1">>,
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, FT)),
        R200 = recv_status(Sock, 200),
        TT = to_tag(R200),
        send(Sock, EnginePort, ack(Sock, EnginePort, Call, FT, TT)),
        send(Sock, EnginePort, bye(Sock, EnginePort, Call, FT, TT)),
        _ = recv_status(Sock, 200)
    end),
    ?assertEqual([<<"one">>], header_values(<<"x-step">>, got(c1_invite))),
    ?assertEqual([<<"two">>], header_values(<<"x-step">>, got(c2_invite))),
    ?assertMatch(#{uri := _, index := 2,
                   opts := #{headers := [{<<"X-Step">>, <<"two">>}]}},
                 got(winner)),
    ok = expect({relay_done, a_bye}).

got(Tag) ->
    receive {Tag, V} -> V after 6000 -> ct:fail({missing, Tag}) end.

header_values(Name, Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    chappe_sip_msg:get_all(Name, M).

%% the app forks every INVITE to Uris and relays the call
fork_app(Test, Uris, Opts) ->
    chappe_sip:invite(fun(Req, Res) ->
        case chappe_sip:create_b2bua(Req, Res, {parallel, Uris}, Opts) of
            {ok, Legs} ->
                {done, Why} = chappe_sip_b2b:relay(Legs),
                Test ! {relay_done, Why};
            Err ->
                Test ! {fork_result, Err}
        end
    end).

uri(Port) ->
    <<"sip:callee@127.0.0.1:", (integer_to_binary(Port))/binary>>.

%% a SIPS URI over UDP: the UAC refuses to send it (RFC 3261 19.1.1)
bad_uri() ->
    <<"sips:callee@127.0.0.1;transport=udp">>.

%% ---- peers ----

setup() ->
    EnginePort = pick(),
    CalleePort = pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:",
                                   (integer_to_binary(EnginePort))/binary>>}),
    {EnginePort, CalleePort}.

callee(Port, Fun) -> peer(Port, Fun).

caller(Fun) -> peer(0, Fun).

peer(Port, Fun) ->
    Parent = self(),
    Pid = spawn_link(fun() ->
        {ok, Sock} = gen_udp:open(Port, [binary, {active, true},
                                         {ip, {127,0,0,1}}]),
        Parent ! {peer_ready, self()},
        Fun(Sock)
    end),
    receive {peer_ready, Pid} -> ok after 2000 -> ct:fail(peer_not_ready) end,
    Pid.

expect(Msg) ->
    receive Msg -> ok after 6000 -> ct:fail({expected, Msg}) end.

%% ---- SIP helpers ----

pick() -> chappe_sip_test_port:pick().
ctc(P) -> <<"sip:x@127.0.0.1:", (integer_to_binary(P))/binary>>.
tag() -> binary:encode_hex(crypto:strong_rand_bytes(5), lowercase).
callid() ->
    <<"m5-", (binary:encode_hex(crypto:strong_rand_bytes(4)))/binary, "@ct">>.
branch() ->
    <<"z9hG4bK", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>.
sdp(Marker) ->
    <<"v=0\r\no=", Marker/binary, " 0 0 IN IP4 127.0.0.1\r\ns=-\r\n"
      "c=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio 40000 RTP/AVP 0\r\n">>.

lport(Sock) -> {ok, P} = inet:port(Sock), P.

send(Sock, DstPort, Bin) -> gen_udp:send(Sock, {127,0,0,1}, DstPort, Bin).

recv(Sock, Method) ->
    L = byte_size(Method),
    receive
        {udp, Sock, _, Src, <<M:L/binary, " ", _/binary>> = Bin} when M =:= Method ->
            {Bin, Src};
        {udp, Sock, _, _, _} -> recv(Sock, Method)
    after 6000 -> ct:fail({no_req, Method})
    end.

recv_status(Sock, Code) ->
    CB = integer_to_binary(Code),
    receive
        {udp, Sock, _, _, <<"SIP/2.0 ", C:3/binary, _/binary>> = Bin} ->
            case C of
                CB -> Bin;
                <<"100">> -> recv_status(Sock, Code);
                _ -> recv_status(Sock, Code)   % skip other provisionals
            end
    after 6000 -> ct:fail({no_status, Code})
    end.

to_tag(Resp) ->
    {ok, M} = chappe_sip_msg:parse(Resp),
    chappe_sip_msg:to_tag(M).

%% the first final response
recv_final(Sock) ->
    recv_final(Sock, 6000).

recv_final(Sock, Timeout) ->
    receive
        {udp, Sock, _, _, <<"SIP/2.0 1", _/binary>>} -> recv_final(Sock, Timeout);
        {udp, Sock, _, _, <<"SIP/2.0 ", _/binary>> = Bin} -> Bin;
        {udp, Sock, _, _, _} -> recv_final(Sock, Timeout)
    after Timeout -> ct:fail(no_final)
    end.

status_of(<<"SIP/2.0 ", C:3/binary, _/binary>>) -> binary_to_integer(C).

invite(Sock, _EP, Call, FT) ->
    P = integer_to_binary(lport(Sock)),
    S = sdp(<<"caller">>),
    L = integer_to_binary(byte_size(S)),
    <<"INVITE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Contact: <sip:caller@127.0.0.1:", P/binary, ">\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 INVITE\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: ", L/binary, "\r\n\r\n", S/binary>>.

ack(Sock, _EP, Call, FT, TT) ->
    P = integer_to_binary(lport(Sock)),
    <<"ACK sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 ACK\r\nContent-Length: 0\r\n\r\n">>.

%% ACK for a non-2xx final: To tag comes from the response
ack_status(Sock, _EP, Call, FT, Resp) ->
    TT = case to_tag_of(Resp) of undefined -> <<>>; T -> <<";tag=", T/binary>> end,
    P = integer_to_binary(lport(Sock)),
    <<"ACK sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>", TT/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 ACK\r\nContent-Length: 0\r\n\r\n">>.

bye(Sock, _EP, Call, FT, TT) ->
    P = integer_to_binary(lport(Sock)),
    <<"BYE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 2 BYE\r\nContent-Length: 0\r\n\r\n">>.

%% INVITE and its CANCEL share a caller-chosen branch.
invite_br(Sock, Call, FT, Br) ->
    P = integer_to_binary(lport(Sock)),
    S = sdp(<<"caller">>),
    L = integer_to_binary(byte_size(S)),
    <<"INVITE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", Br/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Contact: <sip:caller@127.0.0.1:", P/binary, ">\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 INVITE\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: ", L/binary, "\r\n\r\n", S/binary>>.

cancel_br(Sock, Call, FT, Br) ->
    P = integer_to_binary(lport(Sock)),
    <<"CANCEL sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", Br/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 CANCEL\r\nContent-Length: 0\r\n\r\n">>.

to_tag_of(Resp) ->
    {ok, M} = chappe_sip_msg:parse(Resp),
    chappe_sip_msg:to_tag(M).

%% Build a response echoing Via/From/Call-ID/CSeq; add To tag if absent.
resp(ReqBin, Status, Reason, ToTag, ExtraHeaders, Body) ->
    {ok, Msg} = chappe_sip_msg:parse(ReqBin),
    Vias = chappe_sip_msg:get_all(<<"via">>, Msg),
    From = chappe_sip_msg:get(<<"from">>, Msg),
    To0 = chappe_sip_msg:get(<<"to">>, Msg),
    To = case chappe_sip_msg:to_tag(Msg) of
             undefined when Status > 100 -> <<To0/binary, ";tag=", ToTag/binary>>;
             _ -> To0
         end,
    Call = chappe_sip_msg:call_id(Msg),
    CSeq = chappe_sip_msg:get(<<"cseq">>, Msg),
    ViaLines = [[<<"Via: ">>, V, <<"\r\n">>] || V <- Vias],
    Extra = [[N, <<": ">>, Val, <<"\r\n">>] || {N, Val} <- ExtraHeaders],
    CL = integer_to_binary(byte_size(Body)),
    iolist_to_binary(
      [<<"SIP/2.0 ">>, integer_to_binary(Status), <<" ">>, Reason, <<"\r\n">>,
       ViaLines, <<"From: ">>, From, <<"\r\n">>, <<"To: ">>, To, <<"\r\n">>,
       <<"Call-ID: ">>, Call, <<"\r\n">>, <<"CSeq: ">>, CSeq, <<"\r\n">>, Extra,
       <<"Content-Length: ">>, CL, <<"\r\n\r\n">>, Body]).
