%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The demo gate's conference, events, privacy and Replaces duties, over
%% real SIP on loopback. The conference is chappe_sip_test_focus (built on
%% chappe_sip_focus); participants and watchers are
%% chappe_sip_test_conf_ua processes. Every conference-info body is
%% validated against the RFC 4575 schema before it is read.
-module(chappe_sip_gate2_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("xmerl/include/xmerl.hrl").
-include_lib("chappe_sip/include/chappe_sip.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    factory_creates_conference/1,
    document_names_the_conference/1,
    child_state_follows_parent/1,
    keys_unique_among_siblings/1,
    conf_uris_unique/1,
    media_types_and_labels/1,
    dial_out_progress/1,
    hold_and_leave/1,
    disconnection_methods/1,
    call_info_needs_policy/1,
    anonymous_uris_unique/1,
    notify_expires_never_lengthens/1,
    no_notify_without_subscribe/1,
    answered_without_waiting/1,
    replacement_needs_authorization/1,
    anonymous_from_keeps_a_tag/1,
    privacy_none_relayed/1
]).

-define(UA, chappe_sip_test_conf_ua).
-define(FOCUS, chappe_sip_test_focus).
-define(CI, <<"application/conference-info+xml">>).
%% cases that run without a conference
-define(NO_CONF, [
    factory_creates_conference,
    answered_without_waiting,
    replacement_needs_authorization,
    anonymous_from_keeps_a_tag,
    privacy_none_relayed
]).

all() ->
    [
        factory_creates_conference,
        document_names_the_conference,
        child_state_follows_parent,
        keys_unique_among_siblings,
        conf_uris_unique,
        media_types_and_labels,
        dial_out_progress,
        hold_and_leave,
        disconnection_methods,
        call_info_needs_policy,
        anonymous_uris_unique,
        notify_expires_never_lengthens,
        no_notify_without_subscribe,
        answered_without_waiting,
        replacement_needs_authorization,
        anonymous_from_keeps_a_tag,
        privacy_none_relayed
    ].

init_per_suite(Config) ->
    application:set_env(
        chappe_sip, engine_mod, chappe_sip_nif, [{persistent, true}]
    ),
    {ok, _} = application:ensure_all_started(chappe_sip),
    EP = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:", (port(EP))/binary>>}),
    [{ep, EP} | Config].

