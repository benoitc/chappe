%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc A conference: one process per room, on a backend
%% (chappe_mrf_conf_backend): native, fs, or a module of the app's.
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
%%   lost                       cluster: the region took the room's name
%%                              back; no new member, the ones in stay
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
%% With the chappe_mrf `cluster' setting chappe_cluster, a room's name has
%% one owner in the region, and start/2 on any node returns the room of
%% the node that holds it (chappe_mrf_conf_cluster). A room waits for the
%% lease its starter claims ({activate, Lease}) before it takes its name
%% and sets its backend up. When the region takes the lease back
%% ({chappe_cluster, Lease, lost}: this node lost its quorum, or stopped
%% renewing), the room takes no new member, tells its event receivers
%% lost, gives its name up on this node and stops once its last member
%% leaves; the members already in keep their calls. A join checks
%% chappe_cluster:valid/1 first (docs/guides/conference.md says why).
%%
%% transfer/3 moves a member to another conference of the same backend
%% (chappe_mrf_conf_transfer): on fs both rooms are on one node and
%% mod_conference moves the channel (conference transfer); on native the
%% member's call is re-anchored to the other room's mixer, the caller
%% seeing no re-INVITE. The member gets a new id there, and leaves this
%% one with reason transferred.
-module(chappe_mrf_conf).
-behaviour(gen_server).

-export([start/2, start_link/1, stop/1, info/1, events/2]).
-export([join/3, leave/2, kick/2, mute/2, unmute/2, deaf/2, undeaf/2]).
-export([lock/1, unlock/1, members/1, relate/4, play/2, play/3]).
-export([record/2, record/3, stop_record/1, transfer/3]).
-export([loop_invite/4, subscribe/3, b2b_event/2]).
%% for the backends, in the caller (chappe_mrf_conf_backend)
-export([call/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([conf/0, member/0]).

-type conf() :: pid().
-type member() :: binary().

-include("chappe_mrf_conf.hrl").

%% ---- API ----

%% Start the conference Name, or find it when it runs. Opts:
%%   backend   => native | fs | module() (default native; a module is a
%%                chappe_mrf_conf_backend)
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
%%                for a REFER with method=BYE or refers a party for a
%%                REFER with method=REFER (RFC 4579 5.5, 5.7, 5.11)
%%   refer_policy => fun((Info) -> boolean() | {reject, Code}): decides a
%%                REFER to the room (chappe_mrf:focus_refer/2) or from a
%%                member, after the room's own checks
%%                (chappe_mrf_conf_refer). Info is
%%                chappe_sip_focus:refer_info/2's map (action add |
%%                remove | refer | transfer, target, method, replaces,
%%                referrer, referred_by, target_dialog, origin, ...) plus
%%                member (the referrer's member id, or undefined), dial
%%                (add: the dial string) and removes (remove: the member
%%                it names). Without one every REFER is refused 403. It
%%                runs in the room process.
%%   dial      => fun((Target) -> iodata()): the dial string of a party a
%%                REFER brings in (default sofia/<dial_profile>/<target>)
%%   dial_profile => the sofia profile of that default (<<"external">>)
%%   dial_timeout => ms the party has to answer (30000), then 408
%%   dial_endpoint => native: create_endpoint/1 options (node, select,
%%                targets) of the endpoint that dials it
%% The 180 and 183 of a dialed party reach the referrer when the node's
%% events carry CHANNEL_PROGRESS and CHANNEL_PROGRESS_MEDIA (chappe_esl:
%% node_add/2's events).
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
%%
%% With the `cluster' setting chappe_cluster the room may run on another
%% node: start/2 returns its pid. {error, no_quorum} when the region
%% cannot be reached and no reachable room is known, {error,
%% {owner_unreachable, Node}} while the lease of a node this one cannot
%% reach runs out (retry: the name comes free within lease_ms).
-spec start(binary(), map()) -> {ok, conf()} | {error, term()}.
start(Name, Opts) ->
    case chappe_mrf_registry:lookup({conf, Name}) of
        {ok, Conf} ->
            {ok, Conf};
        error ->
            Args = #{name => Name, opts => Opts, caller => self()},
            case application:get_env(chappe_mrf, cluster, none) of
                chappe_cluster -> chappe_mrf_conf_cluster:start(Name, Args);
                _ -> start_local(Args)
            end
    end.

