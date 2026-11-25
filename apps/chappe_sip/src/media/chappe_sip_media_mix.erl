%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc chappe_mix backend for chappe_sip_media: the `conference' capability.
%%
%% A room is one chappe_mix conference; each call that joins it gets one
%% mixer leg (a UDP socket in that conference) and the G.711 SDP to put
%% toward the call. This module is both the backend adapter the facade
%% calls and the process that keeps the rooms: one registered server under
%% chappe_sip_media_sup, started when `media => #{mix => _}' is configured.
%%
%% Rooms are made on first join and found by name after that. A room is
%% bound to an owner (the `owner' option of the join that created it,
%% default the creating call's process) and to its legs: it stops when the
%% owner exits or when its last leg leaves. A room created with persist
%% stays up with no leg at all, until its owner exits: a conference
%% process that owns its room keeps it across callers. Each leg is bound to the
%% process that started its media session: when that process exits, the
%% leg leaves.
%%
%% The mixer speaks G.711 over plain RTP/AVP in an 8 kHz room and L16 at
%% 16000 in a 16 kHz one; it takes packets of any size and sends 20 ms
%% ones. A room's rate is set by the join that creates it (its `rate', else
%% the configured one, default 8000) and kept for the room's life. For any
%% other call (another codec, SRTP, DTLS-SRTP), anchor it on rtpengine
%% (chappe_sip_media:mixer_params/2 gives the flags) and give the mixer the
%% offer rtpengine sends toward it; rtpengine transcodes and terminates the
%% crypto. See docs/design/media.md.
-module(chappe_sip_media_mix).
-behaviour(gen_server).

-export([
    configure/1,
    start/2,
    conference/3,
    leave/1,
    mute/2,
    deaf/2,
    relate/3,
    set_remote/2,
    stop/1,
    info/1
]).
-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([ref/0, config/0]).

%% A media session on this backend: who owns it and the key its leg is
%% kept under once it joins a room.
-type ref() :: #{id := reference(), owner := pid()}.

%% ip: the address legs bind to (default 127.0.0.1). advertise: the
%% address put in the SDP, default ip (set it when ip is a wildcard).
%% rate: the rate of a room a join creates without saying one, 8000
%% (default) or 16000. law: default codec of a leg offered without a
%% remote SDP, in an 8 kHz room. depth: the jitter buffer depth in frames.
-type config() :: #{
    ip => inet:ip_address() | string() | binary(),
    advertise => inet:ip_address() | string() | binary(),
    rate => 8000 | 16000,
    law => ulaw | alaw,
    depth => pos_integer()
}.

-record(room, {
    conf :: pid(),
    %% fixed by the join that made it
    rate :: 8000 | 16000,
    conf_mon :: reference(),
    owner_mon :: reference(),
    %% up until the owner exits, even with no leg
    persist = false :: boolean(),
    legs = #{} :: #{reference() => chappe_mix:leg()}
}).

-record(leg, {
    room :: binary(),
    leg :: chappe_mix:leg(),
    %% the leg's format: G.711 in an 8 kHz room, l16 in a 16 kHz one
    law :: chappe_sip_media_mix_sdp:law(),
    %% an L16 leg's payload type, which it takes and sends on
    pt :: 0..127 | undefined,
    local :: {inet:ip_address(), inet:port_number()},
    mon :: reference(),
    muted = false :: boolean(),
    deaf = false :: boolean(),
    %% the call process, and whether it asked for talker events
    owner :: pid(),
    talk = false :: boolean(),
    %% names the leg in its talker events, when set
    talk_tag :: term(),
    %% the direction negotiated in SDP, before mute and deaf
    dir = sendrecv :: chappe_sip_media_mix_sdp:direction(),
    %% a leg that does not keep its room up (a recording of it)
    observer = false :: boolean()
}).

-record(state, {
    conf_opts :: map(),
    advertise :: inet:ip_address() | undefined,
    rate = 8000 :: 8000 | 16000,
    law :: ulaw | alaw,
    rooms = #{} :: #{binary() => #room{}},
    legs = #{} :: #{reference() => #leg{}}
}).
-type state() :: #state{}.

