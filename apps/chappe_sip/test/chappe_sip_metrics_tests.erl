%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% chappe_sip_metrics on the instrument registry, without the SIP stack.
-module(chappe_sip_metrics_tests).

-include_lib("eunit/include/eunit.hrl").

metrics_test_() ->
    {setup,
     fun() ->
             {ok, _} = application:ensure_all_started(instrument),
             ok = chappe_sip_metrics:setup()
     end,
     fun(_) -> ok end,
     [fun counts_requests/0,
      fun counts_responses/0,
      fun unknown_method_is_other/0,
      fun setup_twice/0,
      fun disabled_records_nothing/0,
      fun refresh_without_stack/0,
      fun prometheus_text/0]}.

counts_requests() ->
    B = count(chappe_sip_requests, [<<"in">>, <<"INVITE">>]),
    ok = chappe_sip_metrics:request(in, <<"INVITE">>),
    ok = chappe_sip_metrics:request(in, <<"INVITE">>),
    ok = chappe_sip_metrics:request(out, <<"INVITE">>),
    ?assertEqual(B + 2, count(chappe_sip_requests, [<<"in">>, <<"INVITE">>])),
    ?assert(count(chappe_sip_requests, [<<"out">>, <<"INVITE">>]) >= 1),
    %% a method we could not read is not counted
    ok = chappe_sip_metrics:request(in, undefined).

counts_responses() ->
    B = count(chappe_sip_responses, [<<"out">>, <<"486">>]),
    ok = chappe_sip_metrics:response(out, 486),
    ok = chappe_sip_metrics:guard_blocked(rate),
    ?assertEqual(B + 1, count(chappe_sip_responses, [<<"out">>, <<"486">>])),
    ?assert(count(chappe_sip_guard_blocked, [<<"rate">>]) >= 1).

unknown_method_is_other() ->
    B = count(chappe_sip_requests, [<<"in">>, <<"other">>]),
    ok = chappe_sip_metrics:request(in, <<"XYZZY">>),
    ?assertEqual(B + 1, count(chappe_sip_requests, [<<"in">>, <<"other">>])),
    ?assertEqual(0, count(chappe_sip_requests, [<<"in">>, <<"XYZZY">>])).

setup_twice() ->
    ?assertEqual(ok, chappe_sip_metrics:setup()).

disabled_records_nothing() ->
    application:set_env(chappe_sip, metrics, false),
    try
        ok = chappe_sip_metrics:setup(),
        ?assertNot(chappe_sip_metrics:enabled()),
        B = count(chappe_sip_requests, [<<"in">>, <<"BYE">>]),
        ok = chappe_sip_metrics:request(in, <<"BYE">>),
        ?assertEqual(B, count(chappe_sip_requests, [<<"in">>, <<"BYE">>]))
    after
        application:unset_env(chappe_sip, metrics),
        ok = chappe_sip_metrics:setup()
    end.

%% the gauges' sources are not running: refresh shrugs
refresh_without_stack() ->
    ?assertEqual(ok, chappe_sip_metrics:refresh()).

prometheus_text() ->
    ok = chappe_sip_metrics:request(in, <<"OPTIONS">>),
    Text = instrument_prometheus:format(),
    ?assertMatch({_, _}, binary:match(Text, <<"chappe_sip_requests_total">>)),
    ?assertMatch({_, _}, binary:match(Text, <<"method=\"OPTIONS\"">>)),
    ?assert(is_function(chappe_sip_metrics:handler(), 1)).

count(Name, Labels) ->
    case instrument_metric:get_counter_vec(Name, Labels) of
        N when is_number(N) -> round(N);
        _ -> 0
    end.
