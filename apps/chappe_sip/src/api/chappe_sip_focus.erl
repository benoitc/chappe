%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The SIP side of a conference focus (RFC 4579) and its conference state
%% notifier (RFC 4575 over RFC 6665), as a library for the process that
%% owns the conference.
%%
%% The app keeps one process per conference (typically a gen_server) and a
%% focus() in its state. It:
%%   - puts contact/1 (the conference URI with isfocus) and headers/1 on
%%     every dialog it forms and on its OPTIONS 200, and contact_params/0
%%     on the INVITEs it sends;
%%   - hands each SUBSCRIBE for the conference to subscribe/4, from the
%%     handler of the conference package (chappe_sip:event_package/2),
%%     naming itself as the owner;
%%   - calls update/2 with the conference as a chappe_sip_confinfo:conf()
%%     whenever it changes, passes every message it does not know to
%%     handle_info/2, and calls stop/1 when the conference ends.
%%
%% Each watcher gets the full state at once and on every refresh, then
%% partial documents; versions count per subscription, and so can the
%% view: a subscriber given its own view (subscribe/4) sees the conference
%% through it (RFC 4575 8.2). Changes are
%% coalesced so one watcher never gets two NOTIFYs closer than
%% min_interval ms (RFC 4575 3.9, 5 s by default); a change held back is
%% sent when the interval has passed, so nothing is lost. NOTIFYs go
%% through one process per watcher: a slow watcher never blocks the
%% conference.
-module(chappe_sip_focus).

-include("chappe_sip.hrl").

-export([contact/1, contact_params/0, headers/1, privacy_requested/1]).
-export([departure/1, referred/1, media/2, leg_status/1, refer/4]).
-export([check_subscribe/1, subscribe/4]).
-export([new/1, update/2, handle_info/2, stop/1, subscriptions/1]).

-export_type([focus/0]).

-define(CONFERENCE_INFO, <<"application/conference-info+xml">>).
-define(FOCUS_ALLOW,
    <<"INVITE, ACK, CANCEL, OPTIONS, BYE, REFER, SUBSCRIBE, NOTIFY">>
).
-define(FOCUS_ACCEPT,
    <<"application/sdp, application/conference-info+xml, message/sipfrag">>
).

-record(focus, {
    entity :: binary(),
    gap :: non_neg_integer(),
    %% whether watchers see the dialog identifiers (RFC 4575 5.7.9)
    call_info :: boolean(),
    %% the conference as the app gave it; each watcher sees it through its
    %% view
    model :: chappe_sip_confinfo:conf(),
    %% per subscription dialog id: dialog, notifier, the version and model
    %% last sent, when, a pending flush timer, and whether it is ending
    subs = #{} :: #{non_neg_integer() => sub()}
}).

-type sub() :: #{
    dialog := chappe_sip_dialog:dialog(),
    view := view() | undefined,
    notifier := pid(),
    version := non_neg_integer(),
    sent := chappe_sip_confinfo:conf() | undefined,
    last := integer(),
    timer := reference() | undefined,
    ending := boolean()
}.

-opaque focus() :: #focus{}.

%% What one subscriber may see of the conference.
-type view() :: fun((chappe_sip_confinfo:conf()) -> chappe_sip_confinfo:conf()).
-export_type([view/0]).

%% ---- identity and capabilities ----

%% The Contact of every focus dialog: the conference URI with isfocus
%% (RFC 4579 4.2, 5.1).
-spec contact(binary()) -> binary().
contact(ConfUri) ->
    <<"<", ConfUri/binary, ">;isfocus">>.

%% For a UAC contact_params option: the focus's own INVITEs carry isfocus
%% too (RFC 4579 5.2).
-spec contact_params() -> binary().
contact_params() ->
    <<";isfocus">>.

%% What the focus puts on its INVITE 2xx and OPTIONS 200: Contact, and the
%% Allow, Accept, Allow-Events and Supported RFC 4579 5.13 lists.
-spec headers(binary()) -> [{binary(), binary()}].
headers(Contact) ->
    [
        {<<"Contact">>, Contact},
        {<<"Allow">>, ?FOCUS_ALLOW},
        {<<"Accept">>, ?FOCUS_ACCEPT},
        {<<"Allow-Events">>, <<"conference">>},
        {<<"Supported">>, <<"replaces">>}
    ].

