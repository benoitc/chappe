%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% One conference: the process that owns every leg's socket and runs the
%% mix clock.
%%
%% The clock is absolute. Tick k fires at T0 + 20k ms on the monotonic
%% clock, through erlang:start_timer/4 with {abs, true}, so a late tick
%% does not push the next one back and the output keeps its rate over a
%% long call. How late each tick fired is kept in a histogram; a tick more
%% than a period late skips the frames it missed (an overrun) rather than
%% bursting them out. The RTP timestamp still advances by the frames
%% skipped, so it stays the sampling clock (RFC 3550 5.1).
%%
%% Each tick pops one frame per leg (chappe_mix_jbuf), decodes it, sums
%% the unmuted frames once, and sends every leg with a known far end the
%% sum minus its own frame. A leg with nothing to hear gets silence, so
%% the media path towards rtpengine never goes quiet. Sockets run in
%% {active, N} mode; nothing a peer sends becomes an atom.
%%
%% Each leg (chappe_mix_leg) is its own RTP session towards its far end
%% (chappe_mix_session), and the mixer follows RFC 3550 7.3 on it: its
%% packets carry the SSRCs mixed into them as CSRCs, it sends its own SR
%% and SDES CNAME per leg, and the RTCP a leg receives is consumed there.
%% Only CNAME and NAME items and BYEs cross to other legs, as that section
%% requires; this module does the crossing. All legs share one SSRC
%% space (7.1, 8.2).
-module(chappe_mix_conf).
-behaviour(gen_server).

-include("chappe_mix_leg.hrl").

