%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc A member's side of REFER in a room (chappe_mrf_conf_refer): its
%% REFER in its dialog with a focus room (to the focus, decided as one to
%% the room's URI with the member as referrer), its own transfer in a
%% room without focus (its call's transfer => notify,
%% chappe_sip_b2b_transfer), and an incoming call whose Replaces names it
%% (RFC 3891, RFC 4579 5.9). The join side runs in the caller of
%% chappe_mrf_conf:join/3; the others in the conference process.
-module(chappe_mrf_conf_refer_member).

-include("chappe_mrf_conf.hrl").

-export([join/5, call_opts/2, member_refer/4, transfer/3, transferred/3]).
-export([replace/2]).

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
%% place (RFC 4579 5.9) when it may (replace/2): it joins, then the
%% member it replaces is hung up and leaves with reason replaced. RFC
%% 3891 8 wants the caller authenticated by the app before join/3; the
%% room then lets the member itself (the same address-of-record) or a
%% caller that member referred (Referred-By naming it) replace it, and
%% the refer_policy may let others (action replace). Anyone else is
%% refused 403; a Replaces naming no call 481, a call of no member of
%% this room 403; a member another call is replacing already 603. A join
%% that fails leaves the member as it was.
-spec join(pid(), module(), map(), term(), map()) ->
    {ok, binary()} | {error, term()}.
join(Conf, Mod, Info, Target, Opts0) ->
    Opts = call_opts(Target, Opts0),
    case replacing(Conf, Target) of
        none ->
            Mod:join(Conf, Info, Target, Opts);
        {replace, Old} ->
            Result = Mod:join(Conf, Info, Target, Opts),
            Step =
                case Result of
                    {ok, New} -> {done, Old, New};
                    _ -> {release, Old}
                end,
            _ = chappe_mrf_conf:call(Conf, {refer, {replace, Step}}, 30000),
            Result;
        {reject, St} ->
            {call, _Req, Res} = Target,
            chappe_mrf_conf_refer:reject(Res, St, <<>>)
    end.

%% the member an incoming call's Replaces names, held for it when the
%% room lets it replace that member
replacing(Conf, {call, Req, _Res}) ->
    Who = #{
        referrer => chappe_sip_b2b_hdr:caller(
            chappe_sip_req:get(<<"from">>, Req)
        ),
        referred_by => chappe_sip_req:get(<<"referred-by">>, Req)
    },
    Ask = fun(Step) ->
        chappe_mrf_conf:call(Conf, {refer, {replace, Step}}, 5000)
    end,
    Auth = fun(D, _Req) ->
        case Ask({check, chappe_sip_dialog:pid(D), Who}) of
            true -> true;
            _ -> false
        end
    end,
    case chappe_sip:replaces_response(Req, #{authorize => Auth}) of
        no_replaces ->
            none;
        {accept, D, _} ->
            case Ask({hold, chappe_sip_dialog:pid(D)}) of
                {ok, Old} -> {replace, Old};
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
%% hold (keep that member for this call: a second call for it gets 603),
%% done (the new call is in: the member it replaces is hung up) and
%% release (the new call failed: the member stays).
-spec replace(term(), #state{}) -> {reply, term(), #state{}}.
replace({check, Pid, Who}, S) ->
    {reply, may_replace(chappe_mrf_conf_refer:member_of(Pid, S), Who, S), S};
replace({hold, Pid}, #state{members = M} = S) ->
    case chappe_mrf_conf_refer:member_of(Pid, S) of
        undefined ->
            {reply, {error, gone}, S};
        Id ->
            case M of
                #{Id := #{replacing := true}} ->
                    {reply, {error, held}, S};
                #{Id := Mb} ->
                    {reply, {ok, Id}, S#state{
                        members = M#{Id := Mb#{replacing => true}}
                    }}
            end
    end;
replace({done, Old, New}, #state{members = M} = S) ->
    case M of
        #{Old := _} when Old =/= New ->
            {reply, ok, S1} = chappe_mrf_conf_backend:drop_member(
                Old, replaced, S
            ),
            {reply, ok, S1};
        #{} ->
            {reply, ok, S}
    end;
replace({release, Old}, #state{members = M} = S) ->
    case M of
        #{Old := Mb} ->
            {reply, ok, S#state{
                members = M#{Old := maps:remove(replacing, Mb)}
            }};
        #{} ->
            {reply, ok, S}
    end.

%% the member itself, a caller it referred, or one the policy allows
may_replace(undefined, _Who, _S) ->
    false;
may_replace(Id, Who, #state{members = M} = S) ->
    Mb = maps:get(Id, M),
    Own = aor(maps:get(uri, Mb, undefined)),
    Info = Who#{
        action => replace,
        target => maps:get(uri, Mb, undefined),
        method => <<"INVITE">>,
        member => Id
    },
    Named = [
        aor(uri_of(V))
     || V <- [maps:get(referrer, Who), maps:get(referred_by, Who)]
    ],
    case Own =/= undefined andalso lists:member(Own, Named) of
        true -> true;
        false -> allowed(chappe_mrf_conf_refer:policy(Info, S))
    end.

allowed(true) -> true;
allowed(_Verdict) -> false.

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
        {accept, Key, #state{refer_ops = Ops} = S1} ->
            Opts = #{owner => self(), authorize => fun(_, _) -> true end},
            case chappe_sip_refer:accept(D, Req, Res, Opts) of
                {ok, Refer} ->
                    chappe_mrf_conf_refer:start(Key, Refer, S1);
                {error, _} ->
                    S1#state{
                        refer_ops = chappe_mrf_conf_refer_op:abort(Key, Ops)
                    }
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
            %% itself (privacy) or of the room (a replacement) is not its
            Old = maps:without([private, replacing, referred], maps:get(Id, M)),
            Mb = Old#{name => name(Target, Id), uri => Target},
            S2 = S1#state{members = M#{Id := Mb}},
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