%% The request asks that its sender's identity be withheld (RFC 3323
%% Privacy: id, user or header); show that participant through
%% chappe_sip_confinfo:anonymize/2 (RFC 4579 6).
-spec privacy_requested(chappe_sip_req:req()) -> boolean().
privacy_requested(Req) ->
    lists:any(
        fun(T) -> lists:member(T, [<<"id">>, <<"user">>, <<"header">>]) end,
        header_tokens(<<"privacy">>, [<<";">>, <<",">>], Req)
    ).

%% ---- what SIP says about an endpoint (RFC 4575 5.7) ----

%% How a leg left, for its disconnection-method (RFC 4575 5.7.6), from the
%% reason its dialog's destroy message carries or the error its INVITE got:
%% the peer's BYE is departed, the focus's own is booted, 486 and 600 are
%% busy, anything else failed.
-spec departure(term()) -> departed | booted | failed | busy.
departure(byed) ->
    booted;
departure({error, E}) ->
    departure(E);
departure(#chappe_sip_error{status = S}) when S =:= 486; S =:= 600 ->
    busy;
departure(Why) ->
    case is_bye(Why) of
        true -> departed;
        false -> failed
    end.

is_bye(Why) ->
    try
        chappe_sip_req:method(Why) =:= <<"BYE">>
    catch
        _:_ -> false
    end.

%% ---- REFER to the focus (RFC 4579 5.5, 5.11) ----

%% A REFER to the focus, in a participant's dialog D or outside any dialog
%% (D undefined: a REFER to the conference URI). What it means follows
%% its Request-URI: a REFER to the conference URI, or in a dialog whose
%% Contact carries isfocus, is a REFER to a focus, and a Refer-To for an
%% INVITE (the default method) asks it to bring the target in (add, 5.5);
%% in a dialog of a room that hides it is a focus (no isfocus, 4.2) it is
%% an RFC 3515 transfer of that member (transfer). A Refer-To with
%% method=BYE asks the focus to remove that participant (5.11). Any other
%% method is refused 403: a focus does not fan out requests it does not
%% understand (RFC 5368 10). The app's policy decides all three, with
%%   #{action := add | remove | transfer, target := Uri,
%%     replaces := chappe_sip_hdr:replaces() | undefined,
%%     referrer := NameAddr, referred_by := binary() | undefined}
%% replaces is the Replaces the Refer-To carries: the focus puts it on
%% its INVITE to the target, which brings a point-to-point call into the
%% conference (5.10); chappe_sip_refer:target/1 has it too.
%% referrer is the REFER's From, the identity its dialog (or its digest,
%% when the app checked one) vouches for; referred_by is only claimed
%% (RFC 3892 6). Without a policy everything is refused 403. Once
%% allowed, the REFER is accepted (200 and NOTIFY 100 Trying,
%% chappe_sip_refer:accept/3,4) and the app carries it out, then reports
%% with chappe_sip_refer:final/2. Opts: policy, and accept's (owner,
%% expires, ...).
-spec refer(
    chappe_sip_dialog:dialog() | undefined,
    chappe_sip_req:req(),
    chappe_sip_res:res(),
    map()
) ->
    {add | remove | transfer, binary(), chappe_sip_refer:refer()}
    | {error, {rejected, 300..699} | term()}.
