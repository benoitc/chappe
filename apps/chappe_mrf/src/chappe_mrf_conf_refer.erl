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
%%   3. the room's refer_policy, given chappe_sip_focus:refer_info/2's map
%%      plus member (the referrer's member id, from its dialog or the
%%      dialog its Target-Dialog names), dial (add: the dial string it
%%      would run, made by the room's dial fun; one that crashes is 403,
%%      logged) and removes (remove: the member it names), every key
%%      there for every action (undefined when it does not apply): false
%%      is 403, {reject, Code} is Code, a policy that crashes is 403 (and
%%      logged), and no policy refuses every REFER;
%%   4. only then the room's state, so a refused referrer learns nothing
%%      of it: for a removal the member (the one whose endpoint entity,
%%      `<conference URI>;member=Id', the Refer-To is, else the one member
%%      with that address-of-record; none is 404, more than one 485, only
%%      this room's members looked at), and room for one more (add and
%%      refer: a locked room 403, a full one 486, the parties being
%%      dialed counting as members, chappe_mrf_conf_backend:admission/1).
%%
%% Then the REFER is answered 200 (with the conference URI and isfocus as
%% Contact in a focus room) and NOTIFY 100, and carried out
%% (chappe_mrf_conf_refer_dial). A repeated REFER (the same origin, method
%% and target, chappe_mrf_conf_refer_op), or one from another origin for
%% a party being dialed already, dials nobody again: it hears the first
%% one's outcome. Adding a member that is already in answers 200 at once.
%% An op reserved for a REFER lives until one of the workers waiting on
%% it (the first one's, and those of the REFERs attached to it) starts
%% it; a worker that dies, or cannot accept its REFER, gives up its own
%% part only, and the op goes with the last one.
%% A party being dialed is no member until it answered; a dial that
%% fails leaves the room as it was. When the room ends, the REFERs still
%% under way hear 487 and their dials are given up.
%%
%% The caller-side functions run in the REFER's request worker; the
%% others in the conference process, on its state.
-module(chappe_mrf_conf_refer).

-include("chappe_mrf_conf.hrl").

-export([refer/3, focus/2, b2b_event/2, setup/2, call/2, stop/1]).
-export([admission/2, info/2, progress/3, final/3]).
%% for a member's side (chappe_mrf_conf_refer_member)
-export([decide/2, start/3, abort/3, policy/2, member_of/2, reject/3]).
-export([policy_view/1, down/2, guarded/4]).
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
        {ok, Info0} ->
            %% the URI it was sent to is the room's too (a room without
            %% focus has no entity)
            Info = Info0#{room_uri => chappe_sip_req:uri(Req)},
            Decide = {refer, {decide, Info, self()}},
            case chappe_mrf_conf:call(Conf, Decide, 30000) of
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
            Abort = {refer, {abort, Key, self()}},
            _ = chappe_mrf_conf:call(Conf, Abort, 5000),
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
info({timeout, _, {refer_replace, Id, Hold}}, S) ->
    {ok, chappe_mrf_conf_refer_member:unhold(Id, Hold, S)};
info(Msg, S) ->
    chappe_mrf_conf_refer_dial:info(Msg, S).

%% ---- in the conference process ----

%% The REFER settings of start/2's options: the policies (REFERs, and a
%% call's Replaces of a member), and how a target is dialed.
-spec setup(map(), #state{}) -> #state{}.
setup(Opts, S) ->
    Dial = maps:from_list(
        [
            {K, V}
         || {O, K} <- [
                {dial, dial},
                {dial_profile, profile},
                {dial_codecs, codecs},
                {dial_timeout, timeout},
                {dial_endpoint, endpoint}
            ],
            {ok, V} <- [maps:find(O, Opts)]
        ]
    ),
    S#state{
        refer_policy = maps:get(refer_policy, Opts, undefined),
        replaces_policy = maps:get(replaces_policy, Opts, undefined),
        dial = Dial,
        dial_tag = chappe_mrf_lib:new_id()
    }.

%% The room's REFER requests, sent as {refer, Req}.
-spec call(term(), #state{}) -> {reply, term(), #state{}}.
call({decide, Info, Worker}, S) ->
    %% the worker that will accept the REFER is watched until it starts
    %% or aborts the op it reserves
    case decide(Info, Worker, S) of
        {accept, Key, S1} -> {reply, {accept, Key, accept_opts(S1)}, S1};
        {reject, St} -> {reply, {reject, St}, S}
    end;
call({start, Key, Refer}, S) ->
    {reply, ok, start(Key, Refer, S)};
call({abort, Key, Worker}, S) ->
    {reply, ok, abort(Key, Worker, S)};
call({dialing, Key, Ep}, S) ->
    {Reply, S1} = chappe_mrf_conf_refer_dial:dialing(Key, Ep, S),
    {reply, Reply, S1};
call({replace, Step}, S) ->
    chappe_mrf_conf_refer_member:replace(Step, S);
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

%% The keys every policy Info has, undefined when the action has none, so
%% a policy can match any of them whatever the action.
-define(INFO_KEYS, [
    action,
    target,
    method,
    replaces,
    refer_to,
    nested,
    referrer,
    referred_by,
    target_dialog,
    origin,
    member,
    dial,
    removes
]).

%% Info with every policy key (?INFO_KEYS), undefined when missing.
-spec policy_view(map()) -> map().
policy_view(Info) ->
    maps:merge(maps:from_keys(?INFO_KEYS, undefined), Info).

%% What the room makes of a REFER (refer_info/2's map, with member when
%% the caller knows it): {accept, Key, S} with the op reserved (or one to
%% attach to), or {reject, Status}. The room's own checks on the request
%% come first; nothing that tells the room's state (its members, whether
%% it is full) is answered before the policy said yes.
-spec decide(map(), #state{}) ->
    {accept, term(), #state{}} | {reject, 300..699}.
decide(Info, S) ->
    decide(Info, undefined, S).

decide(Info0, Worker, S) ->
    Info = Info0#{member => maps:get(member, Info0, referrer(Info0, S))},
    case check(Info, S) of
        {reject, _} = Rej ->
            Rej;
        {Kind, Key, Data} ->
            case policy(maps:merge(Info, policy_info(Kind, Data)), S) of
                true -> admit(Kind, Key, Data, Worker, S);
                {reject, Code} -> {reject, Code};
                false -> {reject, 403}
            end
    end.

%% what the policy sees besides refer_info/2's map: the dial string of a
%% party to add, the member a removal names
policy_info(_Kind, #{dial := Dial}) -> #{dial => Dial};
policy_info(remove, #{member := Id}) -> #{removes => Id};
policy_info(_Kind, _Data) -> #{}.

%% what the REFER asks for, checked against the request and the room's
%% configuration only: {Kind, Key, Data}, Kind add, remove, unresolved (a
%% removal naming no one member) or refer
check(#{action := Action} = Info, S) ->
    case focus_only(Action, S) of
        ok -> check_action(Action, Info, S);
        Rej -> Rej
    end.

%% RFC 4579 5.11 and 5.7: removal and REFER for a REFER are a focus's (RFC
%% 3515 2.4.2 leaves the 4xx-6xx to RFC 3261); a member of a room that is
%% no focus transfers through its call
focus_only(remove, #state{entity = undefined}) -> {reject, 403};
focus_only(refer, #state{entity = undefined}) -> {reject, 403};
focus_only(transfer, _S) -> {reject, 403};
focus_only(_Action, _S) -> ok.

check_action(add, #{target := Target} = Info, S) ->
    case
        {
            chappe_mrf_conf_refer_dial:dialable(Target) andalso
                not is_room(Target, Info, S),
            dial_headers(Info)
        }
    of
        {true, {ok, Headers}} ->
            case add_data(Target, Headers, S) of
                {ok, Data} -> {add, key(Info), Data};
                error -> {reject, 403}
            end;
        _ ->
            %% hostile to a dial string, the room itself (a loop), or a
            %% Replaces FreeSWITCH could not carry as it was given
            {reject, 403}
    end;
check_action(remove, #{origin := Origin, target := Target}, S) ->
    case resolve(Target, S) of
        {ok, Id} ->
            Key = chappe_mrf_conf_refer_op:key(Origin, <<"BYE">>, Id),
            {remove, Key, #{action => remove, member => Id}};
        {error, St} ->
            {unresolved, undefined, #{status => St}}
    end;
check_action(refer, #{target := Target, nested := Nested} = Info, S) ->
    case plain_room(Nested, Info, S) andalso not is_room(Target, Info, S) of
        false ->
            %% a focus refers parties to its own conference only, with a
            %% plain Refer-To (an INVITE, no headers), and never itself:
            %% anything else could have it REFER itself in a loop
            {reject, 403};
        true ->
            Data = #{
                action => refer,
                target => Target,
                op_id => chappe_mrf_lib:new_id()
            },
            {refer, key(Info), Data}
    end.

%% whether a URI is the room's own: its conference URI, or the URI the
%% REFER was sent to
is_room(Uri, Info, #state{entity = E}) ->
    Aor = chappe_mrf_conf_refer_op:aor(Uri),
    lists:member(Aor, [
        chappe_mrf_conf_refer_op:aor(R)
     || R <- [E, maps:get(room_uri, Info, undefined)], is_binary(R)
    ]).

plain_room(#{uri := U, method := <<"INVITE">>, headers := []}, Info, S) ->
    is_room(U, Info, S);
plain_room(_Nested, _Info, _S) ->
    false.

admission(S) ->
    chappe_mrf_conf_backend:admission(S).

admission_status(locked) -> 403;
admission_status(full) -> 486.

key(#{origin := Origin, method := M, target := Target}) ->
    chappe_mrf_conf_refer_op:key(Origin, M, Target).

known(Key, #state{refer_ops = Ops}) ->
    chappe_mrf_conf_refer_op:lookup(Key, Ops) =/= none.

%% what an op needs to carry an add out: the dial string, made once (the
%% policy sees it, the backend dials it) by the room's dial fun, guarded
%% as the policy is: error when it crashes or makes no iodata
add_data(Target, Headers, S) ->
    D = Headers#{
        action => add, target => Target, op_id => chappe_mrf_lib:new_id()
    },
    Make = fun() ->
        iolist_to_binary(
            chappe_mrf_conf_refer_dial:dial_string(dial_cfg(S, D), Target)
        )
    end,
    case guarded(dial, Target, Make, S) of
        {ok, Dial} -> {ok, D#{dial => Dial}};
        error -> error
    end.

%% What the INVITE to the party carries of the REFER, made safe for a
%% FreeSWITCH dial string: the Refer-To's Replaces (RFC 4579 5.10),
%% refused when it could not go as it is, and the Referred-By's URI
%% (RFC 3892 2.2 wants the whole value copied; only its URI survives the
%% dial string: a deviation, MRF-23).
dial_headers(Info) ->
    case replaces(Info) of
        {ok, Rep} -> {ok, maps:merge(Rep, referred_uri(Info))};
        error -> error
    end.

referred_uri(#{referred_by := RB}) when is_binary(RB) ->
    case chappe_sip_hdr:name_addr(RB) of
        {ok, #{uri := U}} ->
            case chappe_mrf_conf_refer_dial:dialable(U) of
                true -> #{referred_by => <<"<", U/binary, ">">>};
                false -> #{}
            end;
        _ ->
            #{}
    end;
referred_uri(_Info) ->
    #{}.

replaces(#{replaces := R}) when R =/= undefined ->
    V = chappe_sip_hdr:replaces_value(R),
    case chappe_mrf_conf_refer_dial:safe_value(V) of
        true -> {ok, #{replaces => V}};
        false -> error
    end;
replaces(_Info) ->
    {ok, #{}}.

%% the room's dial options with what the REFER asked for, and the dial
%% string the policy saw
dial_cfg(#state{dial = Dial, entity = E}, Data) ->
    Base = maps:merge(#{endpoint => #{}}, Dial#{entity => E}),
    maps:merge(Base, maps:with([replaces, referred_by, dial_string], Data)).

%% The room's policy, given Info with every policy key; without one every
%% REFER is refused. It runs in the room: one that crashes (a clause that
%% does not match the action, say) refuses the REFER, and the room goes
%% on.
-spec policy(map(), #state{}) -> true | false | {reject, 300..699}.
policy(_Info, #state{refer_policy = undefined}) ->
    false;
policy(Info, #state{refer_policy = P} = S) ->
    About = maps:get(action, Info, undefined),
    case guarded(refer_policy, About, fun() -> P(policy_view(Info)) end, S) of
        {ok, true} ->
            true;
        {ok, {reject, Code}} when
            is_integer(Code), Code >= 300, Code =< 699
        ->
            {reject, Code};
        _ ->
            false
    end.

%% Code of the app the room runs (a policy, its dial fun) on About: {ok,
%% what it returned}, or error when it raised, logged once; the room and
%% its members go on.
-spec guarded(atom(), term(), fun(() -> T), #state{}) -> {ok, T} | error.
guarded(Hook, About, F, #state{name = Name}) ->
    try F() of
        R -> {ok, R}
    catch
        Class:Why ->
            logger:warning(
                "chappe_mrf_conf ~ts: ~ts failed on ~0p: ~0p",
                [Name, Hook, About, {Class, Why}]
            ),
            error
    end.

%% The policy said yes; now the room's state answers: a REFER asking for
%% what an op under way or done asks (from this origin, or another one
%% adding the same party) joins it, a party already in is 200 at once, a
%% removal naming no one member is refused, and anything that brings
%% someone in must find room (admission, 403 locked, 486 full). Then an
%% op is reserved, its worker watched until it starts or aborts it.
admit(unresolved, _Key, #{status := St}, _Worker, _S) ->
    {reject, St};
admit(Kind, Key, Data, Worker, S) ->
    case {known(Key, S), Kind} of
        {true, _} -> {accept, Key, wait(Key, Worker, S)};
        {false, add} -> admit_add(Key, Data, Worker, S);
        {false, remove} -> reserve(remove, Key, Data, Worker, S);
        {false, refer} -> admit_new(Key, Data, Worker, S)
    end.

admit_add(Key, #{target := Target} = Data, Worker, #state{members = M} = S) ->
    Aor = chappe_mrf_conf_refer_op:aor(Target),
    In = [
        Id
     || Id := #{uri := U} <- M, chappe_mrf_conf_refer_op:aor(U) =:= Aor
    ],
    case {In, chappe_mrf_conf_refer_op:adding(Aor, S#state.refer_ops)} of
        {[_ | _], _} ->
            %% in already: nobody is dialed
            reserve(existing, Key, Data, Worker, S);
        {[], {ok, Other}} ->
            %% another origin is bringing the same party in: one dial
            {accept, Other, wait(Other, Worker, S)};
        {[], none} ->
            admit_new(Key, Data, Worker, S)
    end.

admit_new(Key, Data, Worker, S) ->
    case admission(S) of
        ok -> reserve(new, Key, Data, Worker, S);
        {error, Why} -> {reject, admission_status(Why)}
    end.

reserve(Kind, Key, Data, Worker, #state{refer_ops = Ops} = S) ->
    case
        chappe_mrf_conf_refer_op:reserve(
            Key, Data#{kind => Kind, waiting => #{}}, Ops
        )
    of
        {ok, Ops1} ->
            {accept, Key, wait(Key, Worker, S#state{refer_ops = Ops1})};
        {error, exists} ->
            {accept, Key, wait(Key, Worker, S)};
        {error, full} ->
            {reject, 503}
    end.

%% The worker of a REFER (undefined: the room's own, in a member's
%% dialog) waits on the op of Key while that op is reserved, watched: the
%% op lives until one of its workers starts it or the last one gives it
%% up (chappe_mrf_conf_refer_op:leave/3).
wait(_Key, undefined, S) ->
    S;
wait(Key, Worker, #state{refer_ops = Ops} = S) ->
    Mon = erlang:monitor(process, Worker),
    case chappe_mrf_conf_refer_op:wait(Key, Mon, Worker, Ops) of
        {ok, Ops1} -> S#state{refer_ops = Ops1};
        none -> unwatch([Mon], S)
    end.

%% The REFER Worker decided for Key was not accepted after all: Worker
%% stops waiting on that op, and a reserved op nobody waits on any more
%% is dropped. Another origin's REFER attached to it is not touched.
-spec abort(term(), pid() | undefined, #state{}) -> #state{}.
abort(Key, Worker, S) ->
    leave(Key, fun(_Mon, Pid) -> Pid =:= Worker end, S).

leave(Key, Gone, #state{refer_ops = Ops} = S) ->
    {Mons, Ops1} = chappe_mrf_conf_refer_op:leave(Key, Gone, Ops),
    unwatch(Mons, S#state{refer_ops = Ops1}).

unwatch(Mons, S) ->
    _ = [erlang:demonitor(Mon, [flush]) || Mon <- Mons],
    S.

%% A process the room watched went down: a worker waiting on a reserved
%% op (it died between the decision and the answer) gives up its part of
%% that op, and a caller replacing a member releases it
%% (chappe_mrf_conf_refer_member).
-spec down(reference(), #state{}) -> #state{}.
down(Mon, #state{refer_ops = Ops} = S) ->
    S1 =
        case chappe_mrf_conf_refer_op:by_mon(Mon, Ops) of
            {ok, Key} -> leave(Key, fun(M, _Pid) -> M =:= Mon end, S);
            none -> S
        end,
    chappe_mrf_conf_refer_member:hold_down(Mon, S1).

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
        {reserved, #{waiting := W} = Data0} ->
            %% its workers are done with it
            _ = unwatch(maps:keys(W), S),
            %% the <referred> of the party it brings in (RFC 4575 5.7.2),
            %% and the REFER's own Referred-By, for a nested REFER
            Data = Data0#{
                referred => chappe_sip_focus:referred(Refer),
                referred_by_raw => chappe_sip_refer:referred_by(Refer),
                waiting => #{}
            },
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
carry_out(Key, #{kind := new, action := refer, target := T}, S) ->
    %% the party is referred to the conference URI itself, whatever
    %% parameters the referrer's Refer-To had
    chappe_mrf_conf_refer_dial:nested(Key, T, S#state.entity, S);
carry_out(Key, #{kind := new, action := add, target := T, dial := D} = Data, S) ->
    Cfg = dial_cfg(S, Data#{dial_string => D}),
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
