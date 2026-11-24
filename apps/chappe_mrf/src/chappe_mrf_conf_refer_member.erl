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
-export([replaced/3]).

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
%% place (RFC 4579 5.9): it joins, then the member it replaces is hung up
%% and leaves with reason replaced. A Replaces naming anything else is
%% answered as RFC 3891 3 says (481, 486, 603) or, for a call of another
%% room or none of a member's, 403; a join that fails leaves the member.
-spec join(pid(), module(), map(), term(), map()) ->
    {ok, binary()} | {error, term()}.
join(Conf, Mod, Info, Target, Opts0) ->
    Opts = call_opts(Target, Opts0),
    case replacing(Conf, Target) of
        none ->
            Mod:join(Conf, Info, Target, Opts);
        {replace, Old} ->
            case Mod:join(Conf, Info, Target, Opts) of
                {ok, New} = Ok ->
                    Replaced = {refer, {replaced, Old, New}},
                    _ = chappe_mrf_conf:call(Conf, Replaced, 30000),
                    Ok;
                Err ->
                    Err
            end;
        {reject, St} ->
            {call, _Req, Res} = Target,
            chappe_mrf_conf_refer:reject(Res, St, <<>>)
    end.

%% the member an incoming call's Replaces names, when it is one of this
%% room's (RFC 3891 3 and 8: only such a replacement is authorized)
replacing(Conf, {call, Req, _Res}) ->
    Member = fun(D) ->
        chappe_mrf_conf:call(
            Conf, {refer, {leg, chappe_sip_dialog:pid(D)}}, 5000
        )
    end,
    Auth = fun(D, _Req) -> is_binary(Member(D)) end,
    case chappe_sip:replaces_response(Req, #{authorize => Auth}) of
        no_replaces ->
            none;
        {accept, D, _} ->
            case Member(D) of
                Old when is_binary(Old) -> {replace, Old};
                _ -> {reject, 481}
            end;
        {reject, St} ->
            {reject, St}
    end;
replacing(_Conf, _Target) ->
    none.

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
            Mb = (maps:get(Id, M))#{name => name(Target, Id), uri => Target},
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

%% The member an incoming call replaced (join/5), once the call is in:
%% it is hung up and leaves with reason replaced.
-spec replaced(binary(), binary(), #state{}) -> #state{}.
replaced(Old, New, #state{members = M} = S) ->
    case M of
        #{Old := _} when Old =/= New ->
            {reply, ok, S1} = chappe_mrf_conf_backend:drop_member(
                Old, replaced, S
            ),
            S1;
        #{} ->
            S
    end.
