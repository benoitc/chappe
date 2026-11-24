%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The parties a REFER to a room brings in (chappe_mrf_conf_refer),
%% in the conference process, on its state, and the REFER the focus sends
%% for a REFER with method=REFER.
%%
%% native: a helper makes an endpoint of the room's FreeSWITCH pool
%% (dial_endpoint options) and has it bridge to the target (the dial
%% option makes the dial string, default `sofia/<dial_profile>/<target>').
%% The endpoint joins the mixer only once the target answered (its
%% CHANNEL_BRIDGE), so nothing the target plays before reaches the room
%% and the room shows nobody until then. fs: mod_conference dials the
%% target into the room (`conference <room> bgdial'); it is a member once
%% its add-member comes. Either way the referrer hears 200 once the party
%% is in, the target's status when it failed (busy 486, declined 603, no
%% answer 480), 408 when it did not answer within dial_timeout (30 s), and
%% the room is left as it was.
%%
%% Every dial carries two channel variables, chappe_dial (the room's mark)
%% and chappe_dial_op (the op), so the node's CHANNEL_PROGRESS and
%% CHANNEL_PROGRESS_MEDIA of the dialed leg reach the room
%% (chappe_esl:node_events/2) as 180 and 183 for the referrer. The node
%% must be given those events (chappe_esl:node_add/2's events).
-module(chappe_mrf_conf_refer_dial).

-include("chappe_mrf_conf.hrl").

-export([dialable/1, dial_string/2, dial_vars/1]).
-export([native/4, fs/3, nested/4]).
-export([dialing/3, joined/4, native_event/3]).
-export([fs_added/3, fs_result/3, fs_started/3]).
-export([exited/3, info/2, cancel_all/1]).

-define(DIAL_TIMEOUT, 30000).
%% how long a nested REFER's helper follows the target's NOTIFYs
-define(NESTED_FOLLOW, 70000).

%% ---- dial strings ----

%% Whether a target URI is safe in a FreeSWITCH dial string. The
%% originate parser splits on `,' (parallel), `|' (sequential) and `:_:'
%% (enterprise), reads `[...]', `{...}' and `<...>' as channel variables,
%% toggles quoting on `''; the application running it expands `${...}'
%% (and `${api(...)}', on by default) and `\' escapes. Only the
%% characters of a plain SIP URI pass: letters, digits and - . _ ~ ! * +
%% = ; @ : %, and never `:_:'.
-spec dialable(binary()) -> boolean().
dialable(Target) when is_binary(Target), byte_size(Target) =< 256 ->
    re:run(Target, <<"^[A-Za-z0-9._~!*+=;@:%-]+$">>, [{capture, none}]) =:=
        match andalso
        binary:match(Target, <<":_:">>) =:= nomatch;
dialable(_) ->
    false.

%% The dial string of a target: the room's dial fun, else
%% sofia/<dial_profile>/<the URI without its scheme>.
-spec dial_string(map(), binary()) -> iodata().
dial_string(#{dial := F}, Target) when is_function(F, 1) ->
    F(Target);
dial_string(Cfg, Target) ->
    Profile = maps:get(profile, Cfg, <<"external">>),
    Bare =
        case Target of
            <<"sip:", R/binary>> -> R;
            <<"sips:", R/binary>> -> R;
            R -> R
        end,
    [<<"sofia/">>, Profile, <<"/">>, Bare].

%% The channel variables of the INVITE to a party the room dials: the
%% Replaces a REFER to the focus carries, as a header (RFC 4579 5.10),
%% the REFER's Referred-By (RFC 3892 2.2), and in a focus room the
%% conference's user and isfocus in its Contact (5.5). In FreeSWITCH's
%% sofia (sofia_glue.c) sip_contact_user is the Contact's user, and
%% sip_invite_contact_params with a leading `~' adds header parameters
%% after the URI; the host stays the FreeSWITCH node's, which holds that
%% dialog.
-spec dial_vars(map()) -> [{binary(), binary()}].
dial_vars(Cfg) ->
    Rep =
        case Cfg of
            #{replaces := R} -> [{<<"sip_h_Replaces">>, R}];
            _ -> []
        end,
    RB =
        case Cfg of
            #{referred_by := B} -> [{<<"sip_h_Referred-By">>, B}];
            _ -> []
        end,
    Rep ++ RB ++ focus_vars(maps:get(entity, Cfg, undefined)).

focus_vars(undefined) ->
    [];
focus_vars(Entity) ->
    User =
        case chappe_sip_uri:parse(Entity) of
            {ok, #{user := U}} when is_binary(U) -> U;
            _ -> <<>>
        end,
    Params = {<<"sip_invite_contact_params">>, <<"~isfocus">>},
    case User =/= <<>> andalso dialable(User) of
        true -> [{<<"sip_contact_user">>, User}, Params];
        false -> [Params]
    end.

%% what marks the op's dial on its node
marks(Key, #state{dial_tag = Tag, refer_ops = Ops}) ->
    #{op_id := OpId} = chappe_mrf_conf_refer_op:data(Key, Ops),
    [
        {<<"chappe_dial">>, Tag},
        {<<"chappe_dial_op">>, OpId},
        {<<"verbose_events">>, <<"true">>}
    ].

%% the {...} block of channel variables (never empty: a dial has its marks)
var_block(Vars) ->
    [
        <<"{">>,
        lists:join(<<",">>, [[K, <<"=">>, V] || {K, V} <- Vars]),
        <<"}">>
    ].

%% ---- native ----

%% Dial Target for op Key: a helper makes the endpoint and starts its
%% bridge; the endpoint is the room's.
-spec native(binary(), term(), map(), #state{}) -> {ok, #state{}}.
native(Target, Key, Cfg, #state{entity = E} = S) ->
    Conf = self(),
    Dial = [
        var_block(dial_vars(Cfg#{entity => E}) ++ marks(Key, S)),
        dial_string(Cfg, Target)
    ],
    EpOpts = maps:get(endpoint, Cfg, #{}),
    Pid = spawn_link(fun() -> native_helper(Conf, Key, EpOpts, Dial) end),
    {ok, put_dial({helper, Pid}, #{key => Key}, S)}.

native_helper(Conf, Key, EpOpts, Dial) ->
    Ep0 = EpOpts#{owner => Conf, events => [{channel, <<"CHANNEL_BRIDGE">>}]},
    case chappe_mrf:create_endpoint(Ep0) of
        {ok, Ep} ->
            case
                chappe_mrf_conf:call(Conf, {refer, {dialing, Key, Ep}}, 30000)
            of
                ok ->
                    ok = chappe_mrf:set(Ep, #{
                        <<"hangup_after_bridge">> => <<"true">>
                    }),
                    {ok, _} = chappe_mrf:execute(Ep, <<"bridge">>, Dial, #{
                        wait => false
                    }),
                    ok;
                _ ->
                    %% the REFER is over (the room ended, it was given up)
                    chappe_mrf:destroy(Ep)
            end;
        {error, Why} ->
            exit({dial_failed, Why})
    end.

%% The helper's endpoint for op Key: watched until the target answers.
-spec dialing(term(), pid(), #state{}) -> {ok | {error, gone}, #state{}}.
dialing(Key, Ep, #state{refer_ops = Ops} = S) ->
    case chappe_mrf_conf_refer_op:lookup(Key, Ops) of
        {running, _} ->
            T = erlang:start_timer(
                timeout_ms(S), self(), {refer_dial, {ep, Ep}}
            ),
            S1 = watch_node(chappe_mrf:node(Ep), S),
            {ok, put_dial({ep, Ep}, #{key => Key, timer => T}, S1)};
        _ ->
            {{error, gone}, S}
    end.

%% A dialing endpoint's news. The target answered (the bridge is up): the
%% endpoint joins the mixer. The bridge ended before that: the target's
%% status. Anything else is a member's.
-spec native_event(pid(), term(), #state{}) -> #state{}.
native_event(Ep, Event, #state{dialing = D} = S) ->
    case {D, Event} of
        {#{{ep, Ep} := #{answered := true}}, _} ->
            S;
        {#{{ep, Ep} := E}, {channel, <<"CHANNEL_BRIDGE">>, _}} ->
            answered(Ep, E, S);
        {#{{ep, Ep} := E}, {complete, <<"bridge">>, Ev}} ->
            failed({ep, Ep}, E, status(Ev), S);
        {#{{ep, Ep} := E}, {hangup, _}} ->
            failed({ep, Ep}, E, 487, S);
        _ ->
            S
    end.

%% the target answered: the endpoint joins the room, in a helper (a join
%% calls the room)
answered(Ep, #{key := Key, timer := T} = E, #state{refer_ops = Ops} = S) ->
    _ = erlang:cancel_timer(T),
    #{target := Target} = Data = chappe_mrf_conf_refer_op:data(Key, Ops),
    Opts = (maps:with([referred], Data))#{
        name => Target,
        uri => Target,
        refer => Key,
        joining => dialed_out
    },
    Conf = self(),
    Pid = spawn_link(fun() ->
        Result = chappe_mrf_conf:join(Conf, Ep, Opts),
        chappe_mrf_conf:call(Conf, {refer, {joined, Key, Ep, Result}}, 30000)
    end),
    put_dial(
        {helper, Pid},
        #{key => Key},
        put_dial({ep, Ep}, E#{answered => true}, S)
    ).

%% The answered endpoint is in the room (a member, joined), or it could
%% not join: the referrer hears which.
-spec joined(term(), pid(), {ok, binary()} | {error, term()}, #state{}) ->
    #state{}.
joined(Key, Ep, {ok, _Id}, S) ->
    final(Key, 200, drop_dial({ep, Ep}, S));
joined(Key, Ep, {error, _}, S) ->
    _ = spawn(fun() -> chappe_mrf:destroy(Ep) end),
    final(Key, 503, drop_dial({ep, Ep}, S)).

%% a dial that ended before its party was in: the referrer hears St, the
%% room is left as it was
failed({ep, Ep} = DK, #{key := Key} = E, St, S) ->
    _ = cancel(E),
    _ = spawn(fun() -> chappe_mrf:destroy(Ep) end),
    final(Key, St, drop_dial(DK, S));
failed({uuid, Uuid} = DK, #{key := Key} = E, St, S) ->
    _ = cancel(E),
    _ = chappe_mrf_conf_fs:api_raw([<<"uuid_kill ">>, Uuid], S),
    final(Key, St, drop_dial(DK, S));
failed(DK, #{key := Key}, St, S) ->
    final(Key, St, drop_dial(DK, S)).

%% ---- fs ----

%% fs: mod_conference dials the target into the room, under a uuid of
%% ours, so its add-member is ours too. S's dial options carry what the
%% REFER asked for (replaces, referred_by).
-spec fs(binary(), term(), #state{}) -> {ok | {error, term()}, #state{}}.
fs(Target, Key, #state{name = Name} = S) ->
    Uuid = chappe_mrf_lib:new_id(),
    Vars =
        dial_vars((S#state.dial)#{entity => S#state.entity}) ++ marks(Key, S),
    Dial = [
        <<"{origination_uuid=">>,
        Uuid,
        [[<<",">>, K, <<"=">>, V] || {K, V} <- Vars],
        <<"}">>,
        dial_string(S#state.dial, Target)
    ],
    %% bgdial answers at once (dial would originate first, for as long as
    %% the target rings); a helper sends it, so the room never waits on a
    %% socket, and over the node's own connection when the registry has
    %% it rather than a member's call socket
    Cmd = iolist_to_binary([<<"conference ">>, Name, <<" bgdial ">>, Dial]),
    {node, Node, _} = Via = chappe_mrf_conf_fs:api_route(S),
    Conf = self(),
    _ = spawn_monitor(fun() -> Conf ! {refer_bgdial, Uuid, bgdial(Via, Cmd)} end),
    T = erlang:start_timer(timeout_ms(S), self(), {refer_dial, {uuid, Uuid}}),
    Entry = #{key => Key, timer => T, target => Target},
    {ok, put_dial({uuid, Uuid}, Entry, watch_node({ok, Node}, S))}.

bgdial({node, Node, Fallback}, Cmd) ->
    case catch_api(fun() -> chappe_esl:node_api(Node, Cmd) end) of
        ok -> ok;
        _ -> bgdial(Fallback, Cmd)
    end;
bgdial({ep, Ep}, Cmd) ->
    catch_api(fun() -> chappe_mrf:api(Ep, Cmd) end);
bgdial(none, _Cmd) ->
    {error, no_connection}.

catch_api(F) ->
    try F() of
        R -> chappe_mrf_lib:api_ok(R)
    catch
        _:R -> {error, R}
    end.

%% fs: the dialed target is in the room: a member, dialed out, and the
%% referrer hears 200.
-spec fs_added(binary(), binary(), #state{}) -> #state{}.
fs_added(Uuid, Id, #state{dialing = D, refer_ops = Ops} = S) ->
    case D of
        #{{uuid, Uuid} := #{key := Key, target := Target} = E} ->
            _ = cancel(E),
            Data = chappe_mrf_conf_refer_op:data(Key, Ops),
            Opts = (maps:with([referred], Data))#{
                name => Target, uri => Target, joining => dialed_out
            },
            Mb = chappe_mrf_conf_backend:member(Opts, Id, #{dialed => Uuid}),
            S1 = chappe_mrf_conf_backend:joined(
                Id, Mb, drop_dial({uuid, Uuid}, S)
            ),
            final(Key, 200, S1);
        #{} ->
            S
    end.

%% A bgdial-result for a party we dialed: SUCCESS waits for its
%% add-member; any other cause fails the REFER.
-spec fs_result(binary(), binary(), #state{}) -> #state{}.
fs_result(_Uuid, <<"SUCCESS">>, S) ->
    S;
fs_result(Uuid, Cause, #state{dialing = D} = S) ->
    case D of
        #{{uuid, Uuid} := #{key := Key} = E} ->
            %% the call is over: nothing to hang up
            _ = cancel(E),
            final(Key, cause(Cause), drop_dial({uuid, Uuid}, S));
        #{} ->
            S
    end.

%% The helper's answer: a refused bgdial fails the REFER at once.
-spec fs_started(binary(), ok | {error, term()}, #state{}) -> #state{}.
fs_started(_Uuid, ok, S) ->
    S;
fs_started(Uuid, {error, _}, #state{dialing = D} = S) ->
    case D of
        #{{uuid, Uuid} := #{key := Key} = E} ->
            _ = cancel(E),
            final(Key, 503, drop_dial({uuid, Uuid}, S));
        #{} ->
            S
    end.

%% ---- REFER with method=REFER (RFC 4579 5.7) ----

%% The focus REFERs Target to NestedUri (the conference URI), outside any
%% dialog, as the focus, with the REFER's Referred-By (RFC 3892 2.2). A
%% helper sends it: its answer is the referrer's final status, and the
%% target's NOTIFYs come to the room as {refer, Key, {inner, Status}}.
-spec nested(term(), binary(), binary(), #state{}) -> #state{}.
nested(Key, Target, NestedUri, #state{entity = Entity, refer_ops = Ops} = S) ->
    Data = chappe_mrf_conf_refer_op:data(Key, Ops),
    Opts = #{
        from => <<"<", Entity/binary, ">">>,
        contact => Entity,
        contact_params => chappe_sip_focus:contact_params(),
        referred_by => maps:get(referred_by, Data, undefined)
    },
    Conf = self(),
    Pid = spawn_link(fun() ->
        nested_helper(
            Conf, Key, Target, NestedUri, maps:filter(fun known/2, Opts)
        )
    end),
    put_dial({helper, Pid}, #{key => Key}, S).

known(_K, V) -> V =/= undefined.

nested_helper(Conf, Key, Target, NestedUri, Opts) ->
    Mon = erlang:monitor(process, Conf),
    case chappe_sip_refer:send(Target, #{uri => NestedUri}, Opts) of
        {ok, Id, #{status := St, subscription := Sub}} ->
            Conf ! {refer, Key, {sent, St}},
            _ = Sub andalso follow(Conf, Key, Id, Mon),
            ok;
        {error, {rejected, St, _}} ->
            Conf ! {refer, Key, {sent, St}};
        {error, _} ->
            Conf ! {refer, Key, {sent, 503}}
    end.

%% the target's NOTIFYs about its INVITE to the conference
follow(Conf, Key, Id, Mon) ->
    receive
        {refer_progress, Id, St} ->
            Conf ! {refer, Key, {inner, St}},
            follow(Conf, Key, Id, Mon);
        {refer_done, Id, St} ->
            Conf ! {refer, Key, {inner, St}};
        {'DOWN', Mon, process, _, _} ->
            ok
    after ?NESTED_FOLLOW ->
        ok
    end.

%% The room's messages about its dial-outs: a dial's timer, a nested
%% REFER's news, the node's progress events of a dialed leg.
-spec info(term(), #state{}) -> {ok, #state{}} | ignore.
info({timeout, _, {refer_dial, DK}}, S) ->
    {ok, timeout(DK, S)};
info({refer, Key, Event}, S) ->
    {ok, event(Key, Event, S)};
info({chappe_esl_node, _Node, {event, Ev}}, S) ->
    node_event(Ev, S);
info(_Msg, _S) ->
    ignore.

%% A nested REFER's news: its answer ends the referrer's REFER; the
%% target's NOTIFYs are kept with the op.
event(Key, {sent, St}, S) when St >= 200 ->
    final(Key, St, S);
event(Key, {inner, St}, #state{refer_ops = Ops} = S) ->
    S#state{
        refer_ops = chappe_mrf_conf_refer_op:set_data(Key, #{inner => St}, Ops)
    };
event(_Key, _Ev, S) ->
    S.

%% ---- the room's side ----

%% A dial-out the target never answered: 408, and the dial is given up.
timeout(DK, #state{dialing = D} = S) ->
    case D of
        #{DK := #{answered := true}} -> S;
        #{DK := E} -> failed(DK, E#{timer => undefined}, 408, S);
        #{} -> S
    end.

%% A linked process ended: a dial helper that failed fails its REFER
%% (and gives its dial up); any other link is of no interest.
-spec exited(pid(), term(), #state{}) -> #state{}.
exited(Pid, Why, #state{dialing = D} = S) ->
    case D of
        #{{helper, Pid} := #{key := Key}} ->
            helper_done(Key, Why, drop_dial({helper, Pid}, S));
        #{} ->
            S
    end.

helper_done(_Key, normal, S) ->
    S;
helper_done(Key, _Why, #state{dialing = D} = S) ->
    case [DK || DK := #{key := K} <- D, K =:= Key] of
        [DK | _] -> failed(DK, maps:get(DK, D), 503, S);
        [] -> final(Key, 503, S)
    end.

%% A node event (chappe_esl:node_events/2) for one of this room's dials:
%% its 180 or 183, to the referrers. Others are not the room's.
node_event(Ev, #state{dial_tag = Tag} = S) ->
    H = fun(K) -> chappe_esl_event:header(K, Ev) end,
    case {H(<<"variable_chappe_dial">>), H(<<"Event-Name">>)} of
        {Tag, Name} when Tag =/= <<>> ->
            {ok, progress(op_of(H(<<"variable_chappe_dial_op">>), S), Name, S)};
        _ ->
            ignore
    end.

progress(undefined, _Name, S) ->
    S;
progress(Key, <<"CHANNEL_PROGRESS">>, S) ->
    chappe_mrf_conf_refer:progress(Key, 180, S);
progress(Key, <<"CHANNEL_PROGRESS_MEDIA">>, S) ->
    chappe_mrf_conf_refer:progress(Key, 183, S);
progress(_Key, _Name, S) ->
    S.

op_of(OpId, #state{refer_ops = Ops}) ->
    case
        [
            K
         || {K, #{op_id := I}} <- chappe_mrf_conf_refer_op:in_flight(Ops),
            I =:= OpId
        ]
    of
        [K | _] -> K;
        [] -> undefined
    end.

%% The room ends: every dial under way is given up (its channel hung up)
%% and its REFERs hear 487.
-spec cancel_all(#state{}) -> #state{}.
cancel_all(#state{dialing = D} = S) ->
    S1 = maps:fold(
        fun
            ({helper, _} = DK, _E, Acc) -> drop_dial(DK, Acc);
            (DK, E, Acc) -> failed(DK, E, 487, Acc)
        end,
        S,
        D
    ),
    lists:foldl(
        fun({Key, _}, Acc) -> final(Key, 487, Acc) end,
        S1,
        chappe_mrf_conf_refer_op:in_flight(S1#state.refer_ops)
    ).

%% ---- internal ----

final(Key, St, S) ->
    chappe_mrf_conf_refer:final(Key, St, S).

put_dial(DK, E, #state{dialing = D} = S) ->
    S#state{dialing = D#{DK => E}}.

drop_dial(DK, #state{dialing = D} = S) ->
    S#state{dialing = maps:remove(DK, D)}.

cancel(#{timer := T}) when is_reference(T) -> erlang:cancel_timer(T);
cancel(_E) -> ok.

%% the room takes the progress events of its dials on Node
watch_node({ok, Node}, #state{dial_nodes = Ns, dial_tag = Tag} = S) ->
    case lists:member(Node, Ns) of
        true ->
            S;
        false ->
            _ =
                try
                    chappe_esl:node_events(Node, #{
                        <<"variable_chappe_dial">> => Tag
                    })
                catch
                    exit:_ -> ok
                end,
            S#state{dial_nodes = [Node | Ns]}
    end;
watch_node(_, S) ->
    S.

timeout_ms(#state{dial = Cfg}) ->
    maps:get(timeout, Cfg, ?DIAL_TIMEOUT).

%% The status a failed bridge gives the referrer, from FreeSWITCH's cause.
status(Ev) ->
    Cause = chappe_mrf_lib:to_bin(
        first([
            chappe_esl_event:header(H, Ev)
         || H <- [
                <<"variable_originate_disposition">>,
                <<"variable_bridge_hangup_cause">>,
                <<"Hangup-Cause">>
            ]
        ])
    ),
    cause(Cause).

first([undefined | T]) -> first(T);
first([V | _]) -> V;
first([]) -> <<>>.

cause(<<"USER_BUSY">>) -> 486;
cause(<<"NO_ANSWER">>) -> 480;
cause(<<"NO_USER_RESPONSE">>) -> 480;
cause(<<"CALL_REJECTED">>) -> 603;
cause(<<"UNALLOCATED_NUMBER">>) -> 404;
cause(<<"NO_ROUTE_DESTINATION">>) -> 404;
cause(<<"ORIGINATOR_CANCEL">>) -> 487;
cause(<<"RECOVERY_ON_TIMER_EXPIRE">>) -> 408;
cause(_) -> 503.