start_local(Args) ->
    case chappe_mrf_sup:start_conf(Args) of
        {ok, Conf} -> {ok, Conf};
        {error, {already_started, Conf}} -> {ok, Conf};
        {error, _} = Err -> Err
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
%% member flags). {ok, Member} once the member is in. Runs in the caller
%% (the backend's join/4).
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
        #{backend := B} = Info ->
            Mod = chappe_mrf_conf_backend:module(B),
            Opts1 = chappe_mrf_conf_refer:call_opts(Target, Opts),
            Mod:join(Conf, Info, Target, Opts1);
        Err ->
            Err
    end.

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
transfer(Conf, Member, To) ->
    chappe_mrf_conf_transfer:transfer(Conf, Member, To).

%% The loopback INVITE of a native join reached this node (chappe_mrf's
%% middleware): see chappe_mrf_conf_native.
-spec loop_invite(conf(), binary(), chappe_sip_req:req(), chappe_sip_res:res()) ->
    ok.
loop_invite(Conf, Token, Req, Res) ->
    chappe_mrf_conf_native:loop_invite(Conf, Token, Req, Res).

%% Hand the room a B2BUA event of a member's call (the app's notify
%% process gets them): {chappe_sip_b2b, Ref, {transferred, Leg, Info}}
%% shows the member as {left, Member, transferred}, then the target as
%% {joined, Member, Info} in its place; {chappe_sip_b2b, Ref, {request,
%% Leg, refer, Req, Res}} (requests => [refer]) is a member's REFER, which
%% the room answers (see chappe_mrf_conf_refer). Other events are
%% ignored. A caller the room answers itself (join/3 with {call, Req,
%% Res}) needs none of this: the room is its notify process.
-spec b2b_event(conf(), term()) -> ok.
b2b_event(Conf, Event) ->
    chappe_mrf_conf_refer:b2b_event(Conf, Event).

%% A SUBSCRIBE to this conference's state (focus => true).
-spec subscribe(conf(), chappe_sip_req:req(), chappe_sip_res:res()) ->
    {ok, chappe_sip_dialog:dialog()} | {error, term()}.
subscribe(Conf, Req, Res) ->
    chappe_mrf_conf_focus:subscribe(Conf, Req, Res).

call(Conf, Req) ->
    call(Conf, Req, 30000).

%% A call to the room with the caller's timeout: a room still waiting for
%% its lease holds it that long at most.
-spec call(conf(), term(), timeout()) -> term().
call(Conf, Req, Timeout) ->
    try
        gen_server:call(Conf, {within, Timeout, Req}, Timeout)
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:_ -> {error, noproc}
    end.

%% ---- gen_server ----

init(#{name := Name, caller := Caller, wait := true} = Args) ->
    %% cluster: nothing until the starter hands the lease over; a starter
    %% gone, or one that never does, ends the wait
    process_flag(trap_exit, true),
    _ = erlang:send_after(
        chappe_mrf_conf_cluster:start_timeout(), self(), wait_timeout
    ),
    {ok, #state{
        name = Name,
        backend = native,
        room = <<>>,
        waiting = #{
            args => Args, mon => monitor(process, Caller), deferred => []
        }
    }};
