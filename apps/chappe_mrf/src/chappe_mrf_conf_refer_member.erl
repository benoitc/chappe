%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc A member's side of REFER in a room (chappe_mrf_conf_refer): its
%% REFER in its dialog with a focus room (to the focus, decided as one to
%% the room's URI with the member as referrer), its own transfer in a
%% room without focus (its call's transfer => notify,
%% chappe_sip_b2b_transfer), an incoming call whose Replaces names it
%% (RFC 3891, RFC 4579 5.9, decided by the room's replaces_policy), and
%% the B2BUA options and dialog of a member's call that let the room take
%% its REFERs. The join side runs in the caller of chappe_mrf_conf:join/3;
%% the others in the conference process.
-module(chappe_mrf_conf_refer_member).

-include("chappe_mrf_conf.hrl").

-export([join/5, call_opts/2, member_refer/4, transfer/3, transferred/3]).
-export([replace/2, hold_down/2, unhold/3, forget_replaced/3]).
-export([member_opts/2, keep_dialog/2, from_uri/1]).

%% How long a member stays held for a caller replacing it: longer than a
%% joiner waits on the room (MRF_JOIN_MAX + MRF_JOIN_MARGIN at most), with
%% 10 s for what it does before it asks (the room's checks, the answer to
%% its caller), so a join the room completes in time finds its hold. Past
%% it the hold goes, so a caller stuck in its join never keeps the member
%% from everyone else. A member a call replaced is remembered as long, so
%% that a late call finds it taken.
-define(HOLD_MS, (?MRF_JOIN_MAX + ?MRF_JOIN_MARGIN + 10000)).

%% The keys every replaces_policy Info has, undefined when unknown.
-define(REPLACES_KEYS, [caller, referred_by, request, replaced, replaced_aor]).

%% The join options of an incoming call (chappe_mrf_conf:join/3 with
%% {call, Req, Res}), with what it says of its caller for the roster: who
%% referred it here (Referred-By, RFC 4575 5.7.2) and whether it asked for
%% privacy (RFC 4579 6). The join's own options win.
-spec call_opts(term(), map()) -> map().
call_opts({call, Req, _Res}, Opts) ->
    Referred =
        case chappe_sip_focus:referred_by(Req) of
            #{by := _} = R -> #{referred => R};
            #{} -> #{}
        end,
    maps:merge(
        Referred#{private => chappe_sip_focus:privacy_requested(Req)}, Opts
    );
call_opts(_Target, Opts) ->
    Opts.

%% chappe_mrf_conf:join/3, in the caller: an incoming call with Replaces
%% (RFC 3891) naming a member's call in this room takes that member's
%% place (RFC 4579 5.9) when it may (may_replace/3): it joins, then the
%% member it replaces is hung up and leaves with reason replaced. RFC
%% 3891 8 wants the caller authenticated by the app before join/3; the
%% room's replaces_policy decides, else the room lets the member itself
%% (the same address-of-record) or a caller that member referred
%% (Referred-By naming it) replace it, never an anonymous caller. Anyone
%% else is refused 403; a Replaces naming no call 481, a call of no
%% member of this room 403; a member another call is replacing already
%% 603. A join that fails, raises or never ends leaves the member as it
%% was: its hold goes with the join, the caller, or ?HOLD_MS. One that
%% completes once its hold went (?HOLD_MS, another caller holds the
%% member, or the member's call was transferred) is too late: the new call
%% is hung up, {error, expired}; so is one whose member another call
%% replaced meanwhile. A member that left on its own meanwhile (its BYE, a
%% kick) leaves its place to the new call, which stays.
-spec join(pid(), module(), map(), term(), map()) ->
    {ok, binary()} | {error, term()}.
join(Conf, Mod, Info, Target, Opts0) ->
    Opts = call_opts(Target, Opts0),
    case replacing(Conf, Target) of
        none ->
            Mod:join(Conf, Info, Target, Opts);
        {replace, Old, Hold} ->
            Result =
                try
                    Mod:join(Conf, Info, Target, Opts)
                catch
                    Class:Why:Stack ->
                        _ = step(Conf, {release, Old, Hold}),
                        erlang:raise(Class, Why, Stack)
                end,
            case Result of
                {ok, New} ->
                    replaced(step(Conf, {done, Old, New, Hold}), Result);
                _ ->
                    _ = step(Conf, {release, Old, Hold}),
                    Result
            end;
        {reject, St} ->
            {call, _Req, Res} = Target,
            chappe_mrf_conf_refer:reject(Res, St, <<>>)
    end.

step(Conf, Step) ->
    chappe_mrf_conf:call(Conf, {refer, {replace, Step}}, 30000).

%% the new call is in: the member it replaces goes, unless its hold went
%% first, and the new call was hung up instead
replaced({error, expired} = Late, _Joined) -> Late;
replaced(_Done, Joined) -> Joined.

%% the member an incoming call's Replaces names, held for it when the
%% room lets it replace that member
replacing(Conf, {call, Req, _Res}) ->
    Who = #{
        caller => from_uri(Req),
        referred_by => uri_of(chappe_sip_req:get(<<"referred-by">>, Req)),
        request => Req
    },
    Ask = fun(Step) ->
        chappe_mrf_conf:call(Conf, {refer, {replace, Step}}, 5000)
    end,
    Auth = fun(D, _Req) ->
        %% the room's answer, or its failure (a refusal)
        allowed(Ask({check, chappe_sip_dialog:pid(D), Who}))
    end,
    case chappe_sip:replaces_response(Req, #{authorize => Auth}) of
        no_replaces ->
            none;
        {accept, D, _} ->
            case Ask({hold, chappe_sip_dialog:pid(D), self()}) of
                {ok, Old, Hold} -> {replace, Old, Hold};
                {error, held} -> {reject, 603};
                _ -> {reject, 481}
            end;
        {reject, St} ->
            {reject, St}
    end;
replacing(_Conf, _Target) ->
    none.

%% The room's side of a replacement, sent as {replace, Step}: check
%% (whether Who may replace the member whose leg is dialog process Pid),
%% hold (keep that member for the call of Caller, watched: a second call
%% for it gets 603), done (the new call is in: the member it replaces is
%% hung up, while it is still held for this call, and the room remembers
%% for ?HOLD_MS which call replaced it; a member still in but not held for
%% it any more stays, and the new call is hung up, {error, expired}, as it
%% is when another call replaced the member; a member that left on its
%% own lets the new call stay) and release (the new call failed: the
%% member stays).
%% The hold also goes when Caller dies (hold_down/2), after ?HOLD_MS, or
%% when the member's call is transferred (transferred/3).
-spec replace(term(), #state{}) -> {reply, term(), #state{}}.
replace({check, Pid, Who}, S) ->
    {reply, may_replace(chappe_mrf_conf_refer:member_of(Pid, S), Who, S), S};
replace({hold, Pid, Caller}, #state{members = M} = S) ->
    case chappe_mrf_conf_refer:member_of(Pid, S) of
        undefined ->
            {reply, {error, gone}, S};
        Id ->
            case M of
                #{Id := #{replacing := _}} ->
                    {reply, {error, held}, S};
                #{Id := Mb} ->
                    Hold = erlang:monitor(process, Caller),
                    T = erlang:start_timer(
                        ?HOLD_MS, self(), {refer_replace, Id, Hold}
                    ),
                    {reply, {ok, Id, Hold}, S#state{
                        members = M#{Id := Mb#{replacing => {Hold, T}}}
                    }}
            end
    end;
replace({done, Old, Old, Hold}, S) ->
    {reply, ok, unhold(Old, Hold, S)};
replace({done, Old, New, Hold}, #state{members = M, replaced = R} = S) ->
    case {M, R} of
        {#{Old := #{replacing := {Hold, _}}}, _} ->
            S1 = unhold(Old, Hold, S),
            {reply, ok, S2} =
                chappe_mrf_conf_backend:drop_member(Old, replaced, S1),
            {reply, ok, taken(Old, Hold, S2)};
        {#{Old := _}, _} ->
            %% the hold went before the new call was in (its time ran
            %% out, another caller holds the member, the member's call was
            %% transferred): the new call goes, not the member
            late(Old, New, Hold, S);
        {#{}, #{Old := _}} ->
            %% another call took the member's place after this one's hold
            %% ran out: one member is replaced by one call, this one goes
            late(Old, New, Hold, S);
        {#{}, #{}} ->
            %% the member left on its own first (its BYE, a kick):
            %% nobody to replace, the new call stays
            {reply, ok, unhold(Old, Hold, S)}
    end;
replace({release, Old, Hold}, S) ->
    {reply, ok, unhold(Old, Hold, S)}.

%% member Id is gone, replaced by the call whose hold was Hold: kept for
%% ?HOLD_MS, so that a late call that held it before finds it taken
taken(Id, Hold, #state{replaced = R} = S) ->
    T = erlang:start_timer(?HOLD_MS, self(), {refer_replaced, Id, Hold}),
    S#state{replaced = R#{Id => {Hold, T}}}.

%% the {refer_replaced, Id, Hold} timer: who replaced member Id is
%% forgotten
-spec forget_replaced(binary(), reference(), #state{}) -> #state{}.
forget_replaced(Id, Hold, #state{replaced = R} = S) ->
    case R of
        #{Id := {Hold, _}} -> S#state{replaced = maps:remove(Id, R)};
        #{} -> S
    end.

%% a call that came in to replace member Old too late is hung up, and
%% its join fails
late(Old, New, Hold, S) ->
    #state{members = M} = S1 = unhold(Old, Hold, S),
    case M of
        #{New := _} ->
            {reply, ok, S2} =
                chappe_mrf_conf_backend:drop_member(New, expired, S1),
            {reply, {error, expired}, S2};
        #{} ->
            {reply, {error, expired}, S1}
    end.

%% The hold Hold of member Id ends: its caller's join is over, the caller
%% died, or its time is up (the {refer_replace, Id, Hold} timer). A hold
%% that is not Id's any more (gone, or another caller's) stays as it is.
-spec unhold(binary(), reference(), #state{}) -> #state{}.
unhold(Id, Hold, #state{members = M} = S) ->
    _ = erlang:demonitor(Hold, [flush]),
    case M of
        #{Id := #{replacing := {Hold, T}} = Mb} ->
            _ = erlang:cancel_timer(T),
            S#state{members = M#{Id := maps:remove(replacing, Mb)}};
        #{} ->
            S
    end.

%% A process the room watched went down: the caller a member is held for
%% releases it.
-spec hold_down(reference(), #state{}) -> #state{}.
hold_down(Mon, #state{members = M} = S) ->
    case [Id || Id := #{replacing := {H, _}} <- M, H =:= Mon] of
        [Id | _] -> unhold(Id, Mon, S);
        [] -> S
    end.

%% Who may replace member Id: the room's replaces_policy, given the
%% caller (its From's URI), referred_by (its Referred-By's URI), request
%% (the INVITE), replaced (Id) and replaced_aor (Id's address-of-record),
%% every key there, undefined when unknown; true lets it, anything else,
%% or a policy that crashes (logged), refuses. Without one, the member
%% itself or a caller it referred, never an anonymous one.
may_replace(undefined, _Who, _S) ->
    false;
may_replace(Id, Who, #state{members = M, replaces_policy = P} = S) ->
    Uri = maps:get(uri, maps:get(Id, M), undefined),
    Info = maps:merge(
        maps:from_keys(?REPLACES_KEYS, undefined),
        Who#{replaced => Id, replaced_aor => aor(Uri)}
    ),
    case P of
        undefined ->
            by_default(Info);
        _ ->
            Run = fun() -> P(Info) end,
            chappe_mrf_conf_refer:guarded(replaces_policy, Id, Run, S) =:=
                {ok, true}
    end.

allowed(true) -> true;
allowed(_NoOrError) -> false.

%% the member itself (its address-of-record), or a caller whose
%% Referred-By names it; an anonymous caller (all share one
%% address-of-record) or member never
by_default(#{caller := C, referred_by := RB, replaced_aor := Own}) ->
    not anonymous(Own) andalso not anonymous(C) andalso
        lists:member(Own, [aor(C), aor(RB)]).

%% RFC 3323 4 and RFC 3261 8.1.1.3: a URI that names nobody (host
%% anonymous.invalid, or user anonymous), or none at all
anonymous(undefined) ->
    true;
anonymous(Uri) ->
    case chappe_sip_uri:parse(Uri) of
        {ok, U} ->
            Lower = fun(K) -> string:lowercase(maps:get(K, U, <<>>)) end,
            Lower(host) =:= <<"anonymous.invalid">> orelse
                Lower(user) =:= <<"anonymous">>;
        {error, _} ->
            true
    end.

uri_of(undefined) ->
    undefined;
uri_of(NameAddr) ->
    case chappe_sip_hdr:name_addr(NameAddr) of
        {ok, #{uri := U}} -> U;
        _ -> undefined
    end.

aor(undefined) -> undefined;
aor(Uri) -> chappe_mrf_conf_refer_op:aor(Uri).

%% A member's REFER, in its dialog with the room (the room is its call's
%% notify process), decided as a REFER to the room's URI with the member
%% as referrer, and answered in that dialog. A member the room does not
%% know, or whose dialog it cannot find, is refused 603.
-spec member_refer(
    reference(), chappe_sip_req:req(), chappe_sip_res:res(), #state{}
) ->
    #state{}.
member_refer(Ref, Req, Res, #state{members = M} = S) ->
    Member = [{Id, Mb} || Id := #{b2b := {_, R}} = Mb <- M, R =:= Ref],
    case {Member, chappe_mrf_registry:select({a_dialog, Ref, '_'})} of
        {[{Id, _Mb} | _], [{{a_dialog, _, D}, _} | _]} ->
            case chappe_sip_focus:refer_info(D, Req) of
                {reject, St, Reason} ->
                    _ = chappe_mrf_conf_refer:reject(Res, St, Reason),
                    S;
                {ok, #{action := transfer}} ->
                    %% a room without focus: its members transfer through
                    %% their call (member_opts/2's transfer => notify)
                    _ = chappe_mrf_conf_refer:reject(Res, 403, <<>>),
                    S;
                {ok, Info} ->
                    in_dialog(Info#{member => Id}, D, Req, Res, S)
            end;
        _ ->
            _ = chappe_sip_res:send(Res, 603),
            S
    end.

in_dialog(Info, D, Req, Res, S) ->
    case chappe_mrf_conf_refer:decide(Info, S) of
        {reject, St} ->
            _ = chappe_mrf_conf_refer:reject(Res, St, <<>>),
            S;
        {accept, Key, S1} ->
            Opts = #{owner => self(), authorize => fun(_, _) -> true end},
            case chappe_sip_refer:accept(D, Req, Res, Opts) of
                {ok, Refer} ->
                    chappe_mrf_conf_refer:start(Key, Refer, S1);
                {error, _} ->
                    %% an op of its own (nobody waits on it) goes; one it
                    %% joined, reserved for another origin, stays
                    chappe_mrf_conf_refer:abort(Key, undefined, S1)
            end
    end.

%% A member of a room that is no focus transfers itself (its call's
%% transfer => notify, chappe_sip_b2b_transfer): the room decides, with
%% Info as the call's transfer gives it plus action transfer and member;
%% the call carries it out (blind, or attended with the Replaces the
%% Refer-To carries, RFC 5589) and the room hears {transferred, ...}.
%% Only a member's own leg (a) transfers.
transfer(Ref, #{leg := a} = Info, #state{members = M} = S) ->
    case [Id || Id := #{b2b := {_, R}} <- M, R =:= Ref] of
        [Id | _] ->
            case
                chappe_mrf_conf_refer:policy(
                    Info#{action => transfer, member => Id}, S
                )
            of
                true ->
                    ok = chappe_sip_b2b_transfer:accept(Info, #{});
                {reject, Code} ->
                    ok = chappe_sip_b2b_transfer:reject(Info, Code);
                false ->
                    ok = chappe_sip_b2b_transfer:reject(Info, 403)
            end;
        [] ->
            ok = chappe_sip_b2b_transfer:reject(Info, 603)
    end,
    S;
transfer(_Ref, Info, S) ->
    _ = chappe_sip_b2b_transfer:reject(Info, 403),
    S.

%% A member's call was transferred: the target took the member's place on
%% the room's leg. The room sees the member leave (transferred), then the
%% target join under the same id.
-spec transferred(reference(), map(), #state{}) -> #state{}.
transferred(Ref, Info, #state{members = M} = S) ->
    case [Id || Id := #{b2b := {_, R}} <- M, R =:= Ref] of
        [Id | _] ->
            S1 = chappe_mrf_conf_backend:emit({left, Id, transferred}, S),
            Target = maps:get(target, Info, undefined),
            %% the target is someone else: what the old caller asked for
            %% itself (privacy) or of the room (a replacement: its hold
            %% goes, and a late done step finds it gone) is not its
            #state{members = M1} = clear_hold(Id, S1),
            Old = maps:without([private, referred], maps:get(Id, M1)),
            Mb = Old#{name => name(Target, Id), uri => Target},
            S2 = S1#state{members = M1#{Id := Mb}},
            chappe_mrf_conf_backend:publish(
                chappe_mrf_conf_backend:emit(
                    {joined, Id, chappe_mrf_conf_backend:public(Id, Mb)}, S2
                )
            );
        [] ->
            S
    end.

name(undefined, Id) -> Id;
name(Target, _Id) -> Target.

%% member Id is held for no one any more
clear_hold(Id, #state{members = M} = S) ->
    case M of
        #{Id := #{replacing := {Hold, _}}} -> unhold(Id, Hold, S);
        #{} -> S
    end.

%% ---- a member's call ----

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
