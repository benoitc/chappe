%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc UAC public API (async-first).
%%
%% start/2 returns immediately with a reference; the caller (or an
%% explicit notify pid) receives events:
%%   {chappe_sip_uac, Ref, {request_sent, ReqInfo}}   after nta accepts the send;
%%                                                    ReqInfo #{call_id, uri,
%%                                                    method, cseq}, again for
%%                                                    each retry (auth, 3xx)
%%   {chappe_sip_uac, Ref, {early_dialog, Dialog}}     a 101..199 to an INVITE
%%                                                    formed an early dialog
%%                                                    (a new To tag), just
%%                                                    before its provisional
%%   {chappe_sip_uac, Ref, {provisional, Res}}         each 1xx
%%   {chappe_sip_uac, Ref, {answer, Msg}}              the 2xx, just before ok,
%%                                                    with report_answer => true
%%   {chappe_sip_uac, Ref, {ok, Dialog}}               INVITE answered (2xx)
%%   {chappe_sip_uac, Ref, {auth_state, State}}        just before a non-INVITE
%%                                                    2xx, with report_auth
%%   {chappe_sip_uac, Ref, {response, Res}}             non-INVITE final response
%%   {chappe_sip_uac, Ref, {error, SipError | term()}} failure
%% cancel/1 works from any process (it holds the fsm pid), so a caller
%% blocked in await/2 is not the only one who can cancel.
-module(chappe_sip_uac).

-export([start/2, await/2, await_response/2, cancel/1, cancel/2, abandon/1]).
-export([abandon/2]).

-include("chappe_sip_uac.hrl").
-opaque uac_ref() :: #uac_ref{}.
-export_type([uac_ref/0]).

