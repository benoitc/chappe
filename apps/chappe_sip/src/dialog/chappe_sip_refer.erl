%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc REFER (RFC 3515 as updated by RFC 7647), both sides.
%%
%% Recipient: check/2 validates a REFER, accept/3,4 answers it 200 (never
%% 202, RFC 7647 5) and starts its implicit subscription, progress/2,3 and
%% final/2,3 report the referenced request as message/sipfrag NOTIFYs. The
%% subscription itself (Event id, expiry, refresh, rate limit) is a
%% chappe_sip_refer_sub process. The application decides what to do with
%% the target: the policy stays out of here.
%%
%% Sender: send/3 sends a REFER in a dialog or outside one and returns once
%% it is answered; the NOTIFYs that follow are answered 200 and reach the
%% owner as
%%   {refer_progress, Id, StatusCode}   the subscription is still active
%%   {refer_done, Id, StatusCode}       the final NOTIFY (terminated)
%% A NOTIFY for a REFER we do not know is answered 481 (RFC 6665 4.1.3).
%%
%% Inside a dialog the dialog fsm hands the package's SUBSCRIBEs and
%% NOTIFYs to chappe_sip_refer_notify:route/3. Outside one, the stack's NOTIFY router
%% (chappe_sip_notify_router) calls handle_notify/2 before your own NOTIFY
%% handler; notify_handler/0 is still there for a handler of yours.
-module(chappe_sip_refer).

-include("chappe_sip.hrl").

-export([check/1, check/2, accept/3, accept/4]).
-export([progress/2, progress/3, final/2, final/3]).
-export([target/1, referred_by/1, target_dialog/1, origin/1, subscription/1]).
-export([send/3, handle_notify/2, notify_handler/0]).

-export_type([refer/0, target/0, origin/0]).

-record(refer, {
    pid :: pid() | undefined,
    target :: target(),
    dialog :: chappe_sip_dialog:dialog() | undefined,
    referred_by :: binary() | undefined
}).
-opaque refer() :: #refer{}.
-type target() :: chappe_sip_hdr:refer_to().
%% Who sent a REFER (origin/1): a dialog by its Call-ID, local and remote
%% tags, or a request outside any dialog by its Call-ID and From tag.
-type origin() ::
    {dialog, binary(), binary(), binary()} | {request, binary(), binary()}.

%% the NOTIFY gap of RFC 3515 3.10, and the default subscription length
-define(GAP, 1000).
-define(EXPIRES, 60).
-define(MAX_EXPIRES, 3600).

%% ---- recipient ----

-spec check(chappe_sip_req:req()) ->
    {ok, target()} | {reject, 400..699, binary()}.
