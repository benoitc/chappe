%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% A conference: one process per room, on one of two backends.
%%
%% native: the room is a chappe_mix conference the process owns (it stays
%% up between callers, until stop/1 or the owner exits). A caller joins
%% from an anchored call: replace_b/3 swaps the call's leg B for a
%% loopback INVITE to this node, which chappe_mrf's INVITE middleware
%% hands here; the mixer answers rtpengine's offer, so rtpengine stays in
%% front of the mixer (it transcodes and terminates SRTP), and the caller
%% sees no re-INVITE. Mute, deaf, relate and talker events come from the
%% mixer; prompts play on each caller's rtpengine leg (play_media). With
%% focus => true, SUBSCRIBEs to the conference package get RFC 4575
%% conference-info through chappe_sip_focus.
%%
%% fs: the room is a mod_conference room on one FreeSWITCH node. A
%% member is an endpoint on that node running the conference
%% application (a caller is first bridged into a new endpoint); its
%% member id comes from the conference::maintenance events, and mute,
%% deaf, kick and lock are `conference <name> ...' api commands. A pin
%% option has the member enter a PIN (play_collect) before it joins.
%%
%% The event receivers (the caller of start/2, then events/2) get
%% {chappe_mrf_conf, Conf, Event}:
%%   {joined, Member, Info}     Info: #{name, mute, deaf, moderator}
%%   {left, Member, Reason}     departed | kicked | hangup | transferred
%%                              (transferred: moved by transfer/3, or its
%%                              call transferred by REFER, see b2b_event/2)
%%   {talking, Member, boolean()}
%%   {muted, Member, boolean()} the member was muted or unmuted
%%   {dtmf, Member, Digit}      fs: a digit from the member
%%   {play_done, File}          fs: play/2 into the room ended (needs the
%%                              node's events to carry CUSTOM
%%                              conference::maintenance, see start/2)
%%   {play_done, Member, File}  fs: play/3 to the member ended
%%   {recorded, Path, Result}   fs: a recording started with store =>
%%                              default is in the store: {ok, Id}, or
%%                              {error, Reason}
%%
%% transfer/3 moves a member to another conference of the same backend:
%% on fs both rooms are on one node and mod_conference moves the channel
%% (conference transfer); on native the member's call is re-anchored to
%% the other room's mixer, the caller seeing no re-INVITE. The member
%% gets a new id there, and leaves this one with reason transferred.
-module(chappe_mrf_conf).
-behaviour(gen_server).

-export([start/2, start_link/1, stop/1, info/1, events/2]).
-export([join/3, leave/2, kick/2, mute/2, unmute/2, deaf/2, undeaf/2]).
-export([lock/1, unlock/1, members/1, relate/4, play/2, play/3]).
-export([record/2, record/3, stop_record/1, transfer/3]).
-export([loop_invite/4, subscribe/3, refer/3, b2b_event/2]).
%% for the backends (chappe_mrf_conf_native, chappe_mrf_conf_fs)
-export([call/3, emit/2, publish/1, gone/2, gone/3, talking/3, public/2]).
-export([member/3, drop_member/3, recording_closed/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([conf/0, member/0]).

-type conf() :: pid().
-type member() :: binary().

-include("chappe_mrf_conf.hrl").

%% how long a stopped recording waits for its stop-recording event
-define(CLOSE_WAIT, 15000).

%% ---- API ----

%% Start the conference Name, or find it when it runs. Opts:
%%   backend   => native | fs (default native)
%%   owner     => pid(): the conference stops when it exits (default none:
%%                it runs until stop/1)
%%   notify    => pid(): gets its events (default the caller)
%%   max_members => pos_integer(): join/3 returns {error, full} past it
%%                (joins under way count)
%% native:
%%   anchor_params => #{a | b => map()}: rtpengine flags for a caller
%%                moved into the mixer (the mixer runs on this host)
%%   endpoint_params => #{offer, answer => map()}: rtpengine flags between
%%                the mixer and an endpoint's node (offer: toward the node)
%% both:
%%   focus     => true: serve RFC 4575 conference-info (entity, the
%%                conference URI, defaults to sip:Name@<this node>); the
%%                parties a REFER brings in are dialed with isfocus in
%%                their Contact, and only such a room removes a member
%%                for a REFER with method=BYE (RFC 4579 5.5, 5.11)
%%   refer_policy => fun((Info) -> boolean() | {reject, Code}): decides a
%%                REFER to the room (refer/3), Info as chappe_sip_focus:
%%                refer/4 gives it (action add | remove, target, referrer,
%%                referred_by); without one every REFER is refused 403
%%   dial      => fun((Target) -> iodata()): the dial string of a party a
%%                REFER brings in (default sofia/<dial_profile>/<target>)
%%   dial_profile => the sofia profile of that default (<<"external">>)
%%   dial_timeout => ms the party has to answer (30000), then 408
%%   dial_endpoint => native: create_endpoint/1 options (node, select,
%%                targets) of the endpoint that dials it
%% fs:
%%   node      => the chappe_esl node (default chappe_esl:node_select/1
%%                with select => Opts)
%%   profile   => the mod_conference profile (default <<"default">>)
%%   bridge    => chappe_mrf:bridge/3 options for a caller joined from a
%%                call (anchor_params toward the node)
%%   join_timeout => ms a member may take to show up in the room (15000)
%%   room_flags => mod_conference conference flags for the room (as
%%                wait-mod or audio-always), set on each joining channel
%%                as conference_flags; they apply when the room is made
%% For the room-wide fs events ({play_done, File}) the conference listens
%% to its node's events (chappe_esl:node_events/1): give the node
%% events => [<<"CUSTOM">>, <<"conference::maintenance">>] in
%% chappe_esl:node_add/2. A member's own events come over its channel.
-spec start(binary(), map()) -> {ok, conf()} | {error, term()}.
start(Name, Opts) ->
    case chappe_mrf_registry:lookup({conf, Name}) of
        {ok, Conf} ->
            {ok, Conf};
        error ->
            Args = #{name => Name, opts => Opts, caller => self()},
            case chappe_mrf_sup:start_conf(Args) of
                {ok, Conf} -> {ok, Conf};
                {error, {already_started, Conf}} -> {ok, Conf};
                {error, _} = Err -> Err
            end
    end.

-spec start_link(map()) -> gen_server:start_ret().
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%% End the conference: every member is dropped.
-spec stop(conf()) -> ok.
stop(Conf) ->
    try
        gen_server:stop(Conf)
    catch
        exit:_ -> ok
    end.

-spec info(conf()) -> map() | {error, term()}.
info(Conf) ->
    call(Conf, info).

%% Pid gets the conference's events too.
-spec events(conf(), pid()) -> ok | {error, term()}.
events(Conf, Pid) ->
    call(Conf, {events, Pid}).

%% Bring a member in: a call (chappe_sip_b2b:b2b(), anchored), an
%% incoming call not answered yet ({call, Req, Res}: run it in the
%% INVITE's request worker; the room answers the caller, in a focus room
%% with the conference URI and isfocus as its Contact, and takes the
%% REFERs in that dialog; native answers it straight into the mixer
%% through rtpengine, fs bridges it to an endpoint on the room's node),
%% or an endpoint. On native, the
%% endpoint must be one of create_endpoint/1 not bridged: its dialog is
%% re-INVITEd to the mixer through rtpengine. On
%% fs, it must be on the conference's node. Opts: name, mute,
%% deaf, moderator; fs also pin (the PIN to enter first), pin_prompt
%% (the file asking for it), pin_tries (3), flags (more mod_conference
%% member flags). {ok, Member} once the member is in.
-spec join(
    conf(),
    chappe_sip_b2b:b2b()
    | {call, chappe_sip_req:req(), chappe_sip_res:res()}
    | chappe_mrf:endpoint(),
    map()
) ->
    {ok, member()} | {error, term()}.
join(Conf, Target, Opts) ->
    case info(Conf) of
        #{backend := native} ->
            native_join(Conf, Target, Opts);
        #{backend := fs, locked := true} ->
            {error, locked};
        #{backend := fs, members := N, max_members := Max} when N >= Max ->
            {error, full};
        #{backend := fs} = Info ->
            fs_join(Conf, Info, Target, Opts);
        Err ->
            Err
    end.

native_join(Conf, {call, Req, Res}, Opts) ->
    chappe_mrf_conf_native:join_call(Conf, Req, Res, Opts);
native_join(Conf, B2b, Opts) when is_tuple(B2b) ->
    call(Conf, {join, {b2b, B2b, Opts}}, ?MRF_JOIN_TIMEOUT + 80000);
native_join(Conf, Ep, Opts) ->
    call(Conf, {join, {ep, Ep, Opts}}, ?MRF_JOIN_TIMEOUT + 80000).

fs_join(Conf, Info, {call, Req, Res}, Opts) ->
    chappe_mrf_conf_fs:join_call(Conf, Info, Req, Res, Opts);
fs_join(Conf, #{node := Node, bridge := Bridge}, B2b, Opts) when
    is_tuple(B2b)
->
    chappe_mrf_conf_fs:join(Conf, Node, Bridge, B2b, Opts#{b2b => B2b});
fs_join(Conf, #{node := Node, bridge := Bridge}, Ep, Opts) ->
    chappe_mrf_conf_fs:join(Conf, Node, Bridge, Ep, Opts).

%% The member leaves (its call is hung up).
-spec leave(conf(), member()) -> ok | {error, term()}.
leave(Conf, Member) ->
    call(Conf, {drop, Member, departed}).

-spec kick(conf(), member()) -> ok | {error, term()}.
kick(Conf, Member) ->
    call(Conf, {drop, Member, kicked}).

-spec mute(conf(), member()) -> ok | {error, term()}.
mute(Conf, Member) -> call(Conf, {set, Member, mute, true}).

-spec unmute(conf(), member()) -> ok | {error, term()}.
unmute(Conf, Member) -> call(Conf, {set, Member, mute, false}).

-spec deaf(conf(), member()) -> ok | {error, term()}.
deaf(Conf, Member) -> call(Conf, {set, Member, deaf, true}).

-spec undeaf(conf(), member()) -> ok | {error, term()}.
undeaf(Conf, Member) -> call(Conf, {set, Member, deaf, false}).

%% No one joins a locked conference.
-spec lock(conf()) -> ok | {error, term()}.
lock(Conf) -> call(Conf, {lock, true}).

-spec unlock(conf()) -> ok | {error, term()}.
unlock(Conf) -> call(Conf, {lock, false}).

%% [#{id, name, mute, deaf, moderator, talking}]
-spec members(conf()) -> [map()] | {error, term()}.
members(Conf) -> call(Conf, members).

%% Whether Listener hears Speaker (native): nohear for a whisper or a
%% listen-only supervisor, hear to undo it.
-spec relate(conf(), member(), member(), hear | nohear) -> ok | {error, term()}.
relate(Conf, Listener, Speaker, Rel) ->
    call(Conf, {relate, Listener, Speaker, Rel}).

%% Play a file to every member: on native, rtpengine plays it on each
%% caller's leg (the file is read by rtpengine); on fs, mod_conference
%% plays it into the room (read by the node).
-spec play(conf(), binary()) -> ok | {error, term()}.
play(Conf, File) -> call(Conf, {play, all, File}).

-spec play(conf(), member(), binary()) -> ok | {error, term()}.
play(Conf, Member, File) -> call(Conf, {play, Member, File}).

%% Record the room (fs: conference <name> recording start, a file the
%% node writes) until stop_record/1 or the room's end. Opts: store =>
%% default adopts the file into the recording store (chappe_audio_store)
%% when it stops, under ref (default the room's name), with parties for
%% its sidecar; Path must be in the folder FreeSWITCH shares with this
%% node (chappe_mrf's shared_dir env).
%%
%% native: the second argument is a recording server's URI, and the room's
%% mix is recorded to it through SIPREC (chappe_sip_siprec, one
%% participant) under ref (default the room's name), until stop_record/1
%% or the room's end. A chappe_sip recording server with store => default
%% writes it to the recording store.
-spec record(conf(), iodata()) -> ok | {error, term()}.
record(Conf, Path) ->
    record(Conf, Path, #{}).

-spec record(conf(), iodata(), map()) -> ok | {error, term()}.
record(Conf, Path, Opts) when is_map(Opts) ->
    P = iolist_to_binary(Path),
    case P =/= <<>> andalso binary:match(P, [<<"\n">>, <<"\r">>]) of
        nomatch -> call(Conf, {record, {start, P, Opts}});
        _ -> {error, {bad_option, path}}
    end.

%% Stop every recording of the room; those started with store =>
%% default are then adopted into the store, each in a job of the store,
%% and the room's listeners get {recorded, Path, {ok, Id} | {error, R}}.
-spec stop_record(conf()) -> ok | {error, term()}.
stop_record(Conf) ->
    call(Conf, {record, stop}).

%% Move Member to the conference To (same backend; on fs, the same node).
%% Returns its id in To once it is in; it leaves this one with reason
%% transferred. Runs in the caller: each conference only does its part.
-spec transfer(conf(), member(), conf()) -> {ok, member()} | {error, term()}.
transfer(Conf, _Member, Conf) ->
    {error, same_conference};
transfer(Conf, Member, To) ->
    case {info(Conf), info(To)} of
        {#{backend := B} = From, #{backend := B} = Dest} ->
            transfer_to(Conf, Member, To, From, Dest);
        {#{backend := _}, #{backend := _}} ->
            {error, backend_mismatch};
        {#{backend := _}, Err} ->
            Err;
        {Err, _} ->
            Err
    end.

transfer_to(_Conf, _Member, _To, #{node := N1}, #{backend := fs, node := N2}) when
    N1 =/= N2
->
    {error, {unsupported, cross_node}};
transfer_to(Conf, Member, To, #{name := FromName}, _Dest) ->
    case call(Conf, {transfer, out, Member}) of
        {ok, {native, B2b, Opts}} ->
            finish_transfer(Conf, Member, join(To, B2b, Opts));
        {ok, {fs, Ep, Owned, Opts}} ->
            finish_transfer(
                Conf,
                Member,
                call(
                    To,
                    {join, {adopt, Ep, Owned, Opts, FromName, Member}},
                    ?MRF_JOIN_TIMEOUT + 5000
                )
            );
        {error, _} = Err ->
            Err
    end.

finish_transfer(_Conf, _Member, {ok, _} = Ok) ->
    Ok;
finish_transfer(Conf, Member, Error) ->
    _ = call(Conf, {transfer, cancel, Member}),
    Error.

%% The loopback INVITE of a native join reached this node: the mixer
%% answers its offer, and the dialog is the conference's. Runs in the
%% INVITE's request worker (chappe_mrf's middleware).
-spec loop_invite(conf(), binary(), chappe_sip_req:req(), chappe_sip_res:res()) ->
    ok.
loop_invite(Conf, Token, Req, Res) ->
    case call(Conf, {loop_offer, Token, chappe_sip_req:body(Req)}) of
        {ok, Answer} ->
            case
                chappe_sip:create_uas(Req, Res, #{
                    local_sdp => Answer, owner => Conf
                })
            of
                {ok, D} -> gen_server:cast(Conf, {loop_dialog, Token, D});
                {error, _} -> gen_server:cast(Conf, {loop_failed, Token})
            end;
        {error, _} ->
            _ = chappe_sip_res:send(Res, 488),
            ok
    end.

%% A REFER to the room's URI, out of any dialog (run it in the REFER's
%% request worker, from a chappe_sip:refer/1 handler, or use
%% chappe_mrf:focus_refer/2): the room's refer_policy decides, then a
%% Refer-To party is dialed into the room, or with method=BYE the member
%% with that URI (join/3's uri option, or a dialed party's) is removed.
%% The referrer hears the outcome as NOTIFYs. See chappe_mrf_conf_refer.
-spec refer(conf(), chappe_sip_req:req(), chappe_sip_res:res()) ->
    ok | {error, term()}.
refer(Conf, Req, Res) ->
    chappe_mrf_conf_refer:refer(Conf, Req, Res).

%% Hand the room a B2BUA event of a member's call (the app's notify
%% process gets them): {chappe_sip_b2b, Ref, {transferred, Leg, Info}}
%% shows the member as {left, Member, transferred}, then the target as
%% {joined, Member, Info} in its place; {chappe_sip_b2b, Ref, {request,
%% Leg, refer, Req, Res}} (requests => [refer]) is a member's REFER, which
%% the room answers (see chappe_mrf_conf_refer). Other events are
%% ignored. A caller the room answers itself (join/3 with {call, Req,
%% Res}) needs none of this: the room is its notify process.
-spec b2b_event(conf(), term()) -> ok.
b2b_event(Conf, {chappe_sip_b2b, Ref, {transferred, _Leg, Info}}) when
    is_reference(Ref), is_map(Info)
->
    gen_server:cast(Conf, {transferred, Ref, Info});
b2b_event(
    Conf, {chappe_sip_b2b, Ref, {request, _Leg, refer, _Req, _Res}} = M
) when
    is_reference(Ref)
->
    %% a call with requests => [refer] whose notify process is the app's
    Conf ! M,
    ok;
b2b_event(_Conf, _Event) ->
    ok.

%% A SUBSCRIBE to this conference's state (focus => true).
-spec subscribe(conf(), chappe_sip_req:req(), chappe_sip_res:res()) ->
    {ok, chappe_sip_dialog:dialog()} | {error, term()}.
subscribe(Conf, Req, Res) ->
    case info(Conf) of
        #{entity := Entity} when is_binary(Entity) ->
            chappe_sip_focus:subscribe(Req, Res, Conf, #{
                contact => chappe_sip_focus:contact(Entity)
            });
        _ ->
            _ = chappe_sip_res:send(Res, 489),
            {error, no_focus}
    end.

call(Conf, Req) ->
    call(Conf, Req, 30000).

call(Conf, Req, Timeout) ->
    try
        gen_server:call(Conf, Req, Timeout)
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:_ -> {error, noproc}
    end.

%% ---- gen_server ----

init(#{name := Name, opts := Opts, caller := Caller}) ->
    process_flag(trap_exit, true),
    case chappe_mrf_registry:put({conf, Name}, self()) of
        ok ->
            init_backend(Name, Opts, Caller);
        {error, exists} ->
            {ok, Other} = chappe_mrf_registry:lookup({conf, Name}),
            {stop, {already_started, Other}}
    end.

init_backend(Name, Opts, Caller) ->
    Notify = maps:get(notify, Opts, Caller),
    S0 = #state{
        name = Name,
        backend = maps:get(backend, Opts, native),
        room = <<"mrf-", Name/binary>>,
        profile = chappe_mrf_lib:to_bin(maps:get(profile, Opts, <<"default">>)),
        owner_mon =
            case maps:find(owner, Opts) of
                {ok, Owner} -> monitor(process, Owner);
                error -> undefined
            end,
        listeners = #{Notify => monitor(process, Notify)},
        anchor_params = maps:get(anchor_params, Opts, #{}),
        endpoint_params = maps:get(endpoint_params, Opts, #{}),
        join_timeout = maps:get(join_timeout, Opts, ?MRF_JOIN_TIMEOUT),
        bridge = maps:get(bridge, Opts, #{}),
        max_members = maps:get(max_members, Opts, infinity),
        room_flags = [
            chappe_mrf_lib:to_bin(F)
         || F <- maps:get(room_flags, Opts, [])
        ],
        refer_policy = maps:get(refer_policy, Opts, undefined),
        dial = dial_cfg(Opts)
    },
    case S0#state.backend of
        native ->
            {ok, focus(Opts, S0)};
        fs ->
            case fs_node(Opts) of
                {ok, Node} ->
                    %% room-wide events (play-file-done) carry no channel;
                    %% only this room's are sent here
                    ok = node_events(Node, Name),
                    {ok, focus(Opts, S0#state{node = Node})};
                {error, _} = Err ->
                    {stop, Err}
            end
    end.

dial_cfg(Opts) ->
    maps:from_list(
        [
            {K, V}
         || {O, K} <- [
                {dial, dial},
                {dial_profile, profile},
                {dial_timeout, timeout},
                {dial_endpoint, endpoint}
            ],
            {ok, V} <- [maps:find(O, Opts)]
        ]
    ).

%% No node registry running (a node given by name only): no room events.
node_events(Node, Name) ->
    Match = #{
        <<"Event-Subclass">> => <<"conference::maintenance">>,
        <<"Conference-Name">> => Name
    },
    try
        chappe_esl:node_events(Node, Match)
    catch
        exit:_ -> ok
    end.

fs_node(#{node := Node}) ->
    {ok, Node};
fs_node(Opts) ->
    case chappe_esl:node_select(maps:get(select, Opts, #{})) of
        {ok, Node} -> {ok, Node};
        {error, Why} -> {error, Why}
    end.

focus(#{focus := true} = Opts, #state{name = Name} = S) ->
    Entity =
        case maps:find(entity, Opts) of
            {ok, E} -> E;
            error -> conf_uri(Name)
        end,
    F = chappe_sip_focus:new(#{entity => Entity, min_interval => 0}),
    S#state{entity = Entity, focus = F};
focus(_Opts, S) ->
    S.

conf_uri(Name) ->
    case chappe_sip_hdr:name_addr(chappe_sip_b2b:contact()) of
        {ok, #{uri := Uri}} ->
            {ok, U} = chappe_sip_uri:parse(Uri),
            chappe_sip_uri:format(U#{user => Name});
        _ ->
            <<"sip:", Name/binary, "@invalid">>
    end.

handle_call(info, _From, S) ->
    {reply,
        #{
            name => S#state.name,
            backend => S#state.backend,
            node => S#state.node,
            room => S#state.room,
            locked => S#state.locked,
            bridge => S#state.bridge,
            entity => S#state.entity,
            members => map_size(S#state.members),
            max_members => S#state.max_members
        },
        S};
handle_call({record, Req}, _From, S) ->
    record_req(Req, S);
handle_call({refer, Req}, _From, S) ->
    chappe_mrf_conf_refer:call(Req, S);
handle_call({transfer, Step, Id}, _From, S) ->
    transfer_step(Step, Id, S);
handle_call({events, Pid}, _From, #state{listeners = L} = S) ->
    L1 =
        case L of
            #{Pid := _} -> L;
            _ -> L#{Pid => monitor(process, Pid)}
        end,
    {reply, ok, S#state{listeners = L1}};
handle_call({join, Req}, From, S) ->
    join_req(Req, From, S);
handle_call({loop_offer, Token, Offer}, _From, S) ->
    chappe_mrf_conf_native:offer(Token, Offer, S);
handle_call(members, _From, #state{members = M} = S) ->
    {reply, [public(Id, Mb) || {Id, Mb} <- lists:sort(maps:to_list(M))], S};
handle_call({lock, Lock}, _From, S) ->
    _ =
        S#state.backend =:= fs andalso
            chappe_mrf_conf_fs:api(any, [chappe_mrf_conf_fs:lock_cmd(Lock)], S),
    {reply, ok, S#state{locked = Lock}};
handle_call({drop, Id, Reason}, _From, S) ->
    with_member(Id, S, fun(Mb) -> drop(Id, Mb, Reason, S) end);
handle_call({set, Id, Flag, Value}, _From, S) ->
    with_member(Id, S, fun(Mb) -> set_flag(Id, Mb, Flag, Value, S) end);
handle_call({relate, L, Sp, Rel}, _From, #state{backend = native} = S) ->
    case {maps:find(L, S#state.members), maps:find(Sp, S#state.members)} of
        {{ok, #{session := SL}}, {ok, #{session := SS}}} ->
            {reply, chappe_sip_media:relate(SL, SS, Rel), S};
        _ ->
            {reply, {error, not_member}, S}
    end;
handle_call({relate, _, _, _}, _From, S) ->
    {reply, {error, {unsupported, fs}}, S};
handle_call({play, Who, File}, _From, S) ->
    {reply, play_to(Who, File, S), S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

%% Every way in for a member, sent as {join, Req}. A join already under
%% way still completes; a locked room takes no new member, whatever the
%% way in.
join_req({call_done, Token, Result}, From, #state{pending = P} = S) ->
    case P of
        #{Token := J} ->
            {noreply,
                chappe_mrf_conf_native:call_done(Token, J, Result, From, S)};
        _ ->
            {reply, {error, join_failed}, S}
    end;
join_req(_Req, _From, #state{locked = true} = S) ->
    {reply, {error, locked}, S};
join_req(
    _Req, _From, #state{members = M, pending = P, max_members = Max} = S
) when
    map_size(M) + map_size(P) >= Max
->
    {reply, {error, full}, S};
join_req({adopt, Ep, Owned, Opts, FromName, FromId}, From, S) ->
    chappe_mrf_conf_fs:adopt(Ep, Owned, Opts, {FromName, FromId}, From, S);
join_req({ep, Ep, Opts}, _From, S) ->
    chappe_mrf_conf_native:join_endpoint(Ep, Opts, S);
join_req({b2b, B2b, Opts}, From, S) ->
    chappe_mrf_conf_native:join(B2b, Opts, From, S);
join_req({call, Opts}, _From, S) ->
    chappe_mrf_conf_native:prepare_call(Opts, S);
join_req({fs, Ep, Owned, Opts}, From, S) ->
    chappe_mrf_conf_fs:start_join(Ep, Owned, Opts, From, S).

handle_cast({loop_dialog, Token, D}, #state{pending = P} = S) ->
    case P of
        #{Token := J} ->
            {noreply,
                chappe_mrf_conf_native:complete(Token, J#{dialog => D}, S)};
        _ ->
            {noreply, S}
    end;
handle_cast({loop_failed, Token}, S) ->
    {noreply, S#state{pending = maps:remove(Token, S#state.pending)}};
handle_cast({transferred, Ref, Info}, S) ->
    {noreply, chappe_mrf_conf_refer:transferred(Ref, Info, S)};
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({join_result, Token, Result}, #state{pending = P} = S) ->
    case P of
        #{Token := J} ->
            {noreply, chappe_mrf_conf_native:result(Token, J, Result, S)};
        _ ->
            {noreply, S}
    end;
handle_info({chappe_sip_dialog, D, destroy, _Why}, S) ->
    case
        [Id || {Id, #{dialog := MD}} <- maps:to_list(S#state.members), MD =:= D]
    of
        [Id | _] -> {noreply, gone(Id, S)};
        [] -> {noreply, S}
    end;
handle_info({chappe_sip_media, {talking, _Room, Id, Talking}}, S) ->
    {noreply, talking(Id, Talking, S)};
handle_info({chappe_mrf_endpoint, Ep, {event, Ev}}, S) ->
    {noreply, chappe_mrf_conf_fs:event(Ep, Ev, S)};
handle_info({chappe_mrf_endpoint, Ep, hangup}, S) ->
    {noreply, chappe_mrf_conf_fs:gone_ep(Ep, S)};
handle_info({chappe_mrf_endpoint, Ep, {dtmf, Digit}}, S) ->
    {noreply, chappe_mrf_conf_fs:dtmf(Ep, Digit, S)};
handle_info({chappe_esl_node, Node, {event, Ev}}, #state{node = Node} = S) ->
    {noreply, chappe_mrf_conf_fs:room_event(Ev, S)};
handle_info({chappe_mrf, Ep, {hangup, _} = E}, S) when is_pid(Ep) ->
    S1 = chappe_mrf_conf_refer:native_event(Ep, E, S),
    {noreply, chappe_mrf_conf_fs:gone_ep(Ep, S1)};
handle_info({chappe_mrf, Ep, Event}, S) when is_pid(Ep) ->
    %% a dialed endpoint's channel and completion events
    {noreply, chappe_mrf_conf_refer:native_event(Ep, Event, S)};
handle_info({chappe_sip_b2b, Ref, {request, _Leg, refer, Req, Res}}, S) ->
    {noreply, chappe_mrf_conf_refer:member_refer(Ref, Req, Res, S)};
handle_info({chappe_audio_store, _Job, {adopted, Key, Result}}, S) ->
    {noreply, emit({recorded, Key, Result}, S)};
handle_info({timeout, _, room_recording_close}, #state{stopping = St} = S) ->
    _ = adopt_recordings(St, self(), orphan()),
    {noreply, S#state{stopping = []}};
handle_info({refer_bgdial, Uuid, Result}, S) ->
    {noreply, chappe_mrf_conf_refer:fs_started(Uuid, Result, S)};
handle_info({timeout, _, {refer_dial, Key}}, S) ->
    {noreply, chappe_mrf_conf_refer:timeout(Key, S)};
handle_info({fs_join_timeout, Ep}, S) ->
    {noreply, chappe_mrf_conf_fs:join_timeout(Ep, S)};
handle_info({chappe_sip_siprec, Rec, Event}, S) ->
    {noreply, siprec_event(Rec, Event, S)};
handle_info({'DOWN', Mon, process, _, _}, #state{owner_mon = Mon} = S) ->
    {stop, normal, S};
handle_info({'DOWN', Mon, process, Pid, _}, #state{listeners = L} = S) ->
    case L of
        #{Pid := Mon} -> {noreply, S#state{listeners = maps:remove(Pid, L)}};
        _ -> {noreply, S}
    end;
handle_info({'EXIT', _, _}, S) ->
    {noreply, S};
handle_info(Info, #state{focus = F} = S) when F =/= undefined ->
    case chappe_sip_focus:handle_info(Info, F) of
        {ok, F1} -> {noreply, S#state{focus = F1}};
        ignore -> {noreply, S}
    end;
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, #state{members = M, focus = F} = S) ->
    _ = F =/= undefined andalso chappe_sip_focus:stop(F),
    %% the room's end stops its recordings: the stored ones are adopted
    _ =
        S#state.recordings =/= [] andalso
            chappe_mrf_conf_fs:stop_record(S) =:= ok andalso
            adopt_recordings(
                S#state.recordings ++ S#state.stopping, undefined, orphan()
            ),
    maps:foreach(fun(Id, Mb) -> _ = hangup_member(Id, Mb, S) end, M),
    ok.

%% ---- members ----

with_member(Id, #state{members = M} = S, Fun) ->
    case M of
        #{Id := Mb} -> Fun(Mb);
        _ -> {reply, {error, not_member}, S}
    end.

set_flag(Id, Mb, Flag, Value, S) ->
    case apply_flag(Id, Mb, Flag, Value, S) of
        ok ->
            S1 = S#state{
                members = (S#state.members)#{Id => Mb#{Flag => Value}}
            },
            %% fs reports mute-member itself
            S2 =
                case {Flag, S#state.backend} of
                    {mute, native} -> emit({muted, Id, Value}, S1);
                    _ -> S1
                end,
            {reply, ok, publish(S2)};
        {error, _} = Err ->
            {reply, Err, S}
    end.

apply_flag(_Id, #{session := MS}, mute, true, _S) ->
    chappe_sip_media:mute(MS);
apply_flag(_Id, #{session := MS}, mute, false, _S) ->
    chappe_sip_media:unmute(MS);
apply_flag(_Id, #{session := MS}, deaf, true, _S) ->
    chappe_sip_media:deaf(MS);
apply_flag(_Id, #{session := MS}, deaf, false, _S) ->
    chappe_sip_media:undeaf(MS);
apply_flag(Id, #{ep := _} = Mb, Flag, Value, S) ->
    Cmd =
        case {Flag, Value} of
            {mute, true} -> <<"mute">>;
            {mute, false} -> <<"unmute">>;
            {deaf, true} -> <<"deaf">>;
            {deaf, false} -> <<"undeaf">>
        end,
    chappe_mrf_lib:api_ok(chappe_mrf_conf_fs:api(Mb, [Cmd, Id], S)).

%% Drop member Id for Reason (leave/2, kick/2, a REFER's method=BYE).
-spec drop_member(member(), atom(), #state{}) -> {reply, ok, #state{}}.
drop_member(Id, Reason, #state{members = M} = S) ->
    drop(Id, maps:get(Id, M), Reason, S).

%% leave/2 and kick/2
drop(Id, Mb, Reason, S) ->
    _ = hangup_member(Id, Mb, S),
    {reply, ok, gone(Id, Reason, S)}.

hangup_member(_Id, #{rtpe := _}, _S) ->
    %% an endpoint of the app: out of the room, its channel stays
    ok;
hangup_member(_Id, #{dialog := D}, _S) ->
    _ = spawn(fun() -> chappe_mrf_lib:destroy_dialog(D) end),
    ok;
hangup_member(Id, Mb, S) ->
    %% fs: an endpoint in the room, or a party mod_conference dialed in
    %% for a REFER (dialed)
    _ = chappe_mrf_conf_fs:api(Mb, [<<"kick">>, Id], S),
    _ =
        case Mb of
            #{ep := Ep, owned := true} ->
                spawn(fun() -> chappe_mrf:destroy(Ep) end);
            _ ->
                ok
        end,
    ok.

gone(Id, S) ->
    gone(Id, departed, S).

gone(Id, Reason, #state{members = M} = S) ->
    case maps:take(Id, M) of
        {#{transfer := true} = Mb, M1} ->
            %% its call or channel lives on in the other conference
            _ =
                case Mb of
                    #{session := MS} -> chappe_sip_media:leave(MS);
                    _ -> ok
                end,
            publish(emit({left, Id, transferred}, S#state{members = M1}));
        {Mb, M1} ->
            _ =
                case Mb of
                    #{session := MS, rtpe := RS} ->
                        _ = chappe_sip_media:leave(MS),
                        chappe_sip_media:stop(RS);
                    #{session := MS} ->
                        chappe_sip_media:leave(MS);
                    #{ep := Ep, owned := true} ->
                        spawn(fun() -> chappe_mrf:destroy(Ep) end);
                    _ ->
                        ok
                end,
            publish(emit({left, Id, Reason}, S#state{members = M1}));
        error ->
            S
    end.

talking(Id, Talking, #state{members = M} = S) ->
    case M of
        #{Id := Mb} ->
            S1 = S#state{members = M#{Id := Mb#{talking => Talking}}},
            emit({talking, Id, Talking}, S1);
        _ ->
            S
    end.

play_to(all, File, #state{backend = fs} = S) ->
    chappe_mrf_lib:api_ok(chappe_mrf_conf_fs:api(any, [<<"play">>, File], S));
play_to(Id, File, #state{backend = fs, members = M} = S) ->
    case M of
        #{Id := Mb} ->
            chappe_mrf_lib:api_ok(
                chappe_mrf_conf_fs:api(Mb, [<<"play">>, File, Id], S)
            );
        _ ->
            {error, not_member}
    end;
play_to(all, File, #state{members = M}) ->
    lists:foldl(
        fun(Mb, Acc) ->
            case chappe_mrf_conf_native:play_leg(Mb, File) of
                ok -> Acc;
                Err -> Err
            end
        end,
        ok,
        maps:values(M)
    );
play_to(Id, File, #state{members = M}) ->
    case M of
        #{Id := Mb} -> chappe_mrf_conf_native:play_leg(Mb, File);
        _ -> {error, not_member}
    end.

%% A member as the conference keeps it: Base (its media) and what the
%% join asked for.
member(Opts, Id, Base0) ->
    %% uri: who the member is, for a REFER's method=BYE; b2b: its call,
    %% for a transfer (when the backend's own base has none)
    Base = maps:merge(maps:with([uri, b2b], Opts), Base0),
    Base#{
        name => chappe_mrf_lib:to_bin(maps:get(name, Opts, Id)),
        mute => maps:get(mute, Opts, false),
        deaf => maps:get(deaf, Opts, false),
        moderator => maps:get(moderator, Opts, false),
        talking => false
    }.

%% record/2,3 and stop_record/1, sent as {record, Req}.
record_req({start, Path, Opts}, #state{backend = fs} = S) ->
    case chappe_mrf_store:wanted(Opts) of
        false -> {reply, chappe_mrf_conf_fs:record(Path, S), S};
        true -> record_stored(Path, Opts, S)
    end;
record_req(stop, #state{backend = fs} = S) ->
    case chappe_mrf_conf_fs:stop_record(S) of
        ok when S#state.recordings =/= [] ->
            %% adopted on stop-recording (the file closed); a room whose
            %% node events never say it gets a copy after a while
            _ = erlang:start_timer(?CLOSE_WAIT, self(), room_recording_close),
            Stopping = S#state.recordings ++ S#state.stopping,
            {reply, ok, S#state{recordings = [], stopping = Stopping}};
        Reply ->
            {reply, Reply, S}
    end;
record_req({start, Srs, Opts}, #state{backend = native} = S) ->
    Ref = maps:get(ref, Opts, S#state.name),
    case
        chappe_sip_siprec:start({room, S#state.room}, Srs, #{
            call_ref => Ref, owner => self()
        })
    of
        {ok, Rec} -> {reply, ok, S#state{siprec = [Rec | S#state.siprec]}};
        {error, _} = Err -> {reply, Err, S}
    end;
record_req(stop, #state{backend = native, siprec = Recs} = S) ->
    lists:foreach(fun chappe_sip_siprec:stop/1, Recs),
    {reply, ok, S#state{siprec = []}}.

%% The events of a native room's SIPREC recordings, which this process
%% owns: a stopped one is forgotten.
siprec_event(Rec, {stopped, _}, #state{siprec = R} = S) ->
    S#state{siprec = lists:delete(Rec, R)};
siprec_event(_Rec, _Event, S) ->
    S.

%% A recording to adopt when it stops: its path must be shared.
record_stored(Path, Opts, S) ->
    maybe
        {ok, _} ?= chappe_mrf_store:local_path(Path),
        ok ?= chappe_mrf_conf_fs:record(Path, S),
        Rec =
            {Path, maps:get(ref, Opts, S#state.name),
                maps:with([parties], Opts)},
        {reply, ok, S#state{recordings = [Rec | S#state.recordings]}}
    else
        Err -> {reply, Err, S}
    end.

%% The room's stored recordings into the store (source room), each in a
%% job of the store: Notify (the room) hears the outcome and its
%% listeners get {recorded, Path, {ok, Id} | {error, Reason}}. Extra is
%% orphan() for files whose close was never seen: copied, not moved.
adopt_recordings(Recs, Notify, Extra) ->
    [
        chappe_mrf_store:adopt_async(
            Path, Ref, Meta#{source => room}, Notify, Extra
        )
     || {Path, Ref, Meta} <- lists:reverse(Recs)
    ].

orphan() ->
    #{keep => true, settle_ms => 2000}.

%% mod_conference closed a recording's file (stop-recording): a stopped
%% stored one is adopted now.
-spec recording_closed(binary(), #state{}) -> #state{}.
recording_closed(Path, #state{stopping = St} = S) ->
    case lists:keytake(Path, 1, St) of
        {value, Rec, St1} ->
            _ = adopt_recordings([Rec], self(), #{}),
            S#state{stopping = St1};
        false ->
            S
    end.

%% transfer/3's steps here, sent as {transfer, Step, Member}: out marks the
%% member and hands over what the other conference needs, cancel undoes
%% the mark after a failed join there.
transfer_step(out, Id, #state{members = M} = S) ->
    case M of
        #{Id := #{transfer := true}} ->
            {reply, {error, transferring}, S};
        #{Id := #{b2b := B2b} = Mb} ->
            {reply, {ok, {native, B2b, join_opts(Mb)}}, mark(Id, Mb, S)};
        #{Id := #{rtpe := _}} ->
            %% an endpoint of the app in a native room: its dialog is the
            %% app's, not a call this room can re-anchor
            {reply, {error, {unsupported, endpoint_member}}, S};
        #{Id := #{ep := Ep, owned := Owned} = Mb} ->
            {reply, {ok, {fs, Ep, Owned, join_opts(Mb)}}, mark(Id, Mb, S)};
        _ ->
            {reply, {error, not_member}, S}
    end;
transfer_step(cancel, Id, #state{members = M} = S) ->
    case M of
        #{Id := Mb} ->
            {reply, ok, S#state{members = M#{Id := maps:remove(transfer, Mb)}}};
        _ ->
            {reply, ok, S}
    end.

%% A member on its way to another conference: what leaves it here is
%% the transfer.
mark(Id, Mb, #state{members = M} = S) ->
    S#state{members = M#{Id := Mb#{transfer => true}}}.

%% What a member asked for when it joined, for the conference it moves to.
join_opts(Mb) ->
    maps:with([name, mute, deaf, moderator], Mb).

public(Id, Mb) ->
    (maps:with([name, mute, deaf, moderator, talking, uri], Mb))#{id => Id}.

emit(Event, #state{listeners = L} = S) ->
    _ = [Pid ! {chappe_mrf_conf, self(), Event} || Pid <- maps:keys(L)],
    S.

%% the conference-info of a focus: one user per member
publish(#state{focus = undefined} = S) ->
    S;
publish(#state{focus = F, entity = E, members = M} = S) ->
    Users = [
        #{
            entity => <<E/binary, ";member=", Id/binary>>,
            display_text => maps:get(name, Mb),
            roles => [<<"moderator">> || maps:get(moderator, Mb)],
            endpoints => [
                #{
                    entity => <<E/binary, ";member=", Id/binary>>,
                    status =>
                        case maps:get(mute, Mb) of
                            true -> muted_via_focus;
                            false -> connected
                        end,
                    joining_method => dialed_in
                }
            ]
        }
     || {Id, Mb} <- lists:sort(maps:to_list(M))
    ],
    Conf = #{
        entity => E,
        version => 0,
        user_count => length(Users),
        users => Users
    },
    S#state{focus = chappe_sip_focus:update(Conf, F)}.

%% ---- helpers ----