%% Opts: #{method => binary() (default: the URI's method parameter, else
%%           INVITE; the parameter never goes in the Request-URI),
%%         from => binary(), to => binary(), contact => binary(),
%%         local_sdp => iodata(), headers => [{binary(), iodata()}],
%%         body => iodata(), content_type => binary(),
%%         proxy => binary() (the next hop, no Route header),
%%         route_set => [binary()] (Route values, a preloaded route set:
%%           RFC 3261 8.1.1.1, loose or strict first route),
%%         auth => #{user := binary(), pass := binary(), realm => binary()}
%%           or a list of them (a realm-less entry answers any realm), or
%%           fun((Challenge) -> Auth | none), Challenge the parsed
%%           challenge #{scheme := binary(), params := #{<<"realm">> ...}}
%%           (chappe_sip_hdr:auth/1); it runs in the UAC process, on this
%%           node, once or twice per challenge, and a fun that fails
%%           answers none,
%%         report_auth => boolean() (a non-INVITE 2xx is preceded by
%%           {auth_state, State} when credentials were sent),
%%         auth_state => State (from report_auth: the request carries
%%           credentials for those challenges at once, the next nonce
%%           count each; a stale nonce is answered again as usual),
%%         follow_redirects => boolean() (3xx Contacts tried best q first),
%%         keep_uri_on_redirect => boolean() (default false: a followed
%%           3xx Contact becomes the Request-URI and To; true keeps them
%%           and sends the request to the Contact as its next hop),
%%         no_ack => boolean() (3PCC: chappe_sip_dialog:ack/2 sends the ACK),
%%         answer => fun((Offer :: binary()) -> {ok, iodata()} | reject)
%%           (an INVITE without local_sdp: the answer to the offer in the
%%           2xx, sent in the ACK; without it the offer is refused),
%%         owner => pid(), notify => pid(),
%%         contact_params => binary() (after the Contact's `>', e.g. `;isfocus'),
%%         report_answer => boolean() (send the 2xx as {answer, Msg}),
%%         call_id => binary(), cseq => pos_integer() (a request of a
%%           dialog you keep yourself, such as a subscription refresh: its
%%           Call-ID and CSeq number; `to' then carries the remote tag),
%%         session_expires, min_se, session_refresher (RFC 4028, see
%%         chappe_sip_session_timer),
%%         call_ref => binary() (the call an INVITE serves, chappe_sip_call;
%%           default a new one), call_ref_header => boolean() (default
%%           true: the INVITE carries it as X-Chappe-Call, unless headers
%%           has one already), related => binary() (the call_ref of the
%%           call a transfer brings this one from, in its call record)}
%% A call_ref or related that is not a token of 1 to 128 characters is
%% {error, badarg}.
-spec start(binary(), map()) -> {ok, uac_ref()} | {error, term()}.
start(Uri, Opts) ->
    case {at_uac_cap(), chappe_sip_call:valid_opts(Opts)} of
        {_, false} ->
            {error, badarg};
        {true, true} ->
            {error, max_uac_transactions};
        {false, true} ->
            Ref = make_ref(),
            Notify = maps:get(notify, Opts, self()),
            Owner = maps:get(owner, Opts, Notify),
            Args = #{
                uri => Uri,
                opts => Opts,
                ref => Ref,
                notify => Notify,
                owner => Owner
            },
            case chappe_sip_uac_sup:start_uac(Args) of
                {ok, Pid} -> {ok, #uac_ref{pid = Pid, ref = Ref}};
                {error, Reason} -> {error, Reason}
            end
    end.

%% Enforce the advertised outgoing-transaction ceiling.
at_uac_cap() ->
    Active = proplists:get_value(
        active,
        supervisor:count_children(chappe_sip_uac_sup),
        0
    ),
    Active >= chappe_sip_config:get(max_uac_transactions).

%% Await an INVITE result (dialog on 2xx).
-spec await(uac_ref(), timeout()) ->
    {ok, chappe_sip_dialog:dialog()} | {error, term()}.
await(#uac_ref{pid = Pid} = UacRef, Timeout) ->
    MRef = erlang:monitor(process, Pid),
    receive
        {chappe_sip_uac, UacRef, {ok, Dialog}} ->
            erlang:demonitor(MRef, [flush]),
            {ok, Dialog};
        {chappe_sip_uac, UacRef, {error, Reason}} ->
            erlang:demonitor(MRef, [flush]),
            {error, Reason};
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, {uac_down, Reason}}
    after Timeout ->
        erlang:demonitor(MRef, [flush]),
        {error, timeout}
    end.

%% Await a non-INVITE final response.
-spec await_response(uac_ref(), timeout()) ->
    {ok, chappe_sip_msg:msg()} | {error, term()}.
await_response(#uac_ref{pid = Pid} = UacRef, Timeout) ->
    MRef = erlang:monitor(process, Pid),
    receive
        {chappe_sip_uac, UacRef, {response, Res}} ->
            erlang:demonitor(MRef, [flush]),
            {ok, Res};
        {chappe_sip_uac, UacRef, {error, Reason}} ->
            erlang:demonitor(MRef, [flush]),
            {error, Reason};
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, {uac_down, Reason}}
    after Timeout ->
        erlang:demonitor(MRef, [flush]),
        {error, timeout}
    end.

%% CANCEL an in-progress INVITE (before a final response).
-spec cancel(uac_ref()) -> ok.
cancel(#uac_ref{pid = Pid}) ->
    gen_statem:cast(Pid, cancel).

%% cancel/1 with Opts: #{headers => [{binary(), iodata()}]} added to the
%% CANCEL, e.g. a Reason (RFC 3326):
%%   cancel(Ref, #{headers => [{<<"Reason">>, <<"SIP;cause=200">>}]})
-spec cancel(uac_ref(), #{headers => [{binary(), iodata()}]}) -> ok.
cancel(#uac_ref{pid = Pid}, Opts) ->
    gen_statem:cast(Pid, {cancel, maps:get(headers, Opts, [])}).

%% Give up on an INVITE nobody waits for any more (create_uac's timeout):
%% CANCEL it while it rings and, should a 2xx win the race, ACK and BYE
%% that call instead of handing it to anyone.
-spec abandon(uac_ref()) -> ok.
abandon(#uac_ref{pid = Pid}) ->
    gen_statem:cast(Pid, abandon).

%% abandon/1 with Opts: headers => [{binary(), iodata()}] go on the CANCEL
%% and, should a 2xx win the race, on its BYE (a Reason, RFC 3326, say);
%% why => chappe_sip_cdr:reason() is what the call record says ended the
%% call (default cancel).
-spec abandon(uac_ref(), #{
    headers => [{binary(), iodata()}], why => chappe_sip_cdr:reason()
}) -> ok.
abandon(#uac_ref{pid = Pid}, Opts) ->
    gen_statem:cast(
        Pid,
        {abandon, maps:get(why, Opts, cancel), maps:get(headers, Opts, [])}
    ).
