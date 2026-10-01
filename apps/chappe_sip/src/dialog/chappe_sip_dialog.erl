%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Dialog public API and handle.
%%
%% A dialog is created only by chappe_sip (create_uas now; create_uac/b2bua
%% later), never by application code. The handle wraps the dialog fsm pid
%% and its id. Events reach the owner process as messages:
%%   {chappe_sip_dialog, Dialog, Event, Req, Res}
%% where Event is destroy | ack | info | ... and Res is a live response
%% handle for claimed events (undefined otherwise). Unclaimed in-dialog
%% requests are auto-answered by the fsm and reported as
%%   {chappe_sip_dialog, Dialog, {auto_answered, Event}, Req}
%%
%% A dialog created from a SUBSCRIBE is a subscription (RFC 6665). Its owner
%% also receives {chappe_sip_dialog, Dialog, {refreshed, Seconds}, Req} and
%% {chappe_sip_dialog, Dialog, unsubscribed, Req}, and the destroy reason is
%% terminated | expired | {notify_failed, Status}.
-module(chappe_sip_dialog).

-export([create_uas/3]).
-export([
    destroy/1,
    destroy/2,
    modify/2,
    modify/3,
    request/2,
    notify/2,
    id/1,
    local_tag/1,
    remote_tag/1,
    call_id/1,
    remote_sdp/1,
    local_sdp/1,
    local_contact/1,
    set_handled/2,
    wait/1,
    monitor/1
]).
-export([gen_tag/0, make/2, pid/1]).

-include("chappe_sip_dialog.hrl").

%% An in-dialog request gets its final response, a 408, by Timer F (64*T1,
%% 32 s) at the latest; a re-INVITE may first wait up to Timer H for the
%% ACK of an INVITE of the peer (RFC 3261 14.1), then Timer B.
-define(REQUEST_TIMEOUT, 40000).
-define(MODIFY_TIMEOUT, 75000).
-opaque dialog() :: #dialog{}.
-export_type([dialog/0]).

%% Build a handle (used by chappe_sip_dialog_fsm when addressing the owner).
-spec make(pid(), non_neg_integer()) -> dialog().
make(Pid, Id) -> #dialog{pid = Pid, id = Id}.

%% Answer an incoming dialog-forming request as a UAS. Opts:
%%   #{local_sdp => iodata(), status => 100..699 (default 200),
%%     reason => binary(), headers => [{binary(), iodata()}],
%%     handled_events => [atom()] | all, owner => pid(),
%%     on_owner_exit => destroy | continue}
%% For a SUBSCRIBE also:
%%   #{expires => non_neg_integer() (the most granted, default 3600),
%%     min_expires => non_neg_integer() (below it: 423, default 0),
%%     unsubscribe_grace => non_neg_integer() (ms, default 5000)}
%% The 2xx carries the granted Expires: the request's, capped by expires.
%% For an INVITE, session timers (RFC 4028):
%%   #{session_expires => pos_integer() (ask for one when the caller
%%       supports timers and did not), min_se => pos_integer() (below it:
%%       422, default 90), session_refresher => uac | uas (when we pick)}
%% The owner of a timed dialog gets destroy with reason session_expired
%% when the session was not refreshed in time.
%% Returns after the leg is created and the response is enqueued.
-spec create_uas(chappe_sip_req:req(), chappe_sip_res:res(), map()) ->
    {ok, dialog()} | {error, term()}.
create_uas(Req, Res, Opts) ->
    case chappe_sip_req:method(Req) of
        <<"SUBSCRIBE">> -> create_subscription(Req, Res, Opts);
        <<"INVITE">> -> create_session(Req, Res, Opts);
        _ -> create_uas_1(Req, Res, Opts)
    end.

%% RFC 4028 9: the 2xx answers the session timer the INVITE asks for (or
%% asks for one); an interval below min_se is refused 422 with Min-SE
create_session(Req, Res, Opts) ->
    Cfg = chappe_sip_session_timer:config(Opts),
    case maps:get(status, Opts, 200) of
        S when S >= 200, S < 300 ->
            case chappe_sip_session_timer:uas(chappe_sip_req:msg(Req), Cfg) of
                {reject, Min} ->
                    _ = chappe_sip_res:send(Res, 422, #{
                        reason => <<"Session Interval Too Small">>,
                        headers => [{<<"Min-SE">>, integer_to_binary(Min)}]
                    }),
                    {error, {session_interval_too_small, Min}};
                {ok, Headers, St} ->
                    create_uas_1(Req, Res, Opts#{
                        headers => maps:get(headers, Opts, []) ++ Headers,
                        session_timer => St
                    })
            end;
        _ ->
            create_uas_1(Req, Res, Opts)
    end.

