%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% chappe_audio's own pg scope, `chappe_audio', started by its supervisor
%% (chappe-erlang-patterns rule 4): it touches no other app's scope, its
%% lookups use its own, and stopping the app stops it.
-module(chappe_audio_pg_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

all() ->
    [own_scope, other_scopes_untouched, stop_takes_scope].

init_per_testcase(_Case, Config) ->
    _ = application:stop(chappe_audio),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = application:stop(chappe_audio),
    ok.

%% The scope is chappe_audio's, under its supervisor, and its streams and
%% its store are found through it.
own_scope(_Config) ->
    {ok, _} = application:ensure_all_started(chappe_audio),
    Scope = whereis(chappe_audio),
    ?assert(is_pid(Scope)),
    ?assert(
        lists:keymember(Scope, 2, supervisor:which_children(chappe_audio_sup))
    ),
    {ok, L} = chappe_audio:listen(#{}),
    Ref = <<"own">>,
    {ok, S, _Url} = chappe_audio:open(L, #{ref => Ref}),
    ?assertEqual([S], pg:get_members(chappe_audio, {chappe_audio, Ref})),
    ?assertEqual([S], chappe_audio:streams(Ref)),
    ?assertEqual(1, length(pg:get_members(chappe_audio, chappe_audio_store))).

%% No shared scope: chappe_audio neither starts the `chappe' scope nor
%% joins one another app runs.
other_scopes_untouched(_Config) ->
    Holder = spawn(fun() ->
        {ok, _} = pg:start_link(chappe),
        receive
            stop -> ok
        end
    end),
    wait(fun() -> is_pid(whereis(chappe)) end),
    {ok, _} = application:ensure_all_started(chappe_audio),
    {ok, L} = chappe_audio:listen(#{}),
    {ok, _S, _} = chappe_audio:open(L, #{ref => <<"x">>}),
    ?assertEqual([], pg:which_groups(chappe)),
    exit(Holder, kill),
    wait(fun() -> whereis(chappe) =:= undefined end),
    ?assertMatch([_], chappe_audio:streams(<<"x">>)).

%% Stopping the app stops its scope; starting it again starts a new one.
stop_takes_scope(_Config) ->
    {ok, _} = application:ensure_all_started(chappe_audio),
    ?assertEqual(undefined, whereis(chappe)),
    ok = application:stop(chappe_audio),
    ?assertEqual(undefined, whereis(chappe_audio)),
    {ok, _} = application:ensure_all_started(chappe_audio),
    ?assert(is_pid(whereis(chappe_audio))).

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