check(Req) ->
    check(Req, #{}).

%% Validate a REFER:
%%   - exactly one Refer-To, well formed (400, RFC 3515 2.4.2);
%%   - at most one Referred-By (400, RFC 3892 2.1);
%%   - a sip, sips or tel target (416: a UA that cannot reach other schemes
%%     should not accept them, RFC 3515 2.4.2);
%%   - authorize => fun((Target, Req) -> boolean()) approves it (403 when
%%     it says no). A REFER asking for a BYE (RFC 4579 5.11, removing a
%%     participant) is refused 403 unless an authorize fun approves it.
-spec check(chappe_sip_req:req(), map()) ->
    {ok, target()} | {reject, 400..699, binary()}.
check(Req, Opts) ->
    RT = one_refer_to(chappe_sip_req:get_all(<<"refer-to">>, Req)),
    RB = length(chappe_sip_req:get_all(<<"referred-by">>, Req)),
    case RT of
        {ok, _} when RB > 1 ->
            {reject, 400, <<"Only One Referred-By Allowed">>};
        {ok, Value} ->
            case chappe_sip_hdr:refer_to(Value) of
                {ok, Target} -> check_target(Target, Req, Opts);
                {error, _} -> {reject, 400, <<"Bad Refer-To">>}
            end;
        error ->
            {reject, 400, <<"Exactly One Refer-To Required">>}
    end.

one_refer_to([Value]) ->
    case chappe_sip_hdr:name_addr_list(Value) of
        {ok, [_]} -> {ok, Value};
        _ -> error
    end;
one_refer_to(_) ->
    error.

check_target(#{scheme := Scheme} = Target, Req, Opts) ->
    case lists:member(Scheme, [<<"sip">>, <<"sips">>, <<"tel">>]) of
        false ->
            {reject, 416, <<"Unsupported URI Scheme">>};
        true ->
            case
                authorized(Target, Req, maps:get(authorize, Opts, undefined))
            of
                true -> {ok, Target};
                false -> {reject, 403, <<"Forbidden">>}
            end
    end.

authorized(#{method := <<"BYE">>}, _Req, undefined) ->
    false;
authorized(_Target, _Req, undefined) ->
    true;
authorized(Target, Req, Fun) ->
    case Fun(Target, Req) of
        true -> true;
        _ -> false
    end.

%% Accept a REFER that arrived outside any dialog (from a chappe_sip:refer/1
%% handler). The 200 forms the subscription dialog; with Refer-Sub: false
%% and norefersub (RFC 4488 4) there is neither. Opts: check/2's, plus
%%   expires => seconds (default 60), max_expires => seconds (the most a
%%   refresh gets, default 3600), owner => pid() (default self(); if it
%%   dies the subscription ends), notify_gap => ms (default 1000),
%%   contact => NameAddr: the 200's Contact and the subscription's local
%%   target (default the engine's), such as a conference URI with isfocus
%%   (chappe_sip_focus:contact/1) for a REFER to a focus.
-spec accept(chappe_sip_req:req(), chappe_sip_res:res(), map()) ->
    {ok, refer()} | {error, {rejected, 400..699} | term()}.
accept(Req, Res, Opts) ->
    case check(Req, Opts) of
        {reject, Status, Reason} ->
            reject(Res, Status, Reason);
        {ok, Target} ->
            case no_subscription(Req) of
                true ->
                    Contact = maps:get(contact, Opts, engine_contact()),
                    ok = ok_no_sub(Res, [{<<"Contact">>, Contact}]),
                    {ok, #refer{target = Target, referred_by = rb(Req)}};
                false ->
                    accept_ood(Req, Res, Target, Opts)
            end
    end.

accept_ood(Req, Res, Target, Opts) ->
    Expires = maps:get(expires, Opts, ?EXPIRES),
    {ok, Pid} = start_sub(sub, undefined, <<"refer">>, Opts),
    Sub = #{
        expires => Expires,
        max => maps:get(max_expires, Opts, ?MAX_EXPIRES),
        min => 0,
        event => <<"refer">>,
        keep_body => true
    },
    Headers = [{<<"Contact">>, C} || {ok, C} <- [maps:find(contact, Opts)]],
    DOpts = #{
        owner => Pid, subscription => Sub, headers => Headers ++ refer_sub(Req)
    },
    case chappe_sip_dialog:create_uas(Req, Res, DOpts) of
        {ok, D} ->
            ok = gen_server:call(Pid, {attach, D}),
            gen_server:cast(Pid, start),
            {ok, #refer{
                pid = Pid, target = Target, dialog = D, referred_by = rb(Req)
            }};
        {error, _} = Err ->
            exit(Pid, kill),
            Err
    end.

%% Accept a REFER received in Dialog (the {chappe_sip_dialog, Dialog, refer,
%% Req, Res} event). The implicit subscription shares the dialog; its
%% NOTIFYs carry Event: refer for the first REFER in the dialog and
%% refer;id=<CSeq> after that (RFC 3515 2.4.6). Opts as accept/3; the 200
%% carries the dialog's own Contact unless contact gives one.
-spec accept(
    chappe_sip_dialog:dialog(),
    chappe_sip_req:req(),
    chappe_sip_res:res(),
    map()
) ->
    {ok, refer()} | {error, {rejected, 400..699} | term()}.
accept(D, Req, Res, Opts) ->
    DPid = chappe_sip_dialog:pid(D),
    Nth = chappe_sip_refer_registry:bump(received, DPid),
    case check(Req, Opts) of
        {reject, Status, Reason} ->
            reject(Res, Status, Reason);
        {ok, Target} ->
            Own =
                case Opts of
                    #{contact := C0} -> C0;
                    #{} -> chappe_sip_dialog:local_contact(D)
                end,
            Contact = [{<<"Contact">>, C} || C <- [Own], C =/= undefined],
            case no_subscription(Req) of
                true ->
                    ok = ok_no_sub(Res, Contact),
                    {ok, #refer{
                        target = Target, dialog = D, referred_by = rb(Req)
                    }};
                false ->
                    IdParam = id_param(Nth, Req),
                    {ok, Pid} = start_sub(invite, D, event(IdParam), Opts),
                    _ = chappe_sip_refer_registry:add(
                        notifier, {dialog, DPid}, Pid, #{id => IdParam}
                    ),
                    _ = chappe_sip_res:send(Res, 200, #{
                        reason => <<"OK">>,
                        headers => Contact ++ refer_sub(Req)
                    }),
                    gen_server:cast(Pid, start),
                    {ok, #refer{
                        pid = Pid,
                        target = Target,
                        dialog = D,
                        referred_by = rb(Req)
                    }}
            end
    end.

