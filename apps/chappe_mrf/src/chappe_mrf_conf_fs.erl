%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The fs backend of chappe_mrf_conf (chappe_mrf_conf_backend): a
%% mod_conference room on one FreeSWITCH node. join/4 runs in the caller
%% (chappe_mrf_conf_fs_join: an endpoint on the node, made and bridged for
%% a call, and the PIN); the rest runs in the conference process.
-module(chappe_mrf_conf_fs).
-behaviour(chappe_mrf_conf_backend).

-include("chappe_mrf_conf.hrl").

-export([init/2, info/1, join/4, admit/3, handle_info/2]).
-export([set_flag/5, hangup/3, left/2, play/3, portable/0, lock/2]).
-export([record/3, stop_record/1, handover/1, transfer_check/2]).
-export([transfer_in/3, dial/4, terminate/1]).
-export([api_raw/2, api_route/1]).

%% how long a stopped recording waits for its stop-recording event
-define(CLOSE_WAIT, 15000).

-record(fs, {
    node :: term(),
    profile = <<"default">> :: binary(),
    %% how long a member may take to show up in the room
    join_timeout = ?MRF_JOIN_TIMEOUT :: pos_integer(),
    bridge = #{} :: map(),
    %% mod_conference room flags, set on each joining channel
    room_flags = [] :: [binary()],
    %% recordings started with store => default, adopted into the
    %% recording store when they stop: {Path, CallRef, Meta}
    recordings = [] :: [{binary(), binary(), map()}],
    %% those stopped, until mod_conference's stop-recording says the file
    %% is closed
    stopping = [] :: [{binary(), binary(), map()}]
}).

%% ---- the backend ----

init(Name, Opts) ->
    case fs_node(Opts) of
        {ok, Node} ->
            %% room-wide events (play-file-done) carry no channel; only
            %% this room's are sent here
            ok = node_events(Node, Name),
            {ok, #fs{
                node = Node,
                profile = chappe_mrf_lib:to_bin(
                    maps:get(profile, Opts, <<"default">>)
                ),
                join_timeout = maps:get(join_timeout, Opts, ?MRF_JOIN_TIMEOUT),
                bridge = maps:get(bridge, Opts, #{}),
                room_flags = [
                    chappe_mrf_lib:to_bin(F)
                 || F <- maps:get(room_flags, Opts, [])
                ]
            }};
        {error, _} = Err ->
            Err
    end.

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

