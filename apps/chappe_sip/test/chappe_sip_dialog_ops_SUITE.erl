%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% In-dialog operations and resilience.
%%
%% A gen_udp caller sets up a call with the app (UAS); the tests exercise
%% app-initiated re-INVITE (modify) and INFO, and a controlled engine
%% restart that tears live dialogs down.
-module(chappe_sip_dialog_ops_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([
    reinvite_hold/1,
    indialog_info/1,
    getters_during_request/1,
    engine_restart_tears_down/1,
    engine_crash_reestablishes/1
]).

all() ->
    [
        reinvite_hold,
        indialog_info,
        getters_during_request,
        engine_restart_tears_down,
        engine_crash_reestablishes
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

end_per_testcase(_Case, _Config) ->
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% app answers, then app-initiated re-INVITE (hold); caller answers 200.
reinvite_hold(_Config) ->
    EP = setup(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Dlg} = chappe_sip:create_uas(Req, Res, #{
            local_sdp => sdp(<<"app">>)
        }),
        Test ! {dialog, Dlg, self()},
        receive
            do_hold ->
                R = chappe_sip_dialog:modify(Dlg, hold),
                Test ! {hold_result, R}
        end,
        {destroyed, _} = chappe_sip_dialog:wait(Dlg)
    end),
    Call = callid(),
    caller(EP, fun(Sock, Port) ->
        FT = <<"m7ft">>,
        send(Sock, Port, invite(Sock, Call, FT)),
        R200 = recv_status(Sock, 200),
        TT = to_tag(R200),
        send(Sock, Port, ack(Sock, Call, FT, TT)),
        Test ! caller_up,
        %% receive the re-INVITE, answer 200, expect ACK
        {Re, RSrc} = recv(Sock, <<"INVITE">>),
        % hold offer
        {_, _} = binary:match(Re, <<"sendonly">>),
        %% the Contact of a 2xx to a target refresh is the new remote
        %% target (RFC 3261 12.2.1.2): ours, so the ACK comes back here
        send(
            Sock,
            RSrc,
            resp(
                Re,
                200,
                <<"OK">>,
                TT,
                [{<<"Contact">>, ctc(lport(Sock))}],
                sdp(<<"callee">>)
            )
        ),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        Test ! reinvite_acked,
        {_Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(_Bye, 200, <<"OK">>, TT, [], <<>>))
    end),
    {Dlg, Handler} =
        receive
            {dialog, D, H} -> {D, H}
        after 4000 -> ct:fail(no_dialog)
        end,
    ok = expect(caller_up),
    Handler ! do_hold,
    receive
        {hold_result, {ok, RemoteSdp}} ->
            {_, _} = binary:match(RemoteSdp, <<"callee">>)
    after 5000 -> ct:fail(no_hold_result)
    end,
    ok = expect(reinvite_acked),
    ok = chappe_sip_dialog:destroy(Dlg).

%% app-initiated in-dialog INFO; caller answers 200.
indialog_info(_Config) ->
    EP = setup(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Dlg} = chappe_sip:create_uas(Req, Res, #{
            local_sdp => sdp(<<"app">>)
        }),
        Test ! {dialog, Dlg, self()},
        receive
            do_info ->
                R = chappe_sip_dialog:request(Dlg, #{
                    method => <<"INFO">>,
                    content_type => <<"application/dtmf">>,
                    body => <<"1">>
                }),
                Test ! {info_result, R}
        end,
        {destroyed, _} = chappe_sip_dialog:wait(Dlg)
    end),
    Call = callid(),
    caller(EP, fun(Sock, Port) ->
        FT = <<"m7ft2">>,
        send(Sock, Port, invite(Sock, Call, FT)),
        R200 = recv_status(Sock, 200),
        TT = to_tag(R200),
        send(Sock, Port, ack(Sock, Call, FT, TT)),
        Test ! caller_up,
        {Info, ISrc} = recv(Sock, <<"INFO">>),
        {_, _} = binary:match(Info, <<"application/dtmf">>),
        send(Sock, ISrc, resp(Info, 200, <<"OK">>, TT, [], <<>>)),
        {_Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(_Bye, 200, <<"OK">>, TT, [], <<>>))
    end),
    {Dlg, Handler} =
        receive
            {dialog, D, H} -> {D, H}
        after 4000 -> ct:fail(no_dialog)
        end,
    ok = expect(caller_up),
    Handler ! do_info,
    receive
        {info_result, {ok, Msg}} ->
            ?assertEqual(200, chappe_sip_msg:status(Msg))
    after 5000 -> ct:fail(no_info_result)
    end,
    ok = chappe_sip_dialog:destroy(Dlg).

