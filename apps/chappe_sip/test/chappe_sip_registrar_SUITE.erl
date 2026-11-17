%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Registrar location store.
%%
%% The fake group drives chappe_sip_registry directly with constructed REGISTER
%% requests (no engine). The live group registers chappe_sip:registrar/1 as
%% the REGISTER handler and drives real REGISTERs over gen_udp.
-module(chappe_sip_registrar_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([add_and_lookup/1, refresh/1, add_second/1, remove_one/1,
         star_clear/1, expires_zero/1, query_bindings/1, reorder_rejected/1,
         read_time_expiry/1, survives_registry_crash/1,
         bindings_cap/1, aors_cap/1, malformed_contact_rejected/1,
         comma_contacts/1, callid_replaces_binding/1, q_ordering/1,
         star_invalid/1, star_cseq_rules/1, cseq_per_binding/1,
         aor_canonical/1, contact_uri_comparison/1, domains_404/1,
         path_stored/1, outbound_flows/1, outbound_rules/1,
         min_expires_default/1, auth_required/1, refusals_below_600/1,
         independent_registers/1, default_expires_taken/1,
         max_expires_caps/1, bindings_survive_a_node_name_change/1,
         flow_purge_reads_its_own_aors/1, cluster_without_chappe_cluster/1,
         cluster_stops_after_chappe_sip/1]).
-export([live_register/1, live_register_auth/1, live_min_expires_423/1,
         live_path_outbound/1, live_require_path/1,
         live_record_route_ignored/1, live_never_6xx/1,
         live_failure_writes_nothing/1, live_keepalives/1, live_tcp_flow/1,
         live_tcp_plain_binding/1, live_udp_flow/1, live_send_flow_per_binding/1]).

all() ->
    [{group, fake}, {group, live}].

groups() ->
    [{fake, [], [add_and_lookup, refresh, add_second, remove_one, star_clear,
                 expires_zero, query_bindings, reorder_rejected,
                 read_time_expiry, survives_registry_crash,
                 bindings_cap, aors_cap, malformed_contact_rejected,
                 comma_contacts, callid_replaces_binding, q_ordering,
                 star_invalid, star_cseq_rules, cseq_per_binding,
                 aor_canonical, contact_uri_comparison, domains_404,
                 path_stored, outbound_flows, outbound_rules,
                 min_expires_default, auth_required, refusals_below_600,
                 independent_registers, default_expires_taken,
                 max_expires_caps, bindings_survive_a_node_name_change,
                 flow_purge_reads_its_own_aors, cluster_without_chappe_cluster,
                 cluster_stops_after_chappe_sip]},
     {live, [], [live_register, live_register_auth, live_min_expires_423,
                 live_path_outbound, live_require_path,
                 live_record_route_ignored, live_never_6xx,
                 live_failure_writes_nothing, live_keepalives, live_tcp_flow,
                 live_tcp_plain_binding, live_udp_flow, live_send_flow_per_binding]}].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(_Case, Config) ->
    ok = chappe_sip_registry:clear(),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    application:unset_env(chappe_sip, registrar_max_bindings_per_aor),
    application:unset_env(chappe_sip, registrar_max_aors),
    application:unset_env(chappe_sip, registrar_min_expires),
    application:unset_env(chappe_sip, registrar_domains),
    application:unset_env(chappe_sip, registrar_max_expires),
    try sys:resume(chappe_sip_registry) catch _:_ -> ok end,
    ok.

%% ---- fake group ----

%% A contact's own expires parameter sets its expiry.
%% req: R3261-R-21
add_and_lookup(_Config) ->
    {ok, Bs} = reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 1),
    ?assertEqual(1, length(Bs)),
    ?assertEqual([curi(1)], chappe_sip_registry:lookup(aor())),
    [B] = chappe_sip_registry:bindings(aor()),
    ?assert(maps:get(expires, B) =< 3600 andalso maps:get(expires, B) > 3500).

%% the ETS is owned by chappe_sip_registry_keeper, so bindings survive a crash of
%% the chappe_sip_registry gen_server
survives_registry_crash(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 1),
    ?assertEqual([curi(1)], chappe_sip_registry:lookup(aor())),
    Old = whereis(chappe_sip_registry),
    exit(Old, kill),
    ok = wait_restart(Old, 100),
    ?assertEqual([curi(1)], chappe_sip_registry:lookup(aor())).

wait_restart(_Old, 0) -> ct:fail(no_restart);
wait_restart(Old, N) ->
    case whereis(chappe_sip_registry) of
        New when is_pid(New), New =/= Old -> ok;
        _ -> timer:sleep(20), wait_restart(Old, N - 1)
    end.

%% A higher CSeq on the same Call-ID updates the binding.
%% req: R3261-R-28
refresh(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 1),
    {ok, Bs} = reg(aor(), [contact(1, 1800)], undefined, <<"c1">>, 2),
    ?assertEqual(1, length(Bs)),
    [B] = Bs,
    ?assert(maps:get(expires, B) =< 1800 andalso maps:get(expires, B) > 1700).

add_second(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 1),
    {ok, Bs} = reg(aor(), [contact(2, 3600)], undefined, <<"c2">>, 1),
    ?assertEqual(2, length(Bs)),
    ?assertEqual(lists:sort([curi(1), curi(2)]),
                 lists:sort(chappe_sip_registry:lookup(aor()))).

%% expires=0 from another Call-ID removes the binding.
%% req: R3261-R-27
remove_one(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 1),
    {ok, _} = reg(aor(), [contact(2, 3600)], undefined, <<"c2">>, 1),
    {ok, Bs} = reg(aor(), [contact(1, 0)], undefined, <<"c3">>, 1),
    ?assertEqual([curi(2)], [maps:get(contact, B) || B <- Bs]).

%% Contact: * with Expires: 0 clears the AOR.
%% req: R3261-R-18
star_clear(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 1),
    {ok, Bs} = reg(aor(), [<<"*">>], 0, <<"c4">>, 2),
    ?assertEqual([], Bs),
    ?assertEqual([], chappe_sip_registry:lookup(aor())).

%% a contact with no expires param takes the header Expires (0: removed)
%% req: R3261-R-22
expires_zero(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 1),
    {ok, Bs} = reg(aor(), [bare_contact(1)], 0, <<"c5">>, 2),
    ?assertEqual([], Bs).

%% a REGISTER with no Contact returns current bindings unchanged
%% req: R3261-R-32
query_bindings(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 1),
    {ok, Bs} = reg(aor(), [], undefined, <<"c6">>, 2),
    ?assertEqual([curi(1)], [maps:get(contact, B) || B <- Bs]).

%% A lower CSeq on the binding's own Call-ID fails the request.
%% req: R3261-R-29 R3261-R-05
reorder_rejected(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 5),
    ?assertEqual({error, 400},
                 reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 3)).

read_time_expiry(_Config) ->
    application:set_env(chappe_sip, registrar_min_expires, 0),
    {ok, _} = reg(aor(), [contact(1, 1)], undefined, <<"c1">>, 1),
    ?assertEqual([curi(1)], chappe_sip_registry:lookup(aor())),
    timer:sleep(1100),
    ?assertEqual([], chappe_sip_registry:lookup(aor())).

%% F9: too many contacts on one AOR is rejected (403) and nothing is written
%% req: R3261-R-30
bindings_cap(_Config) ->
    application:set_env(chappe_sip, registrar_max_bindings_per_aor, 2),
    ?assertEqual({error, 403},
                 reg(aor(), [contact(1, 3600), contact(2, 3600),
                             contact(3, 3600)], undefined, <<"bc">>, 1)),
    ?assertEqual([], chappe_sip_registry:bindings(aor())).

%% F9: a new AOR past the distinct-AOR cap is rejected (503)
aors_cap(_Config) ->
    application:set_env(chappe_sip, registrar_max_aors, 1),
    ?assertMatch({ok, [_]},
                 reg(aor(), [bare_contact(1)], 3600, <<"ac1">>, 1)),
    ?assertEqual({error, 503},
                 reg(<<"<sip:bob@example.com>">>, [bare_contact(2)], 3600,
                     <<"ac2">>, 1)),
    ?assertEqual([], chappe_sip_registry:bindings(<<"<sip:bob@example.com>">>)).

