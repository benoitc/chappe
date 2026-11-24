%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% A conference participant or watcher for the focus suites: a process
%% speaking raw SIP over UDP to the engine. It calls (INVITE with an audio
%% offer), subscribes, refreshes, holds, REFERs and hangs up, and answers
%% what it is sent: requests get 200 (an INVITE as set_answer/2 says),
%% each recorded once with its arrival time.
-module(chappe_sip_test_conf_ua).

-export([start/2, stop/1, uri/1, requests/1, set_answer/2]).
-export([
    invite/3,
    subscribe/4,
    refresh/3,
    bye/2,
    hold/2,
    refer/4,
    options/2
]).
-export([sdp/1]).

-define(CI, <<"application/conference-info+xml">>).

%% An audio offer or answer with the given direction, sending SSRC 1234.
sdp(Dir) ->
    <<
        "v=0\r\no=ua 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
        "t=0 0\r\nm=audio 40010 RTP/AVP 0\r\na=",
        Dir/binary,
        "\r\n"
        "a=ssrc:1234 cname:ua\r\n"
    >>.

start(Name, EP) ->
    Parent = self(),
    Pid = spawn(fun() ->
        {ok, Sock} = gen_udp:open(0, [
            binary, {active, true}, {ip, {127, 0, 0, 1}}
        ]),
        {ok, P} = inet:port(Sock),
        Parent ! {ua_ready, self()},
        loop(#{
            sock => Sock,
            ep => EP,
            name => Name,
            port => P,
            reqs => [],
            seen => #{},
            dialogs => #{},
            answer => {200, none, 0}
        })
    end),
    receive
        {ua_ready, Pid} -> Pid
    after 5000 -> error(ua_start)
    end.

stop(UA) ->
    UA ! stop,
    ok.

uri(UA) -> call(UA, uri).

%% Every request received, oldest first: [{Method, Msg, ArrivalMs}].
requests(UA) -> call(UA, requests).

%% How an INVITE sent to us is answered: {Status, Ring, Final} sends 180
%% after Ring ms (none: no 180) and Status after Final ms (200 with an
%% answer, else a failure).
set_answer(UA, How) -> call(UA, {set_answer, How}).

invite(UA, RUri, Hdrs) -> call(UA, {invite, RUri, Hdrs}).
subscribe(UA, Uri, Event, Hdrs) -> call(UA, {subscribe, Uri, Event, Hdrs}).
refresh(UA, Call, Expires) -> call(UA, {refresh, Call, Expires}).
bye(UA, Call) -> call(UA, {bye, Call}).
%% re-INVITE with the given direction (sendonly holds, sendrecv resumes)
hold(UA, {Call, Dir}) -> call(UA, {reinvite, Call, Dir}).
refer(UA, Call, Target, Hdrs) -> call(UA, {refer, Call, Target, Hdrs}).
options(UA, Uri) -> call(UA, {options, Uri}).

call(UA, Req) ->
    Ref = monitor(process, UA),
    UA ! {call, self(), Ref, Req},
    receive
        {Ref, Reply} ->
            demonitor(Ref, [flush]),
            Reply;
        {'DOWN', Ref, process, _, Why} ->
            error({ua_down, Why})
    after 20000 -> error({ua_timeout, Req})
    end.

%% ---- the process ----

loop(S) ->
    receive
        {call, From, Ref, Req} ->
            {Reply, S1} = handle(Req, S),
            From ! {Ref, Reply},
            loop(S1);
        {udp, _, _, Src, Bin} ->
            loop(incoming(Bin, Src, S));
        {final, Bin, Src} ->
            send_to(S, Src, Bin),
            loop(S);
        stop ->
            ok
    end.

handle(uri, S) ->
    {self_uri(S), S};
handle(requests, #{reqs := R} = S) ->
    {lists:reverse(R), S};
handle({set_answer, How}, S) ->
    {ok, S#{answer => How}};
handle({invite, RUri, Hdrs}, S) ->
    Call = <<"inv-", (hex(5))/binary, "@ct">>,
    FT = hex(4),
    Bin = request(<<"INVITE">>, RUri, S, #{
        call => Call,
        ft => FT,
        to => RUri,
        cseq => 1,
        hdrs => Hdrs,
        body => sdp(<<"sendrecv">>)
    }),
    {R, S1} = transact(Bin, Call, 1, S),
    case chappe_sip_msg:status(R) of
        200 ->
            TT = chappe_sip_msg:to_tag(R),
            Target = contact_uri(R),
            Ack = request(<<"ACK">>, Target, S1, #{
                call => Call, ft => FT, tt => TT, to => RUri, cseq => 1
            }),
            send(S1, Ack),
            D = #{ft => FT, tt => TT, to => RUri, target => Target, cseq => 1},
            {{ok, Call, R}, add_dialog(Call, D, S1)};
        St ->
            {{error, St, R}, S1}
    end;
