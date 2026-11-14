%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% REFER and a conference (RFC 4579, on chappe_sip_focus's REFER side):
%%
%% - a REFER to the room's URI asks the focus to bring a party in (5.5):
%%   the room dials it out and the referrer hears the outcome as NOTIFYs;
%%   with method=BYE in its Refer-To it asks the focus to remove the
%%   member with that URI (5.11). The room's refer_policy decides both.
%% - a member's REFER, in its dialog with the room, follows what the room
%%   told it it is: a room with focus => true answers its members with the
%%   conference URI and isfocus (RFC 4579 4.2), so its REFER is to a
%%   focus: add (5.5, with the Replaces the Refer-To carries on the INVITE
%%   to the party, 5.10) or remove (method=BYE, 5.11); in a room without
%%   it the REFER is an RFC 3515 transfer: the target takes the member's
%%   place, shown as {left, Member, transferred}, then {joined, Member,
%%   Info} with the target's URI.
%%
%% Dialing out: on native, an endpoint of the room's FreeSWITCH pool
%% (dial_endpoint options, create_endpoint/1's) joins the mixer, then
%% bridges to the target (the dial option makes the dial string, default
%% sofia/<dial_profile>/<target>); the referrer gets 200 once the target
%% answers. On fs, mod_conference dials the target into the room
%% (conference <room> bgdial), and the referrer gets 200 when it is in
%% (add-member, from the node's events: give the node CUSTOM
%% conference::maintenance, see chappe_mrf_conf:start/2). A target that
%% does not answer within dial_timeout (30 s) is given up with 408.
%%
%% The caller-side functions run in the REFER's request worker; the
%% others in the conference process, on its state.
-module(chappe_mrf_conf_refer).

-include("chappe_mrf_conf.hrl").

-export([refer/3, dial_native/4, focus/2, call/2]).
-export([fs_dial/3, remove/2, native_event/3, fs_added/3, timeout/2]).
-export([fs_result/3, fs_started/3, member_refer/4]).
-export([transferred/3, dial_string/2, dialing/4, dialable/1]).

-define(DIAL_TIMEOUT, 30000).

%% ---- in the REFER's request worker ----

%% A REFER to the room's URI (out of any dialog).
-spec refer(pid(), chappe_sip_req:req(), chappe_sip_res:res()) ->
    ok | {error, term()}.
refer(Conf, Req, Res) ->
    case chappe_mrf_conf:call(Conf, {refer, cfg}, 30000) of
        #{policy := Policy, backend := Backend} = Cfg ->
            case
                chappe_sip_focus:refer(undefined, Req, Res, #{
                    policy => guard(Policy, Cfg), owner => Conf
                })
            of
                {remove, Target, Refer} ->
                    Status =
                        case
                            chappe_mrf_conf:call(
                                Conf, {refer, {remove, Target}}, 30000
                            )
                        of
                            ok -> 200;
                            _ -> 404
                        end,
                    chappe_sip_refer:final(Refer, Status);
                {add, Target, Refer} when Backend =:= native ->
                    dial_native(Conf, Target, Refer, Cfg);
                {add, Target, Refer} ->
                    case
                        chappe_mrf_conf:call(
                            Conf, {refer, {dial, Target, Refer}}, 30000
                        )
                    of
                        ok -> ok;
                        {error, _} = Err -> fail(Refer, Err)
                    end;
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            _ = chappe_sip_res:send(Res, 404),
            Err
    end.

%% The room's policy behind the dial-string check: a party to add whose
%% URI FreeSWITCH would read as more than one destination is refused
%% 403 before the policy runs; otherwise the policy sees the dial string
%% it would run as `dial'.
guard(Policy, Cfg) ->
    fun
        (#{action := add, target := Target} = Info) ->
            case dialable(Target) of
                true ->
                    Policy(Info#{
                        dial => iolist_to_binary(dial_string(Cfg, Target))
                    });
                false ->
                    {reject, 403}
            end;
        (Info) ->
            Policy(Info)
    end.

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

%% chappe_mrf:focus_refer/2: the room the Request-URI's user names.
-spec focus(chappe_sip_req:req(), chappe_sip_res:res()) -> ok.
focus(Req, Res) ->
    Name =
        case chappe_sip_uri:parse(chappe_sip_req:uri(Req)) of
            {ok, #{user := U}} -> U;
            _ -> undefined
        end,
    case chappe_mrf_registry:lookup({conf, Name}) of
        {ok, Conf} ->
            _ = refer(Conf, Req, Res),
            ok;
        error ->
            _ = chappe_sip_res:send(Res, 404),
            ok
    end.

%% native: an endpoint joins the mixer, then bridges to the target.
-spec dial_native(pid(), binary(), chappe_sip_refer:refer(), map()) ->
    ok | {error, term()}.
dial_native(Conf, Target, Refer, #{endpoint := EpOpts} = Cfg) ->
    Ep0 = EpOpts#{owner => Conf, events => [{channel, <<"CHANNEL_BRIDGE">>}]},
    maybe
        true ?= dialable(Target) orelse {error, not_dialable},
        {ok, Ep} ?= chappe_mrf:create_endpoint(Ep0),
        {ok, Member} ?=
            joined(
                Ep,
                chappe_mrf_conf:join(Conf, Ep, #{name => Target, uri => Target})
            ),
        ok ?=
            chappe_mrf_conf:call(
                Conf, {refer, {dialing, Ep, Member, Refer}}, 30000
            ),
        ok ?= chappe_mrf:set(Ep, #{<<"hangup_after_bridge">> => <<"true">>}),
        Dial = [var_block(dial_vars(Cfg)), dial_string(Cfg, Target)],
        {ok, _} ?= chappe_mrf:execute(Ep, <<"bridge">>, Dial, #{wait => false}),
        ok
    else
        {error, _} = Err -> fail(Refer, Err)
    end.

joined(_Ep, {ok, _} = Ok) ->
    Ok;
joined(Ep, Err) ->
    _ = chappe_mrf:destroy(Ep),
    Err.

fail(Refer, Err) ->
    ok = chappe_sip_refer:final(Refer, 503),
    Err.

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

%% ---- in the conference process ----

%% The room's REFER requests, sent as {refer, Req}.
-spec call(term(), #state{}) -> {reply, term(), #state{}}.
call(cfg, S) ->
    Policy =
        case S#state.refer_policy of
            undefined -> fun(_) -> false end;
            P -> P
        end,
    Cfg = maps:merge(#{endpoint => #{}}, S#state.dial),
    {reply,
        Cfg#{
            policy => Policy,
            backend => S#state.backend,
            entity => S#state.entity
        },
        S};
call({remove, Target}, S) ->
    {Reply, S1} = remove(Target, S),
    {reply, Reply, S1};
call({dial, Target, Refer}, S) ->
    {Reply, S1} = fs_dial(Target, Refer, S),
    {reply, Reply, S1};
call({dialing, Ep, Id, Refer}, S) ->
    {reply, ok, dialing(Ep, Id, Refer, S)}.

%% native: the endpoint dialing Member's target, until it answers.
-spec dialing(pid(), binary(), chappe_sip_refer:refer(), #state{}) -> #state{}.
dialing(Ep, Id, Refer, #state{dialing = D} = S) ->
    Timer = erlang:start_timer(timeout_ms(S), self(), {refer_dial, {ep, Ep}}),
    S#state{
        dialing = D#{
            {ep, Ep} => #{refer => Refer, member => Id, timer => Timer}
        }
    }.

%% fs: mod_conference dials the target into the room, under a uuid of
%% ours, so its add-member is ours too.
-spec fs_dial(binary(), chappe_sip_refer:refer(), #state{}) ->
    {ok | {error, term()}, #state{}}.
fs_dial(Target, Refer, #state{dialing = D} = S) ->
    case dialable(Target) of
        true -> fs_dial(Target, Refer, D, S);
        false -> {{error, not_dialable}, S}
    end.

fs_dial(Target, Refer, D, #state{name = Name} = S) ->
    Uuid = chappe_mrf_lib:new_id(),
    Vars = dial_vars((S#state.dial)#{entity => S#state.entity}),
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
    Via = chappe_mrf_conf_fs:api_route(S),
    Conf = self(),
    _ = spawn_monitor(fun() -> Conf ! {refer_bgdial, Uuid, bgdial(Via, Cmd)} end),
    Timer = erlang:start_timer(
        timeout_ms(S), self(), {refer_dial, {uuid, Uuid}}
    ),
    Entry = #{refer => Refer, target => Target, timer => Timer},
    {ok, S#state{dialing = D#{{uuid, Uuid} => Entry}}}.

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

%% fs: the bgdial job did not start, or its call failed (bgdial-result
%% with another cause than SUCCESS): the referrer's final status.
-spec fs_failed(binary(), 300..699, #state{}) -> #state{}.
fs_failed(Uuid, Status, #state{dialing = D} = S) ->
    case maps:take({uuid, Uuid}, D) of
        {#{refer := R, timer := T}, D1} ->
            _ = erlang:cancel_timer(T),
            ok = chappe_sip_refer:final(R, Status),
            S#state{dialing = D1};
        error ->
            S
    end.

%% A bgdial-result for a party we dialed: SUCCESS waits for its
%% add-member; any other cause fails the REFER.
-spec fs_result(binary(), binary(), #state{}) -> #state{}.
fs_result(_Uuid, <<"SUCCESS">>, S) ->
    S;
fs_result(Uuid, Cause, S) ->
    fs_failed(Uuid, cause(Cause), S).

%% The helper's answer: a refused bgdial fails the REFER at once.
-spec fs_started(binary(), ok | {error, term()}, #state{}) -> #state{}.
fs_started(_Uuid, ok, S) ->
    S;
fs_started(Uuid, {error, _}, S) ->
    fs_failed(Uuid, 503, S).

%% The channel variables of the INVITE to a party the room dials: the
%% Replaces a REFER to the focus carries, as a header (RFC 4579 5.10),
%% and in a focus room the conference's user and isfocus in its Contact
%% (5.5). In FreeSWITCH's sofia (sofia_glue.c) sip_contact_user is the
%% Contact's user, and sip_invite_contact_params with a leading `~' adds
%% header parameters after the URI; the host stays the FreeSWITCH node's,
%% which holds that dialog.
-spec dial_vars(map()) -> [{binary(), binary()}].
dial_vars(Cfg) ->
    Rep =
        case Cfg of
            #{replaces := R} -> [{<<"sip_h_Replaces">>, R}];
            _ -> []
        end,
    Rep ++ focus_vars(maps:get(entity, Cfg, undefined)).

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

var_block([]) ->
    <<>>;
var_block(Vars) ->
    [
        <<"{">>,
        lists:join(<<",">>, [[K, <<"=">>, V] || {K, V} <- Vars]),
        <<"}">>
    ].

%% A member's REFER, in its dialog with the room (the room is its call's
%% notify process): chappe_sip_focus:refer/4 reads add, remove or transfer
%% from that dialog's Contact (isfocus or not), the room's policy decides,
%% and the room carries it out. A member the room does not know, or whose
%% dialog it cannot find, is refused 603.
-spec member_refer(
    reference(), chappe_sip_req:req(), chappe_sip_res:res(), #state{}
) ->
    #state{}.
