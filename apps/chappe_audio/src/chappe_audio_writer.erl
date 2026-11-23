%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc One recording being written: the process that holds the backend's
%% handle, under chappe_audio_writer_sup (temporary).
%%
%% Its owner is the process that feeds it, which it monitors: when the
%% owner dies, normally or not, the writer finishes the recording with
%% what it has and stops. The bound on queued writes is applied by the
%% sender (chappe_audio_store:write/2). A failed write gives the
%% recording up and stops the writer with {write_failed, Reason}, which
%% the owner sees if it monitors it; the call it records goes on.
-module(chappe_audio_writer).
-behaviour(gen_server).

-export([start_link/2, close/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
    backend :: module(),
    handle :: term(),
    owner_mon :: reference()
}).

-type state() :: #state{}.

-spec start_link(chappe_audio_store:meta(), pid()) ->
    {ok, pid()} | {error, term()}.
start_link(Meta, Owner) ->
    gen_server:start_link(?MODULE, {Meta, Owner}, []).

-spec close(pid(), map()) -> {ok, binary()} | {error, term()}.
close(Pid, Extra) ->
    try
        gen_server:call(Pid, {close, Extra}, 15000)
    catch
        exit:{noproc, _} -> {error, closed};
        exit:{normal, _} -> {error, closed}
    end.

-spec init({chappe_audio_store:meta(), pid()}) ->
    {ok, state()} | {stop, term()}.
init({Meta, Owner}) ->
    {Backend, Config} = chappe_audio_store_srv:backend(),
    case Backend:open(Meta, Config) of
        {ok, Handle} ->
            ok = writing(Backend, Handle),
            {ok, #state{
                backend = Backend,
                handle = Handle,
                owner_mon = monitor(process, Owner)
            }};
        {error, Reason} ->
            {stop, Reason}
    end.

%% Tell the store which partial file is this live writer's, so its sweep
%% leaves it, however long the feeder writes nothing.
writing(Backend, Handle) ->
    case erlang:function_exported(Backend, part, 1) of
        true -> chappe_audio_store_srv:writing(self(), Backend:part(Handle));
        false -> ok
    end.

handle_call({close, Extra}, _From, #state{backend = B, handle = H} = S) ->
    {stop, normal, B:close(H, Extra), S#state{handle = undefined}};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({write, Pcm}, #state{backend = B, handle = H} = S) ->
    case B:write(H, Pcm) of
        {ok, H1} ->
            {noreply, S#state{handle = H1}};
        {error, Reason} ->
            ok = B:abort(H),
            {stop, {write_failed, Reason}, S#state{handle = undefined}}
    end;
handle_info({'DOWN', Mon, process, _, _}, #state{owner_mon = Mon} = S) ->
    #state{backend = B, handle = H} = S,
    _ = B:close(H, #{}),
    {stop, normal, S#state{handle = undefined}};
handle_info(_Info, S) ->
    {noreply, S}.