handle({subscribe, Uri, Event, Hdrs}, S) ->
    Call = <<"sub-", (hex(5))/binary, "@ct">>,
    FT = hex(4),
    Defaults = [{<<"Expires">>, <<"600">>}, {<<"Accept">>, ?CI}],
    Names = [string:lowercase(N) || {N, _} <- Hdrs],
    All =
        [{<<"Event">>, Event}] ++ Hdrs ++
            [
                H
             || {N, _} = H <- Defaults,
                not lists:member(string:lowercase(N), Names)
            ],
    Bin = request(<<"SUBSCRIBE">>, Uri, S, #{
        call => Call, ft => FT, to => Uri, cseq => 1, hdrs => All
    }),
    {R, S1} = transact(Bin, Call, 1, S),
    case chappe_sip_msg:status(R) of
        St when St >= 200, St < 300 ->
            D = #{
                ft => FT,
                tt => chappe_sip_msg:to_tag(R),
                to => Uri,
                target => contact_uri(R),
                cseq => 1,
                event => Event
            },
            {{ok, Call, R}, add_dialog(Call, D, S1)};
        St ->
            {{error, St, R}, S1}
    end;
handle({refresh, Call, Expires}, S) ->
    in_dialog(
        <<"SUBSCRIBE">>,
        Call,
        [{<<"Expires">>, integer_to_binary(Expires)}],
        <<>>,
        S
    );
handle({bye, Call}, S) ->
    in_dialog(<<"BYE">>, Call, [], <<>>, S);