create_subscription(Req, Res, Opts) ->
    Max = maps:get(expires, Opts, 3600),
    Min = maps:get(min_expires, Opts, 0),
    case chappe_sip_dialog_fsm:requested_expires(Req, Max) of
        N when N > 0, N < Min ->
            %% RFC 6665 4.2.1.1: too brief, 423 with Min-Expires
            _ = chappe_sip_res:send(Res, 423, #{
                reason => <<"Interval Too Brief">>,
                headers => [{<<"Min-Expires">>, integer_to_binary(Min)}]
            }),
            {error, {interval_too_brief, Min}};
        N ->
            Granted = min(N, Max),
            Sub = #{
                expires => Granted,
                max => Max,
                min => Min,
                event => chappe_sip_req:get(<<"event">>, Req),
                unsubscribe_grace => maps:get(unsubscribe_grace, Opts, 5000)
            },
            Headers =
                maps:get(headers, Opts, []) ++
                    [{<<"Expires">>, integer_to_binary(Granted)}],
            create_uas_1(Req, Res, Opts#{
                headers => Headers, subscription => Sub
            })
    end.

create_uas_1(Req, Res, Opts) ->
    Owner = maps:get(owner, Opts, self()),
    case chappe_sip_engine:create_uas(Req, Opts#{owner => Owner}) of
        {ok, Pid} ->
            case gen_statem:call(Pid, await_ready, 32000) of
                {ok, Id} ->
                    %% the dialog-forming final response went out via the
                    %% dialog path; stop the worker exit from sending 500
                    chappe_sip_res:mark_final(Res),
                    {ok, #dialog{pid = Pid, id = Id}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Tear the dialog down: a BYE for an INVITE dialog, a final NOTIFY
%% (Subscription-State: terminated;reason=noresource) for a subscription.
-spec destroy(dialog()) -> ok | {error, term()}.
destroy(Dialog) ->
    destroy(Dialog, #{}).

%% destroy/1 with Opts: #{headers => [{binary(), iodata()}]} added to the
%% BYE, e.g. a Reason (RFC 3326):
%%   destroy(D, #{headers => [{<<"Reason">>, <<"Q.850;cause=16">>}]})
%% For an early dialog of ours still ringing (found through a Replaces) the
%% headers go on the CANCEL instead.
-spec destroy(dialog(), #{headers => [{binary(), iodata()}]}) ->
    ok | {error, term()}.
destroy(#dialog{pid = Pid}, Opts) ->
    %% a UAS dialog holds its BYE until its 2xx is ACKed (Timer H, 32 s),
    %% then the BYE itself may take Timer F
    gen_statem:call(Pid, {destroy, Opts}, 70000).

%% Re-INVITE the dialog. SdpSpec: an SDP body, or hold | unhold to toggle
%% the media direction. Serialized: only one in-dialog transaction runs at
%% a time. Returns the peer's answer SDP.
-spec modify(dialog(), iodata() | hold | unhold) ->
    {ok, binary()} | {error, term()}.
modify(#dialog{pid = Pid}, SdpSpec) ->
    gen_statem:call(Pid, {modify, SdpSpec}, ?MODIFY_TIMEOUT).

%% modify/2 with Opts. retry_on_glare => true: on a 491 (both sides
%% re-INVITEd at once) try once more after the RFC 3261 14.1 wait, 2.1 to
%% 4 s when we own the Call-ID, 0 to 2 s otherwise. A second 491, or a 491
%% without the option, returns {error, #chappe_sip_error{status = 491}}.
-spec modify(dialog(), iodata() | hold | unhold, #{retry_on_glare => boolean()}) ->
    {ok, binary()} | {error, term()}.
modify(#dialog{pid = Pid}, SdpSpec, Opts) ->
    gen_statem:call(Pid, {modify, SdpSpec, Opts}, ?MODIFY_TIMEOUT).

%% Send an arbitrary in-dialog request (INFO, REFER, UPDATE, ...). ReqSpec:
%% #{method := binary(), headers => [{binary(), iodata()}],
%%   content_type => binary(), body => iodata()}. Returns the final
%% response message.
-spec request(dialog(), map()) -> {ok, chappe_sip_msg:msg()} | {error, term()}.
request(#dialog{pid = Pid}, ReqSpec) ->
    gen_statem:call(Pid, {request, ReqSpec}, ?REQUEST_TIMEOUT).

%% Send a NOTIFY in the dialog. Spec:
%%   #{state := active | pending | {terminated, Reason},
%%     event => binary(), body => iodata(), content_type => binary(),
%%     headers => [{binary(), iodata()}], expires => non_neg_integer()}
%% In a subscription, Event defaults to the SUBSCRIBE's and active/pending
%% carry expires=<seconds left>; once a terminated NOTIFY is answered the
%% subscription ends and the owner gets destroy with reason terminated.
%% Elsewhere (the implicit REFER subscription of an INVITE dialog) event is
%% required and expires is sent only when given. Returns the final response.
-spec notify(dialog(), map()) -> {ok, chappe_sip_msg:msg()} | {error, term()}.
notify(#dialog{pid = Pid}, Spec) ->
    gen_statem:call(Pid, {notify, Spec}, ?REQUEST_TIMEOUT).

%% The dialog fsm's pid (what chappe_sip_refer keys a dialog's REFER
%% subscriptions by).
-spec pid(dialog()) -> pid().
pid(#dialog{pid = Pid}) -> Pid.

-spec id(dialog()) -> non_neg_integer().
id(#dialog{id = Id}) -> Id.

-spec local_tag(dialog()) -> binary().
local_tag(#dialog{pid = Pid}) ->
    gen_statem:call(Pid, local_tag).

%% The peer's dialog tag (the From tag for a UAS dialog, the To tag for a
%% UAC dialog). undefined until the peer has tagged the dialog.
-spec remote_tag(dialog()) -> binary() | undefined.
remote_tag(#dialog{pid = Pid}) ->
    gen_statem:call(Pid, remote_tag).

-spec call_id(dialog()) -> binary().
call_id(#dialog{pid = Pid}) ->
    gen_statem:call(Pid, call_id).

%% The peer's SDP (INVITE offer for a UAS dialog, 2xx answer for a UAC
%% dialog). Empty binary if none.
-spec remote_sdp(dialog()) -> binary().
remote_sdp(#dialog{pid = Pid}) ->
    gen_statem:call(Pid, remote_sdp).

%% Our SDP as the peer last got it (our offer or answer). Empty binary if
%% none.
-spec local_sdp(dialog()) -> binary().
local_sdp(#dialog{pid = Pid}) ->
    gen_statem:call(Pid, local_sdp).
%% The Contact our side of the dialog advertises (a name-addr), for the 2xx
%% of a target refresh request the owner answers itself, such as a REFER.
%% undefined when the dialog was built without one.
-spec local_contact(dialog()) -> binary() | undefined.
local_contact(#dialog{pid = Pid}) ->
    gen_statem:call(Pid, local_contact).

%% Change the set of in-dialog events the owner will handle itself.
-spec set_handled(dialog(), [atom()] | all) -> ok.
set_handled(#dialog{pid = Pid}, Events) ->
    gen_statem:call(Pid, {set_handled, Events}).

%% Block until the dialog terminates (convenience for simple handlers).
-spec wait(dialog()) -> {destroyed, term()}.
wait(#dialog{pid = Pid}) ->
    MRef = erlang:monitor(process, Pid),
    receive
        {chappe_sip_dialog, #dialog{pid = Pid}, destroy, ReqOrReason} ->
            erlang:demonitor(MRef, [flush]),
            {destroyed, ReqOrReason};
        {'DOWN', MRef, process, Pid, Reason} ->
            {destroyed, Reason}
    end.

%% Monitor the dialog fsm, so a caller blocked on dialog events also learns of
%% an abnormal fsm exit (which emits no destroy' message).
-spec monitor(dialog()) -> reference().
monitor(#dialog{pid = Pid}) ->
    erlang:monitor(process, Pid).

%% 32-bit random dialog tag, hex.
-spec gen_tag() -> binary().
gen_tag() ->
    binary:encode_hex(crypto:strong_rand_bytes(6), lowercase).