member_refer(Ref, Req, Res, #state{members = M} = S) ->
    Member = [{Id, Mb} || Id := #{b2b := {_, R}} = Mb <- M, R =:= Ref],
    case {Member, chappe_mrf_registry:select({a_dialog, Ref, '_'})} of
        {[{Id, Mb} | _], [{{a_dialog, _, D}, _} | _]} ->
            {reply, Cfg, _} = call(cfg, S),
            #{policy := Policy} = Cfg,
            Opts = #{policy => guard(Policy, Cfg), owner => self()},
            case chappe_sip_focus:refer(D, Req, Res, Opts) of
                {error, _} -> S;
                Verdict -> carry_out(Verdict, Id, Mb, D, Cfg, S)
            end;
        _ ->
            _ = chappe_sip_res:send(Res, 603),
            S
    end.

carry_out({remove, Target, Refer}, _Id, _Mb, _D, _Cfg, S) ->
    {Reply, S1} = remove(Target, S),
    ok = chappe_sip_refer:final(Refer, removed(Reply)),
    S1;
carry_out({add, Target, Refer}, _Id, _Mb, _D, Cfg, S) ->
    case replaces(Refer) of
        {error, _} ->
            ok = chappe_sip_refer:final(Refer, 403),
            S;
        Rep ->
            Cfg1 = maps:merge(Cfg, Rep),
            add(Target, Refer, Cfg1, S)
    end;
carry_out({transfer, Target, Refer}, _Id, #{b2b := B2b}, D, _Cfg, S) ->
    %% the target takes the member's place on the call's leg A; the old
    %% member is handed back so the referrer hears the final NOTIFY first
    Conf = self(),
    {_, Ref} = B2b,
    _ = spawn(fun() ->
        case chappe_sip_b2b:replace_leg(B2b, a, Target, #{keep_old => true}) of
            {error, _} ->
                ok = chappe_sip_refer:final(Refer, 503);
            _ ->
                ok = chappe_sip_refer:final(Refer, 200),
                ok = gen_server:cast(
                    Conf, {transferred, Ref, #{target => Target}}
                ),
                chappe_mrf_lib:destroy_dialog(D)
        end
    end),
    S.

removed(ok) -> 200;
removed(_) -> 404.

%% The Replaces of a REFER's Refer-To, as an INVITE header value, safe in
%% a FreeSWITCH variable; none, or {error, _} for one that is not.
replaces(Refer) ->
    case maps:get(replaces, chappe_sip_refer:target(Refer), undefined) of
        undefined ->
            #{};
        R ->
            V = chappe_sip_hdr:replaces_value(R),
            case dialable(V) of
                true -> #{replaces => V};
                false -> {error, replaces}
            end
    end.

%% Bring Target into the room: native dials it from an endpoint (in a
%% helper: it waits for the endpoint), fs has mod_conference dial it.
add(Target, Refer, #{backend := native} = Cfg, S) ->
    Conf = self(),
    _ = spawn(fun() -> dial_native(Conf, Target, Refer, Cfg) end),
    S;
add(Target, Refer, Cfg, S) ->
    Dial = S#state.dial,
    case
        fs_dial(Target, Refer, S#state{
            dial = maps:merge(Dial, maps:with([replaces], Cfg))
        })
    of
        {ok, S1} ->
            S1#state{dial = Dial};
        {{error, _} = Err, S1} ->
            _ = fail(Refer, Err),
            S1#state{dial = Dial}
    end.

%% REFER with method=BYE: the member with that URI is removed.
-spec remove(binary(), #state{}) -> {ok | {error, not_found}, #state{}}.
remove(Target, #state{members = M} = S) ->
    case [Id || Id := #{uri := U} <- M, same_uri(U, Target)] of
        [Id | _] ->
            {reply, ok, S1} = chappe_mrf_conf:drop_member(Id, kicked, S),
            {ok, S1};
        [] ->
            {{error, not_found}, S}
    end.

same_uri(A, B) when is_binary(A), is_binary(B) ->
    case {chappe_sip_uri:parse(A), chappe_sip_uri:parse(B)} of
        {{ok, UA}, {ok, UB}} ->
            maps:with([user, host, port], UA) =:=
                maps:with([user, host, port], UB);
        _ ->
            A =:= B
    end;
same_uri(_, _) ->
    false.

%% native: the dialed endpoint's news. The target answered (the bridge
%% is up): 200. The bridge ended before that: the target's status, and the
%% member goes.
-spec native_event(pid(), term(), #state{}) -> #state{}.
native_event(Ep, Event, #state{dialing = D} = S) ->
    case {maps:take({ep, Ep}, D), Event} of
        {{#{refer := R, timer := T}, D1}, {channel, <<"CHANNEL_BRIDGE">>, _}} ->
            _ = erlang:cancel_timer(T),
            ok = chappe_sip_refer:final(R, 200),
            S#state{dialing = D1};
        {
            {#{refer := R, timer := T, member := Id}, D1},
            {complete, <<"bridge">>, Ev}
        } ->
            _ = erlang:cancel_timer(T),
            ok = chappe_sip_refer:final(R, status(Ev)),
            drop_dialed(Id, S#state{dialing = D1});
        {{#{refer := R, timer := T}, D1}, {hangup, _}} ->
            _ = erlang:cancel_timer(T),
            ok = chappe_sip_refer:final(R, 487),
            S#state{dialing = D1};
        _ ->
            S
    end.

%% fs: the dialed target is in the room.
-spec fs_added(binary(), binary(), #state{}) -> #state{}.
fs_added(Uuid, Id, #state{dialing = D, members = M} = S) ->
    case maps:take({uuid, Uuid}, D) of
        {#{refer := R, timer := T, target := Target}, D1} ->
            _ = erlang:cancel_timer(T),
            ok = chappe_sip_refer:final(R, 200),
            Mb = chappe_mrf_conf:member(
                #{name => Target, uri => Target}, Id, #{
                    dialed => Uuid
                }
            ),
            S1 = S#state{dialing = D1, members = M#{Id => Mb}},
            chappe_mrf_conf:publish(
                chappe_mrf_conf:emit(
                    {joined, Id, chappe_mrf_conf:public(Id, Mb)}, S1
                )
            );
        error ->
            S
    end.

%% A dial-out the target never answered.
-spec timeout(term(), #state{}) -> #state{}.
timeout(Key, #state{dialing = D} = S) ->
    case maps:take(Key, D) of
        {#{refer := R} = E, D1} ->
            ok = chappe_sip_refer:final(R, 408),
            S1 = S#state{dialing = D1},
            case {Key, E} of
                {{ep, _}, #{member := Id}} ->
                    drop_dialed(Id, S1);
                {{uuid, Uuid}, _} ->
                    _ = chappe_mrf_conf_fs:api_raw(
                        [<<"uuid_kill ">>, Uuid], S1
                    ),
                    S1
            end;
        error ->
            S
    end.

drop_dialed(Id, S) ->
    case S#state.members of
        #{Id := _} ->
            {reply, ok, S1} = chappe_mrf_conf:drop_member(Id, departed, S),
            S1;
        _ ->
            S
    end.

timeout_ms(#state{dial = Cfg}) ->
    maps:get(timeout, Cfg, ?DIAL_TIMEOUT).

%% A member's call was transferred: the target took the member's place on
%% the room's leg. The room sees the member leave (transferred), then the
%% target join under the same id.
-spec transferred(reference(), map(), #state{}) -> #state{}.
transferred(Ref, Info, #state{members = M} = S) ->
    case [Id || Id := #{b2b := {_, R}} <- M, R =:= Ref] of
        [Id | _] ->
            S1 = chappe_mrf_conf:emit({left, Id, transferred}, S),
            Target = maps:get(target, Info, undefined),
            Mb = (maps:get(Id, M))#{name => name(Target, Id), uri => Target},
            S2 = S1#state{members = M#{Id := Mb}},
            chappe_mrf_conf:publish(
                chappe_mrf_conf:emit(
                    {joined, Id, chappe_mrf_conf:public(Id, Mb)}, S2
                )
            );
        [] ->
            S
    end.

name(undefined, Id) -> Id;
name(Target, _Id) -> Target.

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
cause(_) -> 503.