%% F13: a malformed Contact rejects the REGISTER (400) instead of silently
%% dropping it and confirming the rest.
malformed_contact_rejected(_Config) ->
    ?assertEqual({error, 400},
                 reg(aor(), [<<"@@ not a contact @@">>], 3600, <<"mc">>, 1)),
    ?assertEqual([], chappe_sip_registry:bindings(aor())).

%% Two contacts in one comma-joined Contact header are two bindings, each
%% with its own expires parameter (the header Expires for the one without).
%% req: R3261-R-21 R3261-R-22
comma_contacts(_Config) ->
    Joined = <<"<", (curi(1))/binary, ">;expires=100, <", (curi(2))/binary,
               ">, \"Desk, 2\" <", (curi(3))/binary, ">;expires=300">>,
    {ok, Bs} = reg(aor(), [Joined], 200, <<"cc">>, 1),
    ?assertEqual(3, length(Bs)),
    Exp = maps:from_list([{maps:get(contact, B), maps:get(expires, B)} || B <- Bs]),
    ?assert(maps:get(curi(1), Exp) =< 100 andalso maps:get(curi(1), Exp) > 90),
    ?assert(maps:get(curi(2), Exp) =< 200 andalso maps:get(curi(2), Exp) > 190),
    ?assert(maps:get(curi(3), Exp) =< 300 andalso maps:get(curi(3), Exp) > 290).

%% A binding refreshed from a new Call-ID is updated whatever its CSeq, and
%% records the new Call-ID and CSeq.
%% req: R3261-R-27
callid_replaces_binding(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"old">>, 50),
    {ok, [B]} = reg(aor(), [contact(1, 600)], undefined, <<"new">>, 1),
    ?assertEqual(<<"new@ct">>, maps:get(callid, B)),
    ?assertEqual(1, maps:get(cseq, B)),
    ?assert(maps:get(expires, B) =< 600).

%% Bindings come back the highest q first (no q counts as 1.0), and q is
%% kept on each binding.
%% req: R3261-R-36
q_ordering(_Config) ->
    Cs = [<<"<", (curi(1))/binary, ">;q=0.1">>,
          <<"<", (curi(2))/binary, ">;q=0.9">>,
          <<"<", (curi(3))/binary, ">">>,
          <<"<", (curi(4))/binary, ">;q=0.5">>],
    {ok, Bs} = reg(aor(), Cs, 3600, <<"q">>, 1),
    ?assertEqual([curi(3), curi(2), curi(4), curi(1)],
                 [maps:get(contact, B) || B <- Bs]),
    ?assertEqual([curi(3), curi(2), curi(4), curi(1)],
                 chappe_sip:location(<<"sip:alice@example.com">>)),
    ?assertEqual([undefined, <<"0.9">>, <<"0.5">>, <<"0.1">>],
                 [maps:get(q, B) || B <- chappe_sip:bindings(aor())]).

%% "*" needs Expires: 0 and no other Contact; anything else is a 400 that
%% leaves the bindings alone.
%% req: R3261-R-17
star_invalid(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"s">>, 1),
    ?assertEqual({error, 400}, reg(aor(), [<<"*">>], 3600, <<"s">>, 2)),
    ?assertEqual({error, 400}, reg(aor(), [<<"*">>], undefined, <<"s">>, 3)),
    ?assertEqual({error, 400}, reg(aor(), [<<"*">>, contact(2, 0)], 0, <<"s">>, 4)),
    ?assertEqual({error, 400}, reg(aor(), [<<"*, ", (contact(2, 0))/binary>>], 0,
                                   <<"s">>, 5)),
    ?assertEqual([curi(1)], chappe_sip_registry:lookup(aor())).

%% "*" removes a binding of another Call-ID, and one of the same Call-ID
%% only with a higher CSeq; otherwise the whole update is aborted.
%% req: R3261-R-18 R3261-R-19 R3261-R-20
star_cseq_rules(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"a">>, 5),
    {ok, _} = reg(aor(), [contact(2, 3600)], undefined, <<"b">>, 1),
    ?assertEqual({error, 400}, reg(aor(), [<<"*">>], 0, <<"a">>, 5)),
    ?assertEqual(2, length(chappe_sip_registry:lookup(aor()))),
    ?assertEqual({ok, []}, reg(aor(), [<<"*">>], 0, <<"a">>, 6)),
    ?assertEqual([], chappe_sip_registry:lookup(aor())).

%% The CSeq check is per binding: a new contact on a Call-ID whose other
%% binding has a higher CSeq is still added. A REGISTER whose one contact
%% fails the check writes none of its contacts.
%% req: R3261-R-28 R3261-R-29 R3261-R-06 R3261-R-30
cseq_per_binding(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 5),
    {ok, Bs} = reg(aor(), [contact(2, 3600)], undefined, <<"c1">>, 3),
    ?assertEqual(2, length(Bs)),
    ?assertEqual({error, 400},
                 reg(aor(), [contact(3, 3600), contact(1, 3600)], undefined,
                     <<"c1">>, 4)),
    ?assertEqual(lists:sort([curi(1), curi(2)]),
                 lists:sort(chappe_sip_registry:lookup(aor()))).

%% The AOR is the To URI in canonical form: no parameters, unescaped,
%% host case-insensitive. Any spelling of it finds the bindings.
%% req: R3261-R-15 R3261-R-16
aor_canonical(_Config) ->
    {ok, _} = reg(<<"<sip:alice@EXAMPLE.COM;user=phone>">>, [contact(1, 3600)],
                  undefined, <<"ac">>, 1),
    ?assertEqual([curi(1)], chappe_sip_registry:lookup(<<"sip:alice@example.com">>)),
    ?assertEqual([curi(1)], chappe_sip:location(<<"sip:%61lice@Example.Com">>)),
    ?assertEqual([curi(1)], chappe_sip:location(<<"Alice <sip:alice@example.com;x=1>">>)),
    %% the user part stays case-sensitive, an explicit port is another AOR
    ?assertEqual([], chappe_sip:location(<<"sip:ALICE@example.com">>)),
    ?assertEqual([], chappe_sip:location(<<"sip:alice@example.com:5060">>)).

%% Contacts are matched with the URI comparison rules: a case or an unknown
%% parameter does not make a new binding, a port does.
%% req: R3261-R-35
contact_uri_comparison(_Config) ->
    {ok, [_]} = reg(aor(), [<<"<sip:alice@10.0.0.1;transport=TCP>">>], 3600,
                    <<"cu">>, 1),
    {ok, [B]} = reg(aor(), [<<"<sip:alice@10.0.0.1;Transport=tcp;x=1>;expires=60">>],
                    3600, <<"cu">>, 2),
    ?assert(maps:get(expires, B) =< 60),
    {ok, Bs} = reg(aor(), [<<"<sip:alice@10.0.0.1:5060;transport=tcp>">>], 3600,
                   <<"cu">>, 3),
    ?assertEqual(2, length(Bs)),
    {ok, [_]} = reg(aor(), [<<"<sip:alice@10.0.0.1;TRANSPORT=TCP>;expires=0">>],
                    3600, <<"cu">>, 4).