info(#fs{node = Node, bridge = Bridge}) ->
    #{node => Node, bridge => Bridge}.

%% in the caller: the lease, the lock and the limit before the caller is
%% bridged or answered
join(_Conf, #{lost := true}, _Target, _Opts) ->
    {error, lost};
join(_Conf, #{locked := true}, _Target, _Opts) ->
    {error, locked};
join(_Conf, #{members := N, max_members := Max}, _Target, _Opts) when
    N >= Max
->
    {error, full};
join(Conf, Info, Target, Opts) ->
    case chappe_mrf_conf:call(Conf, {join, check}, 30000) of
        ok -> chappe_mrf_conf_fs_join:join(Conf, Info, Target, Opts);
        {error, _} = Err -> Err
    end.

admit({fs, Ep, Owned, Opts}, From, S) ->
    start_join(Ep, Owned, Opts, From, S);
admit({adopt, Ep, Owned, Opts, FromName, FromId}, From, S) ->
    adopt(Ep, Owned, Opts, {FromName, FromId}, From, S);
admit(_Req, _From, S) ->
    {reply, {error, unknown_join}, S}.

handle_info({chappe_mrf_endpoint, Ep, {event, Ev}}, S) ->
    {noreply, event(Ep, Ev, S)};
handle_info({chappe_mrf_endpoint, Ep, hangup}, S) ->
    {noreply, gone_ep(Ep, S)};
handle_info({chappe_mrf_endpoint, Ep, {dtmf, Digit}}, S) ->
    %% a digit from a member's channel
    case chappe_mrf_conf_backend:member_by(ep, Ep, S) of
        {ok, Id} ->
            {noreply, chappe_mrf_conf_backend:emit({dtmf, Id, Digit}, S)};
        error ->
            {noreply, S}
    end;
handle_info({chappe_mrf, Ep, {hangup, _}}, S) when is_pid(Ep) ->
    {noreply, gone_ep(Ep, S)};
handle_info({chappe_esl_node, Node, {event, Ev}}, S) ->
    case chappe_mrf_conf_backend:bstate(S) of
        #fs{node = Node} -> {noreply, room_event(Ev, S)};
        #fs{} -> ignore
    end;
handle_info({chappe_audio_store, _Job, {adopted, Key, Result}}, S) ->
    {noreply, chappe_mrf_conf_backend:emit({recorded, Key, Result}, S)};
handle_info({timeout, _, room_recording_close}, S) ->
    #fs{stopping = St} = B = chappe_mrf_conf_backend:bstate(S),
    _ = adopt_recordings(St, self(), orphan()),
    {noreply, chappe_mrf_conf_backend:bstate(B#fs{stopping = []}, S)};
handle_info({refer_bgdial, Uuid, Result}, S) ->
    {noreply, chappe_mrf_conf_refer:fs_started(Uuid, Result, S)};
handle_info({fs_join_timeout, Ep}, S) ->
    {noreply, join_timeout(Ep, S)};
handle_info(_Msg, _S) ->
    ignore.

set_flag(Id, Mb, Flag, Value, S) ->
    case chappe_mrf_lib:api_ok(api(Mb, [flag_cmd(Flag, Value), Id], S)) of
        %% mod_conference reports mute-member itself
        ok -> {ok, S};
        {error, _} = Err -> Err
    end.

flag_cmd(mute, true) -> <<"mute">>;
flag_cmd(mute, false) -> <<"unmute">>;
flag_cmd(deaf, true) -> <<"deaf">>;
flag_cmd(deaf, false) -> <<"undeaf">>.

%% an endpoint in the room, or a party mod_conference dialed in for a
%% REFER (dialed)
hangup(Id, Mb, S) ->
    _ = api(Mb, [<<"kick">>, Id], S),
    _ =
        case Mb of
            #{ep := Ep, owned := true} ->
                spawn(fun() -> chappe_mrf:destroy(Ep) end);
            _ ->
                ok
        end,
    ok.

%% a member gone to another room: its channel lives on there
left(_Mb, transferred) ->
    ok;
left(#{ep := Ep, owned := true}, _Why) ->
    _ = spawn(fun() -> chappe_mrf:destroy(Ep) end),
    ok;
left(_Mb, _Why) ->
    ok.

play(all, File, S) ->
    chappe_mrf_lib:api_ok(api(any, [<<"play">>, File], S));
play({Id, Mb}, File, S) ->
    chappe_mrf_lib:api_ok(api(Mb, [<<"play">>, File, Id], S)).

%% the conference is FreeSWITCH's, each member a channel driven through
%% this node's outbound socket: it does not move
portable() ->
    false.

lock(Lock, S) ->
    _ = api(any, [lock_cmd(Lock)], S),
    ok.

lock_cmd(true) -> <<"lock">>;
lock_cmd(false) -> <<"unlock">>.

%% Record the room: a file on the node; store => default adopts it when
%% it stops.
record(Path, Opts, S) ->
    case chappe_mrf_store:wanted(Opts) of
        false -> {record_cmd(Path, S), S};
        true -> record_stored(Path, Opts, S)
    end.

%% A recording to adopt when it stops: its path must be shared.
record_stored(Path, Opts, S) ->
    maybe
        {ok, _} ?= chappe_mrf_store:local_path(Path),
        ok ?= record_cmd(Path, S),
        #fs{recordings = Recs} = B = chappe_mrf_conf_backend:bstate(S),
        Rec =
            {Path, maps:get(ref, Opts, S#state.name),
                maps:with([parties], Opts)},
        {ok, chappe_mrf_conf_backend:bstate(B#fs{recordings = [Rec | Recs]}, S)}
    else
        Err -> {Err, S}
    end.

record_cmd(Path, S) ->
    chappe_mrf_lib:api_ok(
        api(any, [<<"recording start">>, chappe_esl_exec:arg(Path)], S)
    ).

stop_record(S) ->
    #fs{recordings = Recs, stopping = St} =
        B = chappe_mrf_conf_backend:bstate(S),
    case stop_cmd(S) of
        ok when Recs =/= [] ->
            %% adopted on stop-recording (the file closed); a room whose
            %% node events never say it gets a copy after a while
            _ = erlang:start_timer(?CLOSE_WAIT, self(), room_recording_close),
            B1 = B#fs{recordings = [], stopping = Recs ++ St},
            {ok, chappe_mrf_conf_backend:bstate(B1, S)};
        Reply ->
            {Reply, S}
    end.

stop_cmd(S) ->
    chappe_mrf_lib:api_ok(api(any, [<<"recording stop all">>], S)).

%% the room's end stops its recordings: the stored ones are adopted
terminate(S) ->
    #fs{recordings = Recs, stopping = St} = chappe_mrf_conf_backend:bstate(S),
    _ =
        Recs =/= [] andalso stop_cmd(S) =:= ok andalso
            adopt_recordings(Recs ++ St, undefined, orphan()),
    ok.

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
recording_closed(Path, S) ->
    #fs{stopping = St} = B = chappe_mrf_conf_backend:bstate(S),
    case lists:keytake(Path, 1, St) of
        {value, Rec, St1} ->
            _ = adopt_recordings([Rec], self(), #{}),
            chappe_mrf_conf_backend:bstate(B#fs{stopping = St1}, S);
        false ->
            S
    end.

%% A call moves by a new join there; an endpoint is moved by
%% mod_conference (both rooms on one node), its mover watched.
handover(#{b2b := B2b}) ->
    {ok, {native, B2b}, false};
handover(#{ep := Ep, owned := Owned}) ->
    {ok, {fs, Ep, Owned}, true};
handover(_Mb) ->
    {error, not_member}.

transfer_check(#{node := N1}, #{node := N2}) when N1 =/= N2 ->
    {error, {unsupported, cross_node}};
transfer_check(_From, _Dest) ->
    ok.

transfer_in(To, {fs, Ep, Owned, Opts}, #{name := FromName, member := Id}) ->
    chappe_mrf_conf:call(
        To,
        {join, {adopt, Ep, Owned, Opts, FromName, Id}},
        ?MRF_JOIN_TIMEOUT + 5000
    ).

%% mod_conference dials the party into the room (with the Replaces of a
%% member's REFER, when it has one)
dial(Target, Refer, Cfg, #state{dial = Dial} = S) ->
    Room = S#state{dial = maps:merge(Dial, maps:with([replaces], Cfg))},
    {Reply, S1} = chappe_mrf_conf_refer:fs_dial(Target, Refer, Room),
    {Reply, S1#state{dial = Dial}}.

%% ---- in the room ----

start_join(Ep, Owned, Opts, From, #state{name = Name} = S) ->
    #fs{profile = Profile} = chappe_mrf_conf_backend:bstate(S),
    case watch(Ep) of
        {ok, Call} ->
            Flags =
                [mute || maps:get(mute, Opts, false)] ++
                    [deaf || maps:get(deaf, Opts, false)] ++
                    [moderator || maps:get(moderator, Opts, false)] ++
                    maps:get(flags, Opts, []),
            case
                room_flags(Call, S) =:= ok andalso
                    chappe_esl_call:conference(Call, Name, #{
                        profile => Profile, flags => Flags
                    })
            of
                {ok, _AppUuid} ->
                    {noreply,
                        pending(Ep, #{owned => Owned, opts => Opts}, From, S)};
                false ->
                    {reply, {error, room_flags}, S};
                {error, _} = Err ->
                    {reply, Err, S}
            end;
        {error, _} = Err ->
            {reply, Err, S}
    end.

%% A member of the conference FromName on this node comes over (transfer/3):
%% mod_conference moves its channel, and its add-member here completes the
%% join. Ownership of an endpoint the other conference made follows then.
adopt(Ep, Owned, Opts, {FromName, FromId}, From, #state{name = Name} = S) ->
    case watch(Ep) of
        {ok, _Call} ->
            Cmd = [
                <<"conference ">>,
                FromName,
                <<" transfer ">>,
                Name,
                <<" ">>,
                FromId
            ],
            case chappe_mrf_lib:api_ok(chappe_mrf:api(Ep, Cmd)) of
                ok ->
                    J = #{owned => Owned, opts => Opts, adopt => true},
                    {noreply, pending(Ep, J, From, S)};
                {error, _} = Err ->
                    {reply, Err, S}
            end;
        {error, _} = Err ->
            {reply, Err, S}
    end.

%% The member's channel events reach this conference: its own CUSTOM
%% conference::maintenance, dtmf and hangup (as a watcher).
watch(Ep) ->
    case chappe_mrf:info(Ep) of
        #{conn := Conn} when is_pid(Conn) ->
            ok = chappe_mrf_endpoint:watch(Ep, self()),
            _ = chappe_esl:subscribe(Conn, [
                <<"CUSTOM">>, <<"conference::maintenance">>
            ]),
            chappe_mrf_endpoint:call(Ep);
        #{} ->
            {error, not_connected};
        Err ->
            Err
    end.

room_flags(Call, S) ->
    case chappe_mrf_conf_backend:bstate(S) of
        #fs{room_flags = []} ->
            ok;
        #fs{room_flags = Flags} ->
            chappe_esl_call:set(
                Call, <<"conference_flags">>, lists:join($|, Flags)
            )
    end.

pending(Ep, J, From, S) ->
    #fs{join_timeout = Ms} = chappe_mrf_conf_backend:bstate(S),
    TRef = erlang:send_after(Ms, self(), {fs_join_timeout, Ep}),
    S#state{
        pending = (S#state.pending)#{
            {ep, Ep} => J#{from => From, timer => TRef}
        }
    }.

%% A node event (chappe_esl:node_events/1): only what carries no member,
%% the members' own come over their channels.
room_event(Ev, #state{name = Name} = S) ->
    H = fun(K) -> chappe_esl_event:header(K, Ev) end,
    case {H(<<"Event-Subclass">>), H(<<"Conference-Name">>), H(<<"Action">>)} of
        {<<"conference::maintenance">>, Name, Action} ->
            room_action(Action, H, S);
        _ ->
            S
    end.

room_action(<<"play-file-done">>, H, S) ->
    chappe_mrf_conf_backend:emit(
        {play_done, chappe_mrf_lib:to_bin(H(<<"File">>))}, S
    );
room_action(<<"del-member">>, H, S) ->
    %% a party dialed in for a REFER has no endpoint whose events would
    %% say it left: the node's do (an endpoint member's del-member also
    %% comes on its channel; gone/2 takes it once)
    dialed_gone(chappe_mrf_lib:to_bin(H(<<"Member-ID">>)), S);
room_action(<<"stop-recording">>, H, S) ->
    recording_closed(chappe_mrf_lib:to_bin(H(<<"Path">>)), S);
room_action(<<"bgdial-result">>, H, S) ->
    chappe_mrf_conf_refer:fs_result(
        chappe_mrf_lib:to_bin(H(<<"Peer-UUID">>)),
        chappe_mrf_lib:to_bin(H(<<"Result">>)),
        S
    );
room_action(<<"add-member">>, H, S) ->
    %% a party the room dialed for a REFER (its uuid is ours)
    chappe_mrf_conf_refer:fs_added(
        chappe_mrf_lib:to_bin(H(<<"Unique-ID">>)),
        chappe_mrf_lib:to_bin(H(<<"Member-ID">>)),
        S
    );
room_action(_Action, _H, S) ->
    S.

%% A member that never showed up in the room: its join fails, and the
%% endpoint made for it goes.
join_timeout(Ep, #state{pending = P} = S) ->
    case maps:take({ep, Ep}, P) of
        {#{from := From, owned := Owned}, P1} ->
            gen_server:reply(From, {error, timeout}),
            _ = Owned andalso spawn(fun() -> chappe_mrf:destroy(Ep) end),
            S#state{pending = P1};
        error ->
            S
    end.

dialed_gone(Id, #state{members = M} = S) ->
    case M of
        #{Id := #{dialed := _}} -> chappe_mrf_conf_backend:gone(Id, S);
        _ -> S
    end.

event(Ep, Ev, #state{name = Name} = S) ->
    H = fun(K) -> chappe_esl_event:header(K, Ev) end,
    case {H(<<"Event-Subclass">>), H(<<"Conference-Name">>)} of
        {<<"conference::maintenance">>, Name} ->
            action(
                H(<<"Action">>),
                chappe_mrf_lib:to_bin(H(<<"Member-ID">>)),
                Ep,
                Ev,
                S
            );
        _ ->
            S
    end.

action(<<"add-member">>, Id, Ep, _Ev, #state{pending = P} = S) ->
    case maps:take({ep, Ep}, P) of
        {#{from := From, owned := Owned, opts := Opts, timer := TRef} = J, P1} ->
            _ = erlang:cancel_timer(TRef),
            _ =
                Owned andalso maps:get(adopt, J, false) andalso
                    chappe_mrf_endpoint:set_owner(Ep, self()),
            Mb = chappe_mrf_conf_backend:member(Opts, Id, #{
                ep => Ep, owned => Owned
            }),
            gen_server:reply(From, {ok, Id}),
            S1 = chappe_mrf_conf_backend:put_member(Id, Mb, S#state{
                pending = P1
            }),
            Info = chappe_mrf_conf_backend:public(Id, Mb),
            chappe_mrf_conf_backend:emit({joined, Id, Info}, S1);
        error ->
            S
    end;
action(<<"del-member">>, Id, _Ep, _Ev, S) ->
    chappe_mrf_conf_backend:gone(Id, S);
action(<<"start-talking">>, Id, _Ep, _Ev, S) ->
    chappe_mrf_conf_backend:talking(Id, true, S);
action(<<"stop-talking">>, Id, _Ep, _Ev, S) ->
    chappe_mrf_conf_backend:talking(Id, false, S);
action(<<"mute-member">>, Id, _Ep, _Ev, S) ->
    muted(Id, true, S);
action(<<"unmute-member">>, Id, _Ep, _Ev, S) ->
    muted(Id, false, S);
action(<<"play-file-member-done">>, Id, _Ep, Ev, S) ->
    File = chappe_mrf_lib:to_bin(chappe_esl_event:header(<<"File">>, Ev)),
    chappe_mrf_conf_backend:emit({play_done, Id, File}, S);
action(_Action, _Id, _Ep, _Ev, S) ->
    S.

muted(Id, Mute, #state{members = M} = S) ->
    case M of
        #{Id := Mb} ->
            S1 = S#state{members = M#{Id := Mb#{mute => Mute}}},
            S2 = chappe_mrf_conf_backend:emit({muted, Id, Mute}, S1),
            chappe_mrf_conf_backend:publish(S2);
        _ ->
            S
    end.

gone_ep(Ep, #state{pending = P} = S) ->
    S1 =
        case maps:take({ep, Ep}, P) of
            {#{from := From, timer := TRef}, P1} ->
                _ = erlang:cancel_timer(TRef),
                gen_server:reply(From, {error, hangup}),
                S#state{pending = P1};
            error ->
                S
        end,
    case chappe_mrf_conf_backend:member_by(ep, Ep, S1) of
        {ok, Id} -> chappe_mrf_conf_backend:gone(Id, hangup, S1);
        error -> S1
    end.

api(any, Args, #state{name = Name} = S) ->
    api_raw(conf_cmd(Name, Args), S);
api(#{ep := Ep}, Args, #state{name = Name}) ->
    chappe_mrf:api(Ep, conf_cmd(Name, Args));
api(#{dialed := _}, Args, S) ->
    api(any, Args, S).

%% Where a command for the room's node can go without the room process
%% waiting: the node's own connection (the registry's), else a member's
%% call socket.
-spec api_route(#state{}) -> {node, term(), {ep, pid()} | none}.
api_route(#state{members = M} = S) ->
    #fs{node = Node} = chappe_mrf_conf_backend:bstate(S),
    Member =
        case [Ep || #{ep := Ep} <- maps:values(M)] of
            [Ep | _] -> {ep, Ep};
            [] -> none
        end,
    {node, Node, Member}.

%% A command of the room's node, over a member's call socket if it has
%% one.
-spec api_raw(iodata(), #state{}) -> term().
api_raw(Cmd, #state{members = M} = S) ->
    case [Ep || #{ep := Ep} <- maps:values(M)] of
        [Ep | _] ->
            chappe_mrf:api(Ep, Cmd);
        [] ->
            #fs{node = Node} = chappe_mrf_conf_backend:bstate(S),
            chappe_esl:node_api(Node, Cmd)
    end.

conf_cmd(Name, Args) ->
    [<<"conference ">>, Name, <<" ">> | lists:join(<<" ">>, Args)].
