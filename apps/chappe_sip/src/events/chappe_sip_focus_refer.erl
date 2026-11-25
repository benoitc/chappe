%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc A REFER to a conference focus (RFC 4579 5.5, 5.7, 5.10, 5.11), for
%% chappe_sip_focus: what it asks for (refer_info/2), the app's policy
%% and the answer (refer/4), and the `referred' element of an endpoint it brought
%% in (referred/1, referred_by/1). chappe_sip_focus exports each of them.
-module(chappe_sip_focus_refer).

-export([refer_info/2, refer/4, referred/1, referred_by/1]).

%% What a REFER to the focus asks for, as refer_info/2 reads it.
-type info() :: #{
    action := add | remove | refer | transfer,
    target := binary(),
    method := binary(),
    replaces := chappe_sip_hdr:replaces() | undefined,
    refer_to := chappe_sip_hdr:refer_to(),
    nested => chappe_sip_hdr:refer_to(),
    referrer := binary(),
    referred_by := binary() | undefined,
    target_dialog := chappe_sip_dialog:dialog() | undefined,
    origin := chappe_sip_refer:origin()
}.
-export_type([info/0]).

%% Read a REFER to the focus, in a participant's dialog D or outside any
%% dialog (D undefined: a REFER to the conference URI), and answer
%% nothing: the caller decides and answers. A REFER to the conference
%% URI, or in a dialog whose Contact carries isfocus, is a REFER to a
%% focus, and its Refer-To method names the action: INVITE (the default)
%% asks the focus to bring the target in (add, 5.5), BYE to remove that
%% participant (remove, 5.11), REFER to have the target referred into the
%% conference (refer, 5.7: the Refer-To carries an escaped Refer-To, read
%% as nested; none, or a malformed one, is 400). In a dialog of a room
%% that hides it is a focus (no isfocus, 4.2) an INVITE is an RFC 3515
%% transfer of that member (transfer). Any other method is refused 403: a
%% focus does not fan out requests it does not understand (RFC 5368 10).
%% The REFER itself is checked as chappe_sip_refer:check/1 does (one
%% Refer-To, one Referred-By, a sip, sips or tel target).
%%
%% replaces is the Replaces the Refer-To carries: the focus puts it on
%% its INVITE to the target (5.10). referrer is the REFER's From, the
%% identity its dialog (or its digest, when the app checked one) vouches
%% for; referred_by is only claimed (RFC 3892 6). target_dialog is the
%% dialog of this node a Target-Dialog header names (RFC 4538 4: one that
%% matches none, or lacks a tag, is ignored), origin who sent the REFER
%% (chappe_sip_refer:origin/1).
-spec refer_info(
    chappe_sip_dialog:dialog() | undefined, chappe_sip_req:req()
) ->
    {ok, info()} | {reject, 400..699, binary()}.
refer_info(D, Req) ->
    %% the caller's policy decides a BYE as well
    case chappe_sip_refer:check(Req, #{authorize => fun(_, _) -> true end}) of
        {reject, _, _} = Rej ->
            Rej;
        {ok, #{method := M} = RT} ->
            case focus_action(M, D =:= undefined orelse is_focus(D)) of
                undefined -> {reject, 403, <<"Forbidden">>};
                Action -> nested(Action, info(Action, RT, Req))
            end
    end.

info(Action, #{target := Target, method := M} = RT, Req) ->
    From = chappe_sip_req:get(<<"from">>, Req),
    TD =
        case chappe_sip_refer:target_dialog(Req) of
            {ok, Dialog} -> Dialog;
            {error, _} -> undefined
        end,
    #{
        action => Action,
        target => Target,
        method => M,
        replaces => maps:get(replaces, RT, undefined),
        refer_to => RT,
        referrer => chappe_sip_b2b_hdr:caller(From),
        referred_by => chappe_sip_req:get(<<"referred-by">>, Req),
        target_dialog => TD,
        origin => chappe_sip_refer:origin(Req)
    }.

%% RFC 4579 5.7: the Refer-To of a REFER for a REFER carries, escaped in
%% its headers, the Refer-To the target is to get
nested(refer, #{refer_to := #{headers := Hdrs}} = Info) ->
    case [V || {N, V} <- Hdrs, chappe_sip_lib:lower(N) =:= <<"refer-to">>] of
        [V] ->
            case chappe_sip_hdr:refer_to(V) of
                {ok, Nested} -> {ok, Info#{nested => Nested}};
                {error, _} -> {reject, 400, <<"Bad Nested Refer-To">>}
            end;
        _ ->
            {reject, 400, <<"Exactly One Nested Refer-To Required">>}
    end;
nested(_Action, Info) ->
    {ok, Info}.

focus_action(<<"INVITE">>, true) -> add;
focus_action(<<"INVITE">>, false) -> transfer;
focus_action(<<"BYE">>, _Focus) -> remove;
focus_action(<<"REFER">>, _Focus) -> refer;
focus_action(_M, _Focus) -> undefined.

%% A REFER to the focus, read by refer_info/2, decided by the app's policy
%% and answered. The policy gets refer_info/2's map and returns true,
%% false (403) or {reject, Code}; without a policy everything is refused
%% 403. Once allowed, the REFER is accepted (200 and NOTIFY 100 Trying,
%% chappe_sip_refer:accept/3,4) and the app carries it out, then reports
%% with chappe_sip_refer:final/2. Opts: policy, and accept's (owner,
%% expires, contact: give a REFER to the conference URI contact/1 of it,
%% so its subscription is the focus's, ...).
-spec refer(
    chappe_sip_dialog:dialog() | undefined,
    chappe_sip_req:req(),
    chappe_sip_res:res(),
    map()
) ->
    {add | remove | refer | transfer, binary(), chappe_sip_refer:refer()}
    | {error, {rejected, 300..699} | term()}.
refer(D, Req, Res, Opts) ->
    case refer_info(D, Req) of
        {reject, Status, Reason} -> reject(Res, Status, Reason);
        {ok, Info} -> allowed(D, Req, Res, Info, Opts)
    end.

%% whether the REFER reached a focus: the conference URI itself, or a
%% dialog whose Contact (the member's remote target) carries isfocus
is_focus(D) ->
    try chappe_sip_dialog:local_contact(D) of
        C -> chappe_sip_hdr:has_param(C, <<"isfocus">>)
    catch
        exit:_ -> false
    end.

allowed(D, Req, Res, #{action := Action, target := Target} = Info, Opts) ->
    Verdict =
        case maps:find(policy, Opts) of
            {ok, F} when is_function(F, 1) -> F(Info);
            _ -> false
        end,
    case Verdict of
        true ->
            AOpts = (maps:without([policy], Opts))#{
                authorize => fun(_, _) -> true end
            },
            case accept_refer(D, Req, Res, AOpts) of
                {ok, Refer} -> {Action, Target, Refer};
                {error, _} = Err -> Err
            end;
        {reject, Code} when is_integer(Code), Code >= 300, Code =< 699 ->
            reject(Res, Code, <<>>);
        _ ->
            reject(Res, 403, <<"Forbidden">>)
    end.

accept_refer(undefined, Req, Res, Opts) ->
    chappe_sip_refer:accept(Req, Res, Opts);
accept_refer(D, Req, Res, Opts) ->
    chappe_sip_refer:accept(D, Req, Res, Opts).

reject(Res, Status, Reason) ->
    _ = chappe_sip_res:send(Res, Status, reason(Reason)),
    {error, {rejected, Status}}.

reason(<<>>) -> #{};
reason(R) -> #{reason => R}.

%% The <referred> of an endpoint the focus called because of a REFER: by
%% is the REFER's Referred-By URI (RFC 4575 5.7.2, RFC 3892).
-spec referred(chappe_sip_refer:refer()) -> #{by => binary()}.
referred(Refer) ->
    by(chappe_sip_refer:referred_by(Refer)).

%% The <referred> of an endpoint that joined with an INVITE carrying
%% Referred-By (a party a participant referred to the conference URI,
%% RFC 4579 5.6 and 5.7): by is its URI (RFC 4575 5.7.2). Like the
%% Referred-By of a REFER, it is only claimed (RFC 3892 6).
-spec referred_by(chappe_sip_req:req()) -> #{by => binary()}.
referred_by(Req) ->
    by(chappe_sip_req:get(<<"referred-by">>, Req)).

by(undefined) ->
    #{};
by(RB) ->
    case chappe_sip_hdr:name_addr(RB) of
        {ok, #{uri := U}} -> #{by => U};
        _ -> #{}
    end.