handle({reinvite, Call, Dir}, S) ->
    {{ok, St}, S1} = Reply = in_dialog(<<"INVITE">>, Call, [], sdp(Dir), S),
    case St of
        200 ->
            #{target := T, cseq := C} =
                D = maps:get(Call, maps:get(dialogs, S1)),
            send(S1, request(<<"ACK">>, T, S1, D#{call => Call, cseq => C})),
            Reply;
        _ ->
            Reply
    end;
handle({refer, Call, Target, Hdrs}, S) ->
    in_dialog(
        <<"REFER">>, Call, [{<<"Refer-To">>, Target} | Hdrs], <<>>, S
    );
handle({options, Uri}, S) ->
    Call = <<"opt-", (hex(5))/binary, "@ct">>,
    Bin = request(<<"OPTIONS">>, Uri, S, #{
        call => Call, ft => hex(4), to => Uri, cseq => 1
    }),
    transact(Bin, Call, 1, S).

in_dialog(Method, Call, Hdrs, Body, #{dialogs := Ds} = S) ->
    #{target := Target, cseq := C} = D = maps:get(Call, Ds),
    Ev =
        case {Method, D} of
            {<<"SUBSCRIBE">>, #{event := E}} -> [{<<"Event">>, E}];
            _ -> []
        end,
    N = C + 1,
    Bin = request(Method, Target, S, D#{
        call => Call, cseq => N, hdrs => Ev ++ Hdrs, body => Body
    }),
    {R, S1} = transact(Bin, Call, N, add_dialog(Call, D#{cseq => N}, S)),
    {{ok, chappe_sip_msg:status(R)}, S1}.

add_dialog(Call, D, #{dialogs := Ds} = S) ->
    S#{dialogs => maps:put(Call, D, Ds)}.

%% send a request and wait for its final response, answering whatever
%% arrives meanwhile
transact(Bin, Call, N, S) ->
    send(S, Bin),
    await_final(Call, N, S).

await_final(Call, N, #{sock := Sock} = S) ->
    receive
        {udp, Sock, _, _, <<"SIP/2.0 ", _/binary>> = Bin} ->
            {ok, M} = chappe_sip_msg:parse(Bin),
            {ok, #{seq := Seq}} = chappe_sip_msg:cseq(M),
            case {chappe_sip_msg:call_id(M), Seq, chappe_sip_msg:status(M)} of
                {Call, N, St} when St >= 200 -> {M, S};
                _ -> await_final(Call, N, S)
            end;
        {udp, Sock, _, Src, Bin} ->
            await_final(Call, N, incoming(Bin, Src, S))
    after 10000 -> exit({no_final, Call})
    end.

%% requests are answered and recorded once each (a retransmission is
%% answered again, not recorded again)
incoming(<<"SIP/2.0 ", _/binary>>, _Src, S) ->
    S;
incoming(Bin, Src, #{reqs := Reqs, seen := Seen} = S) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    Method = chappe_sip_msg:method(M),
    Key = {chappe_sip_msg:call_id(M), chappe_sip_msg:get(<<"cseq">>, M)},
    New = not maps:is_key(Key, Seen),
    case Method of
        <<"ACK">> -> ok;
        <<"INVITE">> when New -> answer_invite(M, Src, S);
        <<"INVITE">> -> ok;
        _ -> send_to(S, Src, resp(M, 200, <<>>, S))
    end,
    case New of
        false ->
            S;
        true ->
            Now = erlang:monotonic_time(millisecond),
            S#{reqs => [{Method, M, Now} | Reqs], seen => Seen#{Key => true}}
    end.

answer_invite(M, Src, #{answer := {Status, Ring, Final}} = S) ->
    case Ring of
        none ->
            ok;
        _ ->
            erlang:send_after(Ring, self(), {final, resp(M, 180, <<>>, S), Src})
    end,
    Body =
        case Status of
            200 -> sdp(<<"sendrecv">>);
            _ -> <<>>
        end,
    erlang:send_after(Final, self(), {final, resp(M, Status, Body, S), Src}).

self_uri(#{name := N, port := P}) ->
    <<"sip:", N/binary, "@127.0.0.1:", (integer_to_binary(P))/binary>>.

request(Method, RUri, S, #{call := Call, ft := FT, to := To, cseq := CSeq} = O) ->
    #{name := Name, port := P} = S,
    ToTag =
        case O of
            #{tt := TT} when is_binary(TT) -> <<";tag=", TT/binary>>;
            _ -> <<>>
        end,
    Display = <<(string:uppercase(Name))/binary, " Phone">>,
    Body = maps:get(body, O, <<>>),
    CT =
        case Body of
            <<>> -> [];
            _ -> <<"Content-Type: application/sdp\r\n">>
        end,
    iolist_to_binary([
        Method,
        <<" ">>,
        RUri,
        <<" SIP/2.0\r\n">>,
        <<"Via: SIP/2.0/UDP 127.0.0.1:">>,
        integer_to_binary(P),
        <<";rport;branch=z9hG4bK">>,
        hex(6),
        <<"\r\n">>,
        <<"Max-Forwards: 70\r\n">>,
        <<"From: \"">>,
        Display,
        <<"\" <">>,
        self_uri(S),
        <<">;tag=">>,
        FT,
        <<"\r\n">>,
        <<"To: <">>,
        To,
        <<">">>,
        ToTag,
        <<"\r\n">>,
        <<"Contact: <">>,
        self_uri(S),
        <<">\r\n">>,
        <<"Call-ID: ">>,
        Call,
        <<"\r\n">>,
        <<"CSeq: ">>,
        integer_to_binary(CSeq),
        <<" ">>,
        Method,
        <<"\r\n">>,
        [[K, <<": ">>, V, <<"\r\n">>] || {K, V} <- maps:get(hdrs, O, [])],
        CT,
        <<"Content-Length: ">>,
        integer_to_binary(byte_size(Body)),
        <<"\r\n\r\n">>,
        Body
    ]).

resp(M, Status, Body, S) ->
    To0 = chappe_sip_msg:get(<<"to">>, M),
    To =
        case chappe_sip_msg:to_tag(M) of
            undefined -> <<To0/binary, ";tag=ua">>;
            _ -> To0
        end,
    CT =
        case Body of
            <<>> -> [];
            _ -> <<"Content-Type: application/sdp\r\n">>
        end,
    iolist_to_binary([
        <<"SIP/2.0 ">>,
        integer_to_binary(Status),
        <<" ">>,
        reason(Status),
        <<"\r\n">>,
        [
            [<<"Via: ">>, V, <<"\r\n">>]
         || V <- chappe_sip_msg:get_all(<<"via">>, M)
        ],
        <<"From: ">>,
        chappe_sip_msg:get(<<"from">>, M),
        <<"\r\n">>,
        <<"To: ">>,
        To,
        <<"\r\n">>,
        <<"Call-ID: ">>,
        chappe_sip_msg:call_id(M),
        <<"\r\n">>,
        <<"CSeq: ">>,
        chappe_sip_msg:get(<<"cseq">>, M),
        <<"\r\n">>,
        <<"Contact: <">>,
        self_uri(S),
        <<">\r\n">>,
        CT,
        <<"Content-Length: ">>,
        integer_to_binary(byte_size(Body)),
        <<"\r\n\r\n">>,
        Body
    ]).

reason(180) -> <<"Ringing">>;
reason(200) -> <<"OK">>;
reason(486) -> <<"Busy Here">>;
reason(_) -> <<"Failed">>.

contact_uri(M) ->
    {ok, #{uri := U}} = chappe_sip_hdr:name_addr(
        chappe_sip_msg:get(<<"contact">>, M)
    ),
    U.

send(#{ep := EP} = S, Bin) ->
    send_to(S, EP, Bin).

send_to(#{sock := Sock}, Port, Bin) ->
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, Bin).

hex(N) -> binary:encode_hex(crypto:strong_rand_bytes(N), lowercase).