%% With registrar_domains set, a REGISTER for another domain (in the
%% Request-URI or the To) gets 404, as does a To that is not a URI.
%% req: R3261-R-04 R3261-R-14
domains_404(_Config) ->
    ?assertEqual({error, 404},
                 regx(#{to => <<"<garbage>">>, contacts => [contact(1, 3600)]})),
    application:set_env(chappe_sip, registrar_domains, [<<"Example.com">>]),
    ?assertMatch({ok, [_], _}, regx(#{contacts => [contact(1, 3600)]})),
    ?assertEqual({error, 404},
                 regx(#{ruri => <<"sip:other.example">>, cseq => 2,
                        contacts => [contact(1, 3600)]})),
    ?assertEqual({error, 404},
                 regx(#{to => <<"<sip:alice@other.example>">>, cseq => 3,
                        contacts => [contact(1, 3600)]})),
    ?assertEqual([], chappe_sip:location(<<"sip:alice@other.example">>)).

%% RFC 3327: the Path values are kept in order with the binding, and given
%% back by bindings/1 as the route set toward the contact. A Path the UA
%% did not declare support for is refused 420.
%% req: R3327-R-01 R3327-R-02 R3327-R-05 R5626-R-01
path_stored(_Config) ->
    Path = [{<<"Path">>, <<"<sip:p1.example.net;lr>">>},
            {<<"Path">>, <<"<sip:p2.example.net;lr>, <sip:p3.example.net;lr>">>}],
    ?assertEqual({error, 420},
                 regx(#{contacts => [contact(1, 3600)], headers => Path})),
    ?assertEqual([], chappe_sip:location(<<"sip:alice@example.com">>)),
    {ok, _, #{path := P}} =
        regx(#{contacts => [contact(1, 3600)], cseq => 2,
               headers => [{<<"Supported">>, <<"path">>} | Path]}),
    Want = [<<"<sip:p1.example.net;lr>">>, <<"<sip:p2.example.net;lr>">>,
            <<"<sip:p3.example.net;lr>">>],
    ?assertEqual(Want, P),
    [B] = chappe_sip:bindings(<<"sip:alice@example.com">>),
    ?assertEqual(Want, maps:get(path, B)).

%% RFC 5626: one binding per (instance, reg-id) flow, beside a plain
%% binding; a re-registration of a flow updates its transport flow; a flow
%% that drops takes only its own binding with it.
%% req: R5626-R-09 R5626-R-10 R5626-R-11 R5626-R-14 R5626-R-17 R5626-R-12
outbound_flows(_Config) ->
    Inst = <<"\"<urn:uuid:00000000-0000-1000-8000-000A95A0E128>\"">>,
    Ob = fun(RegId) ->
        <<"<", (curi(1))/binary, ";ob>;+sip.instance=", Inst/binary,
          ";reg-id=", RegId/binary>>
    end,
    Sup = [{<<"Supported">>, <<"outbound, path">>}],
    {ok, _, #{outbound := true}} =
        regx(#{contacts => [Ob(<<"1">>)], headers => Sup, flow => f1,
               callid => <<"ob1">>}),
    {ok, _, #{outbound := true}} =
        regx(#{contacts => [Ob(<<"2">>)], headers => Sup, flow => f2,
               callid => <<"ob2">>}),
    {ok, Bs, #{outbound := false}} =
        regx(#{contacts => [contact(1, 3600)], callid => <<"plain">>}),
    ?assertEqual(3, length(Bs)),
    ?assertEqual(lists:sort([{Inst, <<"1">>}, {Inst, <<"2">>}, {undefined, undefined}]),
                 lists:sort([{maps:get(instance, B), maps:get(reg_id, B)} || B <- Bs])),
    %% every Contact parameter is kept
    [B1] = [B || B <- Bs, maps:get(reg_id, B) =:= <<"1">>],
    ?assertEqual(Inst, maps:get(<<"+sip.instance">>, maps:get(params, B1))),
    %% flow 1 re-registers over a new transport flow
    {ok, _, _} = regx(#{contacts => [Ob(<<"1">>)], headers => Sup, flow => f3,
                        callid => <<"ob1">>, cseq => 2}),
    Flows = [maps:get(flow, B) || B <- chappe_sip:bindings(aor()),
                                  maps:get(reg_id, B) =:= <<"1">>],
    ?assertEqual([f3], Flows),
    ok = chappe_sip_registry:remove_flow(f2),
    _ = sys:get_state(chappe_sip_registry),
    ?assertEqual(lists:sort([<<"1">>, undefined]),
                 lists:sort([maps:get(reg_id, B) || B <- chappe_sip:bindings(aor())])),
    ok = chappe_sip_registry:remove_flow(f1),
    _ = sys:get_state(chappe_sip_registry),
    ?assertEqual(2, length(chappe_sip:bindings(aor()))).

%% RFC 5626 6: a reg-id without +sip.instance is ignored; past the first
%% hop without an "ob" Path the reg-id is ignored, or a 439 when the UA
%% asked for outbound; with an "ob" Path it applies; a reg-id with two
%% non-zero Contacts is a 400.
%% req: R5626-R-02 R5626-R-03 R5626-R-04 R5626-R-05 R5626-R-06 R5626-R-07 R5626-R-08
outbound_rules(_Config) ->
    Inst = <<"\"<urn:uuid:1>\"">>,
    Sup = {<<"Supported">>, <<"outbound, path">>},
    TwoVias = [<<"SIP/2.0/UDP edge.example.net;branch=z9hG4bKe">>,
               <<"SIP/2.0/UDP 192.0.2.4;branch=z9hG4bKu">>],
    Lone = <<"<", (curi(1))/binary, ">;reg-id=1">>,
    {ok, [B0], #{outbound := false}} =
        regx(#{contacts => [Lone], headers => [Sup], callid => <<"r0">>}),
    ?assertEqual(undefined, maps:get(reg_id, B0)),
    Flow = <<"<", (curi(2))/binary, ">;+sip.instance=", Inst/binary, ";reg-id=1">>,
    ?assertEqual({error, 439},
                 regx(#{contacts => [Flow], headers => [Sup], vias => TwoVias,
                        callid => <<"r1">>})),
    {ok, _, #{outbound := false}} =
        regx(#{contacts => [Flow], vias => TwoVias, callid => <<"r2">>,
               headers => [{<<"Supported">>, <<"path">>}]}),
    [B2] = [B || B <- chappe_sip:bindings(aor()), maps:get(contact, B) =:= curi(2)],
    ?assertEqual(undefined, maps:get(reg_id, B2)),
    {ok, _, #{outbound := true, first_hop := false}} =
        regx(#{contacts => [Flow], vias => TwoVias, callid => <<"r3">>,
               headers => [Sup, {<<"Path">>, <<"<sip:edge.example.net;lr;ob>">>}]}),
    Two = [Flow, <<"<", (curi(3))/binary, ">">>],
    ?assertEqual({error, 400},
                 regx(#{contacts => Two, headers => [Sup], callid => <<"r4">>})).

%% registrar_min_expires defaults to 60, so 423 works out of the box; only
%% an interval under an hour is ever refused.
%% req: R3261-R-25
min_expires_default(_Config) ->
    ?assertEqual(60, chappe_sip_config:get(registrar_min_expires)),
    ?assertEqual({error, 423}, reg(aor(), [contact(1, 30)], undefined, <<"m">>, 1)),
    ?assertMatch({ok, [_]}, reg(aor(), [contact(1, 60)], undefined, <<"m">>, 2)),
    application:set_env(chappe_sip, registrar_min_expires, 7200),
    ?assertMatch({ok, [_]}, reg(aor(), [contact(1, 3700)], undefined, <<"m">>, 3)).

%% A registrar authenticates: without an auth hook it must be opted out
%% explicitly.
%% req: R3261-R-10
auth_required(_Config) ->
    ?assertError({registrar, auth_required}, chappe_sip:registrar(#{})),
    ?assertError({registrar, auth_required},
                 chappe_sip:registrar(#{allow_unauthenticated => false})),
    ?assert(is_function(chappe_sip:registrar(#{allow_unauthenticated => true}), 2)),
    ?assert(is_function(chappe_sip:registrar(#{auth => fun(_) -> ok end}), 2)).

%% Every refusal of the store is a 4xx or a 5xx, never a 6xx: an invalid
%% Contact: *, a CSeq out of order, a Path the UA does not support, a
%% reg-id past an edge without outbound, too short an interval, too many
%% bindings, a full store, a domain we do not serve.
%% req: R3261-R-01
refusals_below_600(_Config) ->
    TwoVias = [<<"SIP/2.0/UDP 192.0.2.4:5060;branch=z9hG4bKa">>,
               <<"SIP/2.0/UDP 192.0.2.5:5060;branch=z9hG4bKb">>],
    Flow = <<"<", (curi(9))/binary,
             ">;+sip.instance=\"<urn:uuid:9>\";reg-id=1">>,
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"o">>, 5),
    Refused = [
        reg(aor(), [<<"*">>], 3600, <<"s">>, 1),
        reg(aor(), [contact(1, 3600)], undefined, <<"o">>, 4),
        regx(#{contacts => [bare_contact(2)], callid => <<"p">>,
               headers => [{<<"Path">>, <<"<sip:edge.example.net;lr>">>}]}),
        regx(#{contacts => [Flow], vias => TwoVias, callid => <<"f">>,
               headers => [{<<"Supported">>, <<"outbound">>}]}),
        reg(aor(), [contact(3, 30)], undefined, <<"m">>, 1)
    ],
    application:set_env(chappe_sip, registrar_max_bindings_per_aor, 1),
    Full = reg(aor(), [contact(4, 3600)], undefined, <<"b">>, 1),
    application:set_env(chappe_sip, registrar_max_aors, 1),
    Aors = reg(<<"<sip:carol@example.com>">>, [contact(5, 3600)], undefined,
               <<"a">>, 1),
    application:set_env(chappe_sip, registrar_domains, [<<"example.net">>]),
    Domain = reg(aor(), [contact(6, 3600)], undefined, <<"d">>, 1),
    Statuses = [S || {error, S} <- Refused ++ [Full, Aors, Domain]],
    ?assertEqual([400, 400, 420, 439, 423, 403, 503, 404], Statuses).

%% Each REGISTER is applied on its own to the bindings as they stand:
%% twenty REGISTERs of one AOR racing from as many processes, each with its
%% own Call-ID and Contact, all land, and a REGISTER of another AOR among
%% them leaves those alone.
%% req: R3261-R-07
independent_registers(_Config) ->
    application:set_env(chappe_sip, registrar_max_bindings_per_aor, 20),
    Test = self(),
    Pids = [spawn_link(fun() ->
                 CallId = <<"race", (integer_to_binary(N))/binary>>,
                 Test ! {self(), reg(aor(), [contact(N, 3600)], undefined,
                                     CallId, 1)}
             end) || N <- lists:seq(1, 20)],
    {ok, [_]} = reg(<<"<sip:bob@example.com>">>, [contact(99, 3600)],
                    undefined, <<"bob">>, 1),
    [receive {P, R} -> ?assertMatch({ok, _}, R) after 5000 -> ct:fail(lost) end
     || P <- Pids],
    ?assertEqual(lists:sort([curi(N) || N <- lists:seq(1, 20)]),
                 lists:sort(chappe_sip_registry:lookup(aor()))),
    ?assertEqual([curi(99)],
                 chappe_sip_registry:lookup(<<"<sip:bob@example.com>">>)).

%% A Contact with neither an expires parameter nor an Expires header takes
%% the configured default: registrar_default_expires (3600), or the
%% handler's default_expires option.
%% req: R3261-R-23
default_expires_taken(_Config) ->
    ?assertEqual(3600, chappe_sip_config:get(registrar_default_expires)),
    {ok, [B1]} = reg(aor(), [bare_contact(1)], undefined, <<"e1">>, 1),
    ?assert(maps:get(expires, B1) > 3590 andalso maps:get(expires, B1) =< 3600),
    {ok, Msg} = chappe_sip_msg:parse(
                  reg_raw(<<"<sip:bob@example.com>">>, [bare_contact(2)],
                          undefined, <<"e2">>, 1)),
    {ok, [B2]} = chappe_sip_registry:register_contacts(
                   chappe_sip_req:new(Msg, undefined, #{}),
                   #{default_expires => 120}),
    ?assert(maps:get(expires, B2) > 110 andalso maps:get(expires, B2) =< 120).

%% The registrar may grant less than asked: registrar_max_expires caps
%% the interval of a Contact parameter and of the Expires header alike.
%% req: R3261-R-24
max_expires_caps(_Config) ->
    application:set_env(chappe_sip, registrar_max_expires, 600),
    {ok, [B1]} = reg(aor(), [contact(1, 7200)], undefined, <<"x1">>, 1),
    ?assert(maps:get(expires, B1) > 590 andalso maps:get(expires, B1) =< 600),
    {ok, Bs} = reg(aor(), [bare_contact(2)], 86400, <<"x2">>, 1),
    [?assert(maps:get(expires, B) =< 600) || B <- Bs].

%% ---- live group ----

%% The 200 lists every binding with its expires (and q), and a Date.
%% req: R3261-R-32 R3261-R-33 R3261-R-34
live_register(_Config) ->
    EP = start(),
    ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
    LP = lport(Sock),
    send(Sock, EP, register_req(LP, 3600, 1)),
    R1 = recv_status(Sock, 200),
    {_, _} = binary:match(R1, <<"expires=">>),
    %% the binding is now resolvable
    ?assertMatch([_], chappe_sip:location(<<"sip:alice@127.0.0.1">>)),
    %% and records the transport its REGISTER came over
    [B1] = chappe_sip:bindings(<<"sip:alice@127.0.0.1">>),
    ?assertEqual(<<"udp">>, maps:get(transport, B1)),
    %% a refresh with a higher CSeq is accepted
    send(Sock, EP, register_req(LP, 7200, 2, [{<<"Contact">>, <<"<sip:bob@127.0.0.1:9>;q=0.5">>}])),
    R2 = recv_status(Sock, 200),
    {ok, M} = chappe_sip_msg:parse(R2),
    Contacts = chappe_sip_msg:get_all(<<"contact">>, M),
    ?assertEqual(2, length(Contacts)),
    [?assertMatch({match, _}, re:run(C, ";expires=[0-9]+$")) || C <- Contacts],
    ?assertMatch([<<"<sip:alice@127.0.0.1:", _/binary>>,
                  <<"<sip:bob@127.0.0.1:9>;q=0.5;expires=", _/binary>>], Contacts),
    Date = chappe_sip_msg:get(<<"date">>, M),
    ?assertMatch({match, _},
                 re:run(Date, "^[A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} "
                              "[0-9]{2}:[0-9]{2}:[0-9]{2} GMT$")),
    [Ct, _] = chappe_sip:location(<<"sip:alice@127.0.0.1">>),
    ?assertEqual(<<"sip:alice@127.0.0.1:", (integer_to_binary(LP))/binary>>, Ct),
    gen_udp:close(Sock).

%% RFC 3261 10.3 step 7: a REGISTER whose expiry is below the configured floor
%% is refused 423 with a Min-Expires header.
%% req: R3261-R-25 R3261-R-26
live_min_expires_423(_Config) ->
    EP = start(),
    application:set_env(chappe_sip, registrar_min_expires, 60),
    ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
    LP = lport(Sock),
    send(Sock, EP, register_req(LP, 30, 1)),        % 30 < 60
    R = recv_status(Sock, 423),
    {ok, M} = chappe_sip_msg:parse(R),
    ?assertEqual(<<"60">>, chappe_sip_msg:get(<<"min-expires">>, M)),
    ?assertEqual([], chappe_sip:location(<<"sip:alice@127.0.0.1">>)),
    %% at the floor it is accepted
    send(Sock, EP, register_req(LP, 60, 2)),
    _ = recv_status(Sock, 200),
    ?assertMatch([_], chappe_sip:location(<<"sip:alice@127.0.0.1">>)),
    gen_udp:close(Sock).

%% F9: a REGISTER must authenticate before it can write bindings, and an
%% authenticated user cannot register a different AOR.
%% req: R3261-R-10 R3261-R-12 R3261-R-13
live_register_auth(_Config) ->
    EP = start(),
    Auth = #{realm => <<"sip">>, domain => <<"127.0.0.1">>,
             secret => fun(<<"alice">>) -> {ok, <<"secret">>};
                          (_) -> error end},
    ok = chappe_sip:register(chappe_sip:registrar(#{auth => Auth})),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
    LP = lport(Sock),
    %% 1) an unauthenticated REGISTER is challenged and writes nothing
    send(Sock, EP, register_req(LP, 3600, 1)),
    R401 = recv_status(Sock, 401),
    {ok, Chal} = chappe_sip_hdr:auth(www_auth_of(R401)),
    ?assertEqual([], chappe_sip:location(<<"sip:alice@127.0.0.1">>)),
    %% 2) an authenticated REGISTER binds the AOR
    Creds = client_creds(Chal, <<"alice">>, <<"secret">>),
    send(Sock, EP, register_auth_req(LP, 3600, 2, <<"alice">>, Creds)),
    _ = recv_status(Sock, 200),
    ?assertMatch([_], chappe_sip:location(<<"sip:alice@127.0.0.1">>)),
    %% 3) alice's credentials cannot register bob's AOR (a fresh nonce
    %% count: the same one again is a replay)
    Creds2 = client_creds(Chal, <<"alice">>, <<"secret">>, 2),
    send(Sock, EP, register_auth_req(LP, 3600, 3, <<"bob">>, Creds2)),
    _ = recv_status(Sock, 403),
    ?assertEqual([], chappe_sip:location(<<"sip:bob@127.0.0.1">>)),
    gen_udp:close(Sock).

%% On the wire: Path is echoed in the 200; an outbound flow gets Require:
%% outbound, and a Flow-Timer when we are the first hop; a UA that did not
%% ask for outbound gets no Require.
%% req: R3327-R-03 R5626-R-12 R5626-R-16 R5626-R-08
live_path_outbound(_Config) ->
    EP = start(),
    ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
    LP = lport(Sock),
    P = integer_to_binary(LP),
    Flow = {<<"Contact">>, <<"<sip:alice@127.0.0.1:", P/binary,
                             ";ob>;+sip.instance=\"<urn:uuid:1>\";reg-id=1">>},
    %% direct: Require: outbound and Flow-Timer
    send(Sock, EP, register_req(LP, 3600, 1, [Flow, {<<"Supported">>, <<"outbound, path">>}])),
    {ok, M1} = chappe_sip_msg:parse(recv_status(Sock, 200)),
    ?assertEqual(<<"outbound">>, chappe_sip_msg:get(<<"require">>, M1)),
    ?assertEqual(<<"120">>, chappe_sip_msg:get(<<"flow-timer">>, M1)),
    ?assertMatch({match, _}, re:run(chappe_sip_msg:get(<<"contact">>, M1), "reg-id=1")),
    %% through an edge that put itself in an "ob" Path: Path echoed,
    %% Require: outbound, no Flow-Timer
    Edge = [{<<"Path">>, <<"<sip:edge.example.net;lr;ob>">>},
            {<<"Via">>, <<"SIP/2.0/UDP 192.0.2.4:5060;branch=z9hG4bKua">>}],
    send(Sock, EP, register_req(LP, 3600, 2,
                                [Flow, {<<"Supported">>, <<"outbound, path">>} | Edge])),
    {ok, M2} = chappe_sip_msg:parse(recv_status(Sock, 200)),
    ?assertEqual(<<"<sip:edge.example.net;lr;ob>">>, chappe_sip_msg:get(<<"path">>, M2)),
    ?assertEqual(<<"outbound">>, chappe_sip_msg:get(<<"require">>, M2)),
    ?assertEqual(undefined, chappe_sip_msg:get(<<"flow-timer">>, M2)),
    %% the UA did not list outbound: no Require
    send(Sock, EP, register_req(LP, 3600, 3, [Flow])),
    {ok, M3} = chappe_sip_msg:parse(recv_status(Sock, 200)),
    ?assertEqual(undefined, chappe_sip_msg:get(<<"require">>, M3)),
    gen_udp:close(Sock).

%% A registrar processes Require as a UAS: path in Require gets 420 unless
%% the route takes it (handle/3 option_tags).
%% req: R3261-R-09
live_require_path(_Config) ->
    EP = start(),
    Reg = chappe_sip:registrar(#{allow_unauthenticated => true}),
    ok = chappe_sip:register(Reg),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
    LP = lport(Sock),
    Hdrs = [{<<"Require">>, <<"path">>}, {<<"Supported">>, <<"path">>},
            {<<"Path">>, <<"<sip:edge.example.net;lr>">>}],
    send(Sock, EP, register_req(LP, 3600, 1, Hdrs)),
    {ok, M} = chappe_sip_msg:parse(recv_status(Sock, 420)),
    ?assertEqual(<<"path">>, chappe_sip_msg:get(<<"unsupported">>, M)),
    ok = chappe_sip:handle(<<"REGISTER">>, Reg,
                           #{option_tags => [<<"path">>, <<"outbound">>]}),
    send(Sock, EP, register_req(LP, 3600, 2, Hdrs)),
    _ = recv_status(Sock, 200),
    gen_udp:close(Sock).

%% A Record-Route in a REGISTER is ignored and never echoed.
%% req: R3261-R-02 R3261-R-03
live_record_route_ignored(_Config) ->
    EP = start(),
    ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
    LP = lport(Sock),
    send(Sock, EP, register_req(LP, 3600, 1,
                                [{<<"Record-Route">>, <<"<sip:rr.example.net;lr>">>}])),
    {ok, M} = chappe_sip_msg:parse(recv_status(Sock, 200)),
    ?assertEqual(undefined, chappe_sip_msg:get(<<"record-route">>, M)),
    [B] = chappe_sip:bindings(<<"sip:alice@127.0.0.1">>),
    ?assertEqual([], maps:get(path, B)),
    gen_udp:close(Sock).

%% An auth policy that refuses with a 6xx does not make the registrar
%% send one: the REGISTER gets 403 and nothing is bound.
%% req: R3261-R-01
live_never_6xx(_Config) ->
    EP = start(),
    Policy = fun(_Req) -> {reject, 603} end,
    ok = chappe_sip:register(chappe_sip:registrar(#{auth => Policy})),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
    LP = lport(Sock),
    send(Sock, EP, register_req(LP, 3600, 1)),
    R = recv_final(Sock),
    ?assertMatch(<<"SIP/2.0 403", _/binary>>, R),
    ?assertEqual([], chappe_sip:location(<<"sip:alice@127.0.0.1">>)),
    gen_udp:close(Sock).

%% When the store cannot apply a REGISTER in time (here it is held still),
%% the request fails with 500 and none of its bindings is written, not
%% even once the store is back.
%% req: R3261-R-31
live_failure_writes_nothing(_Config) ->
    EP = start(),
    ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
    LP = lport(Sock),
    ok = sys:suspend(chappe_sip_registry),
    send(Sock, EP, register_req(LP, 3600, 1)),
    R = recv_final(Sock, 10000),
    ok = sys:resume(chappe_sip_registry),
    ?assertMatch(<<"SIP/2.0 500", _/binary>>, R),
    _ = sys:get_state(chappe_sip_registry),
    ?assertEqual([], chappe_sip:location(<<"sip:alice@127.0.0.1">>)),
    gen_udp:close(Sock).

%% A UA registers with us directly, so we answer its keep-alives like an
%% edge proxy (RFC 5626 5.4): a STUN Binding request on the UDP port gets
%% a Binding success response, a CRLFCRLF ping on TCP a CRLF pong.
%% req: R5626-R-15
live_keepalives(_Config) ->
    EP = start(),
    ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
    Tid = crypto:strong_rand_bytes(12),
    send(Sock, EP, <<16#0001:16, 0:16, 16#2112A442:32, Tid/binary>>),
    receive
        {udp, Sock, _, _, <<16#0101:16, _Len:16, 16#2112A442:32, Tid:12/binary,
                            _/binary>>} -> ok
    after 3000 -> ct:fail(no_stun_response)
    end,
    gen_udp:close(Sock),
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, EP, [binary, {active, false}]),
    ok = gen_tcp:send(S, <<"\r\n\r\n">>),
    ?assertEqual({ok, <<"\r\n">>}, gen_tcp:recv(S, 0, 3000)),
    gen_tcp:close(S).

recv_final(Sock) ->
    recv_final(Sock, 6000).

recv_final(Sock, Timeout) ->
    receive
        {udp, Sock, _, _, <<"SIP/2.0 1", _/binary>>} -> recv_final(Sock, Timeout);
        {udp, Sock, _, _, <<"SIP/2.0 ", _/binary>> = Bin} -> Bin
    after Timeout -> ct:fail(no_final)
    end.

client_creds(Chal, User, Pass) ->
    client_creds(Chal, User, Pass, 1).

client_creds(Chal, User, Pass, Nc) ->
    {ok, Creds} = chappe_sip_digest:credentials(
                    #{method => <<"REGISTER">>, uri => <<"sip:127.0.0.1">>,
                      username => User, password => Pass, challenge => Chal,
                      nc => Nc, cnonce => <<"abcd1234">>}),
    Creds.

www_auth_of(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    chappe_sip_msg:get(<<"www-authenticate">>, M).

register_auth_req(LP, Exp, CSeq, User, Auth) ->
    P = integer_to_binary(LP),
    CS = integer_to_binary(CSeq),
    E = integer_to_binary(Exp),
    <<"REGISTER sip:127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=z9hG4bKa", CS/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: <sip:", User/binary, "@127.0.0.1>;tag=ft\r\n"
      "To: <sip:", User/binary, "@127.0.0.1>\r\n"
      "Contact: <sip:", User/binary, "@127.0.0.1:", P/binary, ">\r\n"
      "Authorization: ", Auth/binary, "\r\n"
      "Expires: ", E/binary, "\r\n"
      "Call-ID: rega-", P/binary, "@ct\r\n"
      "CSeq: ", CS/binary, " REGISTER\r\nContent-Length: 0\r\n\r\n">>.

%% RFC 5626 over TCP: an outbound REGISTER sent straight to us binds to
%% its connection; an INVITE for the AOR goes back over that connection
%% (the contact's own address is unreachable), and closing the connection
%% removes the binding.
%% req: R5626-R-13 R5626-R-17
live_tcp_flow(_Config) ->
    EP = start(),
    ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})),
    ok = chappe_sip:invite(fun(Req, _Res) ->
        {ok, Uri, Flow} = chappe_sip:location_flow(<<"sip:alice@127.0.0.1">>),
        chappe_sip:proxy_request(Req, {flow, Uri, Flow}, #{})
    end),
    {ok, T} = gen_tcp:connect({127,0,0,1}, EP, [binary, {active, false}]),
    LP = lport(T),
    Ct = <<"<sip:alice@192.0.2.9:5070;transport=tcp;ob>"
           ";+sip.instance=\"<urn:uuid:t1>\";reg-id=1">>,
    ok = gen_tcp:send(T, tcp_register(LP, Ct, 1)),
    {ok, R} = chappe_sip_msg:parse(tcp_recv(T, <<"SIP/2.0">>)),
    ?assertEqual(200, chappe_sip_msg:status(R)),
    ?assertEqual(<<"outbound">>, chappe_sip_msg:get(<<"require">>, R)),
    [B] = chappe_sip:bindings(<<"sip:alice@127.0.0.1">>),
    ?assertMatch({conn, _}, maps:get(flow, B)),
    %% a call for the AOR reaches the UA over its connection
    {ok, U} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
    send(U, EP, caller_invite(lport(U))),
    {ok, Inv} = chappe_sip_msg:parse(tcp_recv(T, <<"INVITE">>)),
    ?assertEqual(<<"sip:alice@192.0.2.9:5070;transport=tcp;ob">>,
                 chappe_sip_msg:uri(Inv)),
    ok = gen_tcp:send(T, busy(Inv)),
    _ = recv_status(U, 486),
    %% the connection closes: the binding goes
    ok = gen_tcp:close(T),
    ?assertEqual([], wait_unbound(<<"sip:alice@127.0.0.1">>, 30)),
    gen_udp:close(U).

%% A TCP REGISTER without outbound binds by its contact URI alone: the
%% binding outlives the connection.
%% req: R5626-R-08
live_tcp_plain_binding(_Config) ->
    EP = start(),
    ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})),
    {ok, T} = gen_tcp:connect({127,0,0,1}, EP, [binary, {active, false}]),
    LP = lport(T),
    ok = gen_tcp:send(T, tcp_register(LP, <<"<sip:alice@192.0.2.9:5070;transport=tcp>">>, 1)),
    {ok, R} = chappe_sip_msg:parse(tcp_recv(T, <<"SIP/2.0">>)),
    ?assertEqual(200, chappe_sip_msg:status(R)),
    [B] = chappe_sip:bindings(<<"sip:alice@127.0.0.1">>),
    ?assertEqual(undefined, maps:get(flow, B)),
    ?assertEqual(<<"tcp">>, maps:get(transport, B)),
    ok = gen_tcp:close(T),
    timer:sleep(500),
    ?assertMatch([_], chappe_sip:bindings(<<"sip:alice@127.0.0.1">>)).

%% RFC 5626 over UDP: the flow of an outbound REGISTER is the address and
%% port it came from, and a request for the AOR goes there, not to the
%% contact's own address.
%% req: R5626-R-13
live_udp_flow(_Config) ->
    EP = start(),
    ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})),
    ok = chappe_sip:invite(fun(Req, _Res) ->
        {ok, Uri, Flow} = chappe_sip:location_flow(<<"sip:alice@127.0.0.1">>),
        chappe_sip:proxy_request(Req, {flow, Uri, Flow}, #{})
    end),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
    LP = lport(Sock),
    Ct = {<<"Contact">>, <<"<sip:alice@192.0.2.9:5070;ob>"
                           ";+sip.instance=\"<urn:uuid:u1>\";reg-id=1">>},
    send(Sock, EP, register_req(LP, 3600, 1, [Ct, {<<"Supported">>, <<"outbound">>}])),
    _ = recv_status(Sock, 200),
    [B] = chappe_sip:bindings(<<"sip:alice@127.0.0.1">>),
    ?assertEqual({udp, <<"127.0.0.1">>, LP}, maps:get(flow, B)),
    {ok, U} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
    send(U, EP, caller_invite(lport(U))),
    Inv = receive
              {udp, Sock, _, _, <<"INVITE ", _/binary>> = I} -> I
          after 5000 -> ct:fail(no_invite_on_flow)
          end,
    {ok, M} = chappe_sip_msg:parse(Inv),
    ?assertEqual(<<"sip:alice@192.0.2.9:5070;ob">>, chappe_sip_msg:uri(M)),
    gen_udp:close(U),
    gen_udp:close(Sock).

%% Each binding of an AOR says where to send to it (send_flow), the way
%% location_flow/1 does for the first one: a device behind a NAT (its
%% Contact is not where its REGISTER came from) is reached at that source,
%% a direct one by its Contact.
live_send_flow_per_binding(_Config) ->
    EP = start(),
    ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})),
    {ok, Direct} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
    send(Direct, EP, register_req(lport(Direct), 3600, 1)),
    _ = recv_status(Direct, 200),
    {ok, Nated} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
    NatCt = {<<"Contact">>, <<"<sip:alice@192.0.2.50:5060>">>},
    send(Nated, EP, register_req(lport(Nated), 3600, 1, [NatCt])),
    _ = recv_status(Nated, 200),
    Bs = chappe_sip:bindings(<<"sip:alice@127.0.0.1">>),
    ?assertEqual(2, length(Bs)),
    [NB] = [B || #{contact := <<"sip:alice@192.0.2.50:5060">>} = B <- Bs],
    [DB] = [B || #{contact := C} = B <- Bs, C =/= <<"sip:alice@192.0.2.50:5060">>],
    ?assertEqual({udp, <<"127.0.0.1">>, lport(Nated)}, maps:get(send_flow, NB)),
    ?assertEqual(undefined, maps:get(send_flow, DB)),
    gen_udp:close(Direct),
    gen_udp:close(Nated).

%% Without a cluster every binding is this node's, whatever the node is
%% called: a binding taken before distribution starts keeps its flow.
bindings_survive_a_node_name_change(_Config) ->
    {ok, [_], _} = regx(#{contacts => [bare_contact(1)], expires => 3600,
                          flow => 7}),
    with_dist(fun() ->
        [B] = chappe_sip_registry:bindings(aor()),
        ?assertEqual(7, maps:get(flow, B)),
        ?assertEqual([curi(1)], chappe_sip_registry:lookup(aor()))
    end).

%% Fun with this node distributed (@localhost), as it was after
with_dist(Fun) ->
    Started =
        case node() of
            nonode@nohost ->
                _ = os:cmd("epmd -daemon"),
                Name = list_to_atom("clc_rename_" ++ os:getpid() ++ "@localhost"),
                {ok, _} = net_kernel:start(Name, #{name_domain => shortnames}),
                true;
            _ ->
                false
        end,
    try
        Fun()
    after
        Started andalso net_kernel:stop()
    end.

%% A dropped flow purges the AORs bound to it, not every AOR in the store:
%% the purge reads the one AOR on the flow, whatever the store holds.
flow_purge_reads_its_own_aors(_Config) ->
    [{ok, [_]} = reg(<<"<sip:u", (integer_to_binary(I))/binary, "@example.com>">>,
                     [contact(1, 3600)], undefined, <<"p">>, 1)
     || I <- lists:seq(1, 300)],
    {ok, [_], _} = regx(#{contacts => [bare_contact(2)], expires => 3600, flow => 7}),
    MFA = {chappe_sip_location, read, 3},
    erlang:trace_pattern(MFA, true, [call_count]),
    try
        ok = chappe_sip_registry:remove_flow(7),
        %% the cast is handled once the registry answers a later call
        _ = sys:get_state(chappe_sip_registry),
        {call_count, Reads} = erlang:trace_info(MFA, call_count),
        ok = wait_empty(aor(), 50),
        ct:pal("purge read ~b AORs", [Reads]),
        ?assert(Reads < 10)
    after
        erlang:trace_pattern(MFA, false, [call_count])
    end.

wait_empty(_Aor, 0) -> ct:fail(still_bound);
wait_empty(Aor, N) ->
    case chappe_sip_registry:bindings(Aor) of
        [] -> ok;
        _ -> timer:sleep(20), wait_empty(Aor, N - 1)
    end.

%% A release that leaves chappe_cluster out, configured for a cluster:
%% chappe_sip refuses to start with a clear error, instead of starting and
%% crash-looping.
cluster_without_chappe_cluster(_Config) ->
    with_dist(fun no_cluster_app/0).

no_cluster_app() ->
    Paths = [P || P <- code:get_path(), string:find(P, "chappe_cluster") =:= nomatch],
    [_, Host] = string:split(atom_to_list(node()), "@"),
    {ok, Peer, Node} = peer:start_link(#{
        name => peer:random_name(), host => Host, connection => standard_io,
        args => lists:append([["-pa", P] || P <- Paths])}),
    try
        ok = erpc:call(Node, application, load, [chappe_sip]),
        ok = erpc:call(Node, application, set_env, [chappe_sip, cluster, chappe_cluster]),
        ok = erpc:call(Node, application, set_env, [chappe_sip, engine_mod, chappe_sip_nif]),
        R = erpc:call(Node, application, ensure_all_started, [chappe_sip]),
        ct:pal("start: ~p", [R]),
        ?assertMatch({error, {chappe_sip, _}}, R),
        {error, {chappe_sip, Why}} = R,
        ?assertNotEqual(nomatch, string:find(io_lib:format("~p", [Why]), "chappe_cluster"))
    after
        peer:stop(Peer)
    end.

%% In cluster mode chappe_sip starts chappe_cluster before its own
%% supervisor, so the application controller stops chappe_cluster after
%% chappe_sip: when chappe_sip stops, its prep_stop still finds
%% chappe_cluster up and withdraws the registry sweep from it. Without a
%% cluster, chappe_cluster is not started.
cluster_stops_after_chappe_sip(Config) ->
    Dir = filename:join(?config(priv_dir, Config), "stop_order"),
    with_dist(fun() -> stop_order(Dir) end).

stop_order(Dir) ->
    [_, Host] = string:split(atom_to_list(node()), "@"),
    {ok, Peer, Node} = peer:start_link(#{
        name => peer:random_name(), host => Host, connection => standard_io,
        args => lists:append([["-pa", P] || P <- code:get_path()])}),
    try
        ok = erpc:call(Node, application, load, [chappe_cluster]),
        ok = erpc:call(Node, application, set_env,
                       [chappe_cluster, data_dir, Dir]),
        ok = erpc:call(Node, application, load, [chappe_sip]),
        ok = erpc:call(Node, application, set_env, [chappe_sip, cluster, chappe_cluster]),
        ok = erpc:call(Node, application, set_env, [chappe_sip, engine_mod, chappe_sip_nif]),
        {ok, Started} = erpc:call(Node, application, ensure_all_started, [chappe_sip]),
        ct:pal("started: ~p", [Started]),
        %% which_applications lists the latest started first
        Apps = [A || {A, _, _} <- erpc:call(Node, application, which_applications, [])],
        ?assert(index_of(chappe_sip, Apps) < index_of(chappe_cluster, Apps)),
        Sweep = chappe_sip_registry_sweep:name(),
        ok = wait_true(fun() -> lists:keymember(Sweep, 1, singleton_children(Node)) end, 100),
        ok = erpc:call(Node, application, stop, [chappe_sip]),
        ?assert(lists:keymember(chappe_cluster, 1,
                                erpc:call(Node, application, which_applications, []))),
        ?assertNot(lists:keymember(Sweep, 1, singleton_children(Node)))
    after
        peer:stop(Peer)
    end,
    %% cluster => none: chappe_cluster stays unstarted
    {ok, Peer2, Node2} = peer:start_link(#{
        name => peer:random_name(), host => Host, connection => standard_io,
        args => lists:append([["-pa", P] || P <- code:get_path()])}),
    try
        ok = erpc:call(Node2, application, load, [chappe_sip]),
        ok = erpc:call(Node2, application, set_env, [chappe_sip, engine_mod, chappe_sip_nif]),
        {ok, _} = erpc:call(Node2, application, ensure_all_started, [chappe_sip]),
        ?assertNot(lists:keymember(chappe_cluster, 1,
                                   erpc:call(Node2, application, which_applications, [])))
    after
        peer:stop(Peer2)
    end.

singleton_children(Node) ->
    [{Id, P} || {Id, P, _, _} <- erpc:call(Node, supervisor, which_children,
                                           [chappe_cluster_singleton_sup])].

index_of(X, L) ->
    length(lists:takewhile(fun(Y) -> Y =/= X end, L)).

wait_true(_F, 0) -> {error, timeout};
wait_true(F, N) ->
    case F() of
        true -> ok;
        false -> timer:sleep(100), wait_true(F, N - 1)
    end.

%% ---- helpers ----

wait_unbound(Aor, 0) ->
    chappe_sip:bindings(Aor);
wait_unbound(Aor, N) ->
    case chappe_sip:bindings(Aor) of
        [] -> [];
        _ -> timer:sleep(100), wait_unbound(Aor, N - 1)
    end.

tcp_register(LP, Contact, CSeq) ->
    P = integer_to_binary(LP),
    iolist_to_binary(
      [<<"REGISTER sip:127.0.0.1 SIP/2.0\r\n">>,
       <<"Via: SIP/2.0/TCP 127.0.0.1:", P/binary, ";branch=z9hG4bKt">>,
       integer_to_binary(CSeq), <<"\r\n">>,
       <<"Max-Forwards: 70\r\n">>,
       <<"From: Alice <sip:alice@127.0.0.1>;tag=ft\r\n">>,
       <<"To: Alice <sip:alice@127.0.0.1>\r\n">>,
       <<"Contact: ">>, Contact, <<"\r\n">>,
       <<"Supported: outbound\r\n">>,
       <<"Expires: 3600\r\n">>,
       <<"Call-ID: treg-">>, P, <<"@ct\r\n">>,
       <<"CSeq: ">>, integer_to_binary(CSeq),
       <<" REGISTER\r\nContent-Length: 0\r\n\r\n">>]).

caller_invite(LP) ->
    P = integer_to_binary(LP),
    <<"INVITE sip:alice@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=z9hG4bKci", P/binary, "\r\n"
      "Max-Forwards: 70\r\n"
      "From: <sip:bob@127.0.0.1>;tag=cb\r\n"
      "To: <sip:alice@127.0.0.1>\r\n"
      "Contact: <sip:bob@127.0.0.1:", P/binary, ">\r\n"
      "Call-ID: inv-", P/binary, "@ct\r\nCSeq: 1 INVITE\r\n"
      "Content-Length: 0\r\n\r\n">>.

%% a 486 to the request M, echoing its Vias
busy(M) ->
    Vias = [[<<"Via: ">>, V, <<"\r\n">>] || V <- chappe_sip_msg:get_all(<<"via">>, M)],
    iolist_to_binary(
      [<<"SIP/2.0 486 Busy Here\r\n">>, Vias,
       <<"From: ">>, chappe_sip_msg:get(<<"from">>, M), <<"\r\n">>,
       <<"To: ">>, chappe_sip_msg:get(<<"to">>, M), <<";tag=al\r\n">>,
       <<"Call-ID: ">>, chappe_sip_msg:call_id(M), <<"\r\n">>,
       <<"CSeq: ">>, chappe_sip_msg:get(<<"cseq">>, M), <<"\r\n">>,
       <<"Content-Length: 0\r\n\r\n">>]).

%% the next message starting with Prefix on a TCP connection, framed by
%% Content-Length (CRLF keepalives skipped)
tcp_recv(T, Prefix) ->
    tcp_recv(T, Prefix, <<>>).

tcp_recv(T, Prefix, Buf) ->
    case tcp_frame(Buf) of
        {ok, Msg, Rest} ->
            L = byte_size(Prefix),
            case Msg of
                <<Prefix:L/binary, _/binary>> -> Msg;
                _ -> tcp_recv(T, Prefix, Rest)
            end;
        more ->
            case gen_tcp:recv(T, 0, 6000) of
                {ok, D} -> tcp_recv(T, Prefix, <<Buf/binary, D/binary>>);
                Err -> ct:fail({no_tcp_msg, Prefix, Err})
            end
    end.

tcp_frame(<<"\r\n", Rest/binary>>) ->
    tcp_frame(Rest);
tcp_frame(Buf) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [Head, Tail] ->
            {ok, M} = chappe_sip_msg:parse(<<Head/binary, "\r\n\r\n">>),
            Len = binary_to_integer(chappe_sip_msg:get(<<"content-length">>, M)),
            case Tail of
                <<Body:Len/binary, Rest/binary>> ->
                    {ok, <<Head/binary, "\r\n\r\n", Body/binary>>, Rest};
                _ ->
                    more
            end;
        _ ->
            more
    end.

start() ->
    EP = pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:",
                                         (integer_to_binary(EP))/binary>>}),
    EP.

reg(Aor, Contacts, ExpiresHdr, CallId, CSeq) ->
    {ok, Msg} = chappe_sip_msg:parse(reg_raw(Aor, Contacts, ExpiresHdr, CallId, CSeq)),
    chappe_sip_registry:register_contacts(chappe_sip_req:new(Msg, undefined, #{}), #{}).

%% a REGISTER through register_request/2. Opts: to, ruri, contacts,
%% expires, callid, cseq, headers, vias, flow.
regx(Opts) ->
    To = maps:get(to, Opts, aor()),
    Vias = maps:get(vias, Opts, [<<"SIP/2.0/UDP 127.0.0.1:5060;branch=z9hG4bKreg">>]),
    Raw = iolist_to_binary(
      [<<"REGISTER ">>, maps:get(ruri, Opts, <<"sip:example.com">>), <<" SIP/2.0\r\n">>,
       [[<<"Via: ">>, V, <<"\r\n">>] || V <- Vias],
       <<"Max-Forwards: 70\r\n">>,
       <<"From: ">>, To, <<";tag=ft\r\n">>,
       <<"To: ">>, To, <<"\r\n">>,
       <<"Call-ID: ">>, maps:get(callid, Opts, <<"x">>), <<"@ct\r\n">>,
       <<"CSeq: ">>, integer_to_binary(maps:get(cseq, Opts, 1)), <<" REGISTER\r\n">>,
       [[<<"Contact: ">>, C, <<"\r\n">>] || C <- maps:get(contacts, Opts, [])],
       [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- maps:get(headers, Opts, [])],
       case maps:get(expires, Opts, undefined) of
           undefined -> [];
           E -> [<<"Expires: ">>, integer_to_binary(E), <<"\r\n">>]
       end,
       <<"Content-Length: 0\r\n\r\n">>]),
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    RegOpts = case maps:get(flow, Opts, undefined) of
                  undefined -> #{};
                  F -> #{flow => F}
              end,
    chappe_sip_registry:register_request(chappe_sip_req:new(Msg, undefined, #{}),
                                         RegOpts).

aor() -> <<"<sip:alice@example.com>">>.
curi(N) -> <<"sip:alice@10.0.0.", (integer_to_binary(N))/binary>>.
contact(N, Exp) ->
    <<"<", (curi(N))/binary, ">;expires=", (integer_to_binary(Exp))/binary>>.
bare_contact(N) -> <<"<", (curi(N))/binary, ">">>.

reg_raw(Aor, Contacts, ExpiresHdr, CallId, CSeq) ->
    CS = integer_to_binary(CSeq),
    ContactLines = [[<<"Contact: ">>, C, <<"\r\n">>] || C <- Contacts],
    ExpLine = case ExpiresHdr of
                  undefined -> [];
                  _ -> [<<"Expires: ">>, integer_to_binary(ExpiresHdr), <<"\r\n">>]
              end,
    iolist_to_binary(
      [<<"REGISTER sip:example.com SIP/2.0\r\n">>,
       <<"Via: SIP/2.0/UDP 127.0.0.1:5060;branch=z9hG4bKreg\r\n">>,
       <<"Max-Forwards: 70\r\n">>,
       <<"From: ">>, Aor, <<";tag=ft\r\n">>,
       <<"To: ">>, Aor, <<"\r\n">>,
       <<"Call-ID: ">>, CallId, <<"@ct\r\n">>,
       <<"CSeq: ">>, CS, <<" REGISTER\r\n">>,
       ContactLines, ExpLine,
       <<"Content-Length: 0\r\n\r\n">>]).

register_req(LP, Exp, CSeq) ->
    register_req(LP, Exp, CSeq, []).

%% Extra headers go after the Contact; an extra Via goes below ours.
register_req(LP, Exp, CSeq, Extra) ->
    P = integer_to_binary(LP),
    CS = integer_to_binary(CSeq),
    E = integer_to_binary(Exp),
    {Vias, Others} = lists:partition(fun({N, _}) -> N =:= <<"Via">> end, Extra),
    {Contacts, Rest} = lists:partition(fun({N, _}) -> N =:= <<"Contact">> end, Others),
    ContactLines = case Contacts of
                       [] -> [<<"Contact: <sip:alice@127.0.0.1:", P/binary, ">\r\n">>];
                       _ -> [<<"Contact: <sip:alice@127.0.0.1:", P/binary, ">\r\n">> ||
                                not lists:any(fun({_, V}) -> binary:match(V, <<"alice">>) =/= nomatch end, Contacts)]
                   end,
    iolist_to_binary(
      [<<"REGISTER sip:127.0.0.1 SIP/2.0\r\n">>,
       <<"Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=z9hG4bKr", CS/binary, "\r\n">>,
       [[<<"Via: ">>, V, <<"\r\n">>] || {_, V} <- Vias],
       <<"Max-Forwards: 70\r\n">>,
       <<"From: Alice <sip:alice@127.0.0.1>;tag=ft\r\n">>,
       <<"To: Alice <sip:alice@127.0.0.1>\r\n">>,
       ContactLines,
       [[<<"Contact: ">>, V, <<"\r\n">>] || {_, V} <- Contacts],
       [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Rest],
       <<"Expires: ">>, E, <<"\r\n">>,
       <<"Call-ID: reg-">>, P, <<"@ct\r\n">>,
       <<"CSeq: ">>, CS, <<" REGISTER\r\nContent-Length: 0\r\n\r\n">>]).

pick() -> chappe_sip_test_port:pick().
lport(Sock) -> {ok, P} = inet:port(Sock), P.
send(Sock, Dst, Bin) -> gen_udp:send(Sock, {127,0,0,1}, Dst, Bin).

recv_status(Sock, Code) ->
    CB = integer_to_binary(Code),
    receive
        {udp, Sock, _, _, <<"SIP/2.0 ", C:3/binary, _/binary>> = Bin} ->
            case C of CB -> Bin; _ -> recv_status(Sock, Code) end
    after 6000 -> ct:fail({no_status, Code})
    end.
