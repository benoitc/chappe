%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Publication (RFC 3903), presence (RFC 3856, RFC 3863) and message
%% waiting (RFC 3842), both sides, on the wire.
%%
%% A raw UDP peer plays the other side: an EPA publishing to chappe's ESC,
%% a watcher subscribing to chappe's presence agent or message-summary
%% notifier, an ESC taking chappe's publications, a notifier sending
%% chappe's subscriber its NOTIFYs. The codec cases check chappe_sip_pidf
%% and chappe_sip_mwi on their own.
-module(chappe_sip_presence_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-import(chappe_sip_core_peer, [
    open/0, port/1, send/3, recv/3, recv_none/3, request/3, response/3,
    hdr/2, hdrs/2, status/1, body/1, from_tag/1, to_tag/1, cseq/1, tag/0,
    call_id/0
]).

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([esc_lifecycle/1, esc_default_expires/1, esc_423/1, esc_489/1,
         esc_two_etags_400/1, esc_no_body_400/1, esc_415/1, esc_404/1,
         esc_digest/1, esc_options/1, presence_start_option/1]).
-export([esc_cross_user_403/1, esc_unauthenticated_403/1, esc_own_aor/1,
         esc_resources_with_auth/1, esc_authorize_hook/1, esc_max_total/1,
         esc_max_per_resource/1, esc_body_413/1, esc_watch_once/1]).
-export([pa_full_state/1, pa_rate/1, pa_accept_406/1, pa_deny_403/1,
         pa_pending/1, pa_polite/1, pa_digest/1, pa_fetch/1]).
-export([mwi_initial_and_update/1, mwi_rate/1, mwi_auth/1]).
-export([epa_lifecycle/1, epa_one_at_a_time/1, epa_412/1, epa_423/1,
         epa_digest/1]).
-export([watcher_pidf/1, watcher_mwi/1, watcher_one_dialog/1,
         watcher_digest/1]).
-export([pidf_render/1, pidf_parse/1, pidf_compose/1, mwi_codec/1]).

-define(PIDF, <<"application/pidf+xml">>).
-define(MWI, <<"application/simple-message-summary">>).

all() ->
    [{group, esc}, {group, pa}, {group, mwi}, {group, epa},
     {group, watcher}, {group, codecs}].

groups() ->
    [{esc, [], [esc_lifecycle, esc_default_expires, esc_423, esc_489,
                esc_two_etags_400, esc_no_body_400, esc_415, esc_404,
                esc_digest, esc_options, presence_start_option,
                esc_cross_user_403, esc_unauthenticated_403, esc_own_aor,
                esc_resources_with_auth, esc_authorize_hook, esc_max_total,
                esc_max_per_resource, esc_body_413, esc_watch_once]},
     {pa, [], [pa_full_state, pa_rate, pa_accept_406, pa_deny_403,
               pa_pending, pa_polite, pa_digest, pa_fetch]},
     {mwi, [], [mwi_initial_and_update, mwi_rate, mwi_auth]},
     {epa, [], [epa_lifecycle, epa_one_at_a_time, epa_412, epa_423,
                epa_digest]},
     {watcher, [], [watcher_pidf, watcher_mwi, watcher_one_dialog,
                    watcher_digest]},
     {codecs, [], [pidf_render, pidf_parse, pidf_compose, mwi_codec]}].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(Case, Config) ->
    EP = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => chappe_sip_core_peer:contact(EP)}),
    User = atom_to_binary(Case),
    [{ep, EP}, {sock, open()}, {user, User} | Config].

end_per_testcase(_Case, Config) ->
    [application:unset_env(chappe_sip, K) || K <- esc_limit_keys()],
    chappe_sip_core_peer:close(?config(sock, Config)),
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% ---- ESC (RFC 3903 6) ----

