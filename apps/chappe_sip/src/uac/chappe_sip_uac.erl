%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc UAC public API (async-first).
%%
%% start/2 returns immediately with a reference; the caller (or an
%% explicit notify pid) receives events:
%%   {chappe_sip_uac, Ref, {request_sent, ReqInfo}}   after nta accepts the send
%%   {chappe_sip_uac, Ref, {provisional, Res}}         each 1xx
%%   {chappe_sip_uac, Ref, {answer, Msg}}              the 2xx, just before ok,
%%                                                    with report_answer => true
%%   {chappe_sip_uac, Ref, {ok, Dialog}}               INVITE answered (2xx)
%%   {chappe_sip_uac, Ref, {response, Res}}             non-INVITE final response
%%   {chappe_sip_uac, Ref, {error, SipError | term()}} failure
%% cancel/1 works from any process (it holds the fsm pid), so a caller
%% blocked in await/2 is not the only one who can cancel.
-module(chappe_sip_uac).

-export([start/2, await/2, await_response/2, cancel/1, cancel/2]).

-include("chappe_sip_uac.hrl").
-opaque uac_ref() :: #uac_ref{}.
-export_type([uac_ref/0]).

%% Opts: #{method => binary() (default INVITE),
%%         from => binary(), to => binary(), contact => binary(),
%%         local_sdp => iodata(), headers => [{binary(), iodata()}],
%%         body => iodata(), content_type => binary(),
%%         proxy => binary(), auth => #{user := binary(), pass := binary()},
%%         follow_redirects => boolean(), no_ack => boolean(),
%%         answer => fun((Offer :: binary()) -> {ok, iodata()} | reject)
%%           (an INVITE without local_sdp: the answer to the offer in the
%%           2xx, sent in the ACK; without it the offer is refused),
%%         owner => pid(), notify => pid(),
%%         contact_params => binary() (after the Contact's `>', e.g. `;isfocus'),
%%         report_answer => boolean() (send the 2xx as {answer, Msg}),
%%         session_expires, min_se, session_refresher (RFC 4028, see
%%         chappe_sip_session_timer)}
-spec start(binary(), map()) -> {ok, uac_ref()} | {error, term()}.
start(Uri, Opts) ->
    case at_uac_cap() of
        true ->
            {error, max_uac_transactions};
        false ->
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
