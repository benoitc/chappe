%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% A REGISTER on a node whose local replica lags: the compare-and-swap on
%% the stale version fails, and the retry must read the region's value,
%% not the same stale replica again (chappe_sip_location_lagging).
-module(chappe_sip_registry_lag_tests).

-include_lib("eunit/include/eunit.hrl").
-include("../src/conn/chappe_sip_location.hrl").

-define(STORE, chappe_sip_location_lagging).
-define(AOR, <<"sip:alice@example.com">>).

stale_replica_retry_reads_the_region_test() ->
    ok = ?STORE:new(),
    %% the node's own tables, as chappe_sip_registry_keeper makes them
    _ = chappe_sip_registry_keeper:tables(),
    Other = #binding{
        contact = <<"sip:alice@10.0.0.9">>,
        expiry = erlang:system_time(second) + 3600,
        callid = <<"other@ct">>,
        cseq = 1,
        node = 'other@host'
    },
    %% another node wrote version 3; this node's replica still has nothing
    ok = ?STORE:set(region, ?AOR, {[Other], 3}),
    Result = chappe_sip_registry:register_with(?STORE, req(), #{}),
    ?assertMatch({ok, [_, _], _}, Result),
    {Bs, 4} = ?STORE:region(?AOR),
    ?assertEqual(
        lists:sort([<<"sip:alice@10.0.0.1">>, <<"sip:alice@10.0.0.9">>]),
        lists:sort([C || #binding{contact = C} <- Bs])
    ),
    ?assert(proplists:get_value(consistent, ?STORE:reads(), 0) >= 1).

req() ->
    Raw = <<
        "REGISTER sip:example.com SIP/2.0\r\n"
        "Via: SIP/2.0/UDP 127.0.0.1:5060;branch=z9hG4bKlag\r\n"
        "Max-Forwards: 70\r\n"
        "From: <sip:alice@example.com>;tag=ft\r\n"
        "To: <sip:alice@example.com>\r\n"
        "Call-ID: lag@ct\r\n"
        "CSeq: 1 REGISTER\r\n"
        "Contact: <sip:alice@10.0.0.1>;expires=3600\r\n"
        "Content-Length: 0\r\n\r\n"
    >>,
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    chappe_sip_req:new(Msg, undefined, #{}).
