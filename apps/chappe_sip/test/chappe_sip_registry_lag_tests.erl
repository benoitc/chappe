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

%% The flow index is never shrunk on a stale read: a REGISTER indexed flow
%% 7, the local replica has not caught up, and neither the resync nor a
%% no-op change read from that replica drops the entry. Once the region
%% has no binding on flow 7, the resync drops it.
stale_replica_keeps_the_flow_index_test() ->
    ok = ?STORE:new(),
    _ = chappe_sip_registry_keeper:tables(),
    true = ets:delete_all_objects(chappe_sip_registry_flows),
    {ok, [_], _} = chappe_sip_registry:register_with(?STORE, req(), #{flow => 7}),
    ?assertEqual([?AOR], flow_aors(7)),
    ok = chappe_sip_registry:resync_with(?STORE),
    ?assertEqual([?AOR], flow_aors(7)),
    ok = chappe_sip_registry:modify_with(?STORE, ?AOR, fun(Bs) -> Bs end),
    ?assertEqual([?AOR], flow_aors(7)),
    %% the binding is gone from the region (another node swept it)
    {_, V} = ?STORE:region(?AOR),
    ok = ?STORE:set(region, ?AOR, {[], V + 1}),
    ok = chappe_sip_registry:resync_with(?STORE),
    ?assertEqual([], flow_aors(7)).

flow_aors(Flow) ->
    [A || {{flow, F, A}, _} <- ets:tab2list(chappe_sip_registry_flows), F =:= Flow] ++
        [A || {{flow, F, A}} <- ets:tab2list(chappe_sip_registry_flows), F =:= Flow].

%% A resync read that began before a REGISTER (it saw no binding of this
%% node) does not remove the AOR from what this node holds: the entry the
%% REGISTER made is newer than the read.
held_survives_a_racing_resync_test() ->
    ok = ?STORE:new(),
    _ = chappe_sip_registry_keeper:tables(),
    true = ets:delete_all_objects(chappe_sip_registry_held),
    Before = chappe_sip_registry:gen_for_test(),
    {ok, [_], _} = chappe_sip_registry:register_with(?STORE, req(), #{}),
    ?assert(held(?AOR)),
    ok = chappe_sip_registry:resync_apply(?STORE, ?AOR, [], Before),
    ?assert(held(?AOR)),
    %% a read that began after it, with no binding of this node, does
    After = chappe_sip_registry:gen_for_test(),
    ok = chappe_sip_registry:resync_apply(?STORE, ?AOR, [], After),
    ?assertNot(held(?AOR)).

held(Aor) ->
    ets:member(chappe_sip_registry_held, Aor).