init(#{name := Name, opts := Opts, caller := Caller}) ->
    process_flag(trap_exit, true),
    case chappe_mrf_registry:put({conf, Name}, self()) of
        ok ->
            init_backend(Name, Opts, Caller, undefined);
        {error, exists} ->
            {ok, Other} = chappe_mrf_registry:lookup({conf, Name}),
            {stop, {already_started, Other}}
    end.

%% The lease claimed for this waiting room: still valid, the room takes
%% its name on this node and sets its backend up.
activate(Lease, #state{waiting = W} = S) ->
    #{args := Args, mon := Mon, deferred := Deferred} = W,
    #{name := Name, opts := Opts, caller := Caller} = Args,
    demonitor(Mon, [flush]),
    Draining = chappe_mrf_conf_move:draining(),
    case
        chappe_mrf_conf_cluster:activation(
            Draining, chappe_cluster:valid(Lease)
        )
    of
        release ->
            %% the node began to drain after the claim: no room here, the
            %% start goes elsewhere
            _ = chappe_cluster:release(Lease),
            {stop, normal, {error, draining}, S};
        run ->
            activate_name(Name, Opts, Caller, Lease, Deferred, S);
        no_quorum ->
            {stop, normal, {error, no_quorum}, S}
    end.

%% A waiting room takes only its lease; it ends when its starter goes or
%% never hands the lease over.
waiting_call({activate, Lease}, _From, _Ms, S) ->
    activate(Lease, S);
waiting_call(Req, From, Ms, #state{waiting = #{deferred := D} = W} = S) ->
    %% answered once it runs (or never, when it stops: the caller's call
    %% exits noproc), unless its caller gave up first (Ms, its timeout)
    Expires = erlang:monotonic_time(millisecond) + timeout_ms(Ms),
    {noreply, S#state{waiting = W#{deferred := [{Req, From, Expires} | D]}}}.

%% a call with its caller's timeout (call/3): a waiting room holds it for
%% that long at most
within(Ms, Req, From, #state{waiting = #{}} = S) ->
    waiting_call(Req, From, Ms, S);
within(_Ms, Req, From, S) ->
    handle_call(Req, From, S).

info_map(#state{mod = Mod, bstate = B} = S) ->
    maps:merge(Mod:info(B), #{
        name => S#state.name,
        backend => S#state.backend,
        room => S#state.room,
        locked => S#state.locked,
        entity => S#state.entity,
        members => map_size(S#state.members),
        max_members => S#state.max_members,
        lost => S#state.lost
    }).

timeout_ms(infinity) -> chappe_mrf_conf_cluster:start_timeout();
timeout_ms(Ms) -> Ms.

%% The calls that came while it waited, in their order, now it runs.
run_deferred([], S) ->
    S;
run_deferred([{Req, From, Expires} | Rest], S) ->
    case erlang:monotonic_time(millisecond) > Expires of
        true ->
            %% its caller gave up: the request is not run
            run_deferred(Rest, S);
        false ->
            run_deferred_one(Req, From, Rest, S)
    end.

run_deferred_one(Req, From, Rest, S) ->
    case handle_call(Req, From, S) of
        {reply, Reply, S1} ->
            gen_server:reply(From, Reply),
            run_deferred(Rest, S1);
        {noreply, S1} ->
            run_deferred(Rest, S1)
    end.

waiting_info(wait_timeout, S) ->
    {stop, normal, S};
waiting_info({'DOWN', Mon, process, _, _}, #state{waiting = #{mon := Mon}} = S) ->
    {stop, normal, S};
waiting_info(_Info, S) ->
    %% a lost before the lease was handed over: activate/2 finds the
    %% lease no longer valid
    {noreply, S}.

activate_name(Name, Opts, Caller, Lease, Deferred, S) ->
    case chappe_mrf_registry:put({conf, Name}, self()) of
        ok ->
            %% checked again now the name is ours: a drain that began
            %% between the first check and the name would never hand
            %% this room off
            case chappe_mrf_conf_move:draining() of
                true ->
                    ok = chappe_mrf_registry:delete({conf, Name}),
                    _ = chappe_cluster:release(Lease),
                    {stop, normal, {error, draining}, S};
                false ->
                    run_backend(Name, Opts, Caller, Lease, Deferred, S)
            end;
        {error, exists} ->
            {ok, Other} = chappe_mrf_registry:lookup({conf, Name}),
            {stop, normal, {error, {already_started, Other}}, S}
    end.

run_backend(Name, Opts, Caller, Lease, Deferred, S) ->
    case init_backend(Name, Opts, Caller, Lease) of
        {ok, S1} -> {reply, ok, run_deferred(lists:reverse(Deferred), S1)};
        {stop, Why} -> {stop, normal, {error, Why}, S}
    end.

init_backend(Name, Opts, Caller, Lease) ->
    Backend = maps:get(backend, Opts, native),
    Mod = chappe_mrf_conf_backend:module(Backend),
    case Mod:init(Name, Opts) of
        {ok, B} ->
            Notify = maps:get(notify, Opts, Caller),
            S = #state{
                name = Name,
                backend = Backend,
                mod = Mod,
                bstate = B,
                callbacks = chappe_mrf_conf_backend:callbacks(Mod),
                lease = Lease,
                opts = Opts,
                room = <<"mrf-", Name/binary>>,
                owner_mon =
                    case maps:find(owner, Opts) of
                        {ok, Owner} -> monitor(process, Owner);
                        error -> undefined
                    end,
                listeners = #{Notify => monitor(process, Notify)},
                max_members = maps:get(max_members, Opts, infinity)
            },
            S1 = chappe_mrf_conf_refer:setup(Opts, S),
            {ok, chappe_mrf_conf_focus:setup(Opts, S1)};
        {error, _} = Err ->
            {stop, Err}
    end.

handle_call({within, Ms, Req}, From, S) ->
    within(Ms, Req, From, S);
handle_call(Req, From, #state{waiting = #{}} = S) ->
    waiting_call(Req, From, infinity, S);
handle_call(info, _From, S) ->
    {reply, info_map(S), S};
handle_call({record, Req}, _From, S) ->
    record_req(Req, S);
handle_call({refer, Req}, _From, S) ->
    owned(S, fun(S1) -> chappe_mrf_conf_refer:call(Req, S1) end);
handle_call({transfer, Step, Arg}, {Pid, _}, S) ->
    transfer_step(Step, Arg, Pid, S);
handle_call({events, Pid}, _From, #state{listeners = L} = S) ->
    L1 =
        case L of
            #{Pid := _} -> L;
            _ -> L#{Pid => monitor(process, Pid)}
        end,
    {reply, ok, S#state{listeners = L1}};
handle_call({join, Req}, From, S) ->
    owned(S, fun(S1) -> join_open(Req, From, S1) end);
handle_call({backend, Req}, From, S) ->
    %% the backend's own calls (chappe_mrf_conf_backend)
    chappe_mrf_conf_backend:supported(handle_call, 3, S, fun(Mod) ->
        Mod:handle_call(Req, From, S)
    end);
handle_call(members, _From, #state{members = M} = S) ->
    Sorted = lists:sort(maps:to_list(M)),
    {reply, [chappe_mrf_conf_backend:public(Id, Mb) || {Id, Mb} <- Sorted], S};
handle_call({lock, Lock}, _From, #state{mod = Mod} = S) ->
    _ =
        chappe_mrf_conf_backend:has(lock, 2, S) andalso
            Mod:lock(Lock, S),
    {reply, ok, S#state{locked = Lock}};
handle_call({drop, Id, Reason}, _From, S) ->
    with_member(Id, S, fun(_Mb) ->
        chappe_mrf_conf_backend:drop_member(Id, Reason, S)
    end);
handle_call({set, Id, Flag, Value}, _From, S) ->
    with_member(Id, S, fun(Mb) -> set_flag(Id, Mb, Flag, Value, S) end);
handle_call({relate, L, Sp, Rel}, _From, S) ->
    chappe_mrf_conf_backend:supported(relate, 4, S, fun(Mod) ->
        relate(Mod, L, Sp, Rel, S)
    end);
handle_call({play, Who, File}, _From, S) ->
    {reply, play_to(Who, File, S), S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

%% Every way in for a member, sent as {join, Req}. A join already under
%% way still completes; a locked or full room takes no new member,
%% whatever the way in (chappe_mrf_conf_backend:admission/1). The party a
%% REFER brought in was admitted when the REFER was. The backend takes
%% the rest (admit/3).
join_open(Req, From, S) ->
    case chappe_mrf_conf_refer:admission(Req, S) of
        ok -> admit(Req, From, S);
        {error, _} = Err -> {reply, Err, S}
    end.

admit(check, _From, S) ->
    %% may a member come in now (the lease, the lock, the limit)
    {reply, ok, S};
admit(Req, From, #state{mod = Mod} = S) ->
    Mod:admit(Req, From, S).

%% Run a call that brings someone in (a join, a REFER, a recording) only
%% while the room owns its name: with a lease, chappe_cluster:valid/1
%% says so, read from this node's table before the side effect.
owned(#state{lost = true} = S, _Fun) ->
    {reply, {error, lost}, S};
owned(#state{lease = undefined} = S, Fun) ->
    Fun(S);
owned(#state{lease = Lease} = S, Fun) ->
    case chappe_cluster:valid(Lease) of
        true -> Fun(S);
        false -> {reply, {error, lost}, lose(S)}
    end.

%% The region took the name back: no new member, the receivers hear
%% lost, the name is free on this node for the next start/2 (which
%% claims it again), the members move to the room that owns the name
%% next (chappe_mrf_conf_move:rehome/4), and the room ends with its last
%% member.
lose(S) ->
    lose(S, rehome).

lose(#state{lost = true} = S, _Then) ->
    S;
lose(#state{name = Name} = S, Then) ->
    ok = chappe_mrf_registry:delete({conf, Name}),
    S1 = chappe_mrf_conf_backend:emit(lost, S#state{lost = true}),
    ok = chappe_mrf_conf_backend:close_if_empty(S1),
    ok = rehome(Then, S1),
    S1.

rehome(rehome, #state{mod = Mod, members = M, name = Name, opts = Opts}) when
    map_size(M) > 0
->
    _ = Mod:portable() andalso chappe_mrf_conf_move:start_rehome(Name, Opts),
    ok;
rehome(_Then, _S) ->
    ok.

%% chappe_mrf_conf_move asks: handoff (this node stops: give the lease
%% back, take no member, say which members can move), ids (the members a
%% call can move).
move_req(handoff, #state{lease = Lease, mod = Mod} = S) ->
    _ = Lease =/= undefined andalso chappe_cluster:release(Lease),
    #state{name = Name, opts = Opts, members = M} =
        S1 = lose(S#state{lease = undefined}, handoff),
    Reply = chappe_mrf_conf_move:handoff_of(Name, Opts, Mod:portable(), M),
    {reply, Reply#{backend => S1#state.backend}, S1};
move_req(ids, #state{members = M} = S) ->
    {reply, chappe_mrf_conf_move:movable(M), S}.

lost_empty(#state{lost = Lost, members = M, pending = P} = S) ->
    case chappe_mrf_conf_cluster:closing(Lost, M, P) of
        true -> {stop, normal, S};
        false -> {noreply, S}
    end.

handle_cast(_Msg, #state{waiting = #{}} = S) ->
    {noreply, S};
handle_cast({backend, Msg}, #state{mod = Mod} = S) ->
    %% the backend's own casts; dropped when it takes none
    case chappe_mrf_conf_backend:has(handle_cast, 2, S) of
        true -> Mod:handle_cast(Msg, S);
        false -> {noreply, S}
    end;
handle_cast({transferred, Ref, Info}, S) ->
    {noreply, chappe_mrf_conf_refer:transferred(Ref, Info, S)};
handle_cast(lost_empty, S) ->
    lost_empty(S);
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(Info, #state{waiting = #{}} = S) ->
    waiting_info(Info, S);
handle_info({chappe_sip_dialog, D, destroy, _Why}, S) ->
    case chappe_mrf_conf_backend:member_by(dialog, D, S) of
        {ok, Id} -> {noreply, chappe_mrf_conf_backend:gone(Id, S)};
        error -> {noreply, S}
    end;
handle_info({chappe_sip_media, {talking, _Room, Id, Talking}}, S) ->
    {noreply, chappe_mrf_conf_backend:talking(Id, Talking, S)};
handle_info({chappe_sip_b2b, Ref, {request, _Leg, refer, Req, Res}}, S) ->
    {noreply, chappe_mrf_conf_refer:member_refer(Ref, Req, Res, S)};
handle_info({chappe_cluster, Lost, lost}, #state{lease = Lease} = S) ->
    case chappe_mrf_conf_cluster:same_lease(Lost, Lease) of
        true -> {noreply, lose(S)};
        false -> {noreply, S}
    end;
handle_info({'DOWN', Mon, process, _, _}, #state{owner_mon = Mon} = S) ->
    {stop, normal, S};
handle_info({'DOWN', Mon, process, Pid, _}, #state{listeners = L} = S) ->
    case L of
        #{Pid := Mon} ->
            {noreply, S#state{listeners = maps:remove(Pid, L)}};
        _ ->
            {M, Actions} = chappe_mrf_conf_transfer:mover_down(
                Mon, S#state.members
            ),
            {noreply,
                chappe_mrf_conf_transfer:run(Actions, S#state{members = M})}
    end;
handle_info({'EXIT', Pid, Why}, S) ->
    %% a REFER's dial helper, or a link of no interest
    {noreply, chappe_mrf_conf_refer_dial:exited(Pid, Why, S)};
handle_info(Info, S) ->
    backend_info(Info, S).

%% A message the room does not know: a REFER's dial-out's
%% (chappe_mrf_conf_refer_dial:info/2), else the backend's, else the
%% focus's.
backend_info(Info, #state{mod = Mod} = S) ->
    case chappe_mrf_conf_refer_dial:info(Info, S) of
        {ok, S1} ->
            {noreply, S1};
        ignore ->
            Has = chappe_mrf_conf_backend:has(handle_info, 2, S),
            case Has andalso Mod:handle_info(Info, S) of
                {noreply, _} = Reply -> Reply;
                _NotTheBackends -> chappe_mrf_conf_focus:handle_info(Info, S)
            end
    end.

%% Every step runs, whatever one member's does. Outside a drain, a
%% member on its way out is its mover's: its dialog goes to the mover and
%% ends when the move does. In a drain (a clean stop), the moves had
%% drain_ms; one not done by then is hung up here, on purpose, rather
%% than left to a job the stop kills next.
terminate(_Reason, #state{members = M0, focus = F, mod = Mod} = S) ->
    %% the REFERs under way hear 487, their dials stop
    _ = safely(fun() -> chappe_mrf_conf_refer:stop(S) end),
    Draining = chappe_mrf_conf_move:draining(),
    M = maps:filter(
        fun(_Id, Mb) ->
            not chappe_mrf_conf_transfer:handed_over(Mb, Draining)
        end,
        M0
    ),
    _ = safely(fun() -> F =/= undefined andalso chappe_sip_focus:stop(F) end),
    %% the room's end stops what the backend runs (fs: its recordings)
    _ = safely(fun() ->
        chappe_mrf_conf_backend:has(terminate, 1, S) andalso Mod:terminate(S)
    end),
    maps:foreach(
        fun(Id, Mb) ->
            _ = safely(fun() -> end_member(Id, Mb, Draining, S) end)
        end,
        M
    ),
    ok.

safely(Fun) ->
    try
        Fun()
    catch
        Class:Why ->
            logger:notice("chappe_mrf_conf: at the room's end: ~0p", [
                {Class, Why}
            ]),
            error
    end.

%% a member hung up at the room's end (one cut mid-move by a drain, its
%% whole call: chappe_mrf_conf_transfer:cut/2)
end_member(Id, Mb, Draining, #state{mod = Mod} = S) ->
    ok = chappe_mrf_conf_transfer:cut(Mb, Draining),
    Mod:hangup(Id, Mb, S).

%% ---- members ----

with_member(Id, #state{members = M} = S, Fun) ->
    case M of
        #{Id := Mb} -> Fun(Mb);
        _ -> {reply, {error, not_member}, S}
    end.

set_flag(Id, Mb, Flag, Value, #state{mod = Mod} = S) ->
    case Mod:set_flag(Id, Mb, Flag, Value, S) of
        {ok, #state{members = M} = S1} ->
            S2 = S1#state{members = M#{Id => Mb#{Flag => Value}}},
            {reply, ok, chappe_mrf_conf_backend:publish(S2)};
        {error, unsupported} ->
            {reply, chappe_mrf_conf_backend:unsupported(S), S};
        {error, _} = Err ->
            {reply, Err, S}
    end.

relate(Mod, L, Sp, Rel, #state{members = M} = S) ->
    case M of
        #{L := LMb, Sp := SMb} -> {reply, Mod:relate(LMb, SMb, Rel, S), S};
        _ -> {reply, {error, not_member}, S}
    end.

play_to(all, File, #state{mod = Mod} = S) ->
    Mod:play(all, File, S);
play_to(Id, File, #state{mod = Mod, members = M} = S) ->
    case M of
        #{Id := Mb} -> Mod:play({Id, Mb}, File, S);
        _ -> {error, not_member}
    end.

%% record/2,3 and stop_record/1, sent as {record, Req}: a recording
%% starts only while the room owns its name.
record_req(stop, S) ->
    chappe_mrf_conf_backend:supported(stop_record, 1, S, fun(Mod) ->
        {Reply, S1} = Mod:stop_record(S),
        {reply, Reply, S1}
    end);
record_req({start, Path, Opts}, S) ->
    owned(S, fun(S1) ->
        chappe_mrf_conf_backend:supported(record, 3, S1, fun(Mod) ->
            {Reply, S2} = Mod:record(Path, Opts, S1),
            {reply, Reply, S2}
        end)
    end).

%% transfer/3's steps here, sent as {transfer, Step, Arg}
%% (chappe_mrf_conf_transfer); move: chappe_mrf_conf_move's.
transfer_step(move, Mode, _Pid, S) ->
    move_req(Mode, S);
transfer_step(Step, Arg, Pid, #state{members = M, pending = P} = S) ->
    Handover = fun(Mb) -> handover(Mb, S) end,
    {Reply, M1, Actions} = chappe_mrf_conf_transfer:step(
        Step, Arg, {Pid, Handover}, {M, P}
    ),
    {reply, Reply,
        chappe_mrf_conf_transfer:run(Actions, S#state{members = M1})}.

handover(Mb, #state{mod = Mod} = S) ->
    case chappe_mrf_conf_backend:has(handover, 1, S) of
        true -> Mod:handover(Mb);
        false -> chappe_mrf_conf_backend:unsupported(S)
    end.
