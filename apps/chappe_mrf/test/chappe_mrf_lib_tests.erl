%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_mrf_lib_tests).

-include_lib("eunit/include/eunit.hrl").

to_bin_test() ->
    ?assertEqual(<<"a">>, chappe_mrf_lib:to_bin(<<"a">>)),
    ?assertEqual(<<"mute">>, chappe_mrf_lib:to_bin(mute)),
    ?assertEqual(<<"42">>, chappe_mrf_lib:to_bin(42)),
    ?assertEqual(<<"ab">>, chappe_mrf_lib:to_bin(["a", <<"b">>])).

done_test() ->
    ?assertEqual(ok, chappe_mrf_lib:done({ok, x})),
    ?assertEqual({error, x}, chappe_mrf_lib:done({error, x})).

api_ok_test() ->
    ?assertEqual(ok, chappe_mrf_lib:api_ok({ok, <<"+OK">>})),
    ?assertEqual({error, <<"-ERR no">>}, chappe_mrf_lib:api_ok({ok, <<"-ERR no">>})),
    ?assertEqual({error, closed}, chappe_mrf_lib:api_ok({error, closed})).

new_id_test() ->
    A = chappe_mrf_lib:new_id(),
    ?assertEqual(20, byte_size(A)),
    ?assertNotEqual(A, chappe_mrf_lib:new_id()).
