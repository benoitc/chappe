%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

-module(chappe_sip_lib_tests).
-include_lib("eunit/include/eunit.hrl").

lower_test() ->
    ?assertEqual(<<"invite sip:a@b">>, chappe_sip_lib:lower(<<"INVITE SIP:A@B">>)),
    ?assertEqual(<<>>, chappe_sip_lib:lower(<<>>)),
    %% bytes outside A-Z, UTF-8 or not, are left alone
    ?assertEqual(<<"caf", 16#C3, 16#89, 16#FF>>,
                 chappe_sip_lib:lower(<<"CAF", 16#C3, 16#89, 16#FF>>)).

trim_test() ->
    ?assertEqual(<<"a b">>, chappe_sip_lib:trim(<<" \ta b\t ">>)),
    ?assertEqual(<<>>, chappe_sip_lib:trim(<<>>)),
    ?assertEqual(<<>>, chappe_sip_lib:trim(<<" \t ">>)),
    %% only SP and HTAB are OWS
    ?assertEqual(<<"\r\na\n">>, chappe_sip_lib:trim(<<" \r\na\n ">>)).

unhex_test() ->
    ?assertEqual([0, 9, 10, 15, 10, 15],
                 [chappe_sip_lib:unhex(C) || C <- "09afAF"]),
    ?assertEqual(error, chappe_sip_lib:unhex($g)),
    ?assertEqual(error, chappe_sip_lib:unhex($%)).

to_int_test() ->
    ?assertEqual(3600, chappe_sip_lib:to_int(<<"3600">>, undefined)),
    ?assertEqual(60, chappe_sip_lib:to_int(<<" 60\t">>, undefined)),
    ?assertEqual(-1, chappe_sip_lib:to_int(<<"-1">>, undefined)),
    ?assertEqual(undefined, chappe_sip_lib:to_int(<<"soon">>, undefined)),
    ?assertEqual(5, chappe_sip_lib:to_int(<<>>, 5)).

delta_seconds_test() ->
    ?assertEqual(0, chappe_sip_lib:delta_seconds(<<"0">>, 300)),
    ?assertEqual(90, chappe_sip_lib:delta_seconds(<<" 90 ">>, 300)),
    ?assertEqual(300, chappe_sip_lib:delta_seconds(<<"-1">>, 300)),
    ?assertEqual(300, chappe_sip_lib:delta_seconds(<<"1.5">>, 300)),
    ?assertEqual(undefined, chappe_sip_lib:delta_seconds(<<"x">>, undefined)).