reject(Res, Status, Reason) ->
    _ = chappe_sip_res:send(Res, Status, #{reason => Reason}),
    {error, {rejected, Status}}.

ok_no_sub(Res, Contact) ->
    _ = chappe_sip_res:send(Res, 200, #{
        reason => <<"OK">>,
        headers => Contact ++ [{<<"Refer-Sub">>, <<"false">>}]
    }),
    ok.

start_sub(Mode, D, Event, Opts) ->
    chappe_sip_refer_sup:start_sub(#{
        mode => Mode,
        dialog => D,
        event => Event,
        owner => maps:get(owner, Opts, self()),
        expires => maps:get(expires, Opts, ?EXPIRES),
        max_expires => maps:get(max_expires, Opts, ?MAX_EXPIRES),
        gap => maps:get(notify_gap, Opts, ?GAP)
    }).

%% RFC 4488 4: Refer-Sub: false asks for no subscription; it is honoured
%% when the REFER also says it knows the extension (norefersub in Supported
%% or Require), so the sender is ready for no NOTIFY at all.
no_subscription(Req) ->
    RS = chappe_sip_req:get(<<"refer-sub">>, Req),
    is_binary(RS) andalso
        string:lowercase(first_token(RS)) =:= <<"false">> andalso
        lists:member(
            <<"norefersub">>,
            chappe_sip_hdr:option_tags(
                chappe_sip_req:get_all(<<"supported">>, Req) ++
                    chappe_sip_req:get_all(<<"require">>, Req)
            )
        ).

%% a Refer-Sub the REFER carried and we did not honour is answered true
refer_sub(Req) ->
    case chappe_sip_req:get(<<"refer-sub">>, Req) of
        undefined -> [];
        _ -> [{<<"Refer-Sub">>, <<"true">>}]
    end.

first_token(V) ->
    string:trim(hd(binary:split(V, <<";">>))).

%% the first REFER in a dialog may go without an id; every later one MUST
%% carry the REFER's CSeq number (RFC 3515 2.4.6)
id_param(1, _Req) ->
    undefined;
