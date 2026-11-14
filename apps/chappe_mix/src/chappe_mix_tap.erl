%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Taps: a conference handing the decoded audio of a party, or of the
%% whole room, to a process, every tick. The conference process
%% (chappe_mix_conf) holds them and calls here; nothing here owns a
%% process.
%%
%% Each tick a tap sends {chappe_mix, Conf, {tap, Tap, Pcm}} (with a ref,
%% {chappe_mix, Conf, {tap, Tap, Pcm}, Ref}): 20 ms of 16-bit signed
%% little-endian PCM at 8 kHz, 320 bytes. A party's tap carries what the
%% room takes from that leg this tick (silence when it sends nothing, is
%% muted, or is only listening); the room's carries the sum of every
%% talker, which is what a recorder of the room wants.
%%
%% The bound: a tick's frame is dropped, and counted, when the receiver
%% already has max_queue messages waiting (read directly for a local
%% process; for a remote one, when the distribution buffer is full), so a
%% slow reader never grows the conference's memory or delays its tick.
%%
%% The receiver is monitored: when it dies the tap goes. When its leg
%% leaves the conference (removed, or moved to another one), or the
%% conference stops, the receiver gets {chappe_mix, Conf, {tap_closed,
%% Tap}} (or the same with the ref), its last tap message.
-module(chappe_mix_tap).

-include("chappe_mix_leg.hrl").

-export([call/3, send_all/5, closed/4, down/2]).

-export_type([tap/0, taps/0, source/0]).

-type source() :: room | pos_integer().
-type tap() :: #{
    source := source(),
    to := pid(),
    mon := reference(),
    max := pos_integer(),
    ref := binary() | undefined,
    dropped := non_neg_integer()
}.
-type taps() :: #{reference() => tap()}.

%% The tap requests of chappe_mix:tap/3, untap/2 and taps/1, on the
%% conference's taps, with its legs.
-spec call(
    {add, source(), pid(), pos_integer(), binary() | undefined}
    | {remove, reference()}
    | list,
    taps(),
    #{pos_integer() => #leg{}}
) -> {term(), taps()}.
call({add, Src, To, Max, Ref}, Taps, Legs) ->
    case Src =:= room orelse is_map_key(Src, Legs) of
        true ->
            Id = make_ref(),
            Tap = #{
                source => Src,
                to => To,
                mon => monitor(process, To),
                max => Max,
                ref => Ref,
                dropped => 0
            },
            {{ok, Id}, Taps#{Id => Tap}};
        false ->
            {{error, not_found}, Taps}
    end;
call({remove, Id}, Taps, _Legs) ->
    case maps:take(Id, Taps) of
        {#{mon := Mon}, Taps1} ->
            demonitor(Mon, [flush]),
            {ok, Taps1};
        error ->
            {{error, not_found}, Taps}
    end;
call(list, Taps, _Legs) ->
    Info = [
        #{tap => Id, source => Src, to => To, dropped => D}
     || Id := #{source := Src, to := To, dropped := D} <- Taps
    ],
    {Info, Taps}.

%% One tick: each tap's frame, from the frames in the sum (by leg) and
%% the sum. A tap without a ref of its own carries its leg's, else the
%% room's (RoomRef).
-spec send_all(
    taps(),
    #{pos_integer() => chappe_mix_dsp:frame()},
    chappe_mix_dsp:mixed(),
    #{pos_integer() => #leg{}},
    binary() | undefined
) -> taps().
send_all(Taps, _Frames, _Mixed, _Legs, _RoomRef) when map_size(Taps) =:= 0 ->
    Taps;
send_all(Taps, Frames, Mixed, Legs, RoomRef) ->
    %% the room's PCM once a tick, and only when a room tap wants it
    Room =
        case [x || _ := #{source := room} <- Taps] of
            [] -> none;
            _ -> chappe_mix_dsp:pcm(Mixed)
        end,
    maps:map(
        fun(Id, #{source := Src} = T) ->
            Pcm = pcm(Src, Frames, Room),
            case send(T, msg({tap, Id, Pcm}, T, Legs, RoomRef)) of
                ok -> T;
                dropped -> T#{dropped := maps:get(dropped, T) + 1}
            end
        end,
        Taps
    ).

pcm(room, _Frames, Room) ->
    Room;
pcm(Leg, Frames, _Room) ->
    case maps:find(Leg, Frames) of
        {ok, {Law, Codes}} -> chappe_mix_g711:pcm(Law, Codes);
        error -> <<0:2560>>
    end.

%% The taps of Source end (its leg left, or the conference stops, with
%% Source = all): their receivers hear tap_closed, and they are dropped.
-spec closed(
    taps(), source() | all, #{pos_integer() => #leg{}}, binary() | undefined
) -> taps().
closed(Taps, Which, Legs, RoomRef) ->
    maps:filter(
        fun(Id, #{source := Src, to := To, mon := Mon} = T) ->
            case Which =:= all orelse Which =:= Src of
                true ->
                    demonitor(Mon, [flush]),
                    To ! msg({tap_closed, Id}, T, Legs, RoomRef),
                    false;
                false ->
                    true
            end
        end,
        Taps
    ).

%% The receiver a monitor watched is gone: so is its tap.
-spec down(taps(), reference()) -> taps().
down(Taps, Mon) ->
    maps:filter(fun(_Id, #{mon := M}) -> M =/= Mon end, Taps).

msg(Event, T, Legs, RoomRef) ->
    case tap_ref(T, Legs, RoomRef) of
        undefined -> {chappe_mix, self(), Event};
        Ref -> {chappe_mix, self(), Event, Ref}
    end.

tap_ref(#{ref := Ref}, _Legs, _RoomRef) when Ref =/= undefined ->
    Ref;
tap_ref(#{source := Leg}, Legs, RoomRef) when is_map_key(Leg, Legs) ->
    case maps:get(Leg, Legs) of
        #leg{ref = undefined} -> RoomRef;
        #leg{ref = Ref} -> Ref
    end;
tap_ref(_T, _Legs, RoomRef) ->
    RoomRef.

send(#{to := To, max := Max}, Msg) when node(To) =:= node() ->
    case process_info(To, message_queue_len) of
        {message_queue_len, N} when N < Max ->
            To ! Msg,
            ok;
        _ ->
            dropped
    end;
send(#{to := To}, Msg) ->
    case erlang:send(To, Msg, [nosuspend, noconnect]) of
        ok -> ok;
        _ -> dropped
    end.
