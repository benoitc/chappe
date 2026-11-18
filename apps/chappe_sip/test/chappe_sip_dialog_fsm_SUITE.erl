%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The dialog fsm against a stand-in engine: the paths of modify/2,3,
%% set_owner/2 and the session refresh that the live suites do not reach.
%% The stand-in answers every engine call {ok, 999} and tells the test
%% case what the fsm asked.
-module(chappe_sip_dialog_fsm_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    modify_early_dialog/1,
    modify_request_pending/1,
    set_owner_moves_events/1,
    st_refresh_glare_retry/1
]).

all() ->
    [
        modify_early_dialog,
        modify_request_pending,
        set_owner_moves_events,
        st_refresh_glare_retry
    ].

init_per_testcase(_Case, Config) ->
    [{engine, mock_engine(self())} | Config].

end_per_testcase(_Case, Config) ->
    exit(?config(engine, Config), kill),
    flush(),
    ok.

%% An early dialog of an INVITE we send takes no re-INVITE before the
%% INVITE completes (RFC 3261 14.1): modify/2,3 answer {error, early}.
modify_early_dialog(_Config) ->
    Fsm = start_dialog(#{
        role => uac,
        early_uac => self(),
        cseq_ref => atomics:new(1, [])
    }),
    Dlg = chappe_sip_dialog:make(Fsm, 1),
    ?assertEqual({error, early}, chappe_sip_dialog:modify(Dlg, hold)),
    ?assertEqual(
        {error, early}, chappe_sip_dialog:modify(Dlg, hold, #{})
    ),
    stop_dialog(Fsm).

%% Our 2xx to the INVITE is not ACKed yet: a first modify waits for the
%% ACK (RFC 3261 14.1), a second one meanwhile gets {error,
%% request_pending}, and the ACK releases the first as a re-INVITE.
modify_request_pending(_Config) ->
    Fsm = start_dialog(#{
        role => uas,
        txn => 5,
        ack_wait => true,
        local_sdp => sdp()
    }),
    Dlg = chappe_sip_dialog:make(Fsm, 1),
    Test = self(),
    _ = spawn(fun() -> Test ! {held, chappe_sip_dialog:modify(Dlg, hold)} end),
    %% the held modify reaches the fsm before the second one
    timer:sleep(200),
    ?assertEqual(
        {error, request_pending}, chappe_sip_dialog:modify(Dlg, unhold)
    ),
    refute_request(200),
    Fsm ! {chappe_sip_ack, 5, ack()},
    Raw = expect_request(2000),
    ?assertMatch(<<"INVITE sip:b@example.com SIP/2.0\r\n", _/binary>>, Raw),
    {_, _} = binary:match(Raw, <<"a=sendonly">>),
    Fsm ! {chappe_sip_response, 999, #{status => 200}, ok_200(Raw)},
    receive
        {held, Result} -> ?assertMatch({ok, _}, Result)
    after 2000 -> ct:fail(no_modify_result)
    end,
    stop_dialog(Fsm).

%% set_owner/2 moves the monitor: the old owner's exit leaves the dialog
%% up, and the new owner hears of its requests.
set_owner_moves_events(_Config) ->
    Old = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    Fsm = start_dialog(#{role => uas, owner => Old}),
    Dlg = chappe_sip_dialog:make(Fsm, 1),
    ok = chappe_sip_dialog:set_owner(Dlg, self()),
    Old ! stop,
    refute_request(300),
    ?assert(is_process_alive(Fsm)),
    Fsm ! {chappe_sip_indialog, 1, 41, #{}, info()},
    receive
        {chappe_sip_dialog, _, {auto_answered, info}, _} -> ok
    after 2000 -> ct:fail(no_event)
    end,
    stop_dialog(Fsm).

%% A 491 to our session refresh (RFC 3261 14.1 glare) is retried after
%% 2.1 to 4 s, with the next CSeq (RFC 4028 10). An interval of 30 s
%% refreshes at 15 s, retries by 19 s and expires at 20 s.
st_refresh_glare_retry(_Config) ->
    St = #{interval => 30, refresher => local, min_se => 0, peer_update => true},
    Fsm = start_dialog(#{role => uac, session_timer => St}),
    First = expect_request(17000),
    ?assertMatch(<<"UPDATE ", _/binary>>, First),
    ?assertNotEqual(nomatch, binary:match(First, <<"CSeq: 2 UPDATE">>)),
    T0 = erlang:monotonic_time(millisecond),
    Fsm ! {chappe_sip_response, 999, #{status => 491}, status(First, 491)},
    Retry = expect_request(4500),
    Waited = erlang:monotonic_time(millisecond) - T0,
    ?assert(Waited >= 2000),
    ?assertMatch(<<"UPDATE ", _/binary>>, Retry),
    ?assertNotEqual(nomatch, binary:match(Retry, <<"CSeq: 3 UPDATE">>)),
    stop_dialog(Fsm).

%% ---- helpers ----

start_dialog(Extra) ->
    Base = #{
        leg => 1,
        call_id => <<"fsm-suite">>,
        local_addr => <<"<sip:a@example.com>;tag=a">>,
        remote_addr => <<"<sip:b@example.com>;tag=b">>,
        remote_target => <<"sip:b@example.com">>,
        local_tag => <<"a">>,
        owner => self(),
        opts => #{}
    },
    {ok, Fsm} = chappe_sip_dialog_fsm:start_link(maps:merge(Base, Extra)),
    unlink(Fsm),
    Fsm ! {chappe_sip_op, 1, ok},
    {ok, 1} = gen_statem:call(Fsm, await_ready),
    Fsm.

stop_dialog(Fsm) ->
    exit(Fsm, kill).

expect_request(Timeout) ->
    receive
        {engine_call, {txn, {send_request, _Route, Raw, _Pid, _Opts}}} -> Raw
    after Timeout -> ct:fail(no_request)
    end.

refute_request(Timeout) ->
    receive
        {engine_call, {txn, {send_request, _, Raw, _, _}}} ->
            ct:fail({unexpected_request, Raw})
    after Timeout -> ok
    end.

sdp() ->
    <<"v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
      "t=0 0\r\nm=audio 4000 RTP/AVP 0\r\na=sendrecv\r\n">>.

ack() ->
    <<"ACK sip:a@example.com SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:5070;branch=z9hG4bKsuiteack\r\n"
      "From: <sip:b@example.com>;tag=b\r\n"
      "To: <sip:a@example.com>;tag=a\r\n"
      "Call-ID: fsm-suite\r\nCSeq: 1 ACK\r\nContent-Length: 0\r\n\r\n">>.

info() ->
    <<"INFO sip:a@example.com SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:5070;branch=z9hG4bKsuiteinfo\r\n"
      "From: <sip:b@example.com>;tag=b\r\n"
      "To: <sip:a@example.com>;tag=a\r\n"
      "Call-ID: fsm-suite\r\nCSeq: 2 INFO\r\nContent-Length: 0\r\n\r\n">>.

%% a response to Raw, the request we sent: its CSeq line, no body
status(Raw, Status) ->
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    {ok, #{seq := Seq, method := M}} = chappe_sip_msg:cseq(Msg),
    S = integer_to_binary(Status),
    N = integer_to_binary(Seq),
    <<"SIP/2.0 ", S/binary, " Status\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:5060;branch=z9hG4bKsuite\r\n"
      "From: <sip:a@example.com>;tag=a\r\n"
      "To: <sip:b@example.com>;tag=b\r\n"
      "Call-ID: fsm-suite\r\nCSeq: ", N/binary, " ", M/binary, "\r\n"
      "Content-Length: 0\r\n\r\n">>.

ok_200(Raw) ->
    status(Raw, 200).

mock_engine(Test) ->
    case whereis(chappe_sip_engine) of
        undefined -> ok;
        Old -> exit(Old, kill)
    end,
    Pid = spawn(fun() -> engine_loop(Test) end),
    true = register(chappe_sip_engine, Pid),
    Pid.

engine_loop(Test) ->
    receive
        {'$gen_call', From, Req} ->
            Test ! {engine_call, Req},
            gen_server:reply(From, {ok, 999}),
            engine_loop(Test);
        _ ->
            engine_loop(Test)
    end.

flush() ->
    receive
        _ -> flush()
    after 0 -> ok
    end.
