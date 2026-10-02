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
%% owner exits or when its last leg leaves. Each leg is bound to the
%% process that started its media session: when that process exits, the
%% leg leaves.
%%
%% The mixer speaks G.711 over plain RTP/AVP; it takes packets of any
%% size and sends 20 ms ones. For any
%% other call (another codec, SRTP, DTLS-SRTP), anchor it on rtpengine and
%% give the mixer the offer rtpengine sends toward it; rtpengine transcodes
%% and terminates the crypto. See docs/design/media.md.
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
%% law: default codec of a leg offered without a remote SDP. depth: the
%% jitter buffer depth in frames.
-type config() :: #{
    ip => inet:ip_address() | string() | binary(),
    advertise => inet:ip_address() | string() | binary(),
    law => ulaw | alaw,
    depth => pos_integer()
}.

-record(room, {
    conf :: pid(),
    conf_mon :: reference(),
    owner_mon :: reference(),
    legs = #{} :: #{reference() => chappe_mix:leg()}
}).

-record(leg, {
    room :: binary(),
    leg :: chappe_mix:leg(),
    law :: ulaw | alaw,
    local :: {inet:ip_address(), inet:port_number()},
    mon :: reference(),
    muted = false :: boolean(),
    deaf = false :: boolean(),
    %% the direction negotiated in SDP, before mute and deaf
    dir = sendrecv :: chappe_sip_media_mix_sdp:direction()
}).

-record(state, {
    conf_opts :: map(),
    advertise :: inet:ip_address() | undefined,
    law :: ulaw | alaw,
    rooms = #{} :: #{binary() => #room{}},
    legs = #{} :: #{reference() => #leg{}}
}).
-type state() :: #state{}.

-define(SERVER, ?MODULE).
%% the telephone-event payload type the mixer offers
-define(DTMF_PT, 101).

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
%% creates it), law (codec of an offer, ignored when answering), mute,
%% name (SDES NAME the other legs see).
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
handle_info(_Info, S) ->
    {noreply, S}.

%% ---- join / leave ----

join(#{id := Id, owner := Owner}, #{room := Room} = Opts, S) ->
    case leg_plan(Opts, S) of
        {ok, Plan} ->
            case ensure_room(Room, maps:get(owner, Opts, Owner), S) of
                {ok, R, S1} -> add_leg(Id, Owner, Room, R, Plan, Opts, S1);
                {error, _} = Err -> {reply, Err, S}
            end;
        {error, _} = Err ->
            {reply, Err, S}
    end.

%% What the leg looks like before it exists: answering an offer fixes the
%% law, RTCP mux and far end; offering uses the configured law and muxes.
leg_plan(#{sdp := Offer} = Opts, _S) ->
    case chappe_sip_media_mix_sdp:accept_offer(Offer) of
        {ok, #{
            endpoint := Ep,
            law := Law,
            mux := Mux,
            ptime := Ptime,
            dtmf := Dtmf,
            rtcp := Rtcp,
            direction := Dir
        }} ->
            {ok, #{
                law => Law,
                mux => Mux,
                ptime => Ptime,
                dtmf => Dtmf,
                rtcp_remote => Rtcp,
                remote => Ep,
                answer_to => Offer,
                mute => maps:get(mute, Opts, false),
                %% what the offer allows and the join asks, both
                dir => chappe_sip_media_mix_sdp:combine(
                    maps:get(direction, Opts, sendrecv), Dir
                )
            }};
        {error, _} = Err ->
            Err
    end;
leg_plan(Opts, S) ->
    {ok, #{
        law => maps:get(law, Opts, S#state.law),
        mux => true,
        %% offered; the leg takes it when the answer does
        dtmf_offer => ?DTMF_PT,
        mute => maps:get(mute, Opts, false),
        dir => maps:get(direction, Opts, sendrecv)
    }}.

ensure_room(Room, Owner, #state{rooms = Rooms} = S) ->
    case maps:find(Room, Rooms) of
        {ok, R} ->
            {ok, R, S};
        error ->
            case chappe_mix:start(S#state.conf_opts) of
                {ok, Conf} ->
                    R = #room{
                        conf = Conf,
                        conf_mon = monitor(process, Conf),
                        owner_mon = monitor(process, Owner)
                    },
                    {ok, R, S#state{rooms = Rooms#{Room => R}}};
                {error, _} = Err ->
                    Err
            end
    end.

add_leg(Id, Owner, Room, #room{conf = Conf} = R, Plan, Opts, S) ->
    LegOpts0 = #{
        law => maps:get(law, Plan),
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
                local = {Ip, Port},
                mon = monitor(process, Owner),
                muted = maps:get(mute, Plan),
                dir = maps:get(dir, Plan)
            },
            R1 = R#room{legs = (R#room.legs)#{Id => Leg}},
            S1 = S#state{
                rooms = (S#state.rooms)#{Room => R1},
                legs = (S#state.legs)#{Id => L}
            },
            {reply, {ok, sdp(Plan, Ip, Port, S1)}, S1};
        {error, _} = Err ->
            {reply, Err, maybe_close_room(Room, S)}
    end.

sdp(Plan, Ip, Port, S) ->
    Local0 = #{
        addr => advertised(Ip, S),
        port => Port,
        law => maps:get(law, Plan),
        mux => maps:get(mux, Plan),
        direction => maps:get(dir, Plan)
    },
    Local =
        case Plan of
            #{dtmf := #{pt := Pt}} -> Local0#{dtmf_pt => Pt};
            #{dtmf_offer := Pt} -> Local0#{dtmf_pt => Pt};
            _ -> Local0
        end,
    case maps:find(answer_to, Plan) of
        {ok, Offer} -> chappe_sip_media_mix_sdp:answer(Offer, Local);
        error -> chappe_sip_media_mix_sdp:offer(Local)
    end.

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

maybe_close_room(Room, S) ->
    case maps:find(Room, S#state.rooms) of
        {ok, #room{legs = Legs}} when map_size(Legs) =:= 0 ->
            close_room(Room, S);
        _ ->
            S
    end.

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

do_set_remote(Id, #leg{room = Room, leg = Leg, law = Law} = L, Remote, S) ->
    #room{conf = Conf} = maps:get(Room, S#state.rooms),
    case remote_endpoint(Remote, Law) of
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

remote_endpoint({Ip, Port} = Ep, _Law) when is_tuple(Ip), is_integer(Port) ->
    {ok, Ep, sendrecv};
remote_endpoint(Sdp, Law) ->
    case chappe_sip_media_mix_sdp:read_answer(Sdp, Law) of
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
    #room{conf = Conf} = maps:get(Room, S#state.rooms),
    #{
        backend => mix,
        room => Room,
        conf => Conf,
        leg => Leg,
        law => Law,
        local => Local,
        muted => L#leg.muted,
        deaf => L#leg.deaf,
        direction => L#leg.dir
    }.

%% ---- config ----

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

apply_config(#{ip := Ip, advertise := Adv, law := Law, depth := Depth}, S) ->
    Opts0 = put_opt(ip, Ip, #{}),
    Opts = put_opt(depth, Depth, Opts0),
    S#state{conf_opts = Opts, advertise = Adv, law = Law}.

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
