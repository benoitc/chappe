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
-module(chappe_sip_dialog).

-export([create_uas/3]).
-export([
    destroy/1,
    modify/2,
    request/2,
    id/1,
    local_tag/1,
    remote_tag/1,
    call_id/1,
    remote_sdp/1,
    set_handled/2,
    wait/1,
    monitor/1
]).
-export([gen_tag/0, make/2]).

-include("chappe_sip_dialog.hrl").
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
%% Returns after the leg is created and the response is enqueued.
-spec create_uas(chappe_sip_req:req(), chappe_sip_res:res(), map()) ->
    {ok, dialog()} | {error, term()}.
create_uas(Req, Res, Opts) ->
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

%% Tear the dialog down (BYE for an INVITE dialog).
-spec destroy(dialog()) -> ok | {error, term()}.
destroy(#dialog{pid = Pid}) ->
    gen_statem:call(Pid, destroy, 32000).

%% Re-INVITE the dialog. SdpSpec: an SDP body, or hold | unhold to toggle
%% the media direction. Serialized: only one in-dialog transaction runs at
%% a time. Returns the peer's answer SDP.
-spec modify(dialog(), iodata() | hold | unhold) ->
    {ok, binary()} | {error, term()}.
modify(#dialog{pid = Pid}, SdpSpec) ->
    gen_statem:call(Pid, {modify, SdpSpec}, 32000).

%% Send an arbitrary in-dialog request (INFO, REFER, UPDATE, ...). ReqSpec:
%% #{method := binary(), headers => [{binary(), iodata()}],
%%   content_type => binary(), body => iodata()}. Returns the final
%% response message.
-spec request(dialog(), map()) -> {ok, chappe_sip_msg:msg()} | {error, term()}.
request(#dialog{pid = Pid}, ReqSpec) ->
    gen_statem:call(Pid, {request, ReqSpec}, 32000).

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
