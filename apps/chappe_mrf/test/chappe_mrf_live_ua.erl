%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% A softphone for chappe_mrf_live_SUITE: SIP over UDP plus a PCMU RTP
%% stream on a 20 ms clock. It sends a tone (or silence) all along, so
%% rtpengine learns where it is, sends RFC 2833 digits, and keeps what it
%% hears for a Goertzel detector: hears/3 says whether a frequency came
%% through. The tone detection is chappe_mix's test helper, copied (the
%% apps share no code).
%%
%% call/2 calls the engine; callee/1 takes one INVITE and answers it as its
%% answer option says: now (the default), {after_ms, Ms} (180, then 200),
%% ring (180, until a CANCEL) or {status, St}. The test gets {ua, Ua,
%% Event}: {final, Status}, invite, cancel, reinvite, bye.
%%
%% refer/4 and subscribe/3 are signalling only (no RTP): a REFER outside
%% any dialog, whose answer and NOTIFYs come as {ua, Ua, {refer, Status}}
%% and {ua, Ua, {notify, StatusLine, SubscriptionState}}, and a SUBSCRIBE
%% to the conference package, whose NOTIFY bodies come as {ua, Ua,
%% {conference, Body}}. Every NOTIFY is answered 200.
-module(chappe_mrf_live_ua).

-export([call/2, callee/1, port/1, stop/1, refer/4, subscribe/3]).
-export([tone/2, dtmf/2, bye/1, reinvite/1, clear/1, hears/3, silent/3, level/2]).
-export([write_wav/3, write_wav/4, write_wav/5, write_samples/3, wav_level/2]).

%% the RTP stream is PCMU, so 8 kHz; the wav helpers take other rates
-define(RATE, 8000).
-define(PRESENT_DB, -40.0).

%% ---- start ----

