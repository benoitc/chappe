%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The dialog fsm against a stand-in engine: orderings a live peer cannot
%% produce on demand.
-module(chappe_sip_dialog_fsm_tests).
-include_lib("eunit/include/eunit.hrl").

%% A BYE that reaches the dialog while it is still in setup (before the
%% leg is confirmed) is kept, then answered 200 once the dialog is up, and
%% the owner is told the dialog is gone (RFC 3261 12.2.2: it belongs to
%% the dialog).
bye_in_setup_test() ->
    Engine = mock_engine(self()),
    {ok, Fsm} = chappe_sip_dialog_fsm:start_link(#{
        leg => 1,
        call_id => <<"setup-bye">>,
        local_addr => <<"<sip:a@example.com>;tag=a">>,
        remote_addr => <<"<sip:b@example.com>">>,
        remote_target => <<"sip:b@example.com">>,
        local_tag => <<"a">>,
        owner => self(),
        role => uas,
        opts => #{}
    }),
    Bye = <<"BYE sip:a@example.com SIP/2.0\r\n"
            "Via: SIP/2.0/UDP 127.0.0.1:5070;branch=z9hG4bKsetup\r\n"
            "From: <sip:b@example.com>;tag=b\r\n"
            "To: <sip:a@example.com>;tag=a\r\n"
            "Call-ID: setup-bye\r\nCSeq: 2 BYE\r\nContent-Length: 0\r\n\r\n">>,
    Fsm ! {chappe_sip_indialog, 1, 77, #{}, Bye},
    %% still in setup: nothing answered yet
    receive
        {engine_call, {dialog_respond, 77, _, _, _, _, _}} -> ?assert(false)
    after 200 -> ok
    end,
    Fsm ! {chappe_sip_op, 1, ok},
    ?assertEqual({ok, 1}, gen_statem:call(Fsm, await_ready)),
    receive
        {engine_call, {dialog_respond, 77, Status, _, _, _, _}} ->
            ?assertEqual(200, Status)
    after 2000 -> ?assert(false)
    end,
    receive
        {chappe_sip_dialog, _, destroy, _} -> ok
    after 2000 -> ?assert(false)
    end,
    unlink(Fsm),
    exit(Engine, kill),
    flush().

mock_engine(Test) ->
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