%% the query and set_handled calls answer while an app-initiated in-dialog
%% request is in flight (the peer holds its answer back meanwhile).
getters_during_request(_Config) ->
    EP = setup(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Dlg} = chappe_sip:create_uas(Req, Res, #{
            local_sdp => sdp(<<"app">>)
        }),
        Test ! {dialog, Dlg, self()},
        receive
            do_info ->
                R = chappe_sip_dialog:request(Dlg, #{method => <<"INFO">>}),
                Test ! {info_result, R}
        end,
        {destroyed, _} = chappe_sip_dialog:wait(Dlg)
    end),
    Call = callid(),
    FT = <<"m7ft4">>,
    Caller = caller(EP, fun(Sock, Port) ->
        send(Sock, Port, invite(Sock, Call, FT)),
        R200 = recv_status(Sock, 200),
        TT = to_tag(R200),
        send(Sock, Port, ack(Sock, Call, FT, TT)),
        Test ! caller_up,
        {Info, ISrc} = recv(Sock, <<"INFO">>),
        Test ! info_held,
        receive
            release -> ok
        after 6000 -> ok
        end,
        send(Sock, ISrc, resp(Info, 200, <<"OK">>, TT, [], <<>>)),
        {_Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(_Bye, 200, <<"OK">>, TT, [], <<>>))
    end),
    {Dlg, Handler} =
        receive
            {dialog, D, H} -> {D, H}
        after 4000 -> ct:fail(no_dialog)
        end,
    ok = expect(caller_up),
    Handler ! do_info,
    ok = expect(info_held),
    ?assertEqual(FT, chappe_sip_dialog:remote_tag(Dlg)),
    ?assert(is_binary(chappe_sip_dialog:local_tag(Dlg))),
    ?assertEqual(Call, chappe_sip_dialog:call_id(Dlg)),
    ?assertMatch(<<"v=0", _/binary>>, chappe_sip_dialog:remote_sdp(Dlg)),
    ?assertEqual(ok, chappe_sip_dialog:set_handled(Dlg, [info])),
    Caller ! release,
    receive
        {info_result, {ok, Msg}} ->
            ?assertEqual(200, chappe_sip_msg:status(Msg))
    after 5000 -> ct:fail(no_info_result)
    end,
    ok = chappe_sip_dialog:destroy(Dlg).