-export([start_link/1, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(PTIME, 20).
-define(FRAME, 160).
-define(ACTIVE, 64).
%% tick lateness histogram bounds, microseconds
-define(BUCKETS, [500, 1000, 2000, 5000, 10000, 20000]).
%% at most this many CSRCs fit in the RTP header
-define(MAX_CSRC, 15).
%% the counters stats/1 totals over legs
-define(TOTALS, [
    filtered, collisions, loops, rtcp_sent, rtcp_received, rtcp_invalid
]).

-record(state, {
    owner :: pid(),
    %% receives one message per tick when set (see chappe_mix:conf_opts())
    trace :: pid() | undefined,
    ip :: inet:ip_address(),
    law :: chappe_mix_g711:law(),
    depth :: pos_integer(),
    cname :: binary(),
    %% draws a candidate SSRC (see chappe_mix:conf_opts())
    draw :: fun(() -> 0..16#FFFFFFFF),
    legs = #{} :: #{pos_integer() => #leg{}},
    socks = #{} :: #{gen_udp:socket() => pos_integer()},
    next_id = 1 :: pos_integer(),
    %% scheduled time of the next tick, native monotonic units
    next_tick :: integer(),
    period :: pos_integer(),
    ticks = 0 :: non_neg_integer(),
    overruns = 0 :: non_neg_integer(),
    late = #{} :: #{pos_integer() | infinity => non_neg_integer()},
    late_max = 0 :: non_neg_integer(),
    %% counters of legs that were removed
    retired = #{} :: #{atom() => non_neg_integer()}
}).

-type state() :: #state{}.

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-spec stop(pid()) -> ok.
stop(Conf) ->
    gen_server:stop(Conf).

%% ---- gen_server ----

-spec init(map()) -> {ok, state()}.
init(#{owner := Owner} = Opts) ->
    monitor(process, Owner),
    Period = erlang:convert_time_unit(?PTIME, millisecond, native),
    Next = erlang:monotonic_time() + Period,
    arm(Next),
    {ok, #state{
        owner = Owner,
        trace = maps:get(trace, Opts, undefined),
        ip = maps:get(ip, Opts, {127, 0, 0, 1}),
        law = maps:get(law, Opts, ulaw),
        depth = maps:get(depth, Opts, 3),
        cname = maps:get(cname, Opts, chappe_mix_rtcp:cname()),
        draw = maps:get(ssrc_draw, Opts, fun random32/0),
        next_tick = Next,
        period = Period
    }}.

handle_call({add_leg, Opts}, _From, #state{next_id = Id} = S) ->
    Defaults = #{
        ip => S#state.ip,
        law => S#state.law,
        depth => S#state.depth,
        ssrc => new_ssrc(S)
    },
    case chappe_mix_leg:open(Id, Opts, Defaults) of
        {ok, #leg{port = Port, rtcp_port = RPort} = Leg} ->
            Reply = #{ip => S#state.ip, port => Port, rtcp_port => RPort},
            {reply, {ok, Id, Reply}, insert(Leg, S)};
        {error, _} = Err ->
            {reply, Err, S}
    end;
handle_call({remove_leg, Id}, _From, S) ->
    case maps:take(Id, S#state.legs) of
        {Leg, Legs} -> {reply, ok, remove(bye(Leg, S), Legs, S)};
        error -> {reply, {error, not_found}, S}
    end;
handle_call({move_leg, Id, To}, _From, S) ->
    case maps:take(Id, S#state.legs) of
        {Leg, Legs} -> move(Leg, Legs, To, S);
        error -> {reply, {error, not_found}, S}
    end;
handle_call({adopt_leg, Leg}, _From, #state{next_id = Id} = S) ->
    {reply, {ok, Id}, insert(Leg#leg{id = Id}, S)};
handle_call({set_remote, Id, #{remote := _} = Opts}, _From, S) ->
    %% a new far end: unlatch, so its first packet is taken
    update_leg(Id, fun(L) -> chappe_mix_leg:set_remote(Opts, L) end, S);
handle_call({set_remote, Id, Remote}, From, S) ->
    handle_call({set_remote, Id, #{remote => Remote}}, From, S);
handle_call({mute, Id, Mute}, _From, S) ->
    update_leg(Id, fun(L) -> L#leg{mute = Mute} end, S);
handle_call(legs, _From, S) ->
    {reply, [chappe_mix_leg:info(L) || L <- maps:values(S#state.legs)], S};
handle_call(stats, _From, S) ->
    {reply, stats(S), S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({timeout, _Ref, tick}, S) ->
    {noreply, tick(S)};
handle_info({udp, Sock, Ip, Port, Pkt}, S) ->
    {noreply, receive_packet(Sock, {Ip, Port}, Pkt, S)};
handle_info({udp_passive, Sock}, S) ->
    _ = inet:setopts(Sock, [{active, ?ACTIVE}]),
    {noreply, S};
handle_info({'DOWN', _Ref, process, Owner, _}, #state{owner = Owner} = S) ->
    {stop, normal, S};
handle_info(_Info, S) ->
    {noreply, S}.

%% Every leg hears the mixer leave (7.3).
terminate(_Reason, S) ->
    [chappe_mix_leg:close(bye(L, S)) || L <- maps:values(S#state.legs)],
    ok.

%% ---- legs ----

insert(#leg{id = Id} = L, S) ->
    Socks = lists:foldl(
        fun(Sock, M) -> maps:put(Sock, Id, M) end,
        S#state.socks,
        chappe_mix_leg:socks(L)
    ),
    put_leg(L, S#state{socks = Socks, next_id = Id + 1}).

remove(Leg, Legs, S) ->
    chappe_mix_leg:close(Leg),
    left(Leg, S#state{
        legs = Legs,
        socks = maps:without(chappe_mix_leg:socks(Leg), S#state.socks),
        retired = add_totals(chappe_mix_leg:info(Leg), S#state.retired)
    }).

move(Leg, Legs, To, S) ->
    Socks = chappe_mix_leg:socks(Leg),
    [ok = gen_udp:controlling_process(Sock, To) || Sock <- Socks],
    [forward_pending(Sock, To) || Sock <- Socks],
    S1 = S#state{legs = Legs, socks = maps:without(Socks, S#state.socks)},
    {reply, gen_server:call(To, {adopt_leg, Leg}), left(Leg, S1)}.

put_leg(#leg{id = Id} = L, S) ->
    S#state{legs = maps:put(Id, L, S#state.legs)}.

%% Packets that reached our mailbox before the socket changed hands belong
%% to the new owner too.
forward_pending(Sock, To) ->
    receive
        {udp, Sock, _, _, _} = Msg ->
            To ! Msg,
            forward_pending(Sock, To);
        {udp_passive, Sock} = Msg ->
            To ! Msg,
            forward_pending(Sock, To)
    after 0 -> ok
    end.

update_leg(Id, Fun, S) ->
    case maps:find(Id, S#state.legs) of
        {ok, L} ->
            {reply, ok, S#state{legs = maps:put(Id, Fun(L), S#state.legs)}};
        error ->
            {reply, {error, not_found}, S}
    end.

stats(S) ->
    Totals = maps:fold(
        fun(_, L, Acc) -> add_totals(chappe_mix_leg:info(L), Acc) end,
        S#state.retired,
        S#state.legs
    ),
    maps:merge(maps:from_list([{K, 0} || K <- ?TOTALS]), Totals#{
        legs => map_size(S#state.legs),
        ticks => S#state.ticks,
        overruns => S#state.overruns,
        late_max_us => S#state.late_max,
        late_histogram_us => S#state.late
    }).

add_totals(Info, Acc) ->
    lists:foldl(
        fun(K, A) ->
            V = maps:get(K, Info),
            maps:update_with(K, fun(N) -> N + V end, V, A)
        end,
        Acc,
        ?TOTALS
    ).

src_ssrc(#leg{sess = Sess}) -> chappe_mix_session:src_ssrc(Sess).

%% A random SSRC not already seen in the conference, ours or theirs
%% (8.2: a candidate already known is drawn again).
new_ssrc(S) ->
    Taken = maps:fold(
        fun(_, #leg{sess = Sess}, Acc) ->
            [
                chappe_mix_session:ssrc(Sess),
                chappe_mix_session:src_ssrc(Sess)
                | chappe_mix_session:csrcs(Sess)
            ] ++ Acc
        end,
        [],
        S#state.legs
    ),
    new_ssrc(S#state.draw, Taken).

new_ssrc(Draw, Taken) ->
    Cand = Draw(),
    case lists:member(Cand, Taken) of
        true -> new_ssrc(Draw, Taken);
        false -> Cand
    end.

random32() ->
    <<N:32>> = crypto:strong_rand_bytes(4),
    N.

%% ---- receiving ----

receive_packet(Sock, From, Pkt, S) ->
    case maps:find(Sock, S#state.socks) of
        {ok, Id} ->
            L = maps:get(Id, S#state.legs),
            case L#leg.rtcp_sock of
                Sock ->
                    rtcp_in(From, Pkt, L, S);
                _ ->
                    case chappe_mix_rtp:parse(Pkt) of
                        {error, rtcp} ->
                            rtcp_in(From, Pkt, L, S);
                        {error, malformed} ->
                            put_leg(L#leg{bad = L#leg.bad + 1}, S);
                        {ok, P} ->
                            rtp_in(P, From, L, S)
                    end
            end;
        error ->
            S
    end.

rtp_in(P, From, L0, S) ->
    case chappe_mix_leg:accepts_rtp(From, L0) of
        {false, L} ->
            put_leg(L, S);
        {true, L} ->
            Now = erlang:monotonic_time(),
            case chappe_mix_session:rtp_in(L#leg.sess, P, From, Now) of
                {loop, Sess} ->
                    put_leg(L#leg{sess = Sess}, S);
                {collision, Sess} ->
                    %% 8.2: BYE for the old SSRC, a new one, then the packet
                    L1 = renew(L#leg{sess = Sess}, S),
                    rtp_in(P, From, L1, put_leg(L1, S));
                {ok, Sess, New} ->
                    L1 = chappe_mix_leg:take(P, From, L#leg{sess = Sess}),
                    S1 = reclaim(
                        New, maps:get(ssrc, P), L1#leg.id, put_leg(L1, S)
                    ),
                    case chappe_mix_leg:is_event(P, L1) of
                        true -> forward_event(P, L1#leg.id, S1);
                        false -> S1
                    end
            end
    end.

%% All legs share one SSRC space through the mixer (7.1): a source new on
%% one leg that uses the mixer's SSRC on another would show up there as a
%% CSRC equal to the stream's own SSRC. That other leg moves.
reclaim(false, _Ssrc, _FromId, S) ->
    S;
reclaim(true, Ssrc, FromId, S) ->
    maps:fold(
        fun(Id, #leg{sess = Sess} = L, Acc) ->
            case chappe_mix_session:ssrc(Sess) =:= Ssrc andalso Id =/= FromId of
                true -> put_leg(renew(L, Acc), Acc);
                false -> Acc
            end
        end,
        S,
        S#state.legs
    ).

%% BYE for the leg's SSRC, then a new one nobody in the conference uses.
renew(#leg{sess = Sess} = L, S) ->
    Old = chappe_mix_session:ssrc(Sess),
    Bye = #{type => bye, ssrcs => [Old], reason => <<"SSRC collision">>},
    L1 = rtcp_send(L, S, [Bye]),
    L1#leg{sess = chappe_mix_session:renew(L1#leg.sess, new_ssrc(S))}.

%% RTCP from the far end is consumed on this leg; a BYE for its source
%% goes on to the others.
rtcp_in(From, Pkt, L0, S) ->
    case chappe_mix_leg:accepts_rtcp(From, L0) of
        {false, L} ->
            put_leg(L, S);
        {true, L} ->
            case chappe_mix_rtcp:parse(Pkt) of
                {ok, Parts} ->
                    NowUs = erlang:monotonic_time(microsecond),
                    {Sess, Collided, Gone} = chappe_mix_session:rtcp_in(
                        L#leg.sess, Parts, byte_size(Pkt), From, NowUs
                    ),
                    L1 =
                        case Collided of
                            true -> renew(L#leg{sess = Sess}, S);
                            false -> L#leg{sess = Sess}
                        end,
                    forward_byes(Gone, L1#leg.id, put_leg(L1, S));
                {error, invalid} ->
                    Sess = chappe_mix_session:rtcp_invalid(L#leg.sess),
                    put_leg(L#leg{sess = Sess}, S)
            end
    end.

%% A leg leaving the mix: the others hear BYE for its source (7.3).
left(L, S) ->
    case src_ssrc(L) of
        undefined -> S;
        Ssrc -> forward_byes([Ssrc], L#leg.id, S)
    end.

%% A BYE from a source goes to every other leg, the SSRC unchanged (7.3).
forward_byes([], _From, S) ->
    S;
forward_byes(Gone, FromId, S) ->
    maps:fold(
        fun
            (Id, _L, Acc) when Id =:= FromId ->
                Acc;
            (_Id, L, Acc) ->
                put_leg(rtcp_send(L, Acc, [#{type => bye, ssrcs => Gone}]), Acc)
        end,
        S,
        S#state.legs
    ).

%% An RFC 4733 event from one leg goes to every other leg that
%% negotiated telephone-event and lists its codes, never into the mix. On
%% each, it keeps one timestamp for the whole event: the event start is
%% mapped onto that leg's output clock when it comes (M set, or the first
%% packet seen), and every later packet of the event, segments and end
%% retransmissions included, keeps that offset. A muted leg's events are
%% not heard either.
forward_event(_P, FromId, S) when not is_map_key(FromId, S#state.legs) ->
    S;
forward_event(P, FromId, S) ->
    case maps:get(FromId, S#state.legs) of
        #leg{mute = true} ->
            S;
        From ->
            #{ts := Ts, marker := M, payload := Payload, ssrc := Src} = P,
            Codes = chappe_mix_leg:event_codes(Payload),
            Offs0 =
                case M of
                    true -> #{};
                    false -> From#leg.dtmf_off
                end,
            {Offs, S1} = maps:fold(
                fun(Id, T, {OAcc, SAcc} = Acc) ->
                    case
                        Id =/= FromId andalso
                            chappe_mix_leg:takes_events(Codes, T)
                    of
                        true ->
                            Off = event_offset(Id, Ts, T, OAcc),
                            T1 = chappe_mix_leg:send_event(
                                T, (Ts + Off) band 16#FFFFFFFF, M, Payload, [
                                    Src
                                ]
                            ),
                            {OAcc#{Id => Off}, put_leg(T1, SAcc)};
                        false ->
                            Acc
                    end
                end,
                {Offs0, S},
                S#state.legs
            ),
            put_leg(From#leg{dtmf_off = Offs}, S1)
    end.

%% The offset from the event's timestamps to leg Id's clock: kept from
%% the event start, or taken now (the timestamp of its next packet).
event_offset(Id, Ts, #leg{sess = Sess}, Offs) ->
    case maps:find(Id, Offs) of
        {ok, Off} ->
            Off;
        error ->
            #{ts := Now} = chappe_mix_session:header(Sess),
            Now - Ts
    end.

%% ---- RTCP out ----

%% A leg leaving hears BYE for our SSRC and every source it was hearing,
%% unless it never got anything from us (6.3.7).
bye(#leg{sess = Sess} = L, S) ->
    case chappe_mix_session:sent_any(Sess) of
        true ->
            Ssrcs = [
                chappe_mix_session:ssrc(Sess) | chappe_mix_session:csrcs(Sess)
            ],
            rtcp_send(L, S, [#{type => bye, ssrcs => Ssrcs}]);
        false ->
            L
    end.

%% The reports that are due this tick.
reports(#state{legs = Legs} = S, Now) ->
    Due = maps:fold(
        fun(Id, #leg{sess = Sess}, Acc) ->
            case chappe_mix_session:due(Sess, Now) of
                true -> [Id | Acc];
                false -> Acc
            end
        end,
        [],
        Legs
    ),
    lists:foldl(
        fun(Id, Acc) ->
            #leg{sess = Sess0} = L0 = maps:get(Id, Acc#state.legs),
            L = rtcp_send(
                L0#leg{sess = chappe_mix_session:timeout(Sess0, Now)}, Acc, []
            ),
            Sess = chappe_mix_session:reported(L#leg.sess, Now),
            put_leg(L#leg{sess = Sess}, Acc)
        end,
        S,
        Due
    ).

rtcp_send(#leg{sess = Sess} = L, S, Extra) ->
    Chunks = fun(Names) ->
        csrc_chunks(chappe_mix_session:csrcs(Sess), Names, S)
    end,
    chappe_mix_leg:rtcp_send(L, S#state.cname, Chunks, Extra).

%% The SDES chunk of each CSRC, from the leg it comes in on.
csrc_chunks([], _Names, _S) ->
    [];
csrc_chunks(Csrcs, Names, S) ->
    Known = maps:fold(
        fun(_, L, Acc) ->
            case src_ssrc(L) of
                undefined -> Acc;
                Ssrc -> maps:put(Ssrc, L, Acc)
            end
        end,
        #{},
        S#state.legs
    ),
    [
        {C, Items}
     || C <- Csrcs,
        {ok, #leg{sess = Sess, name = Name}} <- [maps:find(C, Known)],
        Items <- [chappe_mix_session:csrc_items(Sess, Name, Names)],
        Items =/= []
    ].

%% ---- clock ----

arm(At) ->
    Ms = erlang:convert_time_unit(At, native, millisecond),
    erlang:start_timer(Ms, self(), tick, [{abs, true}]).

tick(#state{next_tick = Due, period = Period} = S0) ->
    Now = erlang:monotonic_time(),
    LateUs = max(0, erlang:convert_time_unit(Now - Due, native, microsecond)),
    S = record_late(LateUs, S0),
    %% more than a period late: skip the ticks we missed instead of
    %% bursting their frames out back to back
    Missed = max(0, (Now - Due) div Period),
    S1 = mix(S, Missed),
    trace(S1#state.trace, Due, Now, map_size(S1#state.legs)),
    S2 = reports(S1, Now),
    Next = Due + (Missed + 1) * Period,
    arm(Next),
    S2#state{
        next_tick = Next,
        ticks = S2#state.ticks + 1,
        overruns = S2#state.overruns + Missed
    }.

%% One message per tick to the trace process: when the tick was due, when
%% it fired and when the last leg's packet was handed to the socket, all
%% native monotonic time. Off, this is one clause match per tick.
trace(undefined, _Due, _Start, _Legs) ->
    ok;
trace(Pid, Due, Start, Legs) ->
    Done = erlang:monotonic_time(),
    Pid !
        {chappe_mix_tick, self(), #{
            due => Due, start => Start, done => Done, legs => Legs
        }},
    ok.

record_late(Us, #state{late = H, late_max = Max} = S) ->
    Bucket = bucket(Us, ?BUCKETS),
    S#state{
        late = maps:update_with(Bucket, fun(N) -> N + 1 end, 1, H),
        late_max = max(Max, Us)
    }.

bucket(Us, [B | _]) when Us < B -> B;
bucket(Us, [_ | T]) -> bucket(Us, T);
bucket(_Us, []) -> infinity.

%% ---- mixing ----

mix(#state{legs = Legs} = S, _Missed) when map_size(Legs) =:= 0 ->
    S;
mix(#state{legs = Legs0} = S, Missed) ->
    Popped = [chappe_mix_leg:pop(L) || L <- maps:values(Legs0)],
    Sum = lists:foldl(
        fun
            ({#leg{mute = false, law = Law}, Codes}, Acc) when Codes =/= none ->
                chappe_mix_dsp:add(Acc, Law, Codes);
            (_, Acc) ->
                Acc
        end,
        chappe_mix_dsp:new(),
        Popped
    ),
    Mixed = chappe_mix_dsp:mixed(Sum),
    %% who is in the sum, by leg, for the CSRC lists
    Talkers = [
        {Id, Ssrc}
     || {#leg{id = Id, mute = false} = L, Codes} <- Popped,
        Codes =/= none,
        Ssrc <- [src_ssrc(L)],
        Ssrc =/= undefined
    ],
    %% the timestamp moves with the sampling clock, skipped ticks included
    Step = ?FRAME * (1 + Missed),
    Legs = maps:from_list([
        {
            L#leg.id,
            chappe_mix_leg:advance(
                chappe_mix_leg:send(
                    L,
                    chappe_mix_dsp:encode(Mixed, L#leg.law, own(L, Codes)),
                    csrcs(L#leg.id, Talkers, ?MAX_CSRC)
                ),
                Step
            )
        }
     || {L, Codes} <- Popped
    ]),
    S#state{legs = Legs}.

%% This leg's own frame, to take out of what it hears, if it is in the
%% sum: a muted leg's frame is not, and neither is a leg with nothing to
%% play this tick.
own(#leg{mute = true}, _Codes) -> none;
own(_L, none) -> none;
own(#leg{law = Law}, Codes) -> {Law, Codes}.

%% The sources in this leg's mix: every talker but itself, at most N.
csrcs(_Id, _Talkers, 0) -> [];
csrcs(_Id, [], _N) -> [];
csrcs(Id, [{Id, _} | T], N) -> csrcs(Id, T, N);
csrcs(Id, [{_, Ssrc} | T], N) -> [Ssrc | csrcs(Id, T, N - 1)].
