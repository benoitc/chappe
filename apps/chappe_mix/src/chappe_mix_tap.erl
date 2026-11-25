%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc Taps: a conference handing the decoded audio of a party, or of the
%% whole room, to a process, every tick. The conference process
%% (chappe_mix_conf) holds them and calls here; nothing here owns a
%% process.
%%
%% Each tick a tap sends {chappe_mix, Conf, {tap, Tap, Pcm}}: 20 ms of
%% 16-bit signed little-endian PCM at the room's rate, 320 bytes at
%% 8 kHz and 640 at 16 kHz (taps/1 says the rate). A party's tap carries what the
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
%% Tap}}, its last tap message. A tap's ref (its own, else its leg's,
%% else the room's) is fixed when it starts and shown by taps/1.
-module(chappe_mix_tap).

-include("chappe_mix_leg.hrl").

-export([call/5, send_all/4, closed/2, down/2]).

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
%% conference's taps, with its legs, its ref and its rate.
-spec call(
    {add, source(), pid(), pos_integer(), binary() | undefined}
    | {remove, reference()}
    | list,
    taps(),
    #{pos_integer() => #leg{}},
    binary() | undefined,
    chappe_mix_fmt:rate()
) -> {term(), taps()}.
call({add, Src, To, Max, Ref0}, Taps, Legs, RoomRef, _Rate) ->
    case Src =:= room orelse is_map_key(Src, Legs) of
        true ->
            Id = make_ref(),
            Tap = #{
                source => Src,
                to => To,
                mon => monitor(process, To),
                max => Max,
                ref => tap_ref(Ref0, Src, Legs, RoomRef),
                dropped => 0
            },
            {{ok, Id}, Taps#{Id => Tap}};
        false ->
            {{error, not_found}, Taps}
    end;
call({remove, Id}, Taps, _Legs, _RoomRef, _Rate) ->
    case maps:take(Id, Taps) of
        {#{mon := Mon}, Taps1} ->
            demonitor(Mon, [flush]),
            {ok, Taps1};
        error ->
            {{error, not_found}, Taps}
    end;
call(list, Taps, _Legs, _RoomRef, Rate) ->
    Info = [
        #{
            tap => Id,
            source => Src,
            to => To,
            ref => R,
            dropped => D,
            rate => Rate
        }
     || Id := #{source := Src, to := To, ref := R, dropped := D} <- Taps
    ],
    {Info, Taps}.

%% One tick: each tap's frame, from the frames in the sum (by leg) and
%% the sum, Frame samples each.
-spec send_all(
    taps(),
    #{pos_integer() => chappe_mix_dsp:frame()},
    chappe_mix_dsp:mixed(),
    pos_integer()
) -> taps().
send_all(Taps, _Frames, _Mixed, _Frame) when map_size(Taps) =:= 0 ->
    Taps;
send_all(Taps, Frames, Mixed, Frame) ->
    %% the room's PCM once a tick, and only when a room tap wants it
    Room =
        case [x || _ := #{source := room} <- Taps] of
            [] -> none;
            _ -> chappe_mix_dsp:pcm(Mixed, Frame)
        end,
    maps:map(
        fun(Id, #{source := Src} = T) ->
            Pcm = pcm(Src, Frames, Room, Frame),
            case send(T, {chappe_mix, self(), {tap, Id, Pcm}}) of
                ok -> T;
                dropped -> T#{dropped := maps:get(dropped, T) + 1}
            end
        end,
        Taps
    ).

pcm(room, _Frames, Room, _Frame) ->
    Room;
pcm(Leg, Frames, _Room, Frame) ->
    case maps:find(Leg, Frames) of
        {ok, {Codec, P}} -> chappe_mix_fmt:pcm(Codec, Frame, P);
        error -> <<0:(Frame * 16)>>
    end.

%% The taps of Source end (its leg left, or the conference stops, with
%% Source = all): their receivers hear tap_closed, and they are dropped.
-spec closed(taps(), source() | all) -> taps().
closed(Taps, Which) ->
    maps:filter(
        fun(Id, #{source := Src, to := To, mon := Mon}) ->
            case Which =:= all orelse Which =:= Src of
                true ->
                    demonitor(Mon, [flush]),
                    To ! {chappe_mix, self(), {tap_closed, Id}},
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

%% A tap's ref: its own, else its leg's, else the room's.
tap_ref(Ref, _Src, _Legs, _RoomRef) when is_binary(Ref) ->
    Ref;
tap_ref(_Ref, Leg, Legs, RoomRef) when is_map_key(Leg, Legs) ->
    case maps:get(Leg, Legs) of
        #leg{ref = undefined} -> RoomRef;
        #leg{ref = R} -> R
    end;
tap_ref(_Ref, _Src, _Legs, RoomRef) ->
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
