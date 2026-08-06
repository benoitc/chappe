%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Inbound connection setup. Starts an chappe_esl_conn linked to the caller and waits
%% for the authentication handshake to finish. The caller becomes the initial
%% controlling process and receives event messages. On success returns the
%% connection pid; on failure returns a tagged error.
-module(chappe_esl_inbound).

-export([connect/1]).

-spec connect(map()) -> {ok, pid()} | {error, term()}.
connect(Opts0) ->
    Timeout = maps:get(connect_timeout, Opts0, 5000),
    Opts = Opts0#{mode => inbound, owner => self()},
    case chappe_esl_conn:start_link(Opts) of
        {ok, Pid} ->
            wait_ready(Pid, Timeout);
        {error, Reason} ->
            {error, Reason}
    end.

wait_ready(Pid, Timeout) ->
    receive
        {chappe_esl_ready, Pid} ->
            {ok, Pid};
        {chappe_esl_auth_error, Pid, Reason} ->
            {error, Reason}
    after Timeout + 1000 ->
        _ = chappe_esl_conn:close(Pid),
        {error, timeout}
    end.