refer(D, Req, Res, Opts) ->
    %% the policy below decides a BYE as well
    case chappe_sip_refer:check(Req, #{authorize => fun(_, _) -> true end}) of
        {reject, Status, Reason} ->
            reject(Res, Status, Reason);
        {ok, #{method := M, target := Target} = RT} ->
            case focus_action(M, is_focus(D)) of
                undefined ->
                    reject(Res, 403, <<"Forbidden">>);
                Action ->
                    Info = #{
                        action => Action,
                        target => Target,
                        replaces => maps:get(replaces, RT, undefined),
                        referrer => chappe_sip_b2b_hdr:caller(
                            chappe_sip_req:get(<<"from">>, Req)
                        ),
                        referred_by => chappe_sip_req:get(
                            <<"referred-by">>, Req
                        )
                    },
                    allowed(D, Req, Res, Info, Opts)
            end
    end.

focus_action(<<"INVITE">>, true) -> add;
focus_action(<<"INVITE">>, false) -> transfer;
focus_action(<<"BYE">>, _Focus) -> remove;
focus_action(_M, _Focus) -> undefined.

%% whether the REFER reached a focus: the conference URI itself, or a
%% dialog whose Contact (the member's remote target) carries isfocus
is_focus(undefined) ->
    true;
is_focus(D) ->
    try chappe_sip_dialog:local_contact(D) of
        C when is_binary(C) ->
            case chappe_sip_hdr:name_addr(C) of
                {ok, #{params := Ps}} ->
                    lists:member(
                        <<"isfocus">>,
                        [chappe_sip_lib:lower(K) || K <- maps:keys(Ps)]
                    );
                _ ->
                    false
            end;
        _ ->
            false
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
    case chappe_sip_refer:referred_by(Refer) of
        undefined ->
            #{};
        RB ->
            case chappe_sip_hdr:name_addr(RB) of
                {ok, #{uri := U}} -> #{by => U};
                _ -> #{}
            end
    end.

%% The <media> of an endpoint from the SDP it negotiated: one per m= line
%% it did not reject, numbered from 1, with the SDP media type (RFC 4575
%% 5.8.2), the direction, the label of the conference's available media
%% stream of that type when there is one (5.8.3), and the SSRC the
%% endpoint sends, from the stream's first a=ssrc, as src-id (5.8.4).
-spec media(binary(), [#{label := binary(), type := atom()}]) ->
    [chappe_sip_confinfo:media()].
media(Sdp, Available) ->
    {Session, Streams} = sdp_streams(Sdp),
    [
        with_src_id(
            ssrc(Attrs),
            stream_media(
                I,
                Type,
                direction(Attrs, direction(Session, sendrecv)),
                Available
            )
        )
     || {I, {Type, Port, Attrs}} <- lists:enumerate(Streams), Port =/= <<"0">>
    ].

with_src_id(undefined, M) -> M;
with_src_id(Ssrc, M) -> M#{src_id => Ssrc}.

%% the first a=ssrc:<id> of a stream (RFC 5576 4.1); attributes are kept
%% last first
ssrc(Attrs) ->
    Ids = [
        Id
     || <<"ssrc:", V/binary>> <- lists:reverse(Attrs),
        Id <- [hd(binary:split(V, <<" ">>))],
        Id =/= <<>>,
        is_ssrc(Id)
    ],
    case Ids of
        [Id | _] -> Id;
        [] -> undefined
    end.

is_ssrc(Id) ->
    try binary_to_integer(Id) of
        N -> N >= 0 andalso N =< 16#FFFFFFFF
    catch
        error:badarg -> false
    end.

%% connected, or on_hold when the peer sends and receives nothing from us:
%% every stream it keeps is sendonly or inactive (RFC 3264 8.4)
-spec leg_status(binary()) -> connected | on_hold.
leg_status(Sdp) ->
    {Session, Streams} = sdp_streams(Sdp),
    Dirs = [
        direction(Attrs, direction(Session, sendrecv))
     || {_, Port, Attrs} <- Streams, Port =/= <<"0">>
    ],
    case Dirs =/= [] andalso lists:all(fun held/1, Dirs) of
        true -> on_hold;
        false -> connected
    end.

held(D) -> D =:= sendonly orelse D =:= inactive.

stream_media(I, Type, Dir, Available) ->
    Id = integer_to_binary(I),
    M0 = #{id => Id, status => Dir},
    case media_type(Type) of
        undefined ->
            M0;
        T ->
            M = M0#{type => T},
            case [L || #{label := L, type := AT} <- Available, AT =:= T] of
                [L | _] -> M#{label => L};
                [] -> M
            end
    end.

media_type(T) ->
    Known = [audio, video, text, application, message, image],
    case [A || A <- Known, atom_to_binary(A) =:= T] of
        [A] -> A;
        [] -> undefined
    end.

%% session attributes, then [{MediaType, Port, Attrs}] per m= line
sdp_streams(Sdp) ->
    Lines = binary:split(Sdp, [<<"\r\n">>, <<"\n">>], [global]),
    {Session, Streams} = lists:foldl(
        fun
            (<<"m=", M/binary>>, {Sess, Acc}) ->
                case binary:split(M, <<" ">>, [global]) of
                    [T, P | _] -> {Sess, [{string:lowercase(T), P, []} | Acc]};
                    _ -> {Sess, Acc}
                end;
            (<<"a=", A/binary>>, {Sess, []}) ->
                {[A | Sess], []};
            (<<"a=", A/binary>>, {Sess, [{T, P, As} | Acc]}) ->
                {Sess, [{T, P, [A | As]} | Acc]};
            (_, Acc) ->
                Acc
        end,
        {[], []},
        Lines
    ),
    {Session, lists:reverse(Streams)}.

direction(Attrs, Default) ->
    case [binary_to_atom(A) || A <- Attrs, lists:member(A, directions())] of
        [D | _] -> D;
        [] -> Default
    end.

directions() ->
    [<<"sendrecv">>, <<"sendonly">>, <<"recvonly">>, <<"inactive">>].

%% ---- subscriptions ----

%% Whether the focus serves this SUBSCRIBE: the conference package (else
%% 489, RFC 6665 4.2.1.1) with an Accept that allows conference-info+xml
%% (else 406, RFC 4575 3.4). No Accept means the package default.
-spec check_subscribe(chappe_sip_req:req()) ->
    ok | {error, 406 | 489, [{binary(), binary()}]}.
check_subscribe(Req) ->
    case event_package(chappe_sip_req:get(<<"event">>, Req)) of
        <<"conference">> ->
            case header_tokens(<<"accept">>, [<<",">>], Req) of
                [] ->
                    ok;
                Types ->
                    case lists:any(fun accepts_conference_info/1, Types) of
                        true ->
                            ok;
                        false ->
                            {error, 406, [{<<"Accept">>, ?CONFERENCE_INFO}]}
                    end
            end;
        _ ->
            {error, 489, [{<<"Allow-Events">>, <<"conference">>}]}
    end.

%% Answer a SUBSCRIBE to the conference, from the handler process. The
%% subscription dialog belongs to Owner, the conference process, which
%% gets {chappe_sip_focus, subscribed, Dialog, Opts} and must pass it to
%% handle_info/2: the full state goes out from there. A refused SUBSCRIBE
%% is answered here. Opts: contact (required, see contact/1), expires (the
%% most granted, default 600), min_expires, headers, and view: what this
%% subscriber sees, a fun from the conference as given to update/2 (the
%% focus's entity and version set) to the conference it may see, in place
%% of the focus-wide call_info policy (RFC 4575 8.2: a moderator may see
%% <call-info>, others not). A subscriber the app does not want to tell
%% anything still gets 200 and believable documents (RFC 6665 6.2): give
%% it a view such as fun(C) -> C#{users => []} end.
-spec subscribe(chappe_sip_req:req(), chappe_sip_res:res(), pid(), #{
    contact := binary(),
    expires => non_neg_integer(),
    min_expires => non_neg_integer(),
    headers => [{binary(), binary()}],
    view => view()
}) ->
    {ok, chappe_sip_dialog:dialog()} | {error, term()}.
subscribe(Req, Res, Owner, #{contact := Contact} = Opts) ->
    case check_subscribe(Req) of
        ok ->
            UasOpts = #{
                owner => Owner,
                expires => maps:get(expires, Opts, 600),
                min_expires => maps:get(min_expires, Opts, 0),
                headers => headers(Contact) ++ maps:get(headers, Opts, [])
            },
            case chappe_sip:create_uas(Req, Res, UasOpts) of
                {ok, Dialog} ->
                    Owner !
                        {chappe_sip_focus, subscribed, Dialog,
                            maps:with([view], Opts)},
                    {ok, Dialog};
                {error, _} = Err ->
                    Err
            end;
        {error, Status, Headers} ->
            _ = chappe_sip_res:send(Res, Status, #{headers => Headers}),
            {error, Status}
    end.

%% ---- the conference state ----

%% Opts: entity (the conference URI, required), min_interval (ms between
%% two NOTIFYs to one watcher, default 5000), call_info (whether the
%% endpoints' <call-info> goes out: the privacy policy RFC 4575 5.7.9 has
%% the focus consult; default false, it is left out).
-spec new(#{
    entity := binary(),
    min_interval => non_neg_integer(),
    call_info => boolean()
}) ->
    focus().
new(#{entity := Entity} = Opts) ->
    #focus{
        entity = Entity,
        gap = maps:get(min_interval, Opts, 5000),
        call_info = maps:get(call_info, Opts, false),
        model = #{entity => Entity, version => 0, users => []}
    }.

%% The conference as it is now. Its entity and version are the focus's
%% own; every watcher is told what changed.
-spec update(chappe_sip_confinfo:conf(), focus()) -> focus().
update(Conf, #focus{entity = E} = F) ->
    changed(F#focus{model = Conf#{entity => E, version => 0}}).

%% the conference as this watcher may see it: through its own view, else
%% the focus's policy. The entity and version stay the focus's.
sub_view(#{view := View}, #focus{entity = E, model = M}) when
    is_function(View, 1)
->
    (View(M))#{entity => E, version => 0};
sub_view(_Sub, #focus{model = M} = F) ->
    view(M, F).

%% the conference as watchers may see it by default
view(Conf, #focus{call_info = true}) ->
    Conf;
view(#{users := Users} = Conf, _F) ->
    Conf#{
        users => [
            case U of
                #{endpoints := Eps} ->
                    U#{endpoints => [maps:remove(call_info, Ep) || Ep <- Eps]};
                _ ->
                    U
            end
         || U <- Users
        ]
    };
view(Conf, _F) ->
    Conf.

%% A message for the focus: {ok, Focus}, or ignore when it is not one.
-spec handle_info(term(), focus()) -> {ok, focus()} | ignore.
handle_info({chappe_sip_focus, subscribed, Dialog}, F) ->
    handle_info({chappe_sip_focus, subscribed, Dialog, #{}}, F);
handle_info({chappe_sip_focus, subscribed, Dialog, Opts}, F) ->
    Notifier = start_notifier(Dialog),
    Sub = #{
        dialog => Dialog,
        view => maps:get(view, Opts, undefined),
        notifier => Notifier,
        version => 0,
        sent => undefined,
        last => 0,
        timer => undefined,
        ending => false
    },
    {ok, send_full(chappe_sip_dialog:id(Dialog), Sub, active, F)};
handle_info({chappe_sip_focus, flush, Id}, F) ->
    case maps:find(Id, F#focus.subs) of
        {ok, #{ending := false} = Sub} ->
            {ok, send_partial(Id, Sub#{timer => undefined}, F)};
        _ ->
            {ok, F}
    end;
handle_info({chappe_sip_dialog, D, Event, _Req}, F) ->
    Id = chappe_sip_dialog:id(D),
    case maps:find(Id, F#focus.subs) of
        {ok, Sub} -> {ok, dialog_event(Id, Event, Sub, F)};
        error -> ignore
    end;
handle_info({chappe_sip_dialog, D, _Event, _Req, _Res}, F) ->
    case maps:is_key(chappe_sip_dialog:id(D), F#focus.subs) of
        true -> {ok, F};
        false -> ignore
    end;
handle_info(_Msg, _F) ->
    ignore.

%% The conference is over: every subscription ends with one terminated
%% NOTIFY, reason noresource (RFC 4575 3.3).
-spec stop(focus()) -> ok.
stop(#focus{subs = Subs}) ->
    maps:foreach(
        fun
            (_Id, #{ending := true}) ->
                ok;
            (_Id, #{notifier := N, timer := T}) ->
                cancel(T),
                N ! finish
        end,
        Subs
    ).

%% The subscription dialogs being served.
-spec subscriptions(focus()) -> [chappe_sip_dialog:dialog()].
subscriptions(#focus{subs = Subs}) ->
    [D || #{dialog := D, ending := false} <- maps:values(Subs)].

%% ---- internal: subscription events ----

%% a refresh gets the full state again (RFC 4575 3.2)
dialog_event(Id, {refreshed, _Secs}, #{ending := false} = Sub, F) ->
    send_full(Id, Sub, active, F);
%% an unsubscribe gets the full state in a terminated NOTIFY, the last one
dialog_event(Id, unsubscribed, #{ending := false} = Sub, F) ->
    send_full(Id, Sub, {terminated, timeout}, F);
dialog_event(Id, destroy, #{notifier := N, timer := T}, F) ->
    cancel(T),
    N ! stop,
    F#focus{subs = maps:remove(Id, F#focus.subs)};
dialog_event(_Id, _Event, _Sub, F) ->
    F.

%% ---- internal: documents ----

%% Tell every watcher what changed, at most once per gap: a change coming
%% sooner is held and coalesced into one partial when the gap has passed.
changed(#focus{subs = Subs, gap = Gap} = F) ->
    Now = now_ms(),
    maps:fold(
        fun
            (_Id, #{ending := true}, Acc) ->
                Acc;
            (_Id, #{timer := T}, Acc) when T =/= undefined ->
                Acc;
            (Id, #{last := Last} = Sub, Acc) when Now - Last >= Gap ->
                send_partial(Id, Sub, Acc);
            (Id, #{last := Last} = Sub, Acc) ->
                T = erlang:send_after(
                    Last + Gap - Now, self(), {chappe_sip_focus, flush, Id}
                ),
                put_sub(Id, Sub#{timer => T}, Acc)
        end,
        F,
        Subs
    ).

%% the whole document, as the next version of this subscription
send_full(Id, #{notifier := N, version := V0, timer := T} = Sub, State, F) ->
    cancel(T),
    Model = sub_view(Sub, F),
    V = V0 + 1,
    Body = chappe_sip_confinfo:full(Model#{version => V}),
    N ! {notify, spec(State, Body)},
    Ending = State =/= active,
    put_sub(
        Id,
        Sub#{
            version => V,
            sent => Model,
            last => now_ms(),
            timer => undefined,
            ending => Ending
        },
        F
    ).

%% what changed since this subscription's last document, if anything
send_partial(Id, #{notifier := N, version := V0, sent := Sent} = Sub, F) ->
    New = sub_view(Sub, F),
    case Sent =:= New of
        true ->
            put_sub(Id, Sub, F);
        false ->
            V = V0 + 1,
            case
                chappe_sip_confinfo:partial(
                    Sent#{version => V0}, New#{version => V}, V
                )
            of
                {ok, Body} ->
                    N ! {notify, spec(active, Body)},
                    put_sub(
                        Id, Sub#{version => V, sent => New, last => now_ms()}, F
                    );
                {error, _} ->
                    send_full(Id, Sub, active, F)
            end
    end.

spec(State, Body) ->
    #{state => State, content_type => ?CONFERENCE_INFO, body => Body}.

put_sub(Id, Sub, F) ->
    F#focus{subs = maps:put(Id, Sub, F#focus.subs)}.

cancel(undefined) ->
    ok;
cancel(T) ->
    _ = erlang:cancel_timer(T),
    ok.

now_ms() ->
    erlang:monotonic_time(millisecond).

%% ---- internal: the notifier ----

%% One per watcher: NOTIFYs go out in order. `finish' ends the
%% subscription through chappe_sip_dialog:destroy/1, which sends the one
%% terminated;reason=noresource NOTIFY; the dialog fsm sends it just the
%% same, once, if the owner dies first. When the owner is gone the
%% notifier sends nothing more.
start_notifier(Dialog) ->
    Owner = self(),
    spawn(fun() ->
        MRef = monitor(process, Owner),
        notifier(Dialog, MRef)
    end).

notifier(Dialog, MRef) ->
    receive
        {'DOWN', MRef, process, _, _} ->
            ok;
        {notify, #{state := {terminated, _}} = Spec} ->
            _ = call(fun() -> chappe_sip_dialog:notify(Dialog, Spec) end);
        {notify, Spec} ->
            _ = call(fun() -> chappe_sip_dialog:notify(Dialog, Spec) end),
            notifier(Dialog, MRef);
        finish ->
            _ = call(fun() -> chappe_sip_dialog:destroy(Dialog) end);
        stop ->
            ok
    end.

%% the dialog may be gone already: that ends the notifier quietly
call(F) ->
    try
        F()
    catch
        exit:_ -> {error, gone}
    end.

%% ---- internal: headers ----

event_package(undefined) ->
    undefined;
event_package(V) ->
    string:lowercase(string:trim(hd(binary:split(V, <<";">>)))).

accepts_conference_info(Type) ->
    lists:member(Type, [?CONFERENCE_INFO, <<"application/*">>, <<"*/*">>]).

%% lowercase tokens of every value of a header, split on Seps; for Accept
%% the media type parameters are dropped
header_tokens(Name, Seps, Req) ->
    Values = chappe_sip_msg:get_all(Name, chappe_sip_req:msg(Req)),
    [
        string:lowercase(string:trim(hd(binary:split(T, <<";">>))))
     || V <- Values, T <- binary:split(V, Seps, [global]), T =/= <<>>
    ].