-define(SERVER, ?MODULE).

%% ---- backend API ----

%% Start (or reconfigure) the room server under chappe_sip_media_sup.
-spec configure(config()) -> ok | {error, term()}.
configure(Config) ->
    case parse_config(Config) of
        {ok, Cfg} ->
            Spec = #{
                id => ?SERVER,
                start => {?MODULE, start_link, [Cfg]},
                restart => transient,
                shutdown => 5000,
                type => worker,
                modules => [?MODULE]
            },
            case chappe_sip_media_sup:start_child(Spec) of
                {ok, _} -> ok;
                {error, {already_started, _}} -> call({configure, Cfg});
                {error, _} = Err -> Err
            end;
        {error, _} = Err ->
            Err
    end.

%% A session only names its owner; the leg is made by conference/3.
-spec start(map(), map()) -> {ok, ref()} | {error, term()}.
start(_Id, _Opts) ->
    case whereis(?SERVER) of
        undefined -> {error, {not_configured, mix}};
        _ -> {ok, #{id => make_ref(), owner => self()}}
    end.

%% Join the session to a room and return the SDP to send toward the call.
%% Opts: room (required), sdp (the call's offer; answered when present,
%% otherwise the mixer offers), owner (the room's owner if this join
%% creates it), persist (true: a room this join creates stays up with no
%% leg, until its owner exits), create (false: join only a room that is
%% up, else {error, no_room}; a SIPREC recording of the room, say),
%% observer (true: the leg does not keep the room up, which ends when its
%% last other leg leaves), rate (8000 | 16000: the rate of a room this
%% join creates; a join asking another rate than the room's gets
%% {error, {rate_mismatch, RoomRate}}, a join without one takes the
%% room's), law (codec of an offer in an 8 kHz room, ignored when
%% answering), mute, name (SDES NAME the other legs see), direction (what
%% the room may do with the leg, default sendrecv), talk_events (true: the
%% calling process gets {chappe_sip_media, {talking, Room, true | false}}
%% when its party starts or stops talking), talk_tag (with talk_events:
%% the event is {chappe_sip_media, {talking, Room, Tag, true | false}}, so
%% one process holding several legs tells them apart).
-spec conference(ref(), map(), map()) -> {ok, binary()} | {error, term()}.
conference(_Ref, _Id, Opts) when not is_map_key(room, Opts) ->
    {error, {missing, room}};
conference(Ref, _Id, Opts) ->
    call({join, Ref, Opts}).

-spec leave(ref()) -> ok | {error, term()}.
leave(#{id := Id}) ->
    call({leave, Id}).

-spec mute(ref(), boolean()) -> ok | {error, term()}.
mute(#{id := Id}, Mute) ->
    call({mute, Id, Mute}).

%% A deaf leg is still heard by the room but the room sends it nothing.
-spec deaf(ref(), boolean()) -> ok | {error, term()}.
deaf(#{id := Id}, Deaf) ->
    call({deaf, Id, Deaf}).

%% Whether Listener's leg hears Speaker's; both in one room.
-spec relate(ref(), ref(), hear | nohear) -> ok | {error, term()}.
relate(#{id := Listener}, #{id := Speaker}, Rel) ->
    call({relate, Listener, Speaker, Rel}).

%% Point the leg at the far end: the SDP that answers the mixer's offer,
%% or an explicit {Ip, Port}.
-spec set_remote(
    ref(), iodata() | {inet:ip_address(), inet:port_number()}
) -> ok | {error, term()}.
set_remote(#{id := Id}, Remote) ->
    call({set_remote, Id, Remote}).

-spec stop(ref()) -> ok.
stop(Ref) ->
    _ = leave(Ref),
    ok.

-spec info(ref()) -> map() | {error, term()}.
info(#{id := Id}) ->
    call({info, Id}).

%% ---- server ----

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Cfg) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Cfg, []).

-spec init(map()) -> {ok, state()}.
init(Cfg) ->
    {ok, apply_config(Cfg, #state{conf_opts = #{}, law = ulaw})}.

-spec handle_call(term(), gen_server:from(), state()) ->
    {reply, term(), state()}.
handle_call({configure, Cfg}, _From, S) ->
    {reply, ok, apply_config(Cfg, S)};
handle_call({join, #{id := Id} = Ref, Opts}, _From, S) ->
    case maps:is_key(Id, S#state.legs) of
        true -> {reply, {error, already_joined}, S};
        false -> join(Ref, Opts, S)
    end;
handle_call({leave, Id}, _From, S) ->
    with_leg(Id, S, fun(_L) -> {reply, ok, drop_leg(Id, S)} end);
handle_call({mute, Id, Mute}, _From, S) ->
    with_leg(Id, S, fun(L) -> apply_dir(Id, L#leg{muted = Mute}, S) end);
handle_call({deaf, Id, Deaf}, _From, S) ->
    with_leg(Id, S, fun(L) -> apply_dir(Id, L#leg{deaf = Deaf}, S) end);
handle_call({relate, Id, Other, Rel}, _From, S) ->
    with_leg(Id, S, fun(L) -> do_relate(L, Other, Rel, S) end);
handle_call({set_remote, Id, Remote}, _From, S) ->
    with_leg(Id, S, fun(L) -> do_set_remote(Id, L, Remote, S) end);
handle_call({info, Id}, _From, S) ->
    with_leg(Id, S, fun(L) -> {reply, leg_info(L, S), S} end);
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, S) ->
    {noreply, S}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({'DOWN', Mon, process, _Pid, _Reason}, S) ->
    {noreply, down(Mon, S)};
handle_info({chappe_mix, Conf, {talking, Leg, Talking}}, S) ->
    talking(Conf, Leg, Talking, S),
    {noreply, S};
handle_info(_Info, S) ->
    {noreply, S}.

%% ---- join / leave ----

join(#{id := Id, owner := Owner}, #{room := Room} = Opts, S) ->
    maybe
        {ok, Rate} ?= room_rate(Room, Opts, S),
        {ok, Plan} ?= leg_plan(Opts, Rate, S),
        RoomOwner = maps:get(owner, Opts, Owner),
        Persist = maps:get(persist, Opts, false),
        Create = maps:get(create, Opts, true),
        {ok, R, S1} ?= ensure_room(Room, RoomOwner, Persist, Create, Rate, S),
        add_leg(Id, Owner, Room, R, Plan, Opts, S1)
    else
        {error, _} = Err -> {reply, Err, S}
    end.

%% The rate the join runs at: the room's when it is up (a join asking
%% another is refused, before anything is made), else the join's, else
%% the configured one.
room_rate(_Room, #{rate := R}, _S) when R =/= 8000, R =/= 16000 ->
    {error, {bad_option, rate}};
room_rate(Room, Opts, #state{rooms = Rooms} = S) ->
    case {maps:find(Room, Rooms), maps:get(rate, Opts, undefined)} of
        {{ok, #room{rate = R}}, undefined} -> {ok, R};
        {{ok, #room{rate = R}}, R} -> {ok, R};
        {{ok, #room{rate = R}}, _} -> {error, {rate_mismatch, R}};
        {error, undefined} -> {ok, S#state.rate};
        {error, R} -> {ok, R}
    end.

%% What the leg looks like before it exists (chappe_sip_media_mix_sdp:plan/3).
leg_plan(Opts, Rate, S) ->
    chappe_sip_media_mix_sdp:plan(Opts, Rate, S#state.law).

ensure_room(Room, Owner, Persist, Create, Rate, #state{rooms = Rooms} = S) ->
    case maps:find(Room, Rooms) of
        {ok, R} ->
            {ok, R, S};
        error when not Create ->
            {error, no_room};
        error ->
            case chappe_mix:start((S#state.conf_opts)#{rate => Rate}) of
                {ok, Conf} ->
                    R = #room{
                        conf = Conf,
                        rate = Rate,
                        conf_mon = monitor(process, Conf),
                        owner_mon = monitor(process, Owner),
                        persist = Persist
                    },
                    {ok, R, S#state{rooms = Rooms#{Room => R}}};
                {error, _} = Err ->
                    Err
            end
    end.

add_leg(Id, Owner, Room, #room{conf = Conf} = R, Plan, Opts, S) ->
    LegOpts0 = (codec_opts(Plan))#{
        direction => effective(
            maps:get(dir, Plan), maps:get(mute, Plan), false
        ),
        rtcp =>
            case maps:get(mux, Plan) of
                true -> mux;
                false -> pair
            end
    },
    LegOpts = lists:foldl(
        fun({K, V}, M) -> put_opt(K, V, M) end,
        dtmf_opts(maps:get(dtmf, Plan, undefined), LegOpts0),
        [
            {remote, maps:get(remote, Plan, undefined)},
            {ptime, maps:get(ptime, Plan, undefined)},
            {rtcp_remote, maps:get(rtcp_remote, Plan, undefined)},
            {name, maps:get(name, Opts, undefined)}
        ]
    ),
    case safe(fun() -> chappe_mix:add_leg(Conf, LegOpts) end) of
        {ok, Leg, #{ip := Ip, port := Port}} ->
            L = #leg{
                room = Room,
                leg = Leg,
                law = maps:get(law, Plan),
                pt = maps:get(pt, Plan, undefined),
                local = {Ip, Port},
                mon = monitor(process, Owner),
                owner = Owner,
                talk =
                    is_map_key(talk_events, Opts) andalso
                        maps:get(talk_events, Opts),
                talk_tag = maps:get(talk_tag, Opts, undefined),
                muted = maps:get(mute, Plan),
                dir = maps:get(dir, Plan),
                observer = maps:get(observer, Opts, false)
            },
            _ =
                L#leg.talk andalso
                    safe(fun() -> chappe_mix:events(Conf, self()) end),
            R1 = R#room{legs = (R#room.legs)#{Id => Leg}},
            S1 = S#state{
                rooms = (S#state.rooms)#{Room => R1},
                legs = (S#state.legs)#{Id => L}
            },
            {reply, {ok, sdp(Plan, Ip, Port, S1)}, S1};
        {error, _} = Err ->
            {reply, Err, maybe_close_room(Room, S)}
    end.

%% The leg's format as chappe_mix takes it: the law in an 8 kHz room, the
%% payload type of the offer (the far end's, or the mixer's) in a 16 kHz
%% one.
codec_opts(#{law := l16, pt := Pt}) -> #{pt => Pt};
codec_opts(#{law := Law}) -> #{law => Law}.

sdp(Plan, Ip, Port, S) ->
    chappe_sip_media_mix_sdp:leg_sdp(Plan, advertised(Ip, S), Port).

advertised(Ip, #state{advertise = undefined}) -> Ip;
advertised(_Ip, #state{advertise = Adv}) -> Adv.

%% Remove a leg; the room goes with its last leg.
drop_leg(Id, #state{legs = Legs} = S) ->
    case maps:take(Id, Legs) of
        {#leg{room = Room, leg = Leg, mon = Mon}, Legs1} ->
            demonitor(Mon, [flush]),
            S1 = S#state{legs = Legs1},
            case maps:find(Room, S1#state.rooms) of
                {ok, #room{conf = Conf, legs = RLegs} = R} ->
                    _ = safe(fun() -> chappe_mix:remove_leg(Conf, Leg) end),
                    R1 = R#room{legs = maps:remove(Id, RLegs)},
                    maybe_close_room(
                        Room, S1#state{rooms = (S1#state.rooms)#{Room => R1}}
                    );
                error ->
                    S1
            end;
        error ->
            S
    end.

%% a room ends with its last leg; an observer leg does not count
maybe_close_room(Room, #state{legs = All} = S) ->
    case maps:find(Room, S#state.rooms) of
        {ok, #room{legs = Legs, persist = false}} ->
            Kept = [I || I := _ <- Legs, not (maps:get(I, All))#leg.observer],
            close_if(Kept =:= [], Room, S);
        _ ->
            S
    end.

close_if(true, Room, S) -> close_room(Room, S);
close_if(false, _Room, S) -> S.

%% Stop a room and forget every leg in it.
close_room(Room, #state{rooms = Rooms} = S) ->
    case maps:take(Room, Rooms) of
        {#room{conf = Conf, conf_mon = CM, owner_mon = OM, legs = RLegs}, R1} ->
            demonitor(CM, [flush]),
            demonitor(OM, [flush]),
            _ = safe(fun() -> chappe_mix:stop(Conf) end),
            Legs = maps:fold(
                fun(Id, _Leg, Acc) ->
                    case maps:take(Id, Acc) of
                        {#leg{mon = Mon}, Acc1} ->
                            demonitor(Mon, [flush]),
                            Acc1;
                        error ->
                            Acc
                    end
                end,
                S#state.legs,
                RLegs
            ),
            S#state{rooms = R1, legs = Legs};
        error ->
            S
    end.

%% A monitor fired: a leg's owner (the leg leaves), a room's owner or its
%% conference (the room stops).
down(Mon, S) ->
    case [Id || {Id, #leg{mon = M}} <- maps:to_list(S#state.legs), M =:= Mon] of
        [Id | _] ->
            drop_leg(Id, S);
        [] ->
            case
                [
                    Room
                 || {Room, #room{conf_mon = CM, owner_mon = OM}} <- maps:to_list(
                        S#state.rooms
                    ),
                    CM =:= Mon orelse OM =:= Mon
                ]
            of
                [Room | _] -> close_room(Room, S);
                [] -> S
            end
    end.

%% A leg of a room started or stopped talking: its call hears of it, if
%% it asked.
talking(Conf, Leg, Talking, S) ->
    [
        Owner ! {chappe_sip_media, talk_event(Room, Tag, Talking)}
     || {Room, #room{conf = C}} <- maps:to_list(S#state.rooms),
        C =:= Conf,
        #leg{room = R, leg = L, talk = true, owner = Owner, talk_tag = Tag} <-
            maps:values(S#state.legs),
        R =:= Room,
        L =:= Leg
    ],
    ok.

talk_event(Room, undefined, Talking) -> {talking, Room, Talking};
talk_event(Room, Tag, Talking) -> {talking, Room, Tag, Talking}.

%% ---- leg operations ----

with_leg(Id, S, Fun) ->
    case maps:find(Id, S#state.legs) of
        {ok, L} -> Fun(L);
        error -> {reply, {error, not_joined}, S}
    end.

%% The leg's direction in the mixer: what SDP negotiated, less what mute
%% (the room takes nothing) and deaf (the room sends nothing) take away.
apply_dir(Id, #leg{room = Room, leg = Leg} = L, S) ->
    #room{conf = Conf} = maps:get(Room, S#state.rooms),
    case safe(fun() -> chappe_mix:direction(Conf, Leg, effective(L)) end) of
        ok -> {reply, ok, S#state{legs = (S#state.legs)#{Id => L}}};
        {error, _} = Err -> {reply, Err, S}
    end.

effective(#leg{dir = D, muted = M, deaf = Deaf}) ->
    effective(D, M, Deaf).

effective(D, M, Deaf) ->
    chappe_sip_media_mix_sdp:combine(
        D,
        case {M, Deaf} of
            {false, false} -> sendrecv;
            {true, false} -> sendonly;
            {false, true} -> recvonly;
            {true, true} -> inactive
        end
    ).

do_relate(#leg{room = Room, leg = Leg}, Other, Rel, S) ->
    case maps:find(Other, S#state.legs) of
        {ok, #leg{room = Room, leg = OtherLeg}} ->
            #room{conf = Conf} = maps:get(Room, S#state.rooms),
            {reply,
                safe(fun() -> chappe_mix:relate(Conf, Leg, OtherLeg, Rel) end),
                S};
        {ok, _} ->
            {reply, {error, not_same_room}, S};
        error ->
            {reply, {error, not_joined}, S}
    end.

do_set_remote(Id, #leg{room = Room, leg = Leg} = L, Remote, S) ->
    #room{conf = Conf} = maps:get(Room, S#state.rooms),
    case remote_endpoint(Remote, L) of
        {ok, To, Dir} ->
            case safe(fun() -> chappe_mix:set_remote(Conf, Leg, To) end) of
                ok ->
                    %% the answer can narrow what the offer said
                    D = chappe_sip_media_mix_sdp:combine(L#leg.dir, Dir),
                    apply_dir(Id, L#leg{dir = D}, S);
                {error, _} = Err ->
                    {reply, Err, S}
            end;
        {error, _} = Err ->
            {reply, Err, S}
    end.

%% The far end of an answer to the mixer's offer. An L16 leg sends on the
%% payload type it offered (one per leg, both ways), so an answer mapping
%% L16 to another one (RFC 3264 6.1 only says it SHOULD keep the offer's)
%% is {error, {pt_mismatch, Pt}}: the far end would drop what the mixer
%% sends.
remote_endpoint({Ip, Port} = Ep, _L) when is_tuple(Ip), is_integer(Port) ->
    {ok, Ep, sendrecv};
remote_endpoint(Sdp, #leg{law = Law, pt = Mine}) ->
    case chappe_sip_media_mix_sdp:read_answer(Sdp, Law) of
        {ok, #{pt := Pt}} when Law =:= l16, Pt =/= Mine ->
            {error, {pt_mismatch, Pt}};
        {ok, #{endpoint := Ep, rtcp := Rtcp, dtmf := Dtmf, direction := Dir}} ->
            {ok, dtmf_opts(Dtmf, put_opt(rtcp_remote, Rtcp, #{remote => Ep})),
                Dir};
        {error, _} = Err ->
            Err
    end.

%% The telephone-event of the far end as chappe_mix leg options.
dtmf_opts(undefined, Opts) ->
    Opts;
dtmf_opts(#{pt := Pt, events := Events}, Opts) ->
    Opts#{dtmf_pt => Pt, dtmf_events => Events}.

leg_info(#leg{room = Room, leg = Leg, law = Law, local = Local} = L, S) ->
    #room{conf = Conf, rate = Rate} = maps:get(Room, S#state.rooms),
    #{
        backend => mix,
        room => Room,
        conf => Conf,
        leg => Leg,
        rate => Rate,
        law => Law,
        local => Local,
        muted => L#leg.muted,
        deaf => L#leg.deaf,
        direction => L#leg.dir
    }.

%% ---- config ----

parse_config(#{rate := R}) when R =/= 8000, R =/= 16000 ->
    {error, {bad_config, {rate, R}}};
parse_config(Config) when is_map(Config) ->
    case
        {
            addr(maps:get(ip, Config, undefined)),
            addr(maps:get(advertise, Config, undefined))
        }
    of
        {{ok, Ip}, {ok, Adv}} ->
            {ok, #{
                ip => Ip,
                advertise => Adv,
                rate => maps:get(rate, Config, 8000),
                law => maps:get(law, Config, ulaw),
                depth => maps:get(depth, Config, undefined)
            }};
        {{error, _} = Err, _} ->
            Err;
        {_, {error, _} = Err} ->
            Err
    end;
parse_config(Other) ->
    {error, {bad_config, Other}}.

addr(undefined) ->
    {ok, undefined};
addr(Ip) when is_tuple(Ip) ->
    {ok, Ip};
addr(Bin) when is_binary(Bin) ->
    addr(binary_to_list(Bin));
addr(Str) when is_list(Str) ->
    case inet:parse_address(Str) of
        {ok, Ip} -> {ok, Ip};
        {error, _} -> {error, {bad_address, Str}}
    end.

apply_config(#{ip := Ip, advertise := Adv, law := Law, depth := Depth} = C, S) ->
    Opts0 = put_opt(ip, Ip, #{}),
    Opts = put_opt(depth, Depth, Opts0),
    S#state{
        conf_opts = Opts, advertise = Adv, rate = maps:get(rate, C), law = Law
    }.

%% ---- helpers ----

put_opt(_K, undefined, M) -> M;
put_opt(K, V, M) -> M#{K => V}.

%% A conference that died between two messages: report, do not crash.
safe(Fun) ->
    try
        Fun()
    catch
        exit:_ -> {error, noproc}
    end.

call(Req) ->
    try
        gen_server:call(?SERVER, Req)
    catch
        exit:{noproc, _} -> {error, {not_configured, mix}}
    end.
