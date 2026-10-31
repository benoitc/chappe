%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Moving a leg from one conference to another. The move runs in a
%% short-lived process of its own, so no conference ever calls another
%% and two rooms swapping legs cannot wait on each other.
-module(chappe_mix_move).

-include("chappe_mix_leg.hrl").

-export([run/3]).

%% Run the move in a process of its own and wait for its result.
-spec run(pid(), pos_integer(), pid()) ->
    {ok, pos_integer()}
    | {error, not_found | source_down | destination_down | refused}.
run(From, Id, To) ->
    Parent = self(),
    Tag = make_ref(),
    {Pid, Ref} = spawn_monitor(fun() -> Parent ! {Tag, move(From, Id, To)} end),
    receive
        {Tag, Result} ->
            erlang:demonitor(Ref, [flush]),
            Result;
        {'DOWN', Ref, process, Pid, Reason} ->
            exit(Reason)
    end.

%% Move leg Id from conference From to conference To. Runs in a process of
%% its own (see run/3), so no conference ever calls
%% another and two rooms swapping legs cannot wait on each other.
%%
%% The source detaches the leg and hands this process its sockets. The
%% destination then adopts the leg first and gets the sockets second, so
%% every packet it receives is for a leg it knows. If the destination is
%% gone or refuses, the leg goes back to the source under its id; if the
%% source has gone too, the sockets close when this process exits.
-spec move(pid(), pos_integer(), pid()) ->
    {ok, pos_integer()}
    | {error, not_found | source_down | destination_down | refused}.
move(From, Id, To) ->
    case call(From, {detach_leg, Id, self()}) of
        {ok, Leg} -> adopt(Leg, From, To);
        {error, down} -> {error, source_down};
        {error, not_found} -> {error, not_found}
    end.

adopt(Leg, From, To) ->
    case call(To, {adopt_leg, Leg}) of
        {ok, NewId} ->
            _ = chappe_mix_conf:give(chappe_mix_leg:socks(Leg), To),
            {ok, NewId};
        Refused ->
            _ =
                call(From, {return_leg, Leg}) =:= {ok, Leg#leg.id} andalso
                    chappe_mix_conf:give(chappe_mix_leg:socks(Leg), From),
            case Refused of
                {error, down} -> {error, destination_down};
                _ -> {error, refused}
            end
    end.

%% A conference only does local work in a call, so waiting on one has no
%% timeout; it ends when the conference answers or dies.
call(Conf, Req) ->
    try
        gen_server:call(Conf, Req, infinity)
    catch
        exit:_ -> {error, down}
    end.