%% Initial, refresh, modify and remove: each 2xx has the granted Expires
%% and a new SIP-ETag, never a Record-Route or a Contact; a replaced or
%% removed entity-tag then gets 412.
%% req: R3903-23 R3903-24 R3903-29 R3903-31 R3903-32 R3903-37 R3903-38
%% req: R3903-40 R3903-41 R3903-42 R3903-43
esc_lifecycle(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    ok = chappe_sip:publish(open_esc()),
    Uri = res(User),
    R1 = pub(Sock, EP, Uri, #{expires => 120, body => pidf(Uri, <<"t1">>),
                              headers => [{<<"Record-Route">>,
                                           <<"<sip:rr@127.0.0.1;lr>">>}]}),
    ?assertEqual(200, status(R1)),
    ?assertEqual(<<"120">>, hdr(<<"expires">>, R1)),
    ?assertEqual(undefined, hdr(<<"record-route">>, R1)),
    ?assertEqual(undefined, hdr(<<"contact">>, R1)),
    [E1] = hdrs(<<"sip-etag">>, R1),
    R2 = pub(Sock, EP, Uri, #{expires => 120, if_match => E1}),
    ?assertEqual(200, status(R2)),
    E2 = hdr(<<"sip-etag">>, R2),
    ?assertNotEqual(E1, E2),
    ?assertEqual(412, status(pub(Sock, EP, Uri, #{if_match => E1}))),
    R3 = pub(Sock, EP, Uri, #{if_match => E2, body => pidf(Uri, <<"t2">>)}),
    ?assertEqual(200, status(R3)),
    E3 = hdr(<<"sip-etag">>, R3),
    ?assertEqual(3, length(lists:usort([E1, E2, E3]))),
    [#{etag := E3}] = chappe_sip_esc:publications(Uri, <<"presence">>),
    R4 = pub(Sock, EP, Uri, #{if_match => E3, expires => 0}),
    ?assertEqual(200, status(R4)),
    ?assertEqual(<<"0">>, hdr(<<"expires">>, R4)),
    ?assertEqual([], chappe_sip_esc:publications(Uri, <<"presence">>)),
    ?assertEqual(412, status(pub(Sock, EP, Uri, #{if_match => E3}))).

%% No Expires: the configured default.
%% req: R3903-33
esc_default_expires(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    ok = chappe_sip:publish((open_esc())#{default_expires => 1800}),
    Uri = res(User),
    R = pub(Sock, EP, Uri, #{body => pidf(Uri, <<"t1">>)}),
    ?assertEqual(<<"1800">>, hdr(<<"expires">>, R)).

%% Below min_expires: 423 with Min-Expires.
%% req: R3903-34
esc_423(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    ok = chappe_sip:publish((open_esc())#{min_expires => 60}),
    Uri = res(User),
    R = pub(Sock, EP, Uri, #{expires => 10, body => pidf(Uri, <<"t1">>)}),
    ?assertEqual(423, status(R)),
    ?assertEqual(<<"60">>, hdr(<<"min-expires">>, R)).

%% A package not served, or no Event: 489 with Allow-Events.
%% req: R3903-28
esc_489(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    ok = chappe_sip:publish(open_esc()),
    Uri = res(User),
    R1 = pub(Sock, EP, Uri, #{event => <<"dialog">>,
                              body => pidf(Uri, <<"t1">>)}),
    ?assertEqual(489, status(R1)),
    ?assertEqual(<<"presence">>, hdr(<<"allow-events">>, R1)),
    R2 = pub(Sock, EP, Uri, #{event => none, body => pidf(Uri, <<"t1">>)}),
    ?assertEqual(489, status(R2)).

%% Two entity-tags in SIP-If-Match: 400.
%% req: R3903-30
esc_two_etags_400(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    ok = chappe_sip:publish(open_esc()),
    Uri = res(User),
    ?assertEqual(400, status(pub(Sock, EP, Uri, #{if_match => <<"a, b">>}))).

%% Neither a body nor an entity-tag: 400.
%% req: R3903-36
esc_no_body_400(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    ok = chappe_sip:publish(open_esc()),
    ?assertEqual(400, status(pub(Sock, EP, res(User), #{}))).

%% A body the package does not take: 415 with Accept.
%% req: R3903-35
esc_415(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    ok = chappe_sip:publish(open_esc()),
    R = pub(Sock, EP, res(User), #{body => <<"online">>,
                                    content_type => <<"text/plain">>}),
    ?assertEqual(415, status(R)),
    ?assertEqual(?PIDF, hdr(<<"accept">>, R)).

%% A resource we keep no state for: 404.
%% req: R3903-27
esc_404(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    ok = chappe_sip:publish((open_esc())#{resources => fun(_Aor) -> false end}),
    Uri = res(User),
    ?assertEqual(404, status(pub(Sock, EP, Uri,
                                 #{body => pidf(Uri, <<"t1">>)}))).

%% Digest: 401 with a challenge, 200 once the PUBLISH answers it.
%% req: R3903-52
esc_digest(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    ok = chappe_sip:publish(#{auth => local_auth()}),
    Uri = res(<<"bob">>),
    R1 = pub(Sock, EP, Uri, #{body => pidf(Uri, <<"t1">>)}),
    ?assertEqual(401, status(R1)),
    Creds = credentials(<<"PUBLISH">>, Uri, hdr(<<"www-authenticate">>, R1)),
    R2 = pub(Sock, EP, Uri, #{body => pidf(Uri, <<"t1">>),
                              headers => [{<<"Authorization">>, Creds}]}),
    ?assertEqual(200, status(R2)).

%% OPTIONS lists PUBLISH in Allow and presence in Allow-Events.
%% req: R3903-44 R3903-45
esc_options(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    ok = chappe_sip_presence:serve(#{authorize => fun allow/3}),
    send(Sock, EP, request(<<"OPTIONS">>, <<"sip:app@127.0.0.1">>,
                           #{port => port(Sock)})),
    {R, _} = recv(Sock, {status, 200, <<"OPTIONS">>}, 3000),
    ?assert(lists:member(<<"PUBLISH">>, tokens(hdr(<<"allow">>, R)))),
    ?assert(lists:member(<<"presence">>, tokens(hdr(<<"allow-events">>, R)))).

%% chappe_sip:start/1 with presence => Opts serves the package.
presence_start_option(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    ok = chappe_sip:stop(),
    ok = chappe_sip:start(#{contact => chappe_sip_core_peer:contact(EP),
                            presence => #{authorize => fun allow/3}}),
    send(Sock, EP, request(<<"OPTIONS">>, <<"sip:app@127.0.0.1">>,
                           #{port => port(Sock)})),
    {R, _} = recv(Sock, {status, 200, <<"OPTIONS">>}, 3000),
    ?assert(lists:member(<<"PUBLISH">>, tokens(hdr(<<"allow">>, R)))),
    ?assertEqual([<<"presence">>], tokens(hdr(<<"allow-events">>, R))).

%% Bob, authenticated, publishing Alice's state: 403. Before the fix the
%% ESC dropped the authenticated user and took it.
%% req: R3903-51
esc_cross_user_403(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    ok = chappe_sip:publish(#{auth => local_auth()}),
    Alice = res(<<"alice">>),
    ?assertEqual(403, status(auth_pub(Sock, EP, Alice,
                                      #{body => pidf(Alice, <<"t1">>)}))),
    ?assertEqual([], chappe_sip_esc:publications(Alice, <<"presence">>)).

%% No auth and no opt-in: every PUBLISH gets 403; with
%% allow_unauthenticated => true it is taken.
esc_unauthenticated_403(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    Uri = res(User),
    ok = chappe_sip:publish(#{}),
    ?assertEqual(403, status(pub(Sock, EP, Uri,
                                 #{body => pidf(Uri, <<"t1">>)}))),
    ok = chappe_sip:publish(open_esc()),
    ?assertEqual(200, status(pub(Sock, EP, Uri,
                                 #{body => pidf(Uri, <<"t1">>)}))).

%% Bob publishing his own AOR, in the auth domain: 200. Another domain
%% for the same user: 403.
esc_own_aor(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    ok = chappe_sip:publish(#{auth => local_auth()}),
    Bob = res(<<"bob">>),
    ?assertEqual(200, status(auth_pub(Sock, EP, Bob,
                                      #{body => pidf(Bob, <<"t1">>)}))),
    Other = <<"sip:bob@elsewhere.example">>,
    ?assertEqual(403, status(auth_pub(Sock, EP, Other,
                                      #{body => pidf(Other, <<"t1">>)}))).

%% The resource allow list still applies to an authenticated owner.
esc_resources_with_auth(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    ok = chappe_sip:publish(#{auth => local_auth(),
                              resources => fun(_Aor) -> false end}),
    Bob = res(<<"bob">>),
    ?assertEqual(404, status(auth_pub(Sock, EP, Bob,
                                      #{body => pidf(Bob, <<"t1">>)}))).

%% An authorize hook replaces the own-AOR rule: it sees the user, the
%% realm, the resource and the package, and false is 403.
esc_authorize_hook(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Self = self(),
    Alice = res(<<"alice">>),
    Authorize = fun(#{user := U, realm := R, resource := A, event := E,
                      req := _}) ->
                        Self ! {authorize, U, R, A, E},
                        A =:= Alice
                end,
    ok = chappe_sip:publish(#{auth => local_auth(), authorize => Authorize}),
    ?assertEqual(200, status(auth_pub(Sock, EP, Alice,
                                      #{body => pidf(Alice, <<"t1">>)}))),
    receive {authorize, <<"bob">>, <<"lab">>, Alice, <<"presence">>} -> ok
    after 1000 -> ct:fail(no_authorize_call)
    end,
    Bob = res(<<"bob">>),
    ?assertEqual(403, status(auth_pub(Sock, EP, Bob,
                                      #{body => pidf(Bob, <<"t1">>)}))).

%% esc_max_publications: a new publication past it gets 503 with
%% Retry-After; a refresh of a live one is still taken.
esc_max_total(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    ok = fresh_esc(),
    application:set_env(chappe_sip, esc_max_publications, 1),
    ok = chappe_sip:publish(open_esc()),
    A = res(<<"a">>),
    B = res(<<"b">>),
    R1 = pub(Sock, EP, A, #{body => pidf(A, <<"t1">>)}),
    ?assertEqual(200, status(R1)),
    R2 = pub(Sock, EP, B, #{body => pidf(B, <<"t1">>)}),
    ?assertEqual(503, status(R2)),
    ?assertNotEqual(undefined, hdr(<<"retry-after">>, R2)),
    ?assertEqual(200, status(pub(Sock, EP, A,
                                 #{if_match => hdr(<<"sip-etag">>, R1)}))).

%% esc_max_publications_per_resource: a third publication for one resource
%% gets 503; another resource is still taken.
esc_max_per_resource(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    ok = fresh_esc(),
    application:set_env(chappe_sip, esc_max_publications_per_resource, 2),
    ok = chappe_sip:publish(open_esc()),
    Uri = res(User),
    [?assertEqual(200, status(pub(Sock, EP, Uri, #{body => pidf(Uri, T)})))
     || T <- [<<"t1">>, <<"t2">>]],
    R = pub(Sock, EP, Uri, #{body => pidf(Uri, <<"t3">>)}),
    ?assertEqual(503, status(R)),
    ?assertNotEqual(undefined, hdr(<<"retry-after">>, R)),
    ?assertEqual(2, length(chappe_sip_esc:publications(Uri, <<"presence">>))),
    Other = res(<<User/binary, "_other">>),
    ?assertEqual(200, status(pub(Sock, EP, Other,
                                 #{body => pidf(Other, <<"t1">>)}))).

%% A body over esc_max_body_size: 413, nothing stored.
esc_body_413(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    application:set_env(chappe_sip, esc_max_body_size, 64),
    ok = chappe_sip:publish(open_esc()),
    Uri = res(User),
    ?assertEqual(413, status(pub(Sock, EP, Uri,
                                 #{body => pidf(Uri, <<"t1">>)}))),
    ?assertEqual([], chappe_sip_esc:publications(Uri, <<"presence">>)).

%% watch/2 twice for one pid: one monitor, removed when the pid exits.
esc_watch_once(_Config) ->
    Pid = spawn(fun() -> receive stop -> ok end end),
    ok = chappe_sip_esc:watch(<<"presence">>, Pid),
    ok = chappe_sip_esc:watch(<<"presence">>, Pid),
    ok = chappe_sip_esc:watch(<<"dialog">>, Pid),
    ?assertEqual(1, length(esc_monitors(Pid))),
    Pid ! stop,
    timer:sleep(100),
    ?assertEqual([], esc_monitors(Pid)).

esc_monitors(Pid) ->
    {monitors, Ms} = erlang:process_info(whereis(chappe_sip_esc), monitors),
    [P || {process, P} <- Ms, P =:= Pid].

%% ---- presence agent (RFC 3856) ----

%% Two publications for a presentity: a watcher gets one PIDF document
%% with the tuples of both, the newest tuple of each id winning.
%% req: R3856-03 R3856-10 R3856-12 R3863-01 R3863-03 R3863-04 R3863-05
%% req: R3863-11 R3863-12 R3863-13 R3863-15
pa_full_state(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    ok = chappe_sip_presence:serve(#{esc => open_esc(), authorize => fun allow/3}),
    Uri = res(User),
    200 = status(pub(Sock, EP, Uri, #{body => pidf(Uri, [{<<"a">>, open},
                                                         {<<"b">>, open}])})),
    timer:sleep(10),
    200 = status(pub(Sock, EP, Uri, #{body => pidf(Uri, [{<<"a">>, closed}])})),
    {_Sub, N} = watch(Sock, EP, Uri, #{}),
    ?assertEqual(?PIDF, hdr(<<"content-type">>, N)),
    Body = body(N),
    ?assertMatch(<<"<?xml version=\"1.0\" encoding=\"UTF-8\"?>", _/binary>>, Body),
    {ok, #{entity := Uri, tuples := Tuples}} = chappe_sip_pidf:parse(Body),
    ?assertEqual([{<<"a">>, closed}, {<<"b">>, open}],
                 lists:sort([{Id, B} || #{id := Id, basic := B} <- Tuples])),
    [?assertMatch({match, _}, re:run(TS, "^\\d{4}-\\d\\d-\\d\\dT[0-9:.]+Z$"))
     || #{timestamp := TS} <- Tuples],
    ?assertMatch({_, _}, binary:match(Body,
                                      <<"xmlns=\"urn:ietf:params:xml:ns:pidf\"">>)).

%% A change reaches the watcher, never sooner than min_interval after the
%% NOTIFY before.
%% req: R3856-13
pa_rate(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    ok = chappe_sip_presence:serve(#{esc => open_esc(), authorize => fun allow/3,
                                     min_interval => 1000}),
    Uri = res(User),
    R = pub(Sock, EP, Uri, #{body => pidf(Uri, [{<<"a">>, open}])}),
    E1 = hdr(<<"sip-etag">>, R),
    {Sub, _N1} = watch(Sock, EP, Uri, #{}),
    T1 = now_ms(),
    R2 = pub(Sock, EP, Uri, #{if_match => E1,
                              body => pidf(Uri, [{<<"a">>, closed}])}),
    {N2, _} = recv_notify(Sock, EP),
    T2 = now_ms(),
    ?assert(T2 - T1 >= 900, {too_soon, T2 - T1}),
    {ok, #{tuples := [#{basic := closed}]}} = chappe_sip_pidf:parse(body(N2)),
    _ = pub(Sock, EP, Uri, #{if_match => hdr(<<"sip-etag">>, R2),
                             body => pidf(Uri, [{<<"a">>, open}])}),
    {_, _} = recv_notify(Sock, EP),
    ?assert(now_ms() - T2 >= 900),
    _ = Sub.

%% An Accept without application/pidf+xml: 406.
%% req: R3856-10
pa_accept_406(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    ok = chappe_sip_presence:serve(#{esc => open_esc(), authorize => fun allow/3}),
    send(Sock, EP, subscribe(Sock, res(User), <<"presence">>,
                             [{<<"Accept">>, <<"application/xpidf+xml">>}])),
    {R, _} = recv(Sock, final, 3000),
    ?assertEqual(406, status(R)).

%% Not authorized by the presentity: 403.
%% req: R3856-06
pa_deny_403(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    ok = chappe_sip_presence:serve(#{authorize => fun(_, _, _) -> deny end}),
    send(Sock, EP, subscribe(Sock, res(User), <<"presence">>, [])),
    {R, _} = recv(Sock, final, 3000),
    ?assertEqual(403, status(R)).

%% Pending: a pending NOTIFY whose document has a note; once allowed, an
%% active NOTIFY with the state.
%% req: R3856-07 R3856-09
pa_pending(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    ok = chappe_sip_presence:serve(#{esc => open_esc(),
                                     authorize => fun(_, _, _) -> pending end,
                                     min_interval => 0}),
    Uri = res(User),
    200 = status(pub(Sock, EP, Uri, #{body => pidf(Uri, [{<<"a">>, open}])})),
    {_Sub, N1} = watch(Sock, EP, Uri, #{}),
    ?assertMatch(<<"pending", _/binary>>, hdr(<<"subscription-state">>, N1)),
    {ok, #{tuples := [], notes := [_]}} = chappe_sip_pidf:parse(body(N1)),
    ok = chappe_sip_presence:decide(Uri, allow),
    {N2, _} = recv_notify(Sock, EP),
    ?assertMatch(<<"active", _/binary>>, hdr(<<"subscription-state">>, N2)),
    {ok, #{tuples := [#{id := <<"a">>, basic := open}]}} =
        chappe_sip_pidf:parse(body(N2)).

%% Polite blocking: 200 and an active NOTIFY saying closed.
%% req: R3856-08
pa_polite(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    ok = chappe_sip_presence:serve(#{esc => open_esc(),
                                     authorize => fun(_, _, _) -> polite end}),
    Uri = res(User),
    200 = status(pub(Sock, EP, Uri, #{body => pidf(Uri, [{<<"a">>, open}])})),
    {_Sub, N} = watch(Sock, EP, Uri, #{}),
    ?assertMatch(<<"active", _/binary>>, hdr(<<"subscription-state">>, N)),
    {ok, #{tuples := [#{basic := closed}]}} = chappe_sip_pidf:parse(body(N)).

%% Every subscription is authenticated: 401 without credentials.
%% req: R3856-05
pa_digest(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    ok = chappe_sip_presence:serve(#{authorize => fun allow/3, auth => auth()}),
    Uri = res(User),
    send(Sock, EP, subscribe(Sock, Uri, <<"presence">>, [])),
    {R, _} = recv(Sock, final, 3000),
    ?assertEqual(401, status(R)),
    Creds = credentials(<<"SUBSCRIBE">>, Uri, hdr(<<"www-authenticate">>, R)),
    send(Sock, EP, subscribe(Sock, Uri, <<"presence">>,
                             [{<<"Authorization">>, Creds}])),
    {200, _} = ok_and_notify(Sock).

%% A fetch (Expires: 0) gets the state once, in a terminated NOTIFY.
pa_fetch(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    ok = chappe_sip_presence:serve(#{esc => open_esc(), authorize => fun allow/3}),
    Uri = res(User),
    200 = status(pub(Sock, EP, Uri, #{body => pidf(Uri, [{<<"a">>, open}])})),
    send(Sock, EP, subscribe(Sock, Uri, <<"presence">>,
                             [{<<"Expires">>, <<"0">>}])),
    {200, N} = ok_and_notify(Sock),
    ?assertMatch(<<"terminated", _/binary>>, hdr(<<"subscription-state">>, N)),
    {ok, #{tuples := [_]}} = chappe_sip_pidf:parse(body(N)).

%% ---- message waiting notifier (RFC 3842) ----

%% A subscription gets the summary at once (no Accept: the package's
%% type), with the account, and every update after.
%% req: R3842-01 R3842-02 R3842-03 R3842-15 R3842-17 R3842-18
mwi_initial_and_update(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    Acc = res(User),
    ok = chappe_sip_mwi:serve(#{summary => fun(_) -> #{} end}),
    send(Sock, EP, subscribe(Sock, Acc, <<"message-summary">>, [])),
    {200, N1} = ok_and_notify(Sock),
    ?assertEqual(?MWI, hdr(<<"content-type">>, N1)),
    ?assertEqual(<<"Messages-Waiting: no\r\nMessage-Account: ", Acc/binary,
                   "\r\n">>, body(N1)),
    timer:sleep(1100),
    ok = chappe_sip_mwi:update(Acc, #{messages => #{voice => {2, 1}}}),
    {N2, _} = recv_notify(Sock, EP),
    ?assertEqual(<<"Messages-Waiting: yes\r\nMessage-Account: ", Acc/binary,
                   "\r\nVoice-Message: 2/1\r\n">>, body(N2)).

%% Never more than one NOTIFY a second to a subscriber.
%% req: R3842-20
mwi_rate(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    Acc = res(User),
    ok = chappe_sip_mwi:serve(#{summary => fun(_) -> #{} end}),
    send(Sock, EP, subscribe(Sock, Acc, <<"message-summary">>, [])),
    {200, _} = ok_and_notify(Sock),
    T1 = now_ms(),
    ok = chappe_sip_mwi:update(Acc, #{messages => #{voice => {1, 0}}}),
    ok = chappe_sip_mwi:update(Acc, #{messages => #{voice => {3, 0}}}),
    {N2, _} = recv_notify(Sock, EP),
    ?assert(now_ms() - T1 >= 900),
    %% the update held back went out with the latest counts
    ?assertMatch({_, _}, binary:match(body(N2), <<"Voice-Message: 3/0">>)),
    recv_none(Sock, {method, <<"NOTIFY">>}, 1500).

%% Subscriptions are authenticated and authorized.
%% req: R3842-14 R3842-21
mwi_auth(Config) ->
    {EP, Sock, User} = {?config(ep, Config), ?config(sock, Config),
                        ?config(user, Config)},
    Acc = res(User),
    ok = chappe_sip_mwi:serve(#{summary => fun(_) -> #{} end, auth => auth(),
                                authorize => fun(U, _, _) -> U =/= <<"bob">> end}),
    send(Sock, EP, subscribe(Sock, Acc, <<"message-summary">>, [])),
    {R, _} = recv(Sock, final, 3000),
    ?assertEqual(401, status(R)),
    Creds = credentials(<<"SUBSCRIBE">>, Acc, hdr(<<"www-authenticate">>, R)),
    send(Sock, EP, subscribe(Sock, Acc, <<"message-summary">>,
                             [{<<"Authorization">>, Creds}])),
    {R2, _} = recv(Sock, final, 3000),
    ?assertEqual(403, status(R2)).

%% ---- EPA (RFC 3903 4, 5) ----

%% chappe publishes: the initial PUBLISH (one Event, the body, no
%% SIP-If-Match), the refresh before expiry (SIP-If-Match, no body, no
%% Route from the 200's Record-Route), the modify, the remove.
%% req: R3903-01 R3903-02 R3903-04 R3903-05 R3903-06 R3903-07 R3903-08
%% req: R3903-09 R3903-10 R3903-11 R3903-12 R3903-13 R3903-14 R3903-15
%% req: R3903-16 R3903-17 R3903-48
epa_lifecycle(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Uri = esc_uri(Sock),
    Doc = chappe_sip_pidf:render(#{entity => Uri,
                                   tuples => [#{id => <<"t">>, basic => open}]}),
    {ok, Pub} = chappe_sip:publish_state(Uri, <<"presence">>, Doc,
                                         #{expires => 3}),
    {P1, _} = recv(Sock, {method, <<"PUBLISH">>}, 3000),
    ?assertEqual([<<"presence">>], hdrs(<<"event">>, P1)),
    ?assertEqual([], hdrs(<<"sip-if-match">>, P1)),
    ?assertEqual(Doc, body(P1)),
    ?assertEqual(?PIDF, hdr(<<"content-type">>, P1)),
    send(Sock, EP, ok_pub(P1, <<"e1">>, 3,
                          [{<<"Record-Route">>, <<"<sip:rr@10.0.0.9;lr>">>}])),
    {published, 3} = pub_event(Pub),
    {P2, _} = recv(Sock, {method, <<"PUBLISH">>}, 3000),
    ?assertEqual([<<"e1">>], hdrs(<<"sip-if-match">>, P2)),
    ?assertEqual(<<>>, body(P2)),
    ?assertEqual([], hdrs(<<"route">>, P2)),
    ?assertEqual([<<"presence">>], hdrs(<<"event">>, P2)),
    send(Sock, EP, ok_pub(P2, <<"e2">>, 60, [])),
    Doc2 = chappe_sip_pidf:render(#{entity => Uri,
                                    tuples => [#{id => <<"t">>, basic => closed}]}),
    ok = chappe_sip_publisher:update(Pub, Doc2),
    {P3, _} = recv(Sock, {method, <<"PUBLISH">>}, 3000),
    ?assertEqual([<<"e2">>], hdrs(<<"sip-if-match">>, P3)),
    ?assertEqual(Doc2, body(P3)),
    send(Sock, EP, ok_pub(P3, <<"e3">>, 60, [])),
    {published, 60} = pub_event(Pub),
    ok = chappe_sip_publisher:unpublish(Pub),
    {P4, _} = recv(Sock, {method, <<"PUBLISH">>}, 3000),
    ?assertEqual([<<"e3">>], hdrs(<<"sip-if-match">>, P4)),
    ?assertEqual(<<"0">>, hdr(<<"expires">>, P4)),
    ?assertEqual(<<>>, body(P4)),
    send(Sock, EP, ok_pub(P4, <<"e4">>, 0, [])),
    unpublished = pub_event(Pub).

%% An update made while a PUBLISH is out waits for its final response.
%% req: R3903-03
epa_one_at_a_time(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Uri = esc_uri(Sock),
    {ok, Pub} = chappe_sip:publish_state(Uri, <<"presence">>, doc(Uri, open),
                                         #{}),
    {P1, _} = recv(Sock, {method, <<"PUBLISH">>}, 3000),
    ok = chappe_sip_publisher:update(Pub, doc(Uri, closed)),
    Seq1 = cseq(P1),
    recv_none(Sock, fun(B) -> is_publish(B) andalso cseq(B) =/= Seq1 end, 1500),
    send(Sock, EP, ok_pub(P1, <<"e1">>, 3600, [])),
    {P2, _} = recv(Sock, {method, <<"PUBLISH">>}, 3000),
    ?assertEqual([<<"e1">>], hdrs(<<"sip-if-match">>, P2)),
    ?assertEqual(doc(Uri, closed), body(P2)).

%% A 412: the entity-tag goes, the whole state is published again without
%% SIP-If-Match, and the next PUBLISH names the new entity-tag.
%% req: R3903-18 R3903-19 R3903-20
epa_412(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Uri = esc_uri(Sock),
    {ok, Pub} = chappe_sip:publish_state(Uri, <<"presence">>, doc(Uri, open),
                                         #{expires => 3}),
    {P1, _} = recv(Sock, {method, <<"PUBLISH">>}, 3000),
    send(Sock, EP, ok_pub(P1, <<"e1">>, 3, [])),
    {published, 3} = pub_event(Pub),
    {P2, _} = recv(Sock, {method, <<"PUBLISH">>}, 3000),
    ?assertEqual([<<"e1">>], hdrs(<<"sip-if-match">>, P2)),
    send(Sock, EP, response(P2, 412, #{to_tag => tag()})),
    {P3, _} = recv(Sock, {method, <<"PUBLISH">>}, 3000),
    ?assertEqual([], hdrs(<<"sip-if-match">>, P3)),
    ?assertEqual(doc(Uri, open), body(P3)),
    send(Sock, EP, ok_pub(P3, <<"e5">>, 3600, [])),
    {published, 3600} = pub_event(Pub),
    ok = chappe_sip_publisher:unpublish(Pub),
    {P4, _} = recv(Sock, {method, <<"PUBLISH">>}, 3000),
    ?assertEqual([<<"e5">>], hdrs(<<"sip-if-match">>, P4)).

%% A 423: the PUBLISH again with the Min-Expires it asks for.
%% req: R3903-21
epa_423(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Uri = esc_uri(Sock),
    {ok, _Pub} = chappe_sip:publish_state(Uri, <<"presence">>, doc(Uri, open),
                                          #{expires => 30}),
    {P1, _} = recv(Sock, {method, <<"PUBLISH">>}, 3000),
    send(Sock, EP, response(P1, 423, #{to_tag => tag(), headers =>
                                       [{<<"Min-Expires">>, <<"120">>}]})),
    {P2, _} = recv(Sock, {method, <<"PUBLISH">>}, 3000),
    ?assertEqual(<<"120">>, hdr(<<"expires">>, P2)),
    ?assertEqual([], hdrs(<<"sip-if-match">>, P2)).

%% The EPA answers a digest challenge.
%% req: R3903-52
epa_digest(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Uri = esc_uri(Sock),
    {ok, _Pub} = chappe_sip:publish_state(
        Uri, <<"presence">>, doc(Uri, open),
        #{auth => #{user => <<"alice">>, pass => <<"secret">>}}),
    {P1, _} = recv(Sock, {method, <<"PUBLISH">>}, 3000),
    send(Sock, EP, response(P1, 401, #{to_tag => tag(), headers => [
        {<<"WWW-Authenticate">>, chappe_sip_digest:challenge(<<"lab">>)}]})),
    {P2, _} = recv(Sock, {method, <<"PUBLISH">>}, 3000),
    ?assertNotEqual(undefined, hdr(<<"authorization">>, P2)),
    ?assertEqual(doc(Uri, open), body(P2)).

%% ---- watcher (subscriber side) ----

%% A presence subscription asks for application/pidf+xml and hands the
%% owner each PIDF parsed: a prefixed namespace, an unknown element (even
%% mustUnderstand) skipped, priorities absent or out of range read as the
%% lowest, a UTF-8 note.
%% req: R3856-03 R3856-04 R3863-02 R3863-09 R3863-10 R3863-16 R3863-17
%% req: R3863-19
watcher_pidf(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Sub} = chappe_sip:subscribe_to(esc_uri(Sock), <<"presence">>, #{}),
    {S1, _} = recv(Sock, {method, <<"SUBSCRIBE">>}, 3000),
    ?assertEqual(?PIDF, hdr(<<"accept">>, S1)),
    send(Sock, EP, notify(Sock, S1, <<"w1">>, foreign_pidf(), ?PIDF)),
    {_, _} = recv(Sock, {status, 200, <<"NOTIFY">>}, 3000),
    {notify, #{doc := Doc}} = sub_event(Sub),
    #{entity := <<"pres:someone@example.com">>, tuples := Tuples} = Doc,
    [A, B] = lists:sort(fun(X, Y) -> maps:get(id, X) =< maps:get(id, Y) end,
                        Tuples),
    ?assertMatch(#{id := <<"a">>, basic := open,
                   contact := <<"tel:+09012345678">>, priority := +0.0}, A),
    ?assertMatch(#{id := <<"b">>, priority := +0.0}, B),
    ?assertEqual([{<<"fr">>, <<"caf", 16#c3, 16#a9>>}], maps:get(notes, A)).

%% A message-summary subscription asks for its type and hands the owner
%% the summary parsed, a count past 2^32-1 read as 2^32-1.
%% req: R3842-05 R3842-12
watcher_mwi(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Sub} = chappe_sip:subscribe_to(esc_uri(Sock), <<"message-summary">>,
                                         #{}),
    {S1, _} = recv(Sock, {method, <<"SUBSCRIBE">>}, 3000),
    ?assertEqual(?MWI, hdr(<<"accept">>, S1)),
    Body = <<"Messages-Waiting: yes\r\nMessage-Account: sip:a@b\r\n"
             "Voice-Message: 9999999999/1 (0/1)\r\n">>,
    send(Sock, EP, notify(Sock, S1, <<"w2">>, Body, ?MWI)),
    {_, _} = recv(Sock, {status, 200, <<"NOTIFY">>}, 3000),
    {notify, #{doc := Summary}} = sub_event(Sub),
    ?assertEqual(#{waiting => true, account => <<"sip:a@b">>,
                   messages => #{voice => {4294967295, 1, 0, 1}}}, Summary).

%% Presence makes one dialog per SUBSCRIBE (RFC 3856 6.9): a NOTIFY from
%% another fork gets 481.
watcher_one_dialog(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Sub} = chappe_sip:subscribe_to(esc_uri(Sock), <<"presence">>, #{}),
    {S1, _} = recv(Sock, {method, <<"SUBSCRIBE">>}, 3000),
    send(Sock, EP, notify(Sock, S1, <<"f1">>, foreign_pidf(), ?PIDF)),
    {_, _} = recv(Sock, {status, 200, <<"NOTIFY">>}, 3000),
    {notify, _} = sub_event(Sub),
    send(Sock, EP, notify(Sock, S1, <<"f2">>, foreign_pidf(), ?PIDF)),
    {_, _} = recv(Sock, {status, 481, <<"NOTIFY">>}, 3000).

%% A watcher answers the digest challenge to its SUBSCRIBE.
%% req: R3856-15
watcher_digest(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, _Sub} = chappe_sip:subscribe_to(
        esc_uri(Sock), <<"presence">>,
        #{auth => #{user => <<"alice">>, pass => <<"secret">>}}),
    {S1, _} = recv(Sock, {method, <<"SUBSCRIBE">>}, 3000),
    send(Sock, EP, response(S1, 401, #{to_tag => tag(), headers => [
        {<<"WWW-Authenticate">>, chappe_sip_digest:challenge(<<"lab">>)}]})),
    {S2, _} = recv(Sock, {method, <<"SUBSCRIBE">>}, 3000),
    ?assertNotEqual(undefined, hdr(<<"authorization">>, S2)).

%% ---- codecs ----

%% render/1: the XML declaration with UTF-8, the pidf namespace, entity,
%% one tuple per id, a priority with at most 3 decimals (one out of range
%% left out), a timestamp per tuple in RFC 3339 UTC with capital T and Z,
%% UTF-8 text.
%% req: R3863-01 R3863-06 R3863-08 R3863-11 R3863-12 R3863-13 R3863-15
%% req: R3863-19
pidf_render(_Config) ->
    Doc = #{entity => <<"sip:a@b">>,
            tuples => [#{id => <<"x">>, basic => open,
                         contact => <<"sip:a@c">>, priority => 0.12345},
                       #{id => <<"x">>, basic => closed},
                       #{id => <<"y">>, basic => closed, contact => <<"sip:a@d">>,
                         priority => 2, notes => [<<"bient", 16#c3, 16#b4, "t">>]}]},
    Bin = chappe_sip_pidf:render(Doc),
    ?assertMatch(<<"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n", _/binary>>, Bin),
    ?assertMatch({_, _}, binary:match(Bin, <<"priority=\"0.123\"">>)),
    ?assertEqual(1, length(binary:matches(Bin, <<"priority=">>))),
    ?assertEqual(2, length(binary:matches(Bin, <<"<tuple ">>))),
    {ok, #{tuples := [X, Y]}} = chappe_sip_pidf:parse(Bin),
    ?assertMatch(#{id := <<"x">>, basic := open, priority := 0.123}, X),
    ?assertMatch(#{id := <<"y">>, notes := [<<"bient", 16#c3, 16#b4, "t">>]}, Y),
    [?assertMatch({match, _}, re:run(T, "^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\d(\\.\\d+)?Z$"))
     || #{timestamp := T} <- [X, Y]].

%% parse/1: entity required, a tuple without an id dropped, no priority or
%% one out of range the lowest, other namespaces skipped, no DOCTYPE.
%% req: R3863-02 R3863-03 R3863-05 R3863-09 R3863-10 R3863-16 R3863-17
pidf_parse(_Config) ->
    ?assertEqual({error, no_entity}, chappe_sip_pidf:parse(
        <<"<?xml version=\"1.0\"?><presence xmlns=\"urn:ietf:params:xml:ns:pidf\"/>">>)),
    {ok, #{tuples := Ts}} = chappe_sip_pidf:parse(
        <<"<?xml version=\"1.0\"?><presence xmlns=\"urn:ietf:params:xml:ns:pidf\""
          " xmlns:e=\"urn:x\" entity=\"sip:a@b\"><tuple><status><basic>open</basic>"
          "</status></tuple><tuple id=\"k\"><status><basic>closed</basic>"
          "<e:mood mustUnderstand=\"true\">sad</e:mood></status>"
          "<e:x><tuple id=\"inner\"/></e:x>"
          "<contact priority=\"7\">sip:a@c</contact></tuple></presence>">>),
    ?assertMatch([#{id := <<"k">>, basic := closed, priority := +0.0}], Ts),
    ?assertMatch({error, doctype}, chappe_sip_pidf:parse(
        <<"<?xml version=\"1.0\"?><!DOCTYPE p [<!ENTITY a \"b\">]><p/>">>)),
    {ok, #{tuples := [#{notes := [N]}]}} = chappe_sip_pidf:parse(foreign_pidf2()),
    ?assertEqual(<<"caf", 16#c3, 16#a9>>, N).

%% compose/2: one tuple per id, the first (newest) document's winning.
%% req: R3863-06 R3856-12
pidf_compose(_Config) ->
    New = #{entity => <<"e">>, tuples => [#{id => <<"a">>, basic => closed}]},
    Old = #{entity => <<"e">>, tuples => [#{id => <<"a">>, basic => open},
                                          #{id => <<"b">>, basic => open}]},
    #{tuples := [A, B]} = chappe_sip_pidf:compose(<<"e">>, [New, Old]),
    ?assertMatch(#{id := <<"a">>, basic := closed}, A),
    ?assertMatch(#{id := <<"b">>}, B).

%% The simple-message-summary body: no angle brackets on the account,
%% counts capped at 2^32-1 both ways.
%% req: R3842-03 R3842-04 R3842-05
mwi_codec(_Config) ->
    Bin = chappe_sip_mwi:render(#{account => <<"<sip:a@b>">>,
                                  messages => #{voice => {1 bsl 40, 0, 1, 0},
                                                fax => {0, 2}}}),
    ?assertEqual(<<"Messages-Waiting: yes\r\nMessage-Account: sip:a@b\r\n"
                   "Voice-Message: 4294967295/0 (1/0)\r\nFax-Message: 0/2\r\n">>,
                 Bin),
    ?assertEqual({ok, #{waiting => true, account => <<"sip:a@b">>,
                        messages => #{voice => {4294967295, 0, 1, 0},
                                      fax => {0, 2}}}},
                 chappe_sip_mwi:parse(Bin)),
    ?assertEqual({error, no_status}, chappe_sip_mwi:parse(<<"Voice-Message: 1/0\r\n">>)).

%% ---- helpers ----

allow(_, _, _) -> allow.

%% the ESC options of a closed test network: no auth
open_esc() -> #{allow_unauthenticated => true}.

%% bob's credentials, for AORs at 127.0.0.1
local_auth() -> (auth())#{domain => <<"127.0.0.1">>}.

%% a PUBLISH answered with bob's credentials after the 401
auth_pub(Sock, EP, Uri, Opts) ->
    R1 = pub(Sock, EP, Uri, Opts),
    401 = status(R1),
    Creds = credentials(<<"PUBLISH">>, Uri, hdr(<<"www-authenticate">>, R1)),
    pub(Sock, EP, Uri, Opts#{headers => [{<<"Authorization">>, Creds}]}).

esc_limit_keys() ->
    [esc_max_publications, esc_max_publications_per_resource,
     esc_max_body_size].

%% a new ESC with no publications (and the notifiers after it, rest_for_one)
fresh_esc() ->
    Old = whereis(chappe_sip_esc),
    OldN = whereis(chappe_sip_presence_notifier),
    exit(Old, kill),
    ok = wait_new(chappe_sip_esc, Old, 50),
    wait_new(chappe_sip_presence_notifier, OldN, 50).

wait_new(Name, _Old, 0) ->
    ct:fail({not_restarted, Name});
wait_new(Name, Old, N) ->
    case whereis(Name) of
        P when is_pid(P), P =/= Old -> ok;
        _ -> timer:sleep(20), wait_new(Name, Old, N - 1)
    end.

auth() ->
    #{realm => <<"lab">>,
      secret => fun(<<"bob">>) -> {ok, <<"pw">>}; (_) -> error end}.

credentials(Method, Uri, Chal) ->
    {ok, C} = chappe_sip_hdr:auth(Chal),
    {ok, V} = chappe_sip_digest:credentials(#{
        method => Method, uri => Uri, username => <<"bob">>,
        password => <<"pw">>, challenge => C, nc => 1}),
    V.

res(User) -> <<"sip:", User/binary, "@127.0.0.1">>.

esc_uri(Sock) ->
    <<"sip:esc@127.0.0.1:", (integer_to_binary(port(Sock)))/binary>>.

%% one PUBLISH to the ESC and its final response
pub(Sock, EP, Uri, Opts) ->
    Event = case maps:get(event, Opts, <<"presence">>) of
                none -> [];
                E -> [{<<"Event">>, E}]
            end,
    Exp = [{<<"Expires">>, integer_to_binary(X)}
           || X <- [maps:get(expires, Opts, none)], is_integer(X)],
    IfM = [{<<"SIP-If-Match">>, M} || M <- [maps:get(if_match, Opts, none)],
                                      is_binary(M)],
    Body = maps:get(body, Opts, <<>>),
    Req = request(<<"PUBLISH">>, Uri, #{
        port => port(Sock), contact => <<"<sip:epa@127.0.0.1>">>,
        headers => Event ++ Exp ++ IfM ++ maps:get(headers, Opts, []),
        body => Body,
        content_type => maps:get(content_type, Opts, ?PIDF)}),
    send(Sock, EP, Req),
    CallId = hdr(<<"call-id">>, Req),
    {R, _} = recv(Sock, fun(B) -> final_of(CallId, B) end, 3000),
    R.

final_of(CallId, <<"SIP/2.0 ", S:1/binary, _/binary>> = B) when S =/= <<"1">> ->
    hdr(<<"call-id">>, B) =:= CallId;
final_of(_CallId, _B) ->
    false.

pidf(Uri, Tuples) when is_list(Tuples) ->
    chappe_sip_pidf:render(#{entity => Uri,
                             tuples => [#{id => I, basic => B} || {I, B} <- Tuples]});
pidf(Uri, Id) ->
    pidf(Uri, [{Id, open}]).

doc(Uri, Basic) ->
    iolist_to_binary(
      [<<"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<presence xmlns=\""
         "urn:ietf:params:xml:ns:pidf\" entity=\"">>, Uri,
       <<"\"><tuple id=\"t\"><status><basic>">>, atom_to_binary(Basic),
       <<"</basic></status></tuple></presence>\n">>]).

foreign_pidf() ->
    <<"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      "<impp:presence xmlns:impp=\"urn:ietf:params:xml:ns:pidf\""
      " xmlns:x=\"urn:example:ext\" entity=\"pres:someone@example.com\">"
      "<impp:tuple id=\"a\"><impp:status><impp:basic>open</impp:basic>"
      "<x:busy mustUnderstand=\"1\">yes</x:busy></impp:status>"
      "<impp:contact>tel:+09012345678</impp:contact>"
      "<impp:note xml:lang=\"fr\">caf", 16#c3, 16#a9, "</impp:note></impp:tuple>"
      "<impp:tuple id=\"b\"><impp:status><impp:basic>closed</impp:basic>"
      "</impp:status><impp:contact priority=\"1.5\">sip:x@y</impp:contact>"
      "</impp:tuple></impp:presence>">>.

foreign_pidf2() ->
    <<"<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
      "<presence xmlns=\"urn:ietf:params:xml:ns:pidf\" entity=\"sip:a@b\">"
      "<tuple id=\"n\"><status><basic>open</basic></status>"
      "<note>caf", 16#c3, 16#a9, "</note></tuple></presence>">>.

%% a SUBSCRIBE from the peer, to chappe
subscribe(Sock, Uri, Event, Extra) ->
    request(<<"SUBSCRIBE">>, Uri, #{
        port => port(Sock),
        headers => [{<<"Event">>, Event} | Extra]}).

%% subscribe the peer to Uri's presence; the 200 and the first NOTIFY
watch(Sock, EP, Uri, _Opts) ->
    S = subscribe(Sock, Uri, <<"presence">>, []),
    send(Sock, EP, S),
    {200, N} = ok_and_notify(Sock),
    {S, N}.

%% the final response to our SUBSCRIBE and the NOTIFY that follows, in
%% whichever order they come (the NOTIFY answered 200)
ok_and_notify(Sock) ->
    ok_and_notify(Sock, undefined, undefined).

ok_and_notify(_Sock, Status, N) when Status =/= undefined, N =/= undefined ->
    {Status, N};
ok_and_notify(Sock, Status, N) ->
    receive
        {udp, Sock, _, Src, <<"NOTIFY ", _/binary>> = B} ->
            send(Sock, Src, response(B, 200, #{})),
            ok_and_notify(Sock, Status, B);
        {udp, Sock, _, _, <<"SIP/2.0 ", C:3/binary, _/binary>> = B} ->
            case {binary_to_integer(C), cseq(B)} of
                {St, {_, <<"SUBSCRIBE">>}} when St >= 200 ->
                    ok_and_notify(Sock, St, N);
                _ ->
                    ok_and_notify(Sock, Status, N)
            end;
        {udp, Sock, _, _, _} ->
            ok_and_notify(Sock, Status, N)
    after 5000 -> ct:fail({no_subscription, Status, N})
    end.

%% the next NOTIFY to the peer, answered 200
recv_notify(Sock, EP) ->
    {N, Src} = recv(Sock, {method, <<"NOTIFY">>}, 5000),
    send(Sock, Src, response(N, 200, #{})),
    _ = EP,
    {N, Src}.

%% a NOTIFY from the peer in the dialog of SUBSCRIBE Sub
notify(Sock, Sub, Tag, Body, CT) ->
    {ok, #{uri := Contact}} = chappe_sip_hdr:name_addr(hdr(<<"contact">>, Sub)),
    request(<<"NOTIFY">>, Contact, #{
        port => port(Sock), call_id => hdr(<<"call-id">>, Sub),
        from => addr(hdr(<<"to">>, Sub)), from_tag => Tag,
        to => addr(hdr(<<"from">>, Sub)), to_tag => from_tag(Sub),
        cseq => 1, contact => <<"<", (esc_uri(Sock))/binary, ">">>,
        headers => [{<<"Event">>, hdr(<<"event">>, Sub)},
                    {<<"Subscription-State">>, <<"active;expires=600">>}],
        body => Body, content_type => CT}).

ok_pub(Req, ETag, Expires, Extra) ->
    response(Req, 200, #{to_tag => tag(), headers =>
                         [{<<"SIP-ETag">>, ETag},
                          {<<"Expires">>, integer_to_binary(Expires)}] ++ Extra}).

pub_event(Pub) ->
    receive {chappe_sip_publication, Pub, E} -> E
    after 6000 -> ct:fail({no_publication_event, Pub})
    end.

sub_event(Sub) ->
    receive {chappe_sip_subscription, Sub, E} -> E
    after 6000 -> ct:fail({no_subscription_event, Sub})
    end.

addr(V) -> re:replace(V, ";tag=[^;]*", "", [{return, binary}]).

is_publish(<<"PUBLISH ", _/binary>>) -> true;
is_publish(_) -> false.

tokens(undefined) -> [];
tokens(V) -> [string:trim(T) || T <- binary:split(V, <<",">>, [global])].

now_ms() -> erlang:monotonic_time(millisecond).
