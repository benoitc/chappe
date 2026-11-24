%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The 8 kHz path, pinned to its bytes. A seeded run through the parts of
%% a tick (the jitter buffer, the sum, the N-1 encode with each
%% listener's gain carried from frame to frame, the room's PCM, a party's
%% PCM, the jitter of the reports) is hashed, and the hash is the one the
%% G.711 mixer gave before the 16 kHz room was added. A change that moves
%% one byte of what an 8 kHz room sends, or one jitter estimate, changes
%% the hash.
-module(chappe_mix_golden_tests).

-include_lib("eunit/include/eunit.hrl").

-export([run/0, digest/1]).

%% digest(run()), taken on the G.711-only mixer (the parent of this test)
-define(GOLDEN,
    <<"6310f464955ba51d5e8349d36d5f5803a47c4af8a294f69c0415486867ee463b">>
).

golden_test_() ->
    {timeout, 120, fun() ->
        chappe_mix_g711:init(),
        ?assertEqual(?GOLDEN, digest(run()))
    end}.

%% Deterministic: the keys of a map are encoded in sorted order, not in
%% the order of the atom table, which depends on what ran before.
digest(Term) ->
    string:lowercase(
        binary:encode_hex(
            crypto:hash(sha256, term_to_binary(Term, [deterministic]))
        )
    ).

run() ->
    rand:seed(exsss, {2026, 11, 24}),
    [
        {mix, [room(K) || K <- lists:seq(1, 12)]},
        {jbuf, [stream(K) || K <- lists:seq(1, 8)]},
        {party, [party() || _ <- lists:seq(1, 20)]},
        {jitter, [jitter(K) || K <- lists:seq(1, 4)]}
    ].

%% A room of 1 to 40 legs over 30 frames: mixed laws, muted legs, legs
%% with nothing to play, short frames, loud frames that clip, listeners
%% kept from hearing others. Each frame: every leg's payload, its gain,
%% and the room's PCM.
room(_K) ->
    N = rand:uniform(40),
    Legs = [{law(), rand:uniform(6) =:= 1} || _ <- lists:seq(1, N)],
    Loud = rand:uniform(3) =:= 1,
    {Out, _} = lists:mapfoldl(
        fun(_T, Gains) -> frame(Legs, Loud, Gains) end,
        [1.0 || _ <- Legs],
        lists:seq(1, 30)
    ),
    Out.

frame(Legs, Loud, Gains) ->
    Frames = [{Law, codes(Loud), Muted} || {Law, Muted} <- Legs],
    Sum = lists:foldl(
        fun
            ({Law, Codes, false}, Acc) when Codes =/= none ->
                chappe_mix_dsp:add(Acc, Law, Codes);
            (_, Acc) ->
                Acc
        end,
        chappe_mix_dsp:new(),
        Frames
    ),
    %% the same sum through add_level/3, as with talker events
    {Level, Energies} = lists:foldl(
        fun
            ({Law, Codes, false}, {Acc, Es}) when Codes =/= none ->
                {Acc1, E} = chappe_mix_dsp:add_level(Acc, Law, Codes),
                {Acc1, [E | Es]};
            (_, Acc) ->
                Acc
        end,
        {chappe_mix_dsp:new(), []},
        Frames
    ),
    Mixed = chappe_mix_dsp:mixed(Sum),
    Mixed = chappe_mix_dsp:mixed(Level),
    Indexed = lists:enumerate(Frames),
    {Payloads, Gains1} = lists:unzip([
        chappe_mix_dsp:encode(Mixed, Law, out(I, Indexed), G)
     || {{I, {Law, _, _}}, G} <- lists:zip(Indexed, Gains)
    ]),
    {{Payloads, Gains1, Energies, chappe_mix_dsp:pcm(Mixed)}, Gains1}.

%% What leg I does not hear: its own frame and, one time in four, the
%% next leg's too.
out(I, Indexed) ->
    Own = [{Law, C} || {J, {Law, C, false}} <- Indexed, J =:= I, C =/= none],
    Next = [
        {Law, C}
     || rand:uniform(4) =:= 1,
        {J, {Law, C, false}} <- Indexed,
        J =:= I + 1,
        C =/= none
    ],
    case Own ++ Next of
        [] -> none;
        [F] -> F;
        Fs -> Fs
    end.

law() -> lists:nth(rand:uniform(2), [ulaw, alaw]).