%% a controlled engine restart terminates live dialogs with engine_restart
%% and the engine comes back able to handle a new call.
engine_restart_tears_down(_Config) ->
    EP = setup(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Dlg} = chappe_sip:create_uas(Req, Res, #{
            local_sdp => sdp(<<"app">>)
        }),
        {destroyed, Why} = chappe_sip_dialog:wait(Dlg),
        Test ! {torn_down, Why}
    end),
    Call = callid(),
    caller(EP, fun(Sock, Port) ->
        FT = <<"m7ft3">>,
        send(Sock, Port, invite(Sock, Call, FT)),
        R200 = recv_status(Sock, 200),
        TT = to_tag(R200),
        send(Sock, Port, ack(Sock, Call, FT, TT)),
        Test ! caller_up
    end),
    ok = expect(caller_up),
    timer:sleep(200),
    ok = chappe_sip_engine:restart_engine(),
    receive
        {torn_down, engine_restart} -> ok
    after 5000 -> ct:fail(no_teardown)
    end,
    %% engine is back: a fresh OPTIONS is answered
    ok = chappe_sip:options(fun(_Req, Res) ->
        chappe_sip_res:send(Res, 200, #{})
    end),
    caller(EP, fun(Sock, Port) ->
        send(Sock, Port, options(Sock)),
        _ = recv_status(Sock, 200),
        Test ! options_ok
    end),
    ok = expect(options_ok).

%% F6: a crash of the engine process re-establishes the native stack from the
%% persisted config (opts + routes), so SIP recovers without a manual start.
engine_crash_reestablishes(_Config) ->
    EP = setup(),
    ok = chappe_sip:options(fun(_Req, Res) ->
        chappe_sip_res:send(Res, 200, #{})
    end),
    % answered before the crash
    ?assertEqual(ok, poll_options(EP, 8)),
    exit(whereis(chappe_sip_engine), kill),
    timer:sleep(300),
    % answered again after recovery
    ?assertEqual(ok, poll_options(EP, 80)).

%% Send an OPTIONS and look for a 200, retrying (recovery is asynchronous).
poll_options(_EP, 0) ->
    timeout;
poll_options(EP, N) ->
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    _ = gen_udp:send(Sock, {127, 0, 0, 1}, EP, options(Sock)),
    R =
        receive
            {udp, Sock, _, _, <<"SIP/2.0 200", _/binary>>} -> ok
        after 500 -> retry
        end,
    gen_udp:close(Sock),
    case R of
        ok -> ok;
        retry -> poll_options(EP, N - 1)
    end.

%% ---- helpers ----

setup() ->
    EP = pick(),
    ok = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>
    }),
    EP.

caller(EnginePort, Fun) ->
    Parent = self(),
    Pid = spawn_link(fun() ->
        {ok, Sock} = gen_udp:open(0, [
            binary, {active, true}, {ip, {127, 0, 0, 1}}
        ]),
        Parent ! {caller_ready, self()},
        Fun(Sock, EnginePort)
    end),
    receive
        {caller_ready, Pid} -> ok
    after 2000 -> ct:fail(caller_not_ready)
    end,
    Pid.

expect(Msg) ->
    receive
        Msg -> ok
    after 6000 -> ct:fail({expected, Msg})
    end.

pick() -> chappe_sip_test_port:pick().
ctc(P) -> <<"sip:x@127.0.0.1:", (integer_to_binary(P))/binary>>.
callid() ->
    <<"m7-", (binary:encode_hex(crypto:strong_rand_bytes(4)))/binary, "@ct">>.
branch() ->
    <<"z9hG4bK", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>.
sdp(Marker) ->
    <<"v=0\r\no=", Marker/binary,
        " 0 0 IN IP4 127.0.0.1\r\ns=-\r\n"
        "c=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio 40000 RTP/AVP 0\r\n"
        "a=sendrecv\r\n">>.
lport(Sock) ->
    {ok, P} = inet:port(Sock),
    P.
send(Sock, Dst, Bin) -> gen_udp:send(Sock, {127, 0, 0, 1}, Dst, Bin).

recv(Sock, Method) ->
    L = byte_size(Method),
    receive
        {udp, Sock, _, Src, <<M:L/binary, " ", _/binary>> = Bin} when
            M =:= Method
        ->
            {Bin, Src};
        {udp, Sock, _, _, _} ->
            recv(Sock, Method)
    after 6000 -> ct:fail({no_req, Method})
    end.

recv_status(Sock, Code) ->
    CB = integer_to_binary(Code),
    receive
        {udp, Sock, _, _, <<"SIP/2.0 ", C:3/binary, _/binary>> = Bin} ->
            case C of
                CB -> Bin;
                _ -> recv_status(Sock, Code)
            end
    after 6000 -> ct:fail({no_status, Code})
    end.

to_tag(Resp) ->
    {ok, M} = chappe_sip_msg:parse(Resp),
    chappe_sip_msg:to_tag(M).

