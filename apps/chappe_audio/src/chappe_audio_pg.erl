%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc chappe_audio's pg scope, `chappe_audio': its own, started early by
%% chappe_audio_sup (after the RTP receivers), so a restart of the tree
%% restarts it and stopping the app stops it (chappe-erlang-patterns rule
%% 4: one scope per app, no app starts another's). The groups are
%% {chappe_audio, Ref} for a call's streams and chappe_audio_store for the
%% stores of the cluster.
-module(chappe_audio_pg).

-export([scope/0, join/2, members/1]).

-define(SCOPE, chappe_audio).

-spec scope() -> atom().
scope() ->
    ?SCOPE.

%% Put Pid in Group while it lives (pg drops it when it exits).
-spec join(term(), pid()) -> ok.
join(Group, Pid) ->
    pg:join(?SCOPE, Group, Pid).

%% The members of Group on every node.
-spec members(term()) -> [pid()].
members(Group) ->
    pg:get_members(?SCOPE, Group).
