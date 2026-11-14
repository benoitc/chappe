%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The `chappe' pg scope, which chappe_audio shares with the other chappe
%% apps of the node: lookups work whichever app started it, survive it
%% going away, and chappe_audio stopping leaves it to the others.
-module(chappe_audio_pg_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

all() ->
    [scope_started_elsewhere, scope_dies, others_start_after, stop_leaves_scope].

init_per_testcase(_Case, Config) ->
    _ = application:stop(chappe_audio),
    stop_scope(),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = application:stop(chappe_audio),
    stop_scope(),
    ok.

%% Another app started the scope first (as chappe_sip does): chappe_audio
%% uses it, and its streams and store are found through it.
scope_started_elsewhere(_Config) ->
    Other = other_app_scope(),
    {ok, _} = application:ensure_all_started(chappe_audio),
    ?assertEqual(Other, whereis(chappe)),
    {S, Ref} = stream(<<"elsewhere">>),
    ?assertEqual([S], chappe_audio:streams(Ref)),
    ?assertEqual(1, length(pg:get_members(chappe, chappe_audio_store))).

%% The app that ran the scope stops it: chappe_audio starts it again and
%% puts its streams and its store back in their groups, so lookups go on.
scope_dies(_Config) ->
    Other = other_app_scope(),
    {ok, _} = application:ensure_all_started(chappe_audio),
    {S, Ref} = stream(<<"dies">>),
    Mon = monitor(process, Other),
    exit(Other, kill),
    {'DOWN', Mon, process, Other, killed} = recv(),
    wait(fun() -> is_pid(whereis(chappe)) end),
    ?assertNotEqual(Other, whereis(chappe)),
    wait(fun() -> chappe_audio:streams(Ref) =:= [S] end),
    wait(fun() -> length(pg:get_members(chappe, chappe_audio_store)) =:= 1 end),
    ?assert(is_process_alive(S)).

%% chappe_audio started the scope: an app starting it after it is told it
%% runs already, the way chappe_sip's supervisor expects (ignore), and
%% shares it.
others_start_after(_Config) ->
    {ok, _} = application:ensure_all_started(chappe_audio),
    Scope = whereis(chappe),
    ?assert(is_pid(Scope)),
    ?assertEqual({error, {already_started, Scope}}, pg:start_link(chappe)),
    {S, Ref} = stream(<<"after">>),
    ok = pg:join(chappe, {other_app, Ref}, self()),
    ?assertEqual([S], chappe_audio:streams(Ref)),
    ?assertEqual([self()], pg:get_members(chappe, {other_app, Ref})).

%% Stopping chappe_audio leaves the scope, and the other apps' groups,
%% where they are.
stop_leaves_scope(_Config) ->
    {ok, _} = application:ensure_all_started(chappe_audio),
    Scope = whereis(chappe),
    ok = pg:join(chappe, other_app, self()),
    ok = application:stop(chappe_audio),
    ?assertEqual(Scope, whereis(chappe)),
    ?assertEqual([self()], pg:get_members(chappe, other_app)),
    {ok, _} = application:ensure_all_started(chappe_audio),
    ?assertEqual(Scope, whereis(chappe)).

%% ---- helpers ----

%% A scope run by "another app": a process that started it, linked.
other_app_scope() ->
    Test = self(),
    spawn(fun() ->
        {ok, P} = pg:start_link(chappe),
        Test ! {scope, P},
        receive
            stop -> ok
        end
    end),
    receive
        {scope, P} -> P
    after 5000 -> ct:fail(no_scope)
    end.


stream(Ref) ->
    {ok, L} = chappe_audio:listen(#{}),
    {ok, S, _Url} = chappe_audio:open(L, #{ref => Ref, connect_timeout => 60000}),
    {S, Ref}.

stop_scope() ->
    case whereis(chappe) of
        undefined ->
            ok;
        P ->
            Mon = monitor(process, P),
            exit(P, kill),
            receive
                {'DOWN', Mon, process, P, _} -> ok
            end
    end.

recv() ->
    receive
        M -> M
    after 5000 -> ct:fail(timeout)
    end.

wait(F) -> wait(F, 100).

wait(_F, 0) ->
    ct:fail(wait_timeout);
wait(F, N) ->
    case F() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait(F, N - 1)
    end.