invite(Sock, Call, FT) ->
    P = integer_to_binary(lport(Sock)),
    S = sdp(<<"caller">>),
    L = integer_to_binary(byte_size(S)),
    <<
        "INVITE sip:app@127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/UDP 127.0.0.1:",
        P/binary,
        ";rport;branch=",
        (branch())/binary,
        "\r\nMax-Forwards: 70\r\n"
        "From: Caller <sip:caller@127.0.0.1:",
        P/binary,
        ">;tag=",
        FT/binary,
        "\r\n"
        "To: <sip:app@127.0.0.1>\r\n"
        "Contact: <sip:caller@127.0.0.1:",
        P/binary,
        ">\r\n"
        "Call-ID: ",
        Call/binary,
        "\r\nCSeq: 1 INVITE\r\n"
        "Content-Type: application/sdp\r\n"
        "Content-Length: ",
        L/binary,
        "\r\n\r\n",
        S/binary
    >>.

ack(Sock, Call, FT, TT) ->
    P = integer_to_binary(lport(Sock)),
    <<
        "ACK sip:app@127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/UDP 127.0.0.1:",
        P/binary,
        ";branch=",
        (branch())/binary,
        "\r\nMax-Forwards: 70\r\n"
        "From: Caller <sip:caller@127.0.0.1:",
        P/binary,
        ">;tag=",
        FT/binary,
        "\r\n"
        "To: <sip:app@127.0.0.1>;tag=",
        TT/binary,
        "\r\n"
        "Call-ID: ",
        Call/binary,
        "\r\nCSeq: 1 ACK\r\nContent-Length: 0\r\n\r\n"
    >>.

options(Sock) ->
    P = integer_to_binary(lport(Sock)),
    <<
        "OPTIONS sip:app@127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/UDP 127.0.0.1:",
        P/binary,
        ";rport;branch=",
        (branch())/binary,
        "\r\nMax-Forwards: 70\r\n"
        "From: <sip:p@127.0.0.1:",
        P/binary,
        ">;tag=opt\r\n"
        "To: <sip:app@127.0.0.1>\r\n"
        "Call-ID: opt-",
        P/binary,
        "@ct\r\nCSeq: 1 OPTIONS\r\n"
        "Content-Length: 0\r\n\r\n"
    >>.

resp(ReqBin, Status, Reason, ToTag, ExtraHeaders, Body) ->
    {ok, Msg} = chappe_sip_msg:parse(ReqBin),
    Vias = chappe_sip_msg:get_all(<<"via">>, Msg),
    From = chappe_sip_msg:get(<<"from">>, Msg),
    To0 = chappe_sip_msg:get(<<"to">>, Msg),
    To =
        case chappe_sip_msg:to_tag(Msg) of
            undefined when Status > 100 ->
                <<To0/binary, ";tag=", ToTag/binary>>;
            _ ->
                To0
        end,
    Call = chappe_sip_msg:call_id(Msg),
    CSeq = chappe_sip_msg:get(<<"cseq">>, Msg),
    ViaLines = [[<<"Via: ">>, V, <<"\r\n">>] || V <- Vias],
    Extra = [[N, <<": ">>, Val, <<"\r\n">>] || {N, Val} <- ExtraHeaders],
    CL = integer_to_binary(byte_size(Body)),
    iolist_to_binary(
        [
            <<"SIP/2.0 ">>,
            integer_to_binary(Status),
            <<" ">>,
            Reason,
            <<"\r\n">>,
            ViaLines,
            <<"From: ">>,
            From,
            <<"\r\n">>,
            <<"To: ">>,
            To,
            <<"\r\n">>,
            <<"Call-ID: ">>,
            Call,
            <<"\r\n">>,
            <<"CSeq: ">>,
            CSeq,
            <<"\r\n">>,
            Extra,
            <<"Content-Length: ">>,
            CL,
            <<"\r\n\r\n">>,
            Body
        ]
    ).
