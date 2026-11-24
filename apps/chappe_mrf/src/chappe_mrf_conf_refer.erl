%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc REFER and a conference (RFC 4579, on chappe_sip_focus's REFER
%% side). A REFER reaches a room two ways:
%%
%% - to the room's URI, outside any dialog (chappe_mrf:focus_refer/2, the
%%   room the Request-URI's user names);
%% - from a member, in its dialog with the room: a room with focus => true
%%   answers its members with the conference URI and isfocus (RFC 4579
%%   4.2), so a member's REFER is to the focus too. In a room without it
%%   a member's REFER is an RFC 3515 transfer of that member: the target
%%   takes the member's place, shown as {left, Member, transferred}, then
%%   {joined, Member, Info} with the target's URI.
%%
%% A REFER to the focus asks, by its Refer-To method (chappe_sip_focus:
%% refer_info/2): INVITE (add), to bring the target in (5.5), with the
%% Replaces the Refer-To carries on the INVITE to it (5.10); BYE (remove),
%% to remove a member (5.11); REFER (refer), to have the target REFERred
%% to the conference (5.7). The room checks, in this order, and answers
%% the REFER only then:
%%
%%   1. the room owns its name (cluster lease), else 503;
%%   2. what the REFER asks for: a target safe in a FreeSWITCH dial string
%%      (else 403); removal and REFER for a REFER are a focus's (403 in a
%%      room without focus => true); the Refer-To of a REFER for a REFER
%%      is a plain reference to this room, and no party is the room
%%      itself (else 403: either could loop);
%%   3. room for one more (add and refer): a locked room 403, a full one
%%      486, the parties being dialed counting as members (the same check
%%      as join/3's, chappe_mrf_conf_backend:admission/1);
%%   4. the room's refer_policy, given chappe_sip_focus:refer_info/2's map
%%      plus member (the referrer's member id, from its dialog or the
%%      dialog its Target-Dialog names, else undefined), dial (add: the
%%      dial string it would run) and removes (remove: the member it
%%      names): false is 403, {reject, Code} is Code, and no policy
%%      refuses every REFER;
%%   5. for a removal, the member: the one whose endpoint entity
%%      (<conference URI>;member=Id) the Refer-To is, else the one member
%%      with that address-of-record; none is 404, more than one 485.
%%      Only this room's members are looked at.
%%
%% Then the REFER is answered 200 (with the conference URI and isfocus as
%% Contact in a focus room) and NOTIFY 100, and carried out
%% (chappe_mrf_conf_refer_dial). A repeated REFER (the same origin, method
%% and target, chappe_mrf_conf_refer_op) dials nobody again: it hears the
%% first one's outcome. Adding a member that is already in answers 200 at
%% once. A party being dialed is no member until it answered; a dial that
%% fails leaves the room as it was. When the room ends, the REFERs still
%% under way hear 487 and their dials are given up.
%%
%% The caller-side functions run in the REFER's request worker; the
%% others in the conference process, on its state.
-module(chappe_mrf_conf_refer).

-include("chappe_mrf_conf.hrl").

-export([refer/3, focus/2, b2b_event/2, setup/2, call/2, stop/1]).
-export([member_opts/2, keep_dialog/2, from_uri/1]).
-export([admission/2, info/2, progress/3, final/3]).
%% for a member's side (chappe_mrf_conf_refer_member)
-export([decide/2, start/3, policy/2, member_of/2, reject/3]).
%% the backends' events about a dial (chappe_mrf_conf_refer_dial)
-export([native_event/3, fs_added/3, fs_result/3, fs_started/3]).

%% ---- in the REFER's request worker ----

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

%% A REFER to the room's URI (out of any dialog): the room decides, then
%% the REFER is answered here and handed to the room, which owns its
%% subscription.
-spec refer(pid(), chappe_sip_req:req(), chappe_sip_res:res()) ->
    ok | {error, term()}.
refer(Conf, Req, Res) ->
    case chappe_sip_focus:refer_info(undefined, Req) of
        {reject, St, Reason} ->
            reject(Res, St, Reason);
        {ok, Info} ->
            case chappe_mrf_conf:call(Conf, {refer, {decide, Info}}, 30000) of
                {accept, Key, AOpts} ->
                    accept_out(Conf, Key, AOpts, Req, Res);
                {reject, St} ->
                    reject(Res, St, <<>>);
                {error, _} = Err ->
                    %% lost (the region took the name back), or gone
                    _ = reject(Res, 503, <<>>),
                    Err
            end
    end.

accept_out(Conf, Key, AOpts, Req, Res) ->
    Opts = AOpts#{owner => Conf, authorize => fun(_, _) -> true end},
    case chappe_sip_refer:accept(Req, Res, Opts) of
        {ok, Refer} ->
            case
                chappe_mrf_conf:call(Conf, {refer, {start, Key, Refer}}, 30000)
            of
                ok ->
                    ok;
                Err ->
                    ok = chappe_sip_refer:final(Refer, 503),
                    Err
            end;
        {error, _} = Err ->
            _ = chappe_mrf_conf:call(Conf, {refer, {abort, Key}}, 5000),
            Err
    end.

-spec reject(chappe_sip_res:res(), 300..699, binary()) ->
    {error, {rejected, 300..699}}.
reject(Res, St, Reason) ->
    _ = chappe_sip_res:send(Res, St, reason(Reason)),
    {error, {rejected, St}}.

reason(<<>>) -> #{};
reason(R) -> #{reason => R}.

%% A B2BUA event of a member's call the app hands the room
%% (chappe_mrf_conf:b2b_event/2): a transfer, or a member's REFER.
-spec b2b_event(pid(), term()) -> ok.
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
b2b_event(Conf, {chappe_sip_b2b, Ref, {refer, Info}} = M) when
    is_reference(Ref), is_map(Info)
->
    %% a call with transfer => notify whose notify process is the app's
    Conf ! M,
    ok;
b2b_event(_Conf, _Event) ->
    ok.

%% The REFER side of the room's messages: a member's REFER in its dialog
%% (requests => [refer]), a member's transfer to decide (transfer =>
%% notify) and its outcome, and the dial-outs'
%% (chappe_mrf_conf_refer_dial:info/2).
-spec info(term(), #state{}) -> {ok, #state{}} | ignore.
info({chappe_sip_b2b, Ref, {request, _Leg, refer, Req, Res}}, S) ->
    {ok, chappe_mrf_conf_refer_member:member_refer(Ref, Req, Res, S)};
info({chappe_sip_b2b, Ref, {refer, Info}}, S) ->
    {ok, chappe_mrf_conf_refer_member:transfer(Ref, Info, S)};
info({chappe_sip_b2b, Ref, {transferred, _Leg, Info}}, S) ->
    {ok, chappe_mrf_conf_refer_member:transferred(Ref, Info, S)};
info(Msg, S) ->
    chappe_mrf_conf_refer_dial:info(Msg, S).

%% ---- in the conference process ----

%% The REFER settings of start/2's options: the policy, and how a target
%% is dialed.
-spec setup(map(), #state{}) -> #state{}.
setup(Opts, S) ->
    Dial = maps:from_list(
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
    ),
    S#state{
        refer_policy = maps:get(refer_policy, Opts, undefined),
        dial = Dial,
        dial_tag = chappe_mrf_lib:new_id()
    }.

%% The room's REFER requests, sent as {refer, Req}.
-spec call(term(), #state{}) -> {reply, term(), #state{}}.
call({decide, Info}, S) ->
    case decide(Info, S) of
        {accept, Key, S1} -> {reply, {accept, Key, accept_opts(S1)}, S1};
        {reject, St} -> {reply, {reject, St}, S}
    end;
call({start, Key, Refer}, S) ->
    {reply, ok, start(Key, Refer, S)};
call({abort, Key}, #state{refer_ops = Ops} = S) ->
    {reply, ok, S#state{refer_ops = chappe_mrf_conf_refer_op:abort(Key, Ops)}};
call({dialing, Key, Ep}, S) ->
    {Reply, S1} = chappe_mrf_conf_refer_dial:dialing(Key, Ep, S),
    {reply, Reply, S1};
call({leg, Pid}, S) ->
    {reply, member_of(Pid, S), S};
call({replaced, Old, New}, S) ->
    {reply, ok, chappe_mrf_conf_refer_member:replaced(Old, New, S)};
call(_Req, S) ->
    {reply, {error, unknown_call}, S}.

%% Whether a join may come in (chappe_mrf_conf's {join, Req}): the party
%% a REFER brought in (its endpoint, for the op it dials for) was admitted
%% with the REFER; anyone else goes through
%% chappe_mrf_conf_backend:admission/1.
-spec admission(term(), #state{}) -> ok | {error, term()}.
admission({ep, Ep, #{refer := Key}}, #state{dialing = D}) ->
    case D of
        #{{ep, Ep} := #{key := Key}} -> ok;
        #{} -> {error, not_dialing}
    end;
admission(_Req, S) ->
    chappe_mrf_conf_backend:admission(S).

%% the accept options of a REFER to the room's URI: a focus room's
%% subscription has the conference's Contact (RFC 4579 4.2)
accept_opts(#state{entity = undefined}) -> #{};
accept_opts(#state{entity = E}) -> #{contact => chappe_sip_focus:contact(E)}.

%% ---- the decision ----

%% What the room makes of a REFER (refer_info/2's map, with member when
%% the caller knows it): {accept, Key, S} with the op reserved (or a
%% repeat to attach), or {reject, Status}.
-spec decide(map(), #state{}) ->
    {accept, term(), #state{}} | {reject, 300..699}.
decide(Info0, S) ->
    Info = Info0#{member => maps:get(member, Info0, referrer(Info0, S))},
    case check(Info, S) of
        {reject, _} = Rej ->
            Rej;
        {Kind, Key, Data} ->
            case policy(maps:merge(Info, policy_info(Kind, Data)), S) of
                true -> admit(Kind, Key, Data, S);
                {reject, Code} -> {reject, Code};
                false -> {reject, 403}
            end
    end.

%% what the policy sees besides refer_info/2's map: the dial string of a
%% party to add, the member a removal names
policy_info(_Kind, #{dial := Dial}) -> #{dial => Dial};
policy_info(remove, #{member := Id}) -> #{removes => Id};
policy_info(_Kind, _Data) -> #{}.

%% what the REFER asks for, checked against the room: {Kind, Key, Data}
%% with Kind repeat (an op under way or done), existing (the target is a
%% member), new, remove, or unresolved (a removal naming no one member)
check(#{action := Action} = Info, S) ->
    case focus_only(Action, S) of
        ok -> check_action(Action, Info, S);
        Rej -> Rej
    end.

focus_only(Action, #state{entity = undefined}) when
    Action =:= remove; Action =:= refer
->
    %% RFC 4579 5.11 and 5.7: a focus's (RFC 3515 2.4.2 leaves the 4xx-6xx
    %% to RFC 3261)
    {reject, 403};
focus_only(transfer, _S) ->
    %% a member of a room that is no focus transfers through its call
    {reject, 403};
focus_only(_Action, _S) ->
    ok.

check_action(add, #{target := Target} = Info, S) ->
    case
        chappe_mrf_conf_refer_dial:dialable(Target) andalso
            not is_room(Target, S)
    of
        false ->
            %% hostile to a dial string, or the room itself (a loop)
            {reject, 403};
        true ->
            Key = key(Info),
            case known(Key, S) of
                true -> {repeat, Key, #{}};
                false -> add_kind(Key, Target, Info, S)
            end
    end;
check_action(remove, #{target := Target} = Info, S) ->
    Key = key(Info),
    case resolve(Target, S) of
        {ok, Id} -> {remove, Key, #{member => Id}};
        {error, St} -> {unresolved, Key, #{status => St}}
    end;
check_action(refer, #{target := Target, nested := Nested} = Info, S) ->
    case plain_room(Nested, S) andalso not is_room(Target, S) of
        false ->
            %% a focus refers parties to its own conference only, with a
            %% plain Refer-To (an INVITE, no headers), and never itself:
            %% anything else could have it REFER itself in a loop
            {reject, 403};
        true ->
            Key = key(Info),
            case {known(Key, S), admission(S)} of
                {true, _} -> {repeat, Key, #{}};
                {false, ok} -> {new, Key, data(refer, Target, Info, S)};
                {false, {error, Why}} -> {reject, admission_status(Why)}
            end
    end.

%% whether a URI is the room's own (its conference URI)
is_room(_Uri, #state{entity = undefined}) ->
    false;
is_room(Uri, #state{entity = E}) ->
    chappe_mrf_conf_refer_op:aor(Uri) =:= chappe_mrf_conf_refer_op:aor(E).

plain_room(#{uri := U, method := <<"INVITE">>, headers := []}, S) ->
    is_room(U, S);
plain_room(_Nested, _S) ->
    false.

add_kind(Key, Target, Info, #state{members = M} = S) ->
    Aor = chappe_mrf_conf_refer_op:aor(Target),
    case
        [Id || Id := #{uri := U} <- M, chappe_mrf_conf_refer_op:aor(U) =:= Aor]
    of
        [_ | _] ->
            %% in already: nobody is dialed
            {existing, Key, #{action => add, target => Target}};
        [] ->
            case admission(S) of
                ok -> {new, Key, data(add, Target, Info, S)};
                {error, Why} -> {reject, admission_status(Why)}
            end
    end.

admission(S) ->
    chappe_mrf_conf_backend:admission(S).

admission_status(locked) -> 403;
admission_status(full) -> 486.

key(#{origin := Origin, method := M, target := Target}) ->
    chappe_mrf_conf_refer_op:key(Origin, M, Target).

known(Key, #state{refer_ops = Ops}) ->
    chappe_mrf_conf_refer_op:lookup(Key, Ops) =/= none.

%% what an op needs to carry the REFER out
data(Action, Target, Info, S) ->
    Base = #{
        action => Action, target => Target, op_id => chappe_mrf_lib:new_id()
    },
    D = maps:merge(Base, dial_headers(Info)),
    case Action of
        add ->
            Cfg = dial_cfg(S, D),
            D#{
                dial => iolist_to_binary(
                    chappe_mrf_conf_refer_dial:dial_string(Cfg, Target)
                )
            };
        refer ->
            #{nested := #{uri := N}} = Info,
            D#{nested => N}
    end.

%% the Referred-By the dialed INVITE (or the nested REFER) carries, as a
%% bare URI safe in a FreeSWITCH variable (RFC 3892 2.2 wants it copied;
%% only its URI survives the dial string), and the Replaces of the
%% Refer-To (RFC 4579 5.10), safe there too
dial_headers(#{referred_by := RB} = Info) when is_binary(RB) ->
    By =
        case chappe_sip_hdr:name_addr(RB) of
            {ok, #{uri := U}} ->
                case chappe_mrf_conf_refer_dial:dialable(U) of
                    true -> #{referred_by => <<"<", U/binary, ">">>};
                    false -> #{}
                end;
            _ ->
                #{}
        end,
    maps:merge(By, replaces(Info));
dial_headers(Info) ->
    replaces(Info).

replaces(#{replaces := R}) when R =/= undefined ->
    V = chappe_sip_hdr:replaces_value(R),
    case chappe_mrf_conf_refer_dial:dialable(V) of
        true -> #{replaces => V};
        false -> #{}
    end;
replaces(_Info) ->
    #{}.

%% the room's dial options with what the REFER asked for
dial_cfg(#state{dial = Dial, entity = E}, Data) ->
    Base = maps:merge(#{endpoint => #{}}, Dial#{entity => E}),
    maps:merge(Base, maps:with([replaces, referred_by], Data)).

%% The room's policy; without one every REFER is refused.
-spec policy(map(), #state{}) -> true | false | {reject, 300..699}.
policy(_Info, #state{refer_policy = undefined}) ->
    false;
policy(Info, #state{refer_policy = P}) ->
    case P(Info) of
        true ->
            true;
        {reject, Code} when is_integer(Code), Code >= 300, Code =< 699 ->
            {reject, Code};
        _ ->
            false
    end.

%% the policy said yes: an op is reserved (a repeat attaches when it is
%% accepted; a removal naming no one member is refused now)
admit(repeat, Key, _Data, S) ->
    {accept, Key, S};
admit(unresolved, _Key, #{status := St}, _S) ->
    {reject, St};
admit(Kind, Key, Data, #state{refer_ops = Ops} = S) ->
    case chappe_mrf_conf_refer_op:reserve(Key, Data#{kind => Kind}, Ops) of
        {ok, Ops1} -> {accept, Key, S#state{refer_ops = Ops1}};
        {error, full} -> {reject, 503}
    end.

%% The member whose call's leg A (its dialog with the room) is dialog
%% process Pid, or undefined.
-spec member_of(pid(), #state{}) -> binary() | undefined.
member_of(Pid, #state{members = M}) ->
    case
        [
            Id
         || Id := #{b2b := {_, Ref}} <- M,
            {{a_dialog, _, D}, _} <- chappe_mrf_registry:select(
                {a_dialog, Ref, '_'}
            ),
            chappe_sip_dialog:pid(D) =:= Pid
        ]
    of
        [Id | _] -> Id;
        [] -> undefined
    end.

%% The member the referrer is: the one whose call the dialog its
%% Target-Dialog names belongs to (RFC 4538: proof it knows that call).
referrer(#{target_dialog := TD}, S) when TD =/= undefined ->
    member_of(chappe_sip_dialog:pid(TD), S);
referrer(_Info, _S) ->
    undefined.

%% The member a REFER with method=BYE names: by its endpoint entity, else
%% the one member with that address-of-record.
-spec resolve(binary(), #state{}) -> {ok, binary()} | {error, 404 | 485}.
resolve(Target, #state{members = M, entity = E}) ->
    case by_entity(Target, E, M) of
        {ok, Id} ->
            {ok, Id};
        error ->
            Aor = chappe_mrf_conf_refer_op:aor(Target),
            case
                [
                    Id
                 || Id := #{uri := U} <- M,
                    chappe_mrf_conf_refer_op:aor(U) =:= Aor
                ]
            of
                [Id] -> {ok, Id};
                [] -> {error, 404};
                [_, _ | _] -> {error, 485}
            end
    end.

%% <conference URI>;member=Id (chappe_mrf_conf_focus's endpoint entity)
by_entity(Target, E, M) when is_binary(E) ->
    case chappe_sip_uri:parse(Target) of
        {ok, #{params := #{<<"member">> := Id}}} when is_map_key(Id, M) ->
            case
                chappe_mrf_conf_refer_op:aor(Target) =:=
                    chappe_mrf_conf_refer_op:aor(E)
            of
                true -> {ok, Id};
                false -> error
            end;
        _ ->
            error
    end;
by_entity(_Target, _E, _M) ->
    error.

%% ---- carrying it out ----

%% The REFER of Key was accepted: the first one carries the op out, a
%% repeat hears what it heard.
-spec start(term(), chappe_sip_refer:refer(), #state{}) -> #state{}.
start(Key, Refer, #state{refer_ops = Ops} = S) ->
    case chappe_mrf_conf_refer_op:lookup(Key, Ops) of
        {reserved, Data0} ->
            %% the <referred> of the party it brings in (RFC 4575 5.7.2)
            Data = Data0#{referred => chappe_sip_focus:referred(Refer)},
            Ops1 = chappe_mrf_conf_refer_op:set_data(
                Key, Data, chappe_mrf_conf_refer_op:start(Key, Refer, Ops)
            ),
            carry_out(Key, Data, S#state{refer_ops = Ops1});
        _ ->
            S#state{
                refer_ops = chappe_mrf_conf_refer_op:attach(Key, Refer, Ops)
            }
    end.

carry_out(Key, #{kind := existing}, S) ->
    final(Key, 200, S);
carry_out(Key, #{kind := remove, member := Id}, #state{members = M} = S) ->
    case M of
        #{Id := _} ->
            {reply, ok, S1} = chappe_mrf_conf_backend:drop_member(
                Id, kicked, S
            ),
            final(Key, 200, S1);
        #{} ->
            final(Key, 404, S)
    end;
carry_out(Key, #{kind := new, action := refer, target := T, nested := N}, S) ->
    chappe_mrf_conf_refer_dial:nested(Key, T, N, S);
carry_out(Key, #{kind := new, action := add, target := T} = Data, S) ->
    Cfg = dial_cfg(S, Data),
    Dialed = chappe_mrf_conf_backend:supported(dial, 4, S, fun(Mod) ->
        {Reply, S1} = Mod:dial(T, Key, Cfg, S),
        {reply, Reply, S1}
    end),
    case Dialed of
        {reply, ok, S1} -> S1;
        {reply, {error, _}, S1} -> final(Key, 503, S1)
    end.

%% A provisional status of the referenced request, to the REFERs of Key.
-spec progress(term(), 101..199, #state{}) -> #state{}.
progress(Key, St, #state{refer_ops = Ops} = S) ->
    S#state{refer_ops = chappe_mrf_conf_refer_op:progress(Key, St, Ops)}.

%% The final status of the referenced request, to the REFERs of Key.
-spec final(term(), 200..699, #state{}) -> #state{}.
final(Key, St, #state{refer_ops = Ops} = S) ->
    S#state{refer_ops = chappe_mrf_conf_refer_op:final(Key, St, Ops)}.

%% The room ends: the REFERs under way hear 487, their dials stop.
-spec stop(#state{}) -> #state{}.
stop(S) ->
    chappe_mrf_conf_refer_dial:cancel_all(S).

%% ---- the backends' events ----

-spec native_event(pid(), term(), #state{}) -> #state{}.
native_event(Ep, Event, S) ->
    chappe_mrf_conf_refer_dial:native_event(Ep, Event, S).

-spec fs_added(binary(), binary(), #state{}) -> #state{}.
fs_added(Uuid, Id, S) ->
    chappe_mrf_conf_refer_dial:fs_added(Uuid, Id, S).

-spec fs_result(binary(), binary(), #state{}) -> #state{}.
fs_result(Uuid, Cause, S) ->
    chappe_mrf_conf_refer_dial:fs_result(Uuid, Cause, S).

-spec fs_started(binary(), ok | {error, term()}, #state{}) -> #state{}.
fs_started(Uuid, Result, S) ->
    chappe_mrf_conf_refer_dial:fs_started(Uuid, Result, S).

%% ---- members ----

%% The create_b2bua/4 options of a caller the room answers itself. A
%% focus room answers with the conference URI and isfocus as the member's
%% Contact (RFC 4579 4.2) and takes the REFERs in that dialog
%% (member_refer/4); a room without focus has the call carry its
%% transfers out once the room said yes (transfer => notify).
-spec member_opts(pid(), binary() | undefined) -> map().
member_opts(Conf, undefined) ->
    #{transfer => notify, notify => Conf};
member_opts(Conf, Entity) ->
    Contact = chappe_sip_focus:contact(Entity),
    #{
        requests => [refer],
        notify => Conf,
        a_headers => chappe_sip_focus:headers(Contact)
    }.

%% Keep a call's dialog with the caller (leg A) for as long as the call
%% runs, so a REFER it hands a room can be answered in that dialog.
-spec keep_dialog(chappe_sip_b2b:b2b(), chappe_sip_b2b:legs()) -> ok.
keep_dialog({Pid, Ref}, #{uas := Uas}) ->
    _ = chappe_mrf_registry:put({a_dialog, Ref, Uas}, Pid),
    ok.

%% Who a caller is, for a REFER's method=BYE: the URI it calls from.
-spec from_uri(chappe_sip_req:req()) -> binary() | undefined.
from_uri(Req) ->
    case chappe_sip_hdr:name_addr(chappe_sip_req:get(<<"from">>, Req)) of
        {ok, #{uri := U}} -> U;
        _ -> undefined
    end.