codes(Loud) ->
    case rand:uniform(6) of
        1 ->
            none;
        2 ->
            rand:bytes(lists:nth(rand:uniform(3), [40, 80, 120]));
        _ when Loud ->
            %% the loud end of both laws
            <<
                <<(lists:nth(rand:uniform(4), [16#00, 16#80, 16#2A, 16#AA]))>>
             || _ <- lists:seq(1, 160)
            >>;
        _ ->
            rand:bytes(160)
    end.

%% One stream through a jitter buffer: packets of 10 to 200 ms, lost,
%% reordered, late, a pause, an SSRC change, sequence and timestamp
%% wraps, a burst past the depth. Every pop and the stats at the end.
stream(K) ->
    J0 = chappe_mix_jbuf:new(
        2 + rand:uniform(4),
        lists:nth(rand:uniform(2), [16#FF, 16#D5]),
        K rem 2 =:= 0
    ),
    Seq0 = 16#FFFF - rand:uniform(40),
    Ts0 = 16#FFFFFFFF - rand:uniform(4000),
    {Pops, J, _} = lists:foldl(
        fun(Step, {Acc, J1, St}) ->
            {J2, St1} = step(Step, J1, St),
            {F, J3} = chappe_mix_jbuf:pop(J2),
            {[F | Acc], J3, St1}
        end,
        {[], J0, #{ssrc => 7, seq => Seq0, ts => Ts0, held => []}},
        lists:seq(1, 400)
    ),
    {lists:reverse(Pops), chappe_mix_jbuf:stats(J)}.

step(_Step, J, #{ssrc := Ssrc, seq := Seq, ts := Ts, held := Held} = St) ->
    Dur = lists:nth(rand:uniform(7), [80, 160, 160, 160, 240, 400, 1600]),
    Pkt = {Ssrc, Seq band 16#FFFF, Ts band 16#FFFFFFFF, rand:bytes(Dur)},
    Next = St#{seq := Seq + 1, ts := Ts + Dur},
    case rand:uniform(40) of
        1 ->
            %% lost
            {J, Next#{held := Held}};
        2 ->
            %% held back, sent after the next one
            {J, Next#{held := [Pkt | Held]}};
        3 ->
            %% a pause of a sender that suppresses silence
            {push([Pkt | Held], J), Next#{ts := Ts + Dur + 8000, held := []}};
        4 ->
            %% a new SSRC
            {push([Pkt | Held], J), Next#{ssrc := Ssrc + 1, held := []}};
        5 ->
            %% a burst: three packets at once
            P2 =
                {Ssrc, (Seq + 1) band 16#FFFF, (Ts + Dur) band 16#FFFFFFFF,
                    rand:bytes(Dur)},
            P3 =
                {Ssrc, (Seq + 2) band 16#FFFF, (Ts + 2 * Dur) band 16#FFFFFFFF,
                    rand:bytes(Dur)},
            {push([P3, P2, Pkt | Held], J), Next#{
                seq := Seq + 3, ts := Ts + 3 * Dur, held := []
            }};
        6 ->
            %% a packet from long ago: late
            Old =
                {Ssrc, (Seq - 50) band 16#FFFF,
                    (Ts - 50 * 160) band 16#FFFFFFFF, rand:bytes(160)},
            {push([Old, Pkt | Held], J), Next#{held := []}};
        7 ->
            %% a 20 ms packet placed by its sequence number alone
            {
                chappe_mix_jbuf:push(
                    Ssrc, Seq band 16#FFFF, rand:bytes(160), J
                ),
                Next#{ts := Ts + 160}
            };
        _ ->
            {push([Pkt | Held], J), Next#{held := []}}
    end.

%% Packets in the order given, oldest last.
push(Pkts, J) ->
    lists:foldl(
        fun({Ssrc, Seq, Ts, P}, Acc) ->
            chappe_mix_jbuf:push(Ssrc, Seq, Ts, P, Acc)
        end,
        J,
        lists:reverse(Pkts)
    ).

%% A party's tap: its frame as 16-bit little-endian PCM.
party() ->
    chappe_mix_g711:pcm(
        law(), rand:bytes(lists:nth(rand:uniform(3), [80, 160, 200]))
    ).

%% The interarrival jitter of a source (RFC 3550 A.8) as the receiver
%% report gives it, from packets with a seeded spread of arrival times.
jitter(K) ->
    T0 = 1000000000,
    Us = fun(N) -> erlang:convert_time_unit(N, microsecond, native) end,
    S0 = chappe_mix_session:new(16#1000 + K, T0),
    {S, _} = lists:foldl(
        fun(N, {Acc, Arr}) ->
            Arr1 = Arr + 20000 + rand:uniform(8000) - 4000,
            P = #{
                ssrc => 16#A0 + K,
                seq => N,
                ts => N * 160,
                csrcs => [],
                pt => 0,
                marker => false,
                payload => <<>>
            },
            {ok, Acc1, _} = chappe_mix_session:rtp_in(
                Acc, P, {{127, 0, 0, 1}, 9}, T0 + Us(Arr1)
            ),
            {Acc1, Arr1}
        end,
        {S0, 0},
        lists:seq(1, 200)
    ),
    {Pkt, _} = chappe_mix_session:report(
        S, <<"golden">>, fun(_) -> [] end, [], 5000000
    ),
    {ok, [#{type := rr, blocks := Blocks} | _]} = chappe_mix_rtcp:parse(Pkt),
    Blocks.