%% Opts: freq (what to send, default none: silence), ruri, headers (more
%% INVITE headers, such as Replaces).
call(EnginePort, Opts) ->
    start(#{mode => {call, EnginePort}, opts => Opts}).

%% A callee on a port of its own; port/1 tells which.
callee(Opts) ->
    start(#{mode => callee, opts => Opts}).

start(Args) ->
    Parent = self(),
    Pid = spawn(fun() -> init(Parent, Args) end),
    receive
        {Pid, ready} -> Pid
    after 5000 -> error(ua_start)
    end.

port(Ua) -> req(Ua, port).
stop(Ua) ->
    exit(Ua, kill),
    ok.
tone(Ua, Freq) ->
    Ua ! {tone, Freq},
    ok.
dtmf(Ua, Digits) ->
    Ua ! {dtmf, Digits},
    ok.
bye(Ua) ->
    Ua ! bye,
    ok.
reinvite(Ua) ->
    Ua ! reinvite,
    ok.
clear(Ua) ->
    Ua ! clear,
    ok.

%% Whether Freq comes through within Ms (a 200 ms window at -40 dBFS).
hears(Ua, Freq, Ms) ->
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    hears_until(Ua, Freq, Deadline).

hears_until(Ua, Freq, Deadline) ->
    case level(Ua, Freq) >= ?PRESENT_DB of
        true ->
            true;
        false ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    false;
                false ->
                    timer:sleep(200),
                    hears_until(Ua, Freq, Deadline)
            end
    end.

%% Whether Freq stays out for Ms (no 200 ms window reaches -40 dBFS).
silent(Ua, Freq, Ms) ->
    clear(Ua),
    timer:sleep(Ms),
    level(Ua, Freq) < ?PRESENT_DB.

%% The loudest 200 ms window of Freq heard since the last clear/1.
level(Ua, Freq) ->
    Samples = req(Ua, samples),
    lists:max([
        -200.0
        | [goertzel(W, Freq, ?RATE) || W <- windows(Samples, 1600)]
    ]).

req(Ua, What) ->
    Ua ! {What, self()},
    receive
        {Ua, What, V} -> V
    after 5000 -> error({ua, What})
    end.

%% ---- the process ----

init(Parent, #{mode := Mode, opts := Opts}) ->
    {ok, Sip} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    {ok, Rtp} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    S = #{
        parent => Parent,
        sip => Sip,
        rtp => Rtp,
        sip_port => element(2, inet:port(Sip)),
        rtp_port => element(2, inet:port(Rtp)),
        freq => maps:get(freq, Opts, none),
        answer => maps:get(answer, Opts, now),
        remote => undefined,
        seq => 1,
        ts => 0,
        n => 0,
        rx => [],
        dtmf => [],
        dialog => undefined,
        cseq => 1,
        headers => maps:get(headers, Opts, [])
    },
    Parent ! {self(), ready},
    self() ! tick,
    case Mode of
        {call, EP} ->
            invite(EP, maps:get(ruri, Opts, <<"sip:ivr@127.0.0.1">>), S);
        callee ->
            loop(S#{engine => undefined})
    end.

invite(EP, Ruri, #{sip := Sip, sip_port := P0, rtp_port := RP} = S) ->
    P = integer_to_binary(P0),
    CallId = <<"live-", (tag())/binary>>,
    Inv = build(
        <<"INVITE">>,
        Ruri,
        [
            {<<"Via">>,
                <<"SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=",
                    (branch())/binary>>},
            {<<"Max-Forwards">>, <<"70">>},
            {<<"From">>,
                <<"<sip:caller@127.0.0.1:", P/binary, ">;tag=",
                    (tag())/binary>>},
            {<<"To">>, <<"<", Ruri/binary, ">">>},
            {<<"Contact">>, <<"<sip:caller@127.0.0.1:", P/binary, ">">>},
            {<<"Call-ID">>, CallId},
            {<<"CSeq">>, <<"1 INVITE">>},
            {<<"Content-Type">>, <<"application/sdp">>}
        ] ++ maps:get(headers, S, []),
        sdp(RP)
    ),
    ok = gen_udp:send(Sip, {127, 0, 0, 1}, EP, Inv),
    loop(S#{engine => EP, invite => Inv}).

loop(#{sip := Sip, rtp := Rtp, parent := Parent} = S) ->
    receive
        tick ->
            erlang:send_after(20, self(), tick),
            loop(send_frame(S));
        {udp, Sip, _, Src, Bin} ->
            loop(sip(Bin, Src, S));
        {udp, Rtp, _, _, Pkt} ->
            loop(rtp_in(Pkt, S));
        {tone, F} ->
            loop(S#{freq := F});
        {dtmf, Digits} ->
            loop(S#{dtmf := maps:get(dtmf, S) ++ events(Digits)});
        clear ->
            loop(S#{rx := []});
        bye ->
            loop(send_bye(S));
        reinvite ->
            loop(send_reinvite(S));
        {answer, I, Src, Tag} ->
            loop(answer(I, Src, Tag, S));
        {port, From} ->
            From ! {self(), port, maps:get(sip_port, S)},
            loop(S);
        {samples, From} ->
            Samples = lists:append([
                decode(F)
             || F <- lists:reverse(maps:get(rx, S))
            ]),
            From ! {self(), samples, Samples},
            loop(S);
        _ ->
            _ = Parent,
            loop(S)
    end.

sip(<<"SIP/2.0 1", _/binary>>, _Src, S) ->
    S;
sip(
    <<"SIP/2.0 ", Code:3/binary, _/binary>> = R,
    _Src,
    #{dialog := undefined, invite := Inv} = S
) ->
    Status = binary_to_integer(Code),
    tell(S, {final, Status}),
    #{sip := Sip, engine := EP} = S,
    case Status of
        200 ->
            D = #{
                to => hdr(R, <<"to">>),
                from => hdr(Inv, <<"from">>),
                call_id => hdr(Inv, <<"call-id">>),
                target => contact_uri(R),
                dst => {{127, 0, 0, 1}, EP}
            },
            ok = gen_udp:send(Sip, {127, 0, 0, 1}, EP, req(<<"ACK">>, 1, S, D)),
            S#{dialog := D, remote := remote(body(R))};
        _ ->
            ok = gen_udp:send(Sip, {127, 0, 0, 1}, EP, ack_failure(Inv, R)),
            S
    end;
sip(
    <<"SIP/2.0 2", _/binary>> = R,
    _Src,
    #{reinviting := N, dialog := D, sip := Sip} = S
) ->
    %% the 2xx of our re-INVITE: its answer is where to send from now on
    #{dst := {Ip, Port}} = D,
    ok = gen_udp:send(Sip, Ip, Port, req(<<"ACK">>, N, S, D)),
    tell(S, reinvited),
    maps:remove(reinviting, S#{remote := remote(body(R))});
sip(<<"SIP/2.0 ", _/binary>>, _Src, S) ->
    S;
sip(
    <<"INVITE ", _/binary>> = I,
    Src,
    #{dialog := undefined, answer := Answer} = S
) ->
    %% the callee: answer the INVITE as the test asked
    tell(S, invite),
    tell(S, {invite_from, hdr(I, <<"from">>)}),
    Tag = tag(),
    #{sip := Sip} = S,
    case Answer of
        now ->
            answer(I, Src, Tag, S);
        {status, St} ->
            ok = gen_udp:send(
                Sip,
                {127, 0, 0, 1},
                Src,
                resp(I, St, <<"Refused">>, Tag, [], <<>>)
            ),
            S;
        ring ->
            ok = gen_udp:send(
                Sip,
                {127, 0, 0, 1},
                Src,
                resp(I, 180, <<"Ringing">>, Tag, [], <<>>)
            ),
            S#{ringing => {I, Src, Tag}};
        {after_ms, Ms} ->
            ok = gen_udp:send(
                Sip,
                {127, 0, 0, 1},
                Src,
                resp(I, 180, <<"Ringing">>, Tag, [], <<>>)
            ),
            erlang:send_after(Ms, self(), {answer, I, Src, Tag}),
            S
    end;
sip(
    <<"CANCEL ", _/binary>> = C,
    Src,
    #{sip := Sip, ringing := {I, ISrc, Tag}} = S
) ->
    ok = gen_udp:send(
        Sip, {127, 0, 0, 1}, Src, resp(C, 200, <<"OK">>, Tag, [], <<>>)
    ),
    ok = gen_udp:send(
        Sip,
        {127, 0, 0, 1},
        ISrc,
        resp(I, 487, <<"Request Terminated">>, Tag, [], <<>>)
    ),
    tell(S, cancel),
    S;
sip(
    <<"INVITE ", _/binary>> = I,
    Src,
    #{sip := Sip, sip_port := P, rtp_port := RP} = S
) ->
    tell(S, reinvite),
    C =
        {<<"Contact">>,
            <<"<sip:ua@127.0.0.1:", (integer_to_binary(P))/binary, ">">>},
    ok = gen_udp:send(
        Sip, {127, 0, 0, 1}, Src, resp(I, 200, <<"OK">>, <<>>, [C], sdp(RP))
    ),
    S#{remote := remote(body(I))};
sip(<<"BYE ", _/binary>> = B, Src, #{sip := Sip} = S) ->
    ok = gen_udp:send(
        Sip, {127, 0, 0, 1}, Src, resp(B, 200, <<"OK">>, <<>>, [], <<>>)
    ),
    tell(S, bye),
    S#{remote := undefined};
sip(<<"ACK ", _/binary>>, _Src, S) ->
    S;
sip(Req, Src, #{sip := Sip} = S) ->
    _ = gen_udp:send(
        Sip, {127, 0, 0, 1}, Src, resp(Req, 200, <<"OK">>, <<>>, [], <<>>)
    ),
    S.

answer(I, Src, Tag, #{sip := Sip, sip_port := P, rtp_port := RP} = S) ->
    C =
        {<<"Contact">>,
            <<"<sip:callee@127.0.0.1:", (integer_to_binary(P))/binary, ">">>},
    ok = gen_udp:send(
        Sip, {127, 0, 0, 1}, Src, resp(I, 200, <<"OK">>, Tag, [C], sdp(RP))
    ),
    D = #{
        to => hdr(I, <<"from">>),
        from => <<(hdr(I, <<"to">>))/binary, ";tag=", Tag/binary>>,
        call_id => hdr(I, <<"call-id">>),
        target => contact_uri(I),
        dst => {{127, 0, 0, 1}, Src}
    },
    S#{dialog := D, remote := remote(body(I))}.

%% a new offer, with a new o= version so it is not taken for a refresh
send_reinvite(
    #{
        dialog := #{dst := {Ip, Port}} = D,
        sip := Sip,
        cseq := Cseq,
        rtp_port := RP
    } = S
) ->
    N = Cseq + 1,
    Body = sdp(RP, N + 1),
    ok = gen_udp:send(Sip, Ip, Port, req(<<"INVITE">>, N, S, D, Body)),
    S#{cseq := N, reinviting => N}.

send_bye(#{dialog := undefined} = S) ->
    S;
send_bye(#{dialog := #{dst := {Ip, Port}} = D, sip := Sip, cseq := N} = S) ->
    ok = gen_udp:send(Sip, Ip, Port, req(<<"BYE">>, N + 1, S, D)),
    S#{cseq := N + 1, remote := undefined}.

tell(#{parent := P}, Event) ->
    P ! {ua, self(), Event},
    ok.

%% ---- REFER and SUBSCRIBE, signalling only ----

%% A REFER to Uri (the engine at EnginePort) outside any dialog, Refer-To
%% ReferTo, with Hdrs more headers.
refer(EnginePort, Uri, ReferTo, Hdrs) ->
    signal(EnginePort, <<"REFER">>, Uri, [{<<"Refer-To">>, ReferTo} | Hdrs]).

%% A SUBSCRIBE to the conference package of Uri.
subscribe(EnginePort, Uri, Hdrs) ->
    signal(
        EnginePort,
        <<"SUBSCRIBE">>,
        Uri,
        [
            {<<"Event">>, <<"conference">>},
            {<<"Accept">>, <<"application/conference-info+xml">>},
            {<<"Expires">>, <<"120">>}
            | Hdrs
        ]
    ).

signal(EP, Method, Uri, Hdrs) ->
    Parent = self(),
    Pid = spawn(fun() ->
        {ok, Sip} = gen_udp:open(0, [
            binary, {active, true}, {ip, {127, 0, 0, 1}}
        ]),
        P = integer_to_binary(element(2, inet:port(Sip))),
        Req = build(
            Method,
            Uri,
            [
                {<<"Via">>,
                    <<"SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=",
                        (branch())/binary>>},
                {<<"Max-Forwards">>, <<"70">>},
                {<<"From">>,
                    <<"<sip:boss@127.0.0.1:", P/binary, ">;tag=",
                        (tag())/binary>>},
                {<<"To">>, <<"<", Uri/binary, ">">>},
                {<<"Contact">>, <<"<sip:boss@127.0.0.1:", P/binary, ">">>},
                {<<"Call-ID">>, <<"sig-", (tag())/binary>>},
                {<<"CSeq">>, <<"1 ", Method/binary>>}
            ] ++ Hdrs,
            <<>>
        ),
        ok = gen_udp:send(Sip, {127, 0, 0, 1}, EP, Req),
        Parent ! {self(), ready},
        signal_loop(Sip, Parent, Method)
    end),
    receive
        {Pid, ready} -> Pid
    after 5000 -> error(ua_start)
    end.

signal_loop(Sip, Parent, Method) ->
    receive
        {udp, Sip, _, _, <<"SIP/2.0 1", _/binary>>} ->
            signal_loop(Sip, Parent, Method);
        {udp, Sip, _, _, <<"SIP/2.0 ", Code:3/binary, _/binary>>} ->
            Kind =
                case Method of
                    <<"REFER">> -> refer;
                    <<"SUBSCRIBE">> -> subscribe
                end,
            Parent ! {ua, self(), {Kind, binary_to_integer(Code)}},
            signal_loop(Sip, Parent, Method);
        {udp, Sip, _, Src, <<"NOTIFY ", _/binary>> = N} ->
            ok = gen_udp:send(
                Sip, {127, 0, 0, 1}, Src, resp(N, 200, <<"OK">>, <<>>, [], <<>>)
            ),
            Parent ! {ua, self(), notified(Method, N)},
            signal_loop(Sip, Parent, Method);
        {udp, Sip, _, _, _} ->
            signal_loop(Sip, Parent, Method)
    end.

notified(<<"REFER">>, N) ->
    [Line | _] = binary:split(body(N), <<"\r\n">>),
    {notify, Line, hdr(N, <<"subscription-state">>)};
notified(<<"SUBSCRIBE">>, N) ->
    {conference, body(N)}.

%% ---- RTP ----

send_frame(#{remote := undefined} = S) ->
    S;
send_frame(#{dtmf := [{Digit, Dur, End} | Rest]} = S) ->
    %% RFC 4733: one event packet per 20 ms, the last three with E set
    #{rtp := Rtp, remote := To, seq := Seq, ts := Ts} = S,
    E =
        case End of
            true -> 1;
            false -> 0
        end,
    Payload = <<Digit:8, E:1, 0:1, 10:6, Dur:16>>,
    Pkt =
        <<2:2, 0:1, 0:1, 0:4, 0:1, 101:7, Seq:16, Ts:32, 4242:32,
            Payload/binary>>,
    _ = gen_udp:send(Rtp, To, Pkt),
    Next =
        case {End, Rest} of
            {true, [{_, _, true} | _]} -> Ts;
            {true, _} -> Ts + 1000;
            _ -> Ts
        end,
    S#{dtmf := Rest, seq := (Seq + 1) band 16#FFFF, ts := Next};
send_frame(
    #{rtp := Rtp, remote := To, seq := Seq, ts := Ts, n := N, freq := F} = S
) ->
    Samples =
        case F of
            none ->
                lists:duplicate(160, 0);
            _ ->
                [
                    round(6000 * math:sin(2 * math:pi() * F * I / ?RATE))
                 || I <- lists:seq(N * 160, N * 160 + 159)
                ]
        end,
    Payload = list_to_binary([encode(X) || X <- Samples]),
    Pkt =
        <<2:2, 0:1, 0:1, 0:4, 0:1, 0:7, Seq:16, Ts:32, 4242:32,
            Payload/binary>>,
    _ = gen_udp:send(Rtp, To, Pkt),
    S#{
        seq := (Seq + 1) band 16#FFFF,
        ts := (Ts + 160) band 16#FFFFFFFF,
        n := N + 1
    }.

%% each digit: 5 packets of 20 ms, then 3 end packets
events(Digits) ->
    lists:append([
        [{code(D), 160 * K, false} || K <- lists:seq(1, 5)] ++
            [{code(D), 800, true} || _ <- [1, 2, 3]]
     || <<D>> <= Digits
    ]).

code($*) -> 10;
code($#) -> 11;
code(D) -> D - $0.

rtp_in(
    <<2:2, _:1, X:1, CC:4, _:1, 0:7, _:16, _:32, _:32, Rest/binary>>,
    #{rx := Rx} = S
) ->
    Skip = CC * 4,
    <<_:Skip/binary, P0/binary>> = Rest,
    P =
        case X of
            1 ->
                <<_:16, L:16, Ext/binary>> = P0,
                Len = L * 4,
                <<_:Len/binary, P1/binary>> = Ext,
                P1;
            0 ->
                P0
        end,
    %% keep the last 10 s
    S#{rx := lists:sublist([P | Rx], 500)};
rtp_in(_Pkt, S) ->
    S.

%% ---- G.711 mu-law ----

encode(Sample) ->
    Sign =
        case Sample < 0 of
            true -> 16#80;
            false -> 0
        end,
    M = min(abs(Sample), 32635) + 132,
    Exp = exponent(M bsr 7, 7),
    Mant = (M bsr (Exp + 3)) band 16#0F,
    bnot (Sign bor (Exp bsl 4) bor Mant) band 16#FF.

exponent(_V, 0) -> 0;
exponent(V, E) when V band (1 bsl E) =/= 0 -> E;
exponent(V, E) -> exponent(V, E - 1).

decode(Payload) ->
    [decode_byte(B) || <<B>> <= Payload].

decode_byte(U0) ->
    U = bnot U0 band 16#FF,
    Sign = U band 16#80,
    Exp = (U bsr 4) band 7,
    Mant = U band 16#0F,
    Mag = (((Mant bsl 3) + 132) bsl Exp) - 132,
    case Sign of
        0 -> Mag;
        _ -> -Mag
    end.

%% ---- Goertzel (from chappe_mix_test_tone) ----

windows(Samples, N) when length(Samples) >= N ->
    {W, Rest} = lists:split(N, Samples),
    [W | windows(Rest, N)];
windows(_, _) ->
    [].

goertzel(Samples, F, Rate) ->
    N = length(Samples),
    W = 2 * math:pi() * F / Rate,
    Coeff = 2 * math:cos(W),
    {S1, S2} = lists:foldl(
        fun(X, {P1, P2}) -> {X + Coeff * P1 - P2, P1} end, {0.0, 0.0}, Samples
    ),
    Power = S1 * S1 + S2 * S2 - Coeff * S1 * S2,
    Amp = 2 * math:sqrt(max(Power, 0.0)) / N,
    20 * math:log10(max(Amp, 1.0e-9) / 32768).

%% The loudest 200 ms window of Freq in a 16-bit mono wav, at the sample
%% rate its fmt chunk names (8 or 16 kHz, ...).
wav_level(Path, Freq) ->
    {ok, Bin} = file:read_file(Path),
    Rate = wav_rate(Bin),
    {_, Data} = split_data(Bin),
    Samples = [X || <<X:16/little-signed>> <= Data],
    lists:max([
        -200.0
        | [goertzel(W, Freq, Rate) || W <- windows(Samples, Rate div 5)]
    ]).

wav_rate(<<"fmt ", _:32, _:16, _:16, Rate:32/little, _/binary>>) -> Rate;
wav_rate(<<_, Rest/binary>>) -> wav_rate(Rest).

split_data(<<"data", _Size:32/little, Data/binary>>) -> {ok, Data};
split_data(<<_, Rest/binary>>) -> split_data(Rest).

%% ---- prompts ----

%% A 16-bit 8 kHz mono wav of Freq for Ms.
write_wav(Path, Freq, Ms) ->
    write_wav(Path, Freq, Ms, 8000).

write_wav(Path, Freq, Ms, Amp) ->
    write_wav(Path, Freq, Ms, Amp, ?RATE).

%% The same at Rate samples per second (16000 for a wideband prompt).
write_wav(Path, Freq, Ms, Amp, Rate) ->
    write_samples(
        Path,
        [
            round(Amp * math:sin(2 * math:pi() * Freq * I / Rate))
         || I <- lists:seq(0, Ms * Rate div 1000 - 1)
        ],
        Rate
    ).

%% A 16-bit mono wav of Samples at Rate, which the lab's containers can
%% read.
write_samples(Path, Samples, Rate) ->
    Data = <<<<S:16/little-signed>> || S <- Samples>>,
    Size = byte_size(Data),
    Wav =
        <<"RIFF", (36 + Size):32/little, "WAVE", "fmt ", 16:32/little,
            1:16/little, 1:16/little, Rate:32/little, (Rate * 2):32/little,
            2:16/little, 16:16/little, "data", Size:32/little, Data/binary>>,
    ok = file:write_file(Path, Wav),
    ok = file:change_mode(Path, 8#644).

%% ---- SIP text ----

sdp(Port) ->
    sdp(Port, 1).

sdp(Port, Version) ->
    P = integer_to_binary(Port),
    V = integer_to_binary(Version),
    <<"v=0\r\no=live 1 ", V/binary,
        " IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n"
        "m=audio ", P/binary,
        " RTP/AVP 0 101\r\na=rtpmap:0 PCMU/8000\r\n"
        "a=rtpmap:101 telephone-event/8000\r\na=fmtp:101 0-16\r\na=ptime:20\r\na=sendrecv\r\n">>.

remote(Sdp) ->
    case
        {
            re:run(Sdp, <<"c=IN IP4 ([0-9.]+)">>, [
                {capture, all_but_first, list}
            ]),
            re:run(Sdp, <<"m=audio ([0-9]+)">>, [
                {capture, all_but_first, binary}
            ])
        }
    of
        {{match, [Ip]}, {match, [Port]}} ->
            {ok, A} = inet:parse_address(Ip),
            {A, binary_to_integer(Port)};
        _ ->
            undefined
    end.

req(Method, N, S, D) ->
    req(Method, N, S, D, <<>>).

req(
    Method,
    N,
    #{sip_port := P0},
    #{to := To, from := From, call_id := CallId, target := T},
    Body
) ->
    P = integer_to_binary(P0),
    Offer =
        case Body of
            <<>> ->
                [];
            _ ->
                [
                    {<<"Contact">>, <<"<sip:ua@127.0.0.1:", P/binary, ">">>},
                    {<<"Content-Type">>, <<"application/sdp">>}
                ]
        end,
    build(
        Method,
        T,
        [
            {<<"Via">>,
                <<"SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=",
                    (branch())/binary>>},
            {<<"Max-Forwards">>, <<"70">>},
            {<<"From">>, From},
            {<<"To">>, To},
            {<<"Call-ID">>, CallId},
            {<<"CSeq">>, <<(integer_to_binary(N))/binary, " ", Method/binary>>}
        ] ++ Offer,
        Body
    ).

ack_failure(Inv, R) ->
    [_, Ruri | _] = binary:split(Inv, <<" ">>, [global]),
    build(
        <<"ACK">>,
        Ruri,
        [
            {<<"Via">>, hdr(Inv, <<"via">>)},
            {<<"Max-Forwards">>, <<"70">>},
            {<<"From">>, hdr(Inv, <<"from">>)},
            {<<"To">>, hdr(R, <<"to">>)},
            {<<"Call-ID">>, hdr(Inv, <<"call-id">>)},
            {<<"CSeq">>, <<"1 ACK">>}
        ],
        <<>>
    ).

build(Method, RUri, Headers, Body) ->
    iolist_to_binary([
        Method,
        <<" ">>,
        RUri,
        <<" SIP/2.0\r\n">>,
        [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Headers],
        <<"Content-Length: ">>,
        integer_to_binary(byte_size(Body)),
        <<"\r\n\r\n">>,
        Body
    ]).

resp(ReqBin, Status, Reason, ToTag, Extra, Body) ->
    {ok, Msg} = chappe_sip_msg:parse(ReqBin),
    To0 = chappe_sip_msg:get(<<"to">>, Msg),
    To =
        case chappe_sip_msg:to_tag(Msg) of
            undefined when ToTag =/= <<>> ->
                <<To0/binary, ";tag=", ToTag/binary>>;
            _ ->
                To0
        end,
    CT =
        case Body of
            <<>> -> [];
            _ -> [<<"Content-Type: application/sdp\r\n">>]
        end,
    iolist_to_binary([
        <<"SIP/2.0 ">>,
        integer_to_binary(Status),
        <<" ">>,
        Reason,
        <<"\r\n">>,
        [
            [<<"Via: ">>, V, <<"\r\n">>]
         || V <- chappe_sip_msg:get_all(<<"via">>, Msg)
        ],
        <<"From: ">>,
        chappe_sip_msg:get(<<"from">>, Msg),
        <<"\r\n">>,
        <<"To: ">>,
        To,
        <<"\r\n">>,
        <<"Call-ID: ">>,
        chappe_sip_msg:call_id(Msg),
        <<"\r\n">>,
        <<"CSeq: ">>,
        chappe_sip_msg:get(<<"cseq">>, Msg),
        <<"\r\n">>,
        [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Extra],
        CT,
        <<"Content-Length: ">>,
        integer_to_binary(byte_size(Body)),
        <<"\r\n\r\n">>,
        Body
    ]).

hdr(Bin, Name) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    chappe_sip_msg:get(Name, M).

body(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    chappe_sip_msg:body(M).

contact_uri(Msg) ->
    {ok, #{uri := U}} = chappe_sip_hdr:name_addr(hdr(Msg, <<"contact">>)),
    U.

tag() -> binary:encode_hex(crypto:strong_rand_bytes(5), lowercase).

branch() -> <<"z9hG4bK", (tag())/binary>>.