end_per_suite(_Config) ->
    _ = chappe_sip:stop(),
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(Case, Config) ->
    EP = ?config(ep, Config),
    ok = ?FOCUS:install(),
    UAs = [{K, ?UA:start(atom_to_binary(K), EP)} || K <- [host, watcher, p1, p2, p3]],
    C = UAs ++ Config,
    case lists:member(Case, ?NO_CONF) of
        true -> C;
        false -> start_conference(#{}, C)
    end.

end_per_testcase(_Case, Config) ->
    _ = ?FOCUS:stop(),
    [?UA:stop(?config(K, Config)) || K <- [host, watcher, p1, p2, p3]],
    application:unset_env(chappe_sip, handler_deadline_ms),
    application:unset_env(chappe_sip, non_invite_deadline_ms),
    ok.

%% a conference hosted by `host', NOTIFYs at most every 300 ms
start_conference(Opts, Config) ->
    Uri = <<"sip:conf-", (hex(4))/binary, "@127.0.0.1:", (port(?config(ep, Config)))/binary>>,
    {ok, _} = ?FOCUS:start(Uri, Opts#{min_interval => 300}),
    {ok, Call, Resp} = ?UA:invite(?config(host, Config), Uri, []),
    [{conf_uri, Uri}, {host_call, Call}, {host_2xx, Resp} | Config].

%% ---- conference creation (RFC 4579) ----

%% RFC 4579 5.4: an INVITE to the conference factory URI creates a
%% conference; the 200's Contact is the new conference URI, with isfocus.
%% req: R4579-11
factory_creates_conference(Config) ->
    Factory = <<"sip:factory@127.0.0.1:", (port(?config(ep, Config)))/binary>>,
    {ok, _, R} = ?UA:invite(?config(host, Config), Factory, []),
    ConfUri = ?FOCUS:uri(),
    ?assertNotEqual(Factory, ConfUri),
    ?assertEqual(ConfUri, contact_uri(R)),
    ?assertMatch(
        {ok, [#{params := #{<<"isfocus">> := _}} | _]},
        chappe_sip_msg:parsed(<<"contact">>, R)
    ).

%% ---- the document (RFC 4575) ----

%% RFC 4575 3.1: the package is `conference', in Event and Allow-Events;
%% 5.2: the root's entity is the conference URI.
%% req: R4575-01 R4575-69
document_names_the_conference(Config) ->
    W = ?config(watcher, Config),
    Uri = ?config(conf_uri, Config),
    ?assert(lists:member(<<"conference">>, tokens(hdr(?config(host_2xx, Config), 'allow-events')))),
    {ok, Sub, R200} = ?UA:subscribe(W, Uri, <<"conference">>, []),
    ?assertEqual(200, chappe_sip_msg:status(R200)),
    ?assert(lists:member(<<"conference">>, tokens(hdr(R200, 'allow-events')))),
    {ok, _, _} = ?UA:invite(?config(p1, Config), Uri, []),
    [N1, N2] = wait_notifies(W, Sub, 2),
    [
        begin
            ?assertEqual(<<"conference">>, hdr(N, event)),
            ?assertEqual(binary_to_list(Uri), attr(doc(N), entity))
        end
     || N <- [N1, N2]
    ].

%% RFC 4575 4.4: a child's state is consistent with its parent's; under a
%% "full" parent every child is "full".
%% req: R4575-20 R4575-21
child_state_follows_parent(Config) ->
    [W, P1, P2] = [?config(K, Config) || K <- [watcher, p1, p2]],
    Uri = ?config(conf_uri, Config),
    {ok, Sub, _} = ?UA:subscribe(W, Uri, <<"conference">>, []),
    wait_notifies(W, Sub, 1),
    {ok, C1, _} = ?UA:invite(P1, Uri, []),
    {ok, C2, _} = ?UA:invite(P2, Uri, [{<<"Privacy">>, <<"id">>}]),
    wait_status(W, Sub, ua_uri(P1), "connected"),
    wait_status(W, Sub, <<"anonymous">>, "connected"),
    {ok, 200} = ?UA:hold(P1, {C1, <<"sendonly">>}),
    wait_status(W, Sub, ua_uri(P1), "on-hold"),
    {ok, 200} = ?UA:bye(P2, C2),
    wait_status(W, Sub, <<"anonymous">>, "disconnected"),
    {ok, 200} = ?UA:refresh(W, Sub, 600),
    Docs = docs(W, Sub),
    States = lists:usort([attr(D, state) || D <- Docs]),
    ct:log("~p documents, root states ~p", [length(Docs), States]),
    ?assertEqual(["full", "partial"], States),
    [check_states(D, "partial") || D <- Docs].

%% the root's parent counts as "partial": it may be either
check_states(#xmlElement{content = Cs} = El, Parent) ->
    State = attr(El, state, "full"),
    Parent =:= "full" andalso ?assertEqual("full", State, {El#xmlElement.name}),
    [check_states(C, State) || #xmlElement{} = C <- Cs],
    ok.

%% RFC 4575 4.5 and 5.7: keys are unique among siblings; the same user
%% joining twice is one user with two endpoints of distinct entities.
%% req: R4575-23 R4575-41
keys_unique_among_siblings(Config) ->
    [W, P1] = [?config(K, Config) || K <- [watcher, p1]],
    Uri = ?config(conf_uri, Config),
    {ok, Sub, _} = ?UA:subscribe(W, Uri, <<"conference">>, []),
    wait_notifies(W, Sub, 1),
    {ok, _, _} = ?UA:invite(P1, Uri, []),
    {ok, _, _} = ?UA:invite(P1, Uri, []),
    %% a full document: p1 once, with both endpoints
    Full = wait_full(W, Sub, fun(D) -> length(endpoints_of(D, ua_uri(P1))) >= 2 end),
    [check_keys(D) || D <- docs(W, Sub)],
    P1Users = [U || U <- users(Full), attr(U, entity) =:= binary_to_list(ua_uri(P1))],
    ?assertMatch([_], P1Users),
    ?assertEqual(2, length(children(hd(P1Users), endpoint))).

check_keys(Doc) ->
    [
        begin
            Users = children(Us, user),
            unique([attr(U, entity) || U <- Users]),
            [
                begin
                    Eps = children(U, endpoint),
                    unique([attr(E, entity) || E <- Eps]),
                    [unique([attr(M, id) || M <- children(E, media)]) || E <- Eps]
                end
             || U <- Users
            ]
        end
     || Us <- children(Doc, users)
    ],
    ok.

unique(L) ->
    ?assertEqual(length(L), length(lists:usort(L)), {duplicate_key, L}).

%% RFC 4575 5.3.1: each conf-uris URI is unique.
%% req: R4575-32
conf_uris_unique(Config) ->
    W = ?config(watcher, Config),
    Uri = ?config(conf_uri, Config),
    Tel = <<"tel:+15555550100">>,
    ok = ?FOCUS:set_description(#{
        conf_uris => [#{uri => Uri}, #{uri => Tel}, #{uri => Uri, purpose => <<"again">>}]
    }),
    {ok, Sub, _} = ?UA:subscribe(W, Uri, <<"conference">>, []),
    [N] = wait_notifies(W, Sub, 1),
    [Desc] = children(doc(N), 'conference-description'),
    [ConfUris] = children(Desc, 'conf-uris'),
    Uris = [text(E, uri) || E <- children(ConfUris, entry)],
    ?assertEqual([binary_to_list(Uri), binary_to_list(Tel)], Uris).

%% RFC 4575 5.3.4, 5.8.2, 5.8.3: media types are SDP media tokens matching
%% the m= line, and an endpoint's media label is one of the conference's
%% available-media labels.
%% req: R4575-35 R4575-49 R4575-50
media_types_and_labels(Config) ->
    [W, P1] = [?config(K, Config) || K <- [watcher, p1]],
    Uri = ?config(conf_uri, Config),
    ok = ?FOCUS:set_description(#{
        available_media => [
            #{label => <<"main-audio">>, type => audio, status => sendrecv},
            #{label => <<"smell">>, type => smell}
        ]
    }),
    {ok, Sub, _} = ?UA:subscribe(W, Uri, <<"conference">>, []),
    {ok, _, _} = ?UA:invite(P1, Uri, []),
    Doc = wait_full(W, Sub, fun(D) -> endpoints_of(D, ua_uri(P1)) =/= [] end),
    [Desc] = children(Doc, 'conference-description'),
    [Avail] = children(Desc, 'available-media'),
    Entries = children(Avail, entry),
    ?assertEqual(["main-audio"], [attr(E, label) || E <- Entries]),
    ?assertEqual(["audio"], [text(E, type) || E <- Entries]),
    Labels = [attr(E, label) || E <- Entries],
    [Ep] = endpoints_of(Doc, ua_uri(P1)),
    [M] = children(Ep, media),
    %% the UA offered m=audio
    ?assertEqual("audio", text(M, type)),
    ?assert(lists:member(text(M, label), Labels)).

%% RFC 4575 5.7.2 to 5.7.4: a participant REFERs the focus to someone; the
%% focus calls it, and the endpoint shows dialing-out, alerting, then
%% connected, dialed-out, referred by the REFER's Referred-By. The host
%% dialed in.
%% req: R4575-43 R4575-46 R4575-62
dial_out_progress(Config) ->
    [Host, W, P2] = [?config(K, Config) || K <- [host, watcher, p2]],
    Uri = ?config(conf_uri, Config),
    ok = ?UA:set_answer(P2, {200, 700, 1500}),
    {ok, Sub, _} = ?UA:subscribe(W, Uri, <<"conference">>, []),
    wait_notifies(W, Sub, 1),
    P2Uri = ua_uri(P2),
    HostUri = ua_uri(Host),
    {ok, 200} = ?UA:refer(Host, ?config(host_call, Config), <<"<", P2Uri/binary, ">">>, [
        {<<"Referred-By">>, <<"<", HostUri/binary, ">">>}
    ]),
    wait_status(W, Sub, P2Uri, "connected"),
    Seen = ep_values(docs(W, Sub), P2Uri, status),
    ct:log("p2 status ~p", [Seen]),
    ?assertEqual(["dialing-out", "alerting", "connected"], Seen),
    ?assertEqual(["dialed-out"], ep_values(docs(W, Sub), P2Uri, 'joining-method')),
    ?assertEqual(["dialed-in"], ep_values(docs(W, Sub), HostUri, 'joining-method')),
    By = [
        text(R, by)
     || D <- docs(W, Sub), Ep <- endpoints_of(D, P2Uri), R <- children(Ep, referred)
    ],
    ?assertNotEqual([], By),
    ?assertEqual([binary_to_list(HostUri)], lists:usort(By)),
    %% the focus's INVITE says it is a focus (RFC 4579 5.2)
    [{_, Inv, _}] = [R || {<<"INVITE">>, _, _} = R <- ?UA:requests(P2)],
    ?assertNotEqual(nomatch, binary:match(hdr(Inv, contact), <<"isfocus">>)).

%% RFC 4575 5.7.3, 5.7.6: holding shows on-hold, resuming connected, and
%% the participant's BYE disconnected with disconnection-method departed.
%% req: R4575-43 R4575-47
hold_and_leave(Config) ->
    [W, P1] = [?config(K, Config) || K <- [watcher, p1]],
    Uri = ?config(conf_uri, Config),
    {ok, Sub, _} = ?UA:subscribe(W, Uri, <<"conference">>, []),
    {ok, C1, _} = ?UA:invite(P1, Uri, []),
    P1Uri = ua_uri(P1),
    wait_status(W, Sub, P1Uri, "connected"),
    {ok, 200} = ?UA:hold(P1, {C1, <<"sendonly">>}),
    wait_status(W, Sub, P1Uri, "on-hold"),
    {ok, 200} = ?UA:hold(P1, {C1, <<"sendrecv">>}),
    wait_status(W, Sub, P1Uri, "connected"),
    {ok, 200} = ?UA:bye(P1, C1),
    wait_status(W, Sub, P1Uri, "disconnected"),
    ?assertEqual(
        ["connected", "on-hold", "connected", "disconnected"],
        ep_values(docs(W, Sub), P1Uri, status)
    ),
    ?assertEqual(["departed"], ep_values(docs(W, Sub), P1Uri, 'disconnection-method')).

%% RFC 4575 5.7.6: the focus's BYE is booted, a 486 to its INVITE busy,
%% any other failure failed.
%% req: R4575-47
disconnection_methods(Config) ->
    [Host, W, P1, P2, P3] = [?config(K, Config) || K <- [host, watcher, p1, p2, p3]],
    Uri = ?config(conf_uri, Config),
    {ok, Sub, _} = ?UA:subscribe(W, Uri, <<"conference">>, []),
    {ok, _, _} = ?UA:invite(P1, Uri, []),
    P1Uri = ua_uri(P1),
    wait_status(W, Sub, P1Uri, "connected"),
    1 = ?FOCUS:kick(P1Uri),
    wait_status(W, Sub, P1Uri, "disconnected"),
    ok = ?UA:set_answer(P2, {486, none, 200}),
    ok = ?UA:set_answer(P3, {503, none, 200}),
    Call = ?config(host_call, Config),
    [
        {ok, 200} = ?UA:refer(Host, Call, <<"<", (ua_uri(P))/binary, ">">>, [])
     || P <- [P2, P3]
    ],
    wait_status(W, Sub, ua_uri(P2), "disconnected"),
    wait_status(W, Sub, ua_uri(P3), "disconnected"),
    Docs = docs(W, Sub),
    ?assertEqual(["booted"], ep_values(Docs, P1Uri, 'disconnection-method')),
    ?assertEqual(["busy"], ep_values(Docs, ua_uri(P2), 'disconnection-method')),
    ?assertEqual(["failed"], ep_values(Docs, ua_uri(P3), 'disconnection-method')).

%% RFC 4575 5.7.9: the dialog identifiers are shown only when the focus's
%% policy allows it (it does not by default).
%% req: R4575-48
call_info_needs_policy(Config) ->
    [W, P1] = [?config(K, Config) || K <- [watcher, p1]],
    Uri = ?config(conf_uri, Config),
    {ok, Sub, _} = ?UA:subscribe(W, Uri, <<"conference">>, []),
    {ok, _, _} = ?UA:invite(P1, Uri, []),
    wait_status(W, Sub, ua_uri(P1), "connected"),
    [?assertEqual(nomatch, binary:match(chappe_sip_msg:body(N), <<"<call-info">>)) || N <- notifies(W, Sub)],
    %% a focus whose policy shows them
    ok = ?FOCUS:stop(),
    C2 = start_conference(#{call_info => true}, Config),
    Uri2 = ?config(conf_uri, C2),
    {ok, Sub2, _} = ?UA:subscribe(W, Uri2, <<"conference">>, []),
    [N2 | _] = wait_notifies(W, Sub2, 1),
    ?assertNotEqual(nomatch, binary:match(chappe_sip_msg:body(N2), <<"<call-info">>)).

%% RFC 4575 5.6, 8.2: two anonymous participants get distinct URIs in the
%% .invalid domain.
%% req: R4575-39 R4575-60
anonymous_uris_unique(Config) ->
    [W, P1, P2] = [?config(K, Config) || K <- [watcher, p1, p2]],
    Uri = ?config(conf_uri, Config),
    {ok, Sub, _} = ?UA:subscribe(W, Uri, <<"conference">>, []),
    [{ok, _, _} = ?UA:invite(P, Uri, [{<<"Privacy">>, <<"id">>}]) || P <- [P1, P2]],
    Doc = wait_full(W, Sub, fun(D) -> length(anonymous(D)) >= 2 end),
    Anon = anonymous(Doc),
    unique(Anon),
    [
        ?assertMatch({ok, #{host := <<"anonymous.invalid">>}}, chappe_sip_uri:parse(list_to_binary(A)))
     || A <- Anon
    ].

anonymous(Doc) ->
    [E || U <- users(Doc), E <- [attr(U, entity)], string:find(E, ".invalid") =/= nomatch].

%% ---- subscriptions (RFC 6665) ----

%% RFC 6665 4.2.2: the expires a NOTIFY states never exceeds what the 200
%% granted, a refresh to less and a fetch (Expires: 0) included.
%% req: R6665-24
notify_expires_never_lengthens(Config) ->
    W = ?config(watcher, Config),
    Uri = ?config(conf_uri, Config),
    {ok, Sub, R200} = ?UA:subscribe(W, Uri, <<"conference">>, [{<<"Expires">>, <<"60">>}]),
    Granted = binary_to_integer(hdr(R200, expires)),
    ?assert(Granted =< 60),
    [N1] = wait_notifies(W, Sub, 1),
    ?assert(notify_expires(N1) =< Granted),
    {ok, 200} = ?UA:refresh(W, Sub, 20),
    [_, N2] = wait_notifies(W, Sub, 2),
    ?assert(notify_expires(N2) =< 20),
    %% a fetch: whatever comes is terminated or states 0
    {ok, Fetch, F200} = ?UA:subscribe(W, Uri, <<"conference">>, [{<<"Expires">>, <<"0">>}]),
    ?assertEqual(<<"0">>, hdr(F200, expires)),
    [F1 | _] = wait_notifies(W, Fetch, 1),
    ?assert(notify_expires(F1) =< 0).

%% RFC 6665 4.2.1: no NOTIFY without a SUBSCRIBE; the only implicit
%% subscription is REFER's.
%% req: R6665-05
no_notify_without_subscribe(Config) ->
    P1 = ?config(p1, Config),
    Uri = ?config(conf_uri, Config),
    {ok, Call, R} = ?UA:invite(P1, Uri, []),
    {ok, D} = chappe_sip:find_dialog(
        Call, chappe_sip_msg:to_tag(R), chappe_sip_msg:from_tag(R)
    ),
    ?assertMatch(
        {error, _},
        chappe_sip_dialog:notify(D, #{event => <<"conference">>, state => active})
    ),
    %% the conference changes; p1 never subscribed
    {ok, _, _} = ?UA:invite(?config(p2, Config), Uri, []),
    timer:sleep(1500),
    ?assertEqual([], [M || {<<"NOTIFY">>, M, _} <- ?UA:requests(P1)]).

%% RFC 6665 4.2.1.1, RFC 3515 6: a SUBSCRIBE or REFER gets its final
%% response within the non-INVITE transaction's lifetime, even when the
%% handler waits on a user. The focus answers at once.
%% req: R6665-06 R3515-27
answered_without_waiting(Config) ->
    EP = ?config(ep, Config),
    W = ?config(watcher, Config),
    application:set_env(chappe_sip, handler_deadline_ms, 60000),
    application:set_env(chappe_sip, non_invite_deadline_ms, 1500),
    Waits = fun(_Req, _Res) -> receive never -> ok end end,
    ok = chappe_sip:subscribe(Waits),
    ok = chappe_sip:refer(Waits),
    Target = <<"sip:user@127.0.0.1:", (port(EP))/binary>>,
    T0 = now_ms(),
    {error, St, _} = ?UA:subscribe(W, Target, <<"presence">>, []),
    T1 = now_ms(),
    ct:log("SUBSCRIBE ~p after ~p ms", [St, T1 - T0]),
    ?assert(T1 - T0 < 5000),
    {St2, T2} = ood_refer(Target),
    ct:log("REFER ~p after ~p ms", [St2, T2]),
    ?assert(St2 >= 200),
    ?assert(T2 < 5000),
    %% the focus's own subscribe path
    ok = ?FOCUS:install(),
    C = start_conference(#{}, Config),
    T3 = now_ms(),
    {ok, _, R200} = ?UA:subscribe(W, ?config(conf_uri, C), <<"conference">>, []),
    ?assertEqual(200, chappe_sip_msg:status(R200)),
    ?assert(now_ms() - T3 < 2000).

%% a REFER outside any dialog, from a bare socket: {Status, Ms}
ood_refer(Target) ->
    T0 = now_ms(),
    Peer = chappe_sip_core_peer:open(),
    P = chappe_sip_core_peer:port(Peer),
    Req = chappe_sip_core_peer:request(<<"REFER">>, Target, #{
        port => P,
        headers => [{<<"Refer-To">>, <<"<sip:carol@127.0.0.1>">>}]
    }),
    ok = chappe_sip_core_peer:send(Peer, port_of(Target), Req),
    {Bin, _} = chappe_sip_core_peer:recv(Peer, final, 10000),
    chappe_sip_core_peer:close(Peer),
    {chappe_sip_core_peer:status(Bin), now_ms() - T0}.

%% ---- Replaces (RFC 3891) ----

%% RFC 3891 3: a Replaces matching an active dialog is honoured only when
%% the initiator is authorized; refused, the new INVITE gets 403 and the
%% matched dialog carries on.
%% req: R3891-07
replacement_needs_authorization(Config) ->
    EP = ?config(ep, Config),
    [P1, P2] = [?config(K, Config) || K <- [p1, p2]],
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Allow = persistent_term:get({?MODULE, allow}, false),
        Auth = fun(_Dialog, _Req) -> Allow end,
        case chappe_sip:replaces_response(Req, #{authorize => Auth}) of
            no_replaces ->
                {ok, D} = chappe_sip:create_uas(Req, Res, #{}),
                Test ! {dialog, D},
                chappe_sip_dialog:wait(D);
            {reject, St} ->
                chappe_sip_res:send(Res, St);
            {accept, Old, _Info} ->
                {ok, D} = chappe_sip:create_uas(Req, Res, #{}),
                ok = chappe_sip_dialog:destroy(Old),
                chappe_sip_dialog:wait(D)
        end
    end),
    Uri = <<"sip:app@127.0.0.1:", (port(EP))/binary>>,
    {ok, Call, R} = ?UA:invite(P1, Uri, []),
    Old = receive {dialog, D} -> D after 5000 -> ct:fail(no_dialog) end,
    Replaces = iolist_to_binary([
        Call, <<";to-tag=">>, chappe_sip_msg:to_tag(R),
        <<";from-tag=">>, chappe_sip_msg:from_tag(R)
    ]),
    {error, 403, _} = ?UA:invite(P2, Uri, [{<<"Replaces">>, Replaces}]),
    ?assertEqual({ok, Old}, chappe_sip:find_dialog(Call, chappe_sip_msg:to_tag(R), chappe_sip_msg:from_tag(R))),
    timer:sleep(500),
    ?assertEqual([], [M || {<<"BYE">>, M, _} <- ?UA:requests(P1)]),
    %% authorized, it replaces
    persistent_term:put({?MODULE, allow}, true),
    try
        {ok, _, _} = ?UA:invite(P2, Uri, [{<<"Replaces">>, Replaces}]),
        ok = wait_until(fun() -> [M || {<<"BYE">>, M, _} <- ?UA:requests(P1)] =/= [] end, 5000)
    after
        persistent_term:erase({?MODULE, allow})
    end.

%% ---- privacy (RFC 3323) ----

%% RFC 3323 4.1.1.3: an anonymous From still carries a unique tag.
%% req: R3323-03
anonymous_from_keeps_a_tag(Config) ->
    P1 = ?config(p1, Config),
    ok = ?UA:set_answer(P1, {486, none, 0}),
    Anon = <<"\"Anonymous\" <sip:anonymous@anonymous.invalid>">>,
    [
        {error, #chappe_sip_error{status = 486}} =
            chappe_sip:create_uac(ua_uri(P1), #{from => Anon})
     || _ <- [1, 2]
    ],
    Froms = [hdr(M, from) || {<<"INVITE">>, M, _} <- ?UA:requests(P1)],
    ?assertEqual(2, length(Froms)),
    Tags = [
        begin
            {ok, #{uri := U, params := #{<<"tag">> := T}}} = chappe_sip_hdr:name_addr(F),
            ?assertEqual(<<"sip:anonymous@anonymous.invalid">>, U),
            ?assertNotEqual(<<>>, T),
            T
        end
     || F <- Froms
    ],
    unique(Tags).

%% RFC 3323 4.2, 5: Privacy: none reaches the other leg of the b2bua
%% untouched, with the identity it came with when headers are relayed.
%% req: R3323-05 R3323-10
privacy_none_relayed(Config) ->
    EP = ?config(ep, Config),
    [P1, P2] = [?config(K, Config) || K <- [p1, p2]],
    B = ua_uri(P2),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Opts = persistent_term:get({?MODULE, b2b}, #{}),
        case chappe_sip:create_b2bua(Req, Res, B, Opts) of
            {ok, Legs} -> chappe_sip_b2b:relay(Legs);
            _ -> ok
        end
    end),
    Uri = <<"sip:app@127.0.0.1:", (port(EP))/binary>>,
    PAI = <<"<sip:+15555550123@carrier.example.net>">>,
    Hdrs = [{<<"Privacy">>, <<"none">>}, {<<"P-Asserted-Identity">>, PAI}],
    {ok, C1, _} = ?UA:invite(P1, Uri, Hdrs),
    [{_, I1, _}] = [X || {<<"INVITE">>, _, _} = X <- ?UA:requests(P2)],
    ?assertEqual([<<"none">>], chappe_sip_msg:get_all(<<"privacy">>, I1)),
    {ok, 200} = ?UA:bye(P1, C1),
    %% relaying headers: both as they came
    persistent_term:put({?MODULE, b2b}, #{proxy_request_headers => all}),
    try
        {ok, C2, _} = ?UA:invite(P1, Uri, Hdrs),
        [_, {_, I2, _}] = [X || {<<"INVITE">>, _, _} = X <- ?UA:requests(P2)],
        ?assertEqual([<<"none">>], chappe_sip_msg:get_all(<<"privacy">>, I2)),
        ?assertEqual([PAI], chappe_sip_msg:get_all(<<"p-asserted-identity">>, I2)),
        {ok, 200} = ?UA:bye(P1, C2)
    after
        persistent_term:erase({?MODULE, b2b})
    end.

%% ---- helpers: NOTIFYs and documents ----

notifies(UA, Sub) ->
    [M || {<<"NOTIFY">>, M, _} <- ?UA:requests(UA), chappe_sip_msg:call_id(M) =:= Sub].

wait_notifies(UA, Sub, N) ->
    ok = wait_until(fun() -> length(notifies(UA, Sub)) >= N end, 15000),
    lists:sublist(notifies(UA, Sub), N).

%% the root element of a NOTIFY's conference-info, validated
doc(N) ->
    chappe_sip_test_confinfo:validate(chappe_sip_msg:body(N)).

%% a terminated NOTIFY may come without a body
docs(UA, Sub) ->
    [doc(N) || N <- notifies(UA, Sub), chappe_sip_msg:body(N) =/= <<>>].

%% refresh until the full document it brings satisfies F
wait_full(UA, Sub, F) ->
    wait_full(UA, Sub, F, 30).

wait_full(_UA, _Sub, _F, 0) ->
    ct:fail(no_full_document);
wait_full(UA, Sub, F, Tries) ->
    N0 = length(notifies(UA, Sub)),
    {ok, 200} = ?UA:refresh(UA, Sub, 600),
    D = doc(lists:last(wait_notifies(UA, Sub, N0 + 1))),
    ?assertEqual("full", attr(D, state)),
    case F(D) of
        true ->
            D;
        false ->
            timer:sleep(200),
            wait_full(UA, Sub, F, Tries - 1)
    end.

%% the endpoint of the user Uri (or one whose URI contains it) reaches Status
wait_status(UA, Sub, Uri, Status) ->
    ok = wait_until(
        fun() -> lists:member(Status, ep_values(docs(UA, Sub), Uri, status)) andalso
                 lists:last(ep_values(docs(UA, Sub), Uri, status)) =:= Status
        end,
        15000
    ).

%% every value a child element of Uri's endpoints takes, in document
%% order, repeats folded
ep_values(Docs, Uri, Field) ->
    Vs = [text(Ep, Field) || D <- Docs, Ep <- endpoints_of(D, Uri), children(Ep, Field) =/= []],
    fold_repeats(Vs).

fold_repeats([A, A | T]) -> fold_repeats([A | T]);
fold_repeats([A | T]) -> [A | fold_repeats(T)];
fold_repeats([]) -> [].

%% Uri is a user entity, or a part of one when it has no scheme
endpoints_of(Doc, Uri) ->
    U = binary_to_list(Uri),
    Match =
        case string:find(U, ":") of
            nomatch -> fun(E) -> string:find(E, U) =/= nomatch end;
            _ -> fun(E) -> E =:= U end
        end,
    [E || Us <- users(Doc), Match(attr(Us, entity)), E <- children(Us, endpoint)].

users(Doc) ->
    [U || Us <- children(Doc, users), U <- children(Us, user)].

children(#xmlElement{content = Cs}, Name) ->
    [C || #xmlElement{name = N} = C <- Cs, N =:= Name].

text(El, Name) ->
    [C] = children(El, Name),
    lists:flatten([V || #xmlText{value = V} <- C#xmlElement.content]).

attr(El, Name) -> attr(El, Name, undefined).

attr(#xmlElement{attributes = As}, Name, Default) ->
    case [V || #xmlAttribute{name = N, value = V} <- As, N =:= Name] of
        [V] -> V;
        [] -> Default
    end.

notify_expires(N) ->
    case hdr(N, 'subscription-state') of
        <<"terminated", _/binary>> ->
            0;
        V ->
            {match, [E]} = re:run(V, "expires=(\\d+)", [{capture, all_but_first, binary}]),
            binary_to_integer(E)
    end.

%% ---- helpers: misc ----

wait_until(F, Timeout) when Timeout =< 0 ->
    case F() of
        true -> ok;
        false -> ct:fail(timeout)
    end;
wait_until(F, Timeout) ->
    case F() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(F, Timeout - 50)
    end.

hdr(M, Name) -> chappe_sip_msg:get(atom_to_binary(Name), M).

contact_uri(M) ->
    {ok, #{uri := U}} = chappe_sip_hdr:name_addr(hdr(M, contact)),
    U.

tokens(undefined) ->
    [];
tokens(V) ->
    [string:lowercase(string:trim(T)) || T <- binary:split(V, <<",">>, [global])].

ua_uri(UA) -> ?UA:uri(UA).
port(P) -> integer_to_binary(P).
port_of(Uri) ->
    [_, P] = binary:split(Uri, <<"127.0.0.1:">>),
    binary_to_integer(P).
hex(N) -> binary:encode_hex(crypto:strong_rand_bytes(N), lowercase).
now_ms() -> erlang:monotonic_time(millisecond).