id_param(_Nth, Req) ->
    case chappe_sip_msg:cseq(chappe_sip_req:msg(Req)) of
        {ok, #{seq := Seq}} -> integer_to_binary(Seq);
        _ -> undefined
    end.

event(undefined) -> <<"refer">>;
event(Id) -> <<"refer;id=", Id/binary>>.

%% Report progress of the referenced request (a 1xx): a NOTIFY with
%% Subscription-State active. At most one NOTIFY a second goes out; a report
%% that has to wait is replaced by a newer one.
-spec progress(refer(), 100..199) -> ok.
progress(Refer, Status) ->
    progress(Refer, Status, chappe_sip_sipfrag:reason(Status)).

-spec progress(refer(), 100..199, binary()) -> ok.
progress(Refer, Status, Reason) when Status >= 100, Status < 200 ->
    emit(Refer, chappe_sip_sipfrag:build(Status, Reason), active).

%% Report the final status of the referenced request and end the
%% subscription (terminated;reason=noresource, RFC 3515 2.4.7). Never
%% dropped by the rate limit: it waits its turn and replaces any waiting
%% progress.
-spec final(refer(), 200..699) -> ok.
final(Refer, Status) ->
    final(Refer, Status, chappe_sip_sipfrag:reason(Status)).

-spec final(refer(), 200..699, binary()) -> ok.
final(Refer, Status, Reason) when Status >= 200, Status =< 699 ->
    emit(
        Refer,
        chappe_sip_sipfrag:build(Status, Reason),
        {terminated, <<"noresource">>}
    ).

emit(#refer{pid = undefined}, _Frag, _State) ->
    ok;
emit(#refer{pid = Pid}, Frag, State) ->
    gen_server:cast(Pid, {emit, Frag, State}).

%% What the REFER asks for (chappe_sip_hdr:refer_to/1): target URI, method
%% (INVITE, BYE, REFER, ...), URI headers, Replaces.
-spec target(refer()) -> target().
target(#refer{target = T}) -> T.

%% The process of the REFER's implicit subscription, undefined when there
%% is none (Refer-Sub: false). It ends once the final NOTIFY is out (or
%% cannot go out any more), so monitoring it tells when the referrer has
%% heard the result.
-spec subscription(refer()) -> pid() | undefined.
subscription(#refer{pid = Pid}) -> Pid.

%% The REFER's Referred-By value, which the request sent to the target
%% copies (RFC 3892 2.2). undefined when the REFER had none.
-spec referred_by(refer()) -> binary() | undefined.
referred_by(#refer{referred_by = RB}) -> RB.

rb(Req) -> chappe_sip_req:get(<<"referred-by">>, Req).

%% The dialog a Target-Dialog header names (RFC 4538; RFC 7647 4 requires a
%% REFER recipient to process it): an out-of-dialog REFER proves it knows
%% that dialog, which the application may use to authorize it.
-spec target_dialog(chappe_sip_req:req()) ->
    {ok, chappe_sip_dialog:dialog()}
    | {error, no_target_dialog | malformed | not_found}.
target_dialog(Req) ->
    case chappe_sip_req:get(<<"target-dialog">>, Req) of
        undefined ->
            {error, no_target_dialog};
        V ->
            case chappe_sip_hdr:target_dialog(V) of
                {ok, #{call_id := C, local_tag := L, remote_tag := R}} ->
                    chappe_sip_dialog:find(C, L, R);
                {error, _} = E ->
                    E
            end
    end.

%% Who sent a REFER, to tell a repeated one from a new one: the dialog it
%% came in, or the one its Target-Dialog names (target_dialog/1), by
%% Call-ID, local tag and remote tag; outside any dialog the request's
%% Call-ID and From tag. A REFER in a dialog and one outside it naming
%% that dialog have the same origin.
-spec origin(chappe_sip_req:req()) -> origin().
origin(Req) ->
    Msg = chappe_sip_req:msg(Req),
    CallId = chappe_sip_msg:call_id(Msg),
    FromTag = chappe_sip_msg:from_tag(Msg),
    case {chappe_sip_msg:to_tag(Msg), target_dialog(Req)} of
        {ToTag, _} when is_binary(ToTag) ->
            {dialog, CallId, ToTag, FromTag};
        {undefined, {ok, D}} ->
            {dialog, chappe_sip_dialog:call_id(D),
                chappe_sip_dialog:local_tag(D),
                chappe_sip_dialog:remote_tag(D)};
        {undefined, {error, _}} ->
            {request, CallId, FromTag}
    end.

%% ---- sender ----

%% Send a REFER, in Dialog or outside any dialog to Uri, and wait for its
%% final response. Target is the Refer-To URI, or a map for
%% chappe_sip_hdr:refer_to_value/1 (method, headers, display). Opts:
%%   replaces => chappe_sip_hdr:replaces()   embedded in Refer-To (RFC 3891)
%%   referred_by => binary() | map()         Referred-By (RFC 3892)
%%   refer_sub => false                      Refer-Sub: false (RFC 4488)
%%   target_dialog => Dialog | map()          outside a dialog (RFC 4538)
%%   headers, owner (default self()), timeout (ms, default 32000)
%% Outside a dialog, from/to/proxy/contact/auth go to chappe_sip:request/2.
%% A 202 counts as 200 (RFC 7647 5). {ok, Id, Info} on a 2xx: Info says
%% whether a subscription exists; the owner then gets refer_progress /
%% refer_done messages for Id.
-spec send(chappe_sip_dialog:dialog() | binary(), binary() | map(), map()) ->
    {ok, reference(), #{status := 200..299, subscription := boolean()}}
    | {error, {rejected, 300..699, chappe_sip_msg:msg()} | term()}.
send(To, Target, Opts) when is_binary(To) ->
    send_ood(To, Target, Opts);
send(D, Target, Opts) ->
    DPid = chappe_sip_dialog:pid(D),
    First = chappe_sip_refer_registry:bump(sent, DPid) =:= 1,
    Info0 = #{cseq => pending, first => First},
    Owner = maps:get(owner, Opts, self()),
    Id = chappe_sip_refer_registry:add(
        subscriber, {dialog, DPid}, Owner, Info0
    ),
    Spec = #{method => <<"REFER">>, headers => refer_headers(Target, Opts)},
    case chappe_sip_dialog:request(D, Spec) of
        {ok, Msg} -> sent(Id, Info0, Msg);
        {error, _} = Err -> forget(Id, Err)
    end.

send_ood(Uri, Target, Opts) ->
    Tag = chappe_sip_dialog:gen_tag(),
    Owner = maps:get(owner, Opts, self()),
    Info0 = #{cseq => any, first => true},
    Id = chappe_sip_refer_registry:add(subscriber, {tag, Tag}, Owner, Info0),
    UacOpts = (maps:with(
        [to, proxy, contact, contact_params, auth, flow], Opts
    ))#{
        method => <<"REFER">>,
        from => <<(from_base(Opts))/binary, ";tag=", Tag/binary>>,
        headers => refer_headers(Target, Opts) ++ tdialog(Opts)
    },
    case chappe_sip_uac:start(Uri, UacOpts) of
        {ok, Ref} ->
            Result = chappe_sip_uac:await_response(
                Ref, maps:get(timeout, Opts, 32000)
            ),
            flush_uac(Ref),
            case Result of
                {ok, Msg} ->
                    sent(Id, Info0, Msg);
                {error, #chappe_sip_error{status = St, response = M}} ->
                    forget(Id, {error, {rejected, St, M}});
                {error, _} = Err ->
                    forget(Id, Err)
            end;
        {error, _} = Err ->
            forget(Id, Err)
    end.

sent(Id, Info0, Msg) ->
    case chappe_sip_msg:status(Msg) of
        St when St >= 200, St < 300 ->
            case chappe_sip_msg:get(<<"refer-sub">>, Msg) of
                V when is_binary(V) ->
                    case string:lowercase(first_token(V)) of
                        <<"false">> ->
                            _ = forget(Id, ok),
                            {ok, Id, #{status => St, subscription => false}};
                        _ ->
                            subscribed(Id, Info0, Msg, St)
                    end;
                undefined ->
                    subscribed(Id, Info0, Msg, St)
            end;
        St ->
            forget(Id, {error, {rejected, St, Msg}})
    end.

subscribed(Id, #{cseq := pending} = Info0, Msg, St) ->
    {ok, #{seq := Seq}} = chappe_sip_msg:cseq(Msg),
    ok = chappe_sip_refer_registry:update(Id, Info0#{cseq => Seq}),
    {ok, Id, #{status => St, subscription => true}};
subscribed(Id, _Info0, _Msg, St) ->
    {ok, Id, #{status => St, subscription => true}}.

forget(Id, Result) ->
    ok = chappe_sip_refer_registry:delete(Id),
    Result.

%% the UAC's own events for this request (request_sent, provisionals)
flush_uac(Ref) ->
    receive
        {chappe_sip_uac, Ref, _} -> flush_uac(Ref)
    after 0 -> ok
    end.

refer_headers(Target, Opts) ->
    RT0 =
        case Target of
            #{} -> Target;
            Uri when is_binary(Uri) -> #{uri => Uri}
        end,
    RT =
        case maps:get(replaces, Opts, undefined) of
            undefined -> RT0;
            R -> RT0#{replaces => R}
        end,
    [{<<"Refer-To">>, chappe_sip_hdr:refer_to_value(RT)}] ++
        referred_by_hdr(maps:get(referred_by, Opts, undefined)) ++
        case maps:get(refer_sub, Opts, true) of
            false ->
                [
                    {<<"Refer-Sub">>, <<"false">>},
                    {<<"Supported">>, <<"norefersub">>}
                ];
            true ->
                []
        end ++
        maps:get(headers, Opts, []).

referred_by_hdr(undefined) ->
    [];
referred_by_hdr(RB) when is_binary(RB) -> [{<<"Referred-By">>, RB}];
referred_by_hdr(#{} = RB) ->
    [{<<"Referred-By">>, chappe_sip_hdr:referred_by_value(RB)}].

%% RFC 4538 3: the tags as the recipient sees them; our dialog's remote tag
%% is the recipient's local one
tdialog(#{target_dialog := TD}) when is_map(TD) ->
    [
        {<<"Target-Dialog">>, chappe_sip_hdr:target_dialog_value(TD)},
        {<<"Require">>, <<"tdialog">>}
    ];
tdialog(#{target_dialog := D}) ->
    TD = #{
        call_id => chappe_sip_dialog:call_id(D),
        local_tag => chappe_sip_dialog:remote_tag(D),
        remote_tag => chappe_sip_dialog:local_tag(D)
    },
    tdialog(#{target_dialog => TD});
tdialog(_) ->
    [].

from_base(#{from := From}) ->
    From;
from_base(_) ->
    engine_contact().

%% Answer a NOTIFY received outside any dialog when it belongs to a REFER
%% sent by send/3 outside a dialog. pass when it does not (another package,
%% or no REFER of ours): the caller answers it. See chappe_sip_refer_notify.
-spec handle_notify(chappe_sip_req:req(), chappe_sip_res:res()) ->
    handled | pass.
handle_notify(Req, Res) ->
    chappe_sip_refer_notify:handle_notify(Req, Res).

%% A NOTIFY handler for chappe_sip:notify/1: REFER NOTIFYs go to their
%% owner, anything else is answered 481 (RFC 6665 4.1.3).
-spec notify_handler() ->
    fun((chappe_sip_req:req(), chappe_sip_res:res()) -> ok).
notify_handler() ->
    chappe_sip_refer_notify:notify_handler().

%% the engine's bound contact as a name-addr (what a dialog-forming 2xx
%% carries by default)
engine_contact() ->
    Uri =
        case chappe_sip_engine:contact() of
            undefined ->
                <<"sip:anonymous.invalid">>;
            C ->
                case chappe_sip_hdr:name_addr(C) of
                    {ok, #{uri := U}} -> U;
                    _ -> C
                end
        end,
    <<"<", (hd(binary:split(Uri, <<";">>)))/binary, ">">>.
