%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The subscriber side of SIP events (RFC 6665) and the routing of
%% SUBSCRIBEs by event package.
%%
%% chappe subscribes (chappe_sip:subscribe_to/3) to a raw UDP peer that
%% plays the notifier: it answers the SUBSCRIBEs and sends the NOTIFYs a
%% case needs, in the order the case needs, and checks what chappe puts on
%% the wire. The test process owns the subscription.
-module(chappe_sip_subscriber_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-import(chappe_sip_core_peer, [
    open/0,
    port/1,
    send/3,
    recv/3,
    recv_none/3,
    request/3,
    response/3,
    hdr/2,
    hdrs/2,
    status/1,
    from_tag/1,
    to_tag/1,
    cseq/1,
    tag/0
]).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    subscribe_refresh_unsubscribe/1,
    notify_before_2xx/1,
    notify_expires_authoritative/1,
    pending_expires/1,
    terminated_ends/1,
    terminated_expires_ignored/1,
    deactivated_resubscribes/1,
    timeout_resubscribes/1,
    probation_waits/1,
    giveup_waits/1,
    unknown_reason_waits/1,
    invariant_stops/1,
    refresh_481_ends/1,
    timer_n_then_481/1,
    forked_notify/1,
    unmatched_notify_481/1,
    subscribe_rejected/1,
    package_routes/1,
    package_489/1
]).

all() ->
    [
        subscribe_refresh_unsubscribe,
        notify_before_2xx,
        notify_expires_authoritative,
        pending_expires,
        terminated_ends,
        terminated_expires_ignored,
        deactivated_resubscribes,
        timeout_resubscribes,
        probation_waits,
        giveup_waits,
        unknown_reason_waits,
        invariant_stops,
        refresh_481_ends,
        timer_n_then_481,
        forked_notify,
        unmatched_notify_481,
        subscribe_rejected,
        package_routes,
        package_489
    ].

init_per_suite(Config) ->
    application:set_env(
        chappe_sip,
        engine_mod,
        chappe_sip_nif,
        [{persistent, true}]
    ),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(_Case, Config) ->
    EP = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => chappe_sip_core_peer:contact(EP)}),
    [{ep, EP}, {sock, open()} | Config].

