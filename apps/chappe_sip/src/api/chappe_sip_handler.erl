%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Optional behaviour for structured UAS applications.
%%
%% Instead of writing a raw INVITE handler that loops on dialog messages,
%% a module implements this behaviour and lets chappe_sip_handler drive the
%% lifecycle: it answers (or rejects) the call, then translates the
%% dialog's event messages into callbacks until the dialog is destroyed.
%%
%% Example:
%%   -module(my_app).
%%   -behaviour(chappe_sip_handler).
%%   -export([init/1, handle_dialog/4, terminate/2]).
%%   init(_Req) -> {answer, #{local_sdp => Sdp}, #{}}.
%%   handle_dialog(info, _Req, Res, S) -> chappe_sip_res:send(Res, 200), {ok, S};
%%   handle_dialog(_Ev, _Req, _Res, S) -> {ok, S}.
%%   terminate(_Reason, _S) -> ok.
%%
%%   chappe_sip:invite(fun(Req, Res) -> chappe_sip_handler:start(my_app, Req, Res) end).
-module(chappe_sip_handler).

-export([start/3]).

%% Decide what to do with the incoming request.
-callback init(chappe_sip_req:req()) ->
    {answer, Opts :: map(), State :: term()}
    | {reject, Status :: 100..699, State :: term()}
    | {ignore, State :: term()}.

%% Handle an in-dialog event (info, notify, refer, modify, ack, ...).
%% For claimed events Res is a live response handle; for auto-answered
%% events it is undefined.
-callback handle_dialog(
    Event :: atom() | tuple(),
    chappe_sip_req:req() | term(),
    chappe_sip_res:res() | undefined,
    State :: term()
) ->
    {ok, NewState :: term()} | {stop, NewState :: term()}.

%% Called when the dialog ends (peer BYE, engine restart, or stop).
-callback terminate(Reason :: term(), State :: term()) -> any().

-optional_callbacks([terminate/2]).

%% Run the handler for one incoming request. Blocks until the dialog ends
%% (or returns immediately for reject/ignore). Call from an INVITE handler.
-spec start(module(), chappe_sip_req:req(), chappe_sip_res:res()) -> ok.
start(Module, Req, Res) ->
    case Module:init(Req) of
        {answer, Opts, State} ->
            case chappe_sip:create_uas(Req, Res, Opts#{owner => self()}) of
                {ok, Dialog} ->
                    Ref = chappe_sip_dialog:monitor(Dialog),
                    loop(Module, Dialog, Ref, State);
                {error, Reason} ->
                    terminate(Module, {create_failed, Reason}, State)
            end;
        {reject, Status, State} ->
            _ = chappe_sip_res:send(Res, Status),
            terminate(Module, rejected, State);
        {ignore, State} ->
            terminate(Module, ignored, State)
    end.

loop(Module, Dialog, Ref, State) ->
    receive
        {chappe_sip_dialog, Dialog, destroy, ReqOrReason} ->
            _ = call_dialog(Module, destroy, ReqOrReason, undefined, State),
            terminate(Module, {destroyed, ReqOrReason}, State);
        {'DOWN', Ref, process, _, Reason} ->
            %% the dialog fsm exited abnormally (no destroy message)
            terminate(Module, {destroyed, Reason}, State);
        {chappe_sip_dialog, Dialog, Event, Req, Res} ->
            case call_dialog(Module, Event, Req, Res, State) of
                {ok, S1} ->
                    loop(Module, Dialog, Ref, S1);
                {stop, S1} ->
                    _ = chappe_sip_dialog:destroy(Dialog),
                    terminate(Module, stopped, S1)
            end;
        {chappe_sip_dialog, Dialog, Event, Req} ->
            case call_dialog(Module, Event, Req, undefined, State) of
                {ok, S1} ->
                    loop(Module, Dialog, Ref, S1);
                {stop, S1} ->
                    _ = chappe_sip_dialog:destroy(Dialog),
                    terminate(Module, stopped, S1)
            end
    end.

call_dialog(Module, Event, Req, Res, State) ->
    Module:handle_dialog(Event, Req, Res, State).

terminate(Module, Reason, State) ->
    case erlang:function_exported(Module, terminate, 2) of
        true ->
            _ = Module:terminate(Reason, State),
            ok;
        false ->
            ok
    end.
