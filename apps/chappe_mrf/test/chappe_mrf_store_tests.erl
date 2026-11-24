%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_mrf_store_tests).

-include_lib("eunit/include/eunit.hrl").

local_path_test_() ->
    {setup,
        fun() ->
            application:set_env(chappe_mrf, shared_dir, #{
                freeswitch => "/media", local => "/srv/fs"
            })
        end,
        fun(_) -> application:unset_env(chappe_mrf, shared_dir) end, [
            ?_assertEqual(
                {ok, <<"/srv/fs/a/b.wav">>},
                chappe_mrf_store:local_path(<<"/media/a/b.wav">>)
            ),
            ?_assertEqual(
                {error, not_shared},
                chappe_mrf_store:local_path("/mediax/b.wav")
            ),
            ?_assertEqual(
                {error, not_shared}, chappe_mrf_store:local_path("/tmp/b.wav")
            ),
            ?_assertEqual(
                {error, not_shared}, chappe_mrf_store:local_path("/media")
            )
        ]}.

same_path_without_env_test() ->
    application:unset_env(chappe_mrf, shared_dir),
    ?assertEqual(
        {ok, <<"/media/x.wav">>},
        chappe_mrf_store:local_path(["/media", "/x.wav"])
    ).

wanted_test() ->
    ?assert(chappe_mrf_store:wanted(#{store => default})),
    ?assertNot(chappe_mrf_store:wanted(#{store => none})),
    ?assertNot(chappe_mrf_store:wanted(#{})).