end_per_testcase(_Case, Config) ->
    chappe_sip_core_peer:close(?config(sock, Config)),
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% The SUBSCRIBE carries one Event and an Expires; the NOTIFY gets 200 and
%% reaches the owner; the subscription is refreshed in its dialog before
%% it expires, and unsubscribed with Expires: 0, the final NOTIFY ending it.
%% req: R6665-35 R6665-36 R6665-53 R6665-34
subscribe_refresh_unsubscribe(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Sub} = chappe_sip:subscribe_to(
        notifier(Sock),
        <<"presence">>,
        #{expires => 2}
    ),
    {S1, _} = recv(Sock, {method, <<"SUBSCRIBE">>}, 3000),
    ?assertEqual([<<"presence">>], hdrs(<<"event">>, S1)),
    ?assertEqual(<<"2">>, hdr(<<"expires">>, S1)),
    ?assertEqual(undefined, to_tag(S1)),
    send(Sock, EP, ok_2xx(Sock, S1, <<"n1">>, 2)),
    send(
        Sock,
        EP,
        notify(
            Sock,
            S1,
            <<"n1">>,
            1,
            <<"active;expires=2">>,
            <<"doc">>
        )
    ),
    {N200, _} = recv(Sock, {status, 200, <<"NOTIFY">>}, 3000),
    ?assertEqual(undefined, hdr(<<"event">>, N200)),
    {notify, #{state := active, expires := 2, body := <<"doc">>}} =
        sub_event(Sub),
    %% the refresh: in the dialog, the next CSeq, the same Event
    {S2, _} = recv(Sock, {method, <<"SUBSCRIBE">>}, 2500),
    ?assertEqual(<<"n1">>, to_tag(S2)),
    ?assertEqual(from_tag(S1), from_tag(S2)),
    ?assertEqual(hdr(<<"call-id">>, S1), hdr(<<"call-id">>, S2)),
    ?assertEqual({2, <<"SUBSCRIBE">>}, cseq(S2)),
    ?assertEqual([<<"presence">>], hdrs(<<"event">>, S2)),
    ?assertEqual(<<"2">>, hdr(<<"expires">>, S2)),
    send(Sock, EP, ok_2xx(Sock, S2, <<"n1">>, 60)),
    send(
        Sock,
        EP,
        notify(
            Sock,
            S1,
            <<"n1">>,
            2,
            <<"active;expires=60">>,
            <<"doc2">>
        )
    ),
    {_, _} = recv(Sock, {status, 200, <<"NOTIFY">>}, 3000),
    {notify, #{expires := 60}} = sub_event(Sub),
    ok = chappe_sip:unsubscribe(Sub),
    {S3, _} = recv(Sock, {method, <<"SUBSCRIBE">>}, 3000),
    ?assertEqual(<<"0">>, hdr(<<"expires">>, S3)),
    ?assertEqual([<<"presence">>], hdrs(<<"event">>, S3)),
    send(Sock, EP, ok_2xx(Sock, S3, <<"n1">>, 0)),
    send(
        Sock,
        EP,
        notify(
            Sock,
            S1,
            <<"n1">>,
            3,
            <<"terminated;reason=timeout">>,
            <<>>
        )
    ),
    {_, _} = recv(Sock, {status, 200, <<"NOTIFY">>}, 3000),
    {notify, #{state := terminated}} = sub_event(Sub),
    {terminated, unsubscribed} = sub_event(Sub),
    recv_none(Sock, {method, <<"SUBSCRIBE">>}, 1500).

%% A NOTIFY that beats the 200 to the SUBSCRIBE gets 200, forms the dialog
%% and reaches the owner (RFC 6665 4.1.2.4).
%% req: R6665-39
notify_before_2xx(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Sub} = chappe_sip:subscribe_to(notifier(Sock), <<"presence">>, #{}),
    {S1, _} = recv(Sock, {method, <<"SUBSCRIBE">>}, 3000),
    send(
        Sock,
        EP,
        notify(
            Sock,
            S1,
            <<"nb">>,
            1,
            <<"active;expires=600">>,
            <<"first">>
        )
    ),
    {_, _} = recv(Sock, {status, 200, <<"NOTIFY">>}, 3000),
    {notify, #{body := <<"first">>}} = sub_event(Sub),
    send(Sock, EP, ok_2xx(Sock, S1, <<"nb">>, 600)),
    send(
        Sock,
        EP,
        notify(
            Sock,
            S1,
            <<"nb">>,
            2,
            <<"active;expires=600">>,
            <<"second">>
        )
    ),
    {_, _} = recv(Sock, {status, 200, <<"NOTIFY">>}, 3000),
    {notify, #{body := <<"second">>}} = sub_event(Sub),
    stop(Sub).

%% A NOTIFY's expires shorter than the granted Expires is the duration:
%% the refresh comes before it.
%% req: R6665-41
notify_expires_authoritative(Config) ->
    expires_from_notify(Config, <<"active;expires=2">>).

%% req: R6665-42
pending_expires(Config) ->
    expires_from_notify(Config, <<"pending;expires=2">>).

expires_from_notify(Config, State) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Sub} = chappe_sip:subscribe_to(notifier(Sock), <<"presence">>, #{}),
    {S1, _} = recv(Sock, {method, <<"SUBSCRIBE">>}, 3000),
    send(Sock, EP, ok_2xx(Sock, S1, <<"ne">>, 3600)),
    send(Sock, EP, notify(Sock, S1, <<"ne">>, 1, State, <<>>)),
    {_, _} = recv(Sock, {status, 200, <<"NOTIFY">>}, 3000),
    {notify, #{expires := 2}} = sub_event(Sub),
    {S2, _} = recv(Sock, {method, <<"SUBSCRIBE">>}, 2500),
    ?assertEqual(<<"ne">>, to_tag(S2)),
    stop(Sub).

%% A terminated NOTIFY ends the subscription: noresource and rejected are
%% not retried.
%% req: R6665-43 R6665-51 R6665-49
terminated_ends(Config) ->
    [ends(Config, Reason) || Reason <- [<<"noresource">>, <<"rejected">>]].

%% An expires on terminated means nothing (RFC 6665 4.1.3).
%% req: R6665-44
terminated_expires_ignored(Config) ->
    ends(Config, <<"noresource;expires=600">>).

%% invariant is never retried, whatever its retry-after.
%% req: R6665-52
invariant_stops(Config) ->
    ends(Config, <<"invariant;retry-after=1">>).

ends(Config, Reason) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {Sub, S1} = active_sub(Sock, EP),
    send(
        Sock,
        EP,
        notify(
            Sock,
            S1,
            <<"na">>,
            2,
            <<"terminated;reason=", Reason/binary>>,
            <<>>
        )
    ),
    {_, _} = recv(Sock, {status, 200, <<"NOTIFY">>}, 3000),
    {notify, #{state := terminated}} = sub_event(Sub),
    {terminated, Why} = sub_event(Sub),
    [Name | _] = binary:split(Reason, <<";">>),
    ?assertEqual(Name, atom_to_binary(Why)),
    recv_none(Sock, {method, <<"SUBSCRIBE">>}, 2000).

%% deactivated: a new SUBSCRIBE at once, a new Call-ID and From tag.
%% req: R6665-46 R3842-11
deactivated_resubscribes(Config) ->
    resubscribes(Config, <<"deactivated">>, 0).

%% timeout may be retried at once.
timeout_resubscribes(Config) ->
    resubscribes(Config, <<"timeout">>, 0).

%% probation and giveup wait their retry-after.
%% req: R6665-47 R6665-48 R3842-10
probation_waits(Config) ->
    resubscribes(Config, <<"probation;retry-after=1">>, 1000).

%% req: R6665-50
giveup_waits(Config) ->
    resubscribes(Config, <<"giveup;retry-after=1">>, 1000).

%% An unknown reason with retry-after: not before it.
%% req: R6665-45
unknown_reason_waits(Config) ->
    resubscribes(Config, <<"moved;retry-after=1">>, 1000).

resubscribes(Config, Reason, MinWait) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {Sub, S1} = active_sub(Sock, EP),
    T0 = erlang:monotonic_time(millisecond),
    send(
        Sock,
        EP,
        notify(
            Sock,
            S1,
            <<"na">>,
            2,
            <<"terminated;reason=", Reason/binary>>,
            <<>>
        )
    ),
    {_, _} = recv(Sock, {status, 200, <<"NOTIFY">>}, 3000),
    {notify, #{state := terminated}} = sub_event(Sub),
    {retrying, _, _} = sub_event(Sub),
    {S2, _} = recv(Sock, {method, <<"SUBSCRIBE">>}, 3000),
    Waited = erlang:monotonic_time(millisecond) - T0,
    ?assert(Waited >= MinWait, {waited, Waited}),
    ?assert(MinWait > 0 orelse Waited < 1000, {waited, Waited}),
    ?assertEqual(undefined, to_tag(S2)),
    ?assertNotEqual(hdr(<<"call-id">>, S1), hdr(<<"call-id">>, S2)),
    ?assertNotEqual(from_tag(S1), from_tag(S2)),
    send(Sock, EP, ok_2xx(Sock, S2, <<"nr">>, 600)),
    send(
        Sock,
        EP,
        notify(
            Sock,
            S2,
            <<"nr">>,
            1,
            <<"active;expires=600">>,
            <<"again">>
        )
    ),
    {_, _} = recv(Sock, {status, 200, <<"NOTIFY">>}, 3000),
    {notify, #{body := <<"again">>}} = sub_event(Sub),
    stop(Sub).

%% A refresh answered 481 ends the subscription: no SUBSCRIBE follows.
%% req: R6665-37
refresh_481_ends(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Sub} = chappe_sip:subscribe_to(
        notifier(Sock),
        <<"presence">>,
        #{expires => 2}
    ),
    {S1, _} = recv(Sock, {method, <<"SUBSCRIBE">>}, 3000),
    send(Sock, EP, ok_2xx(Sock, S1, <<"nf">>, 2)),
    send(
        Sock,
        EP,
        notify(
            Sock,
            S1,
            <<"nf">>,
            1,
            <<"active;expires=2">>,
            <<>>
        )
    ),
    {_, _} = recv(Sock, {status, 200, <<"NOTIFY">>}, 3000),
    {notify, _} = sub_event(Sub),
    {S2, _} = recv(Sock, {method, <<"SUBSCRIBE">>}, 2500),
    send(Sock, EP, response(S2, 481, #{})),
    {terminated, {refresh_failed, 481}} = sub_event(Sub),
    recv_none(Sock, {method, <<"SUBSCRIBE">>}, 3000).

%% The 200 comes but no NOTIFY before Timer N: the attempt fails, and a
%% NOTIFY sent after it gets 481.
%% req: R6665-38
timer_n_then_481(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Sub} = chappe_sip:subscribe_to(
        notifier(Sock),
        <<"presence">>,
        #{timer_n => 500}
    ),
    {S1, _} = recv(Sock, {method, <<"SUBSCRIBE">>}, 3000),
    send(Sock, EP, ok_2xx(Sock, S1, <<"nt">>, 600)),
    {terminated, timer_n} = sub_event(Sub),
    send(
        Sock,
        EP,
        notify(
            Sock,
            S1,
            <<"nt">>,
            1,
            <<"active;expires=600">>,
            <<>>
        )
    ),
    {R, _} = recv(Sock, {status, 481, <<"NOTIFY">>}, 3000),
    ?assertEqual(481, status(R)).

%% A NOTIFY from a tag other than the 200's is a subscription of its own
%% (a fork, RFC 6665 4.1.4): 200, and the owner gets {forked, Sub2}.
%% req: R6665-54 R3842-19
forked_notify(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {Sub, S1} = active_sub(Sock, EP),
    send(
        Sock,
        EP,
        notify(
            Sock,
            S1,
            <<"fork2">>,
            1,
            <<"active;expires=600">>,
            <<"other">>
        )
    ),
    {_, _} = recv(Sock, {status, 200, <<"NOTIFY">>}, 3000),
    {forked, Sub2} = sub_event(Sub),
    {notify, #{body := <<"other">>}} = sub_event(Sub2),
    ?assertNotEqual(Sub, Sub2),
    %% each has its own dialog: the fork's unsubscribe names its tag
    ok = chappe_sip:unsubscribe(Sub2),
    {U, _} = recv(Sock, {method, <<"SUBSCRIBE">>}, 3000),
    ?assertEqual(<<"fork2">>, to_tag(U)),
    stop(Sub).

%% A NOTIFY matching no subscription of ours gets 481 (RFC 6665 4.1.3).
%% req: R6665-32
unmatched_notify_481(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    N = request(<<"NOTIFY">>, <<"sip:app@127.0.0.1">>, #{
        port => port(Sock),
        to_tag => tag(),
        headers => [
            {<<"Event">>, <<"presence">>},
            {<<"Subscription-State">>, <<"active">>}
        ]
    }),
    send(Sock, EP, N),
    {R, _} = recv(Sock, final, 3000),
    ?assertEqual(481, status(R)).

%% A SUBSCRIBE refused ends the attempt: {terminated, {subscribe_failed, S}}.
subscribe_rejected(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Sub} = chappe_sip:subscribe_to(notifier(Sock), <<"presence">>, #{}),
    {S1, _} = recv(Sock, {method, <<"SUBSCRIBE">>}, 3000),
    send(Sock, EP, response(S1, 489, #{to_tag => tag()})),
    {terminated, {subscribe_failed, 489}} = sub_event(Sub).

%% ---- package routing ----

%% A SUBSCRIBE goes to the handler of its event package; another package
%% to the subscribe/1 catch-all.
%% req: R6665-07
package_routes(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:event_package(<<"Presence">>, fun(_Req, Res) ->
        Test ! presence,
        chappe_sip_res:send(Res, 403)
    end),
    ok = chappe_sip:subscribe(fun(_Req, Res) ->
        Test ! catch_all,
        chappe_sip_res:send(Res, 403)
    end),
    send(Sock, EP, subscribe_req(Sock, <<"presence">>)),
    {_, _} = recv(Sock, {status, 403}, 3000),
    receive
        presence -> ok
    after 2000 -> ct:fail(no_package_handler)
    end,
    send(Sock, EP, subscribe_req(Sock, <<"dialog">>)),
    {_, _} = recv(Sock, {status, 403}, 3000),
    receive
        catch_all -> ok
    after 2000 -> ct:fail(no_catch_all)
    end.

%% With packages only, a SUBSCRIBE for another gets 489 with Allow-Events
%% listing them, and OPTIONS lists them in Allow-Events.
%% req: R6665-07 R6665-16 R6665-27
package_489(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Fun = fun(_Req, Res) -> chappe_sip_res:send(Res, 403) end,
    ok = chappe_sip:event_package(<<"presence">>, Fun),
    ok = chappe_sip:event_package(<<"message-summary">>, Fun),
    send(Sock, EP, subscribe_req(Sock, <<"dialog">>)),
    {R, _} = recv(Sock, {status, 489}, 3000),
    ?assertEqual(
        [<<"message-summary">>, <<"presence">>],
        tokens(hdr(<<"allow-events">>, R))
    ),
    send(
        Sock,
        EP,
        request(
            <<"OPTIONS">>,
            <<"sip:app@127.0.0.1">>,
            #{port => port(Sock)}
        )
    ),
    {O, _} = recv(Sock, {status, 200, <<"OPTIONS">>}, 3000),
    ?assertEqual(
        [<<"message-summary">>, <<"presence">>],
        tokens(hdr(<<"allow-events">>, O))
    ),
    Allow = tokens(hdr(<<"allow">>, O)),
    ?assert(lists:member(<<"SUBSCRIBE">>, Allow)),
    ?assert(lists:member(<<"NOTIFY">>, Allow)).

%% ---- helpers ----

notifier(Sock) ->
    <<"sip:notifier@127.0.0.1:", (integer_to_binary(port(Sock)))/binary>>.

%% a subscription the notifier accepted and notified once (tag na)
active_sub(Sock, EP) ->
    {ok, Sub} = chappe_sip:subscribe_to(notifier(Sock), <<"dialog">>, #{}),
    {S1, _} = recv(Sock, {method, <<"SUBSCRIBE">>}, 3000),
    send(Sock, EP, ok_2xx(Sock, S1, <<"na">>, 600)),
    send(
        Sock,
        EP,
        notify(
            Sock,
            S1,
            <<"na">>,
            1,
            <<"active;expires=600">>,
            <<>>
        )
    ),
    {_, _} = recv(Sock, {status, 200, <<"NOTIFY">>}, 3000),
    {notify, _} = sub_event(Sub),
    {Sub, S1}.

ok_2xx(Sock, Sub, Tag, Expires) ->
    response(Sub, 200, #{
        to_tag => Tag,
        headers => [
            {<<"Contact">>, <<"<", (notifier(Sock))/binary, ">">>},
            {<<"Expires">>, integer_to_binary(Expires)}
        ]
    }).

%% a NOTIFY in the dialog of SUBSCRIBE Sub, the notifier's tag Tag
notify(Sock, Sub, Tag, CSeq, State, Body) ->
    request(<<"NOTIFY">>, contact_of(Sub), #{
        port => port(Sock),
        call_id => hdr(<<"call-id">>, Sub),
        from => addr(hdr(<<"to">>, Sub)),
        from_tag => Tag,
        to => addr(hdr(<<"from">>, Sub)),
        to_tag => from_tag(Sub),
        cseq => CSeq,
        contact => <<"<", (notifier(Sock))/binary, ">">>,
        headers => [
            {<<"Event">>, hdr(<<"event">>, Sub)},
            {<<"Subscription-State">>, State}
        ],
        body => Body,
        content_type => <<"application/pidf+xml">>
    }).

subscribe_req(Sock, Event) ->
    request(<<"SUBSCRIBE">>, <<"sip:app@127.0.0.1">>, #{
        port => port(Sock),
        headers => [{<<"Event">>, Event}, {<<"Expires">>, <<"60">>}]
    }).

sub_event(Sub) ->
    receive
        {chappe_sip_subscription, Sub, E} -> E
    after 6000 -> ct:fail({no_subscription_event, Sub})
    end.

stop(Sub) ->
    MRef = erlang:monitor(process, Sub),
    exit(Sub, kill),
    receive
        {'DOWN', MRef, _, _, _} -> ok
    end.

contact_of(Msg) ->
    {ok, #{uri := U}} = chappe_sip_hdr:name_addr(hdr(<<"contact">>, Msg)),
    U.

addr(V) -> re:replace(V, ";tag=[^;]*", "", [{return, binary}]).

tokens(undefined) ->
    [];
tokens(V) ->
    lists:sort([string:trim(T) || T <- binary:split(V, <<",">>, [global])]).
