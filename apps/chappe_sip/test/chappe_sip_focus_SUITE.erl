%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% A conference focus (RFC 4579) serving its state (RFC 4575 over RFC
%% 6665), as a watcher sees it over real SIP. The focus is
%% chappe_sip_test_focus, the smallest conference built on
%% chappe_sip_focus (no media). Every UA is a process speaking raw SIP over
%% UDP; it answers the NOTIFYs and BYEs it gets and records them with their
%% arrival time. Every NOTIFY body is validated against the RFC 4575
%% schema.
-module(chappe_sip_focus_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    subscription_dialog/1,
    versions_per_subscription/1,
    refresh_gets_full_state/1,
    changes_are_coalesced/1,
    privacy_is_anonymous/1,
    accept_must_allow_conference_info/1,
    unknown_package/1,
    conference_end_terminates/1,
    invite_answer_advertises_focus/1,
    options_advertises_focus/1
]).

-define(CI, <<"application/conference-info+xml">>).

all() ->
    [
        subscription_dialog,
        versions_per_subscription,
        refresh_gets_full_state,
        changes_are_coalesced,
        privacy_is_anonymous,
        accept_must_allow_conference_info,
        unknown_package,
        conference_end_terminates,
        invite_answer_advertises_focus,
        options_advertises_focus
    ].

init_per_suite(Config) ->
    application:set_env(
        chappe_sip, engine_mod, chappe_sip_nif, [{persistent, true}]
    ),
    {ok, _} = application:ensure_all_started(chappe_sip),
    EP = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:", (port(EP))/binary>>}),
    ok = chappe_sip_test_focus:install(),
    [{ep, EP} | Config].

end_per_suite(_Config) ->
    _ = chappe_sip:stop(),
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

%% every case starts with a conference hosted by `host'
init_per_testcase(_Case, Config) ->
    EP = ?config(ep, Config),
    Uri = <<"sip:conf-", (rand_hex(4))/binary, "@127.0.0.1:", (port(EP))/binary>>,
    {ok, _} = chappe_sip_test_focus:start(Uri),
    UAs = [
        {K, ua_start(Name, EP)}
     || {K, Name} <- [
            {host, <<"host">>},
            {watcher, <<"watcher">>},
            {p1, <<"p1">>},
            {p2, <<"p2">>}
        ]
    ],
    Host = proplists:get_value(host, UAs),
    {ok, Focus, Resp} = invite(Host, Uri, []),
    [{conf_uri, Uri}, {focus, Focus}, {host_2xx, Resp} | UAs ++ Config].

end_per_testcase(_Case, Config) ->
    _ = chappe_sip_test_focus:stop(),
    [ua_stop(?config(K, Config)) || K <- [host, watcher, p1, p2]],
    ok.

%% ---- cases ----

%% The subscription dialog: 200 (never 202), a Contact that is the
%% conference URI with isfocus, and an immediate NOTIFY with the full state
%% as version 1.
%% req: R4579-06 R6665-09 R6665-04 R6665-15 R4575-03 R4575-06 R4575-18 R4575-19 R4575-31
subscription_dialog(Config) ->
    W = ?config(watcher, Config),
    Uri = ?config(conf_uri, Config),
    {ok, Sub, R200} = subscribe(W, Uri, <<"conference">>, []),
    ?assertEqual(200, chappe_sip_msg:status(R200)),
    ?assertEqual(Uri, contact_uri(R200)),
    ?assertNotEqual(nomatch, binary:match(hdr(R200, contact), <<"isfocus">>)),
    [First] = wait_notifies(W, Sub, 1),
    ?assertMatch(#{state := "full", version := 1}, info(First)),
    ?assertEqual(<<"conference">>, hdr(First, event)),
    ?assertEqual(?CI, hdr(First, 'content-type')),
    ?assertMatch(<<"active;expires=", _/binary>>, hdr(First, 'subscription-state')),
    ?assertNotEqual(nomatch, binary:match(hdr(First, contact), <<"isfocus">>)),
    %% the host is in it, with its role
    ?assert(mentions(W, Sub, ua_uri(?config(host, Config)))),
    ?assert(mentions(W, Sub, <<"<entry>host</entry>">>)),
    %% a full document has both, even with no description configured
    [
        ?assertNotEqual(nomatch, binary:match(chappe_sip_msg:body(First), T))
     || T <- [<<"<conference-description">>, <<"<users">>]
    ].

%% Version numbers belong to the subscription: a late watcher starts at 1
%% while an early one has moved on, and each partial is exactly +1.
%% req: R4575-27 R4575-28 R4575-10
versions_per_subscription(Config) ->
    [W, P1, P2] = [?config(K, Config) || K <- [watcher, p1, p2]],
    Uri = ?config(conf_uri, Config),
    {ok, SubW, _} = subscribe(W, Uri, <<"conference">>, []),
    wait_notifies(W, SubW, 1),
    {ok, _, _} = invite(P1, Uri, []),
    [_, _] = wait_notifies(W, SubW, 2),
    {ok, SubP, _} = subscribe(P1, Uri, <<"conference">>, []),
    [FirstP] = wait_notifies(P1, SubP, 1),
    ?assertMatch(#{version := 1, state := "full"}, info(FirstP)),
    {ok, _, _} = invite(P2, Uri, []),
    Ws = wait_notifies(W, SubW, 3),
    ?assertEqual([1, 2, 3], [maps:get(version, info(N)) || N <- Ws]),
    ?assertEqual(
        ["full", "partial", "partial"], [maps:get(state, info(N)) || N <- Ws]
    ).

%% A refreshing SUBSCRIBE gets the full state again, as the next version.
%% req: R4575-03 R4575-25 R6665-09
refresh_gets_full_state(Config) ->
    W = ?config(watcher, Config),
    {ok, Sub, _} = subscribe(W, ?config(conf_uri, Config), <<"conference">>, []),
    wait_notifies(W, Sub, 1),
    {ok, 200} = refresh(W, Sub, 600),
    [_, Second] = wait_notifies(W, Sub, 2),
    ?assertMatch(#{state := "full", version := 2}, info(Second)).

%% Two joins within a second reach a watcher as NOTIFYs at least 5 s
%% apart, and nothing is lost: the last document knows both.
%% req: R4575-16
changes_are_coalesced(Config) ->
    [W, P1, P2] = [?config(K, Config) || K <- [watcher, p1, p2]],
    Uri = ?config(conf_uri, Config),
    {ok, Sub, _} = subscribe(W, Uri, <<"conference">>, []),
    wait_notifies(W, Sub, 1),
    {ok, _, _} = invite(P1, Uri, []),
    {ok, _, _} = invite(P2, Uri, []),
    ok = wait_until(fun() -> mentions(W, Sub, ua_uri(P2)) end, 15000),
    Times = [T || {M, T} <- timed_notifies(W, Sub), M =/= undefined],
    Gaps = [B - A || {A, B} <- lists:zip(lists:droplast(Times), tl(Times))],
    ct:log("NOTIFY gaps ~p", [Gaps]),
    ?assertNotEqual([], Gaps),
    [?assert(G >= 4900, {too_fast, G}) || G <- Gaps],
    ?assert(mentions(W, Sub, ua_uri(P1))).

%% A participant asking for privacy appears as AnonymousN at
%% anonymous.invalid, never under its own URI or name.
%% req: R4579-24 R4579-25 R4575-37 R4575-38 R4575-58 R4575-36 R4575-59
privacy_is_anonymous(Config) ->
    [W, P1] = [?config(K, Config) || K <- [watcher, p1]],
    Uri = ?config(conf_uri, Config),
    {ok, Sub, _} = subscribe(W, Uri, <<"conference">>, []),
    wait_notifies(W, Sub, 1),
    {ok, _, _} = invite(P1, Uri, [{<<"Privacy">>, <<"id">>}]),
    ok = wait_until(
        fun() -> mentions(W, Sub, <<"@anonymous.invalid">>) end, 15000
    ),
    ?assert(mentions(W, Sub, <<"Anonymous">>)),
    ?assertNot(mentions(W, Sub, ua_uri(P1))),
    ?assertNot(mentions(W, Sub, <<"p1@">>)),
    ?assertNot(mentions(W, Sub, <<"P1 Phone">>)).

%% A SUBSCRIBE whose Accept leaves out conference-info+xml gets 406,
%% naming the type it would take.
%% req: R4575-07 R6665-04
accept_must_allow_conference_info(Config) ->
    W = ?config(watcher, Config),
    {error, 406, R} = subscribe(
        W, ?config(conf_uri, Config), <<"conference">>, [
            {<<"Accept">>, <<"text/plain">>}
        ]
    ),
    ?assertEqual(?CI, hdr(R, accept)),
    %% a wildcard or a list naming it is fine
    {ok, _, _} = subscribe(
        W, ?config(conf_uri, Config), <<"conference">>, [
            {<<"Accept">>, <<"text/plain, application/*">>}
        ]
    ).

%% An event package the focus does not serve: 489 with Allow-Events.
%% req: R6665-07 R6665-27
unknown_package(Config) ->
    W = ?config(watcher, Config),
    {error, 489, R} = subscribe(
        W, ?config(conf_uri, Config), <<"presence">>, []
    ),
    ?assertEqual(<<"conference">>, hdr(R, 'allow-events')).

%% When the conference ends every subscription ends with noresource, with
%% exactly one terminated NOTIFY each.
%% req: R4575-05 R6665-12 R4579-19
conference_end_terminates(Config) ->
    [Host, W, P1, P2] = [?config(K, Config) || K <- [host, watcher, p1, p2]],
    Uri = ?config(conf_uri, Config),
    {ok, Sub, _} = subscribe(W, Uri, <<"conference">>, []),
    {ok, SubP, _} = subscribe(P1, Uri, <<"conference">>, []),
    wait_notifies(W, Sub, 1),
    wait_notifies(P1, SubP, 1),
    %% a participant still in: the focus hangs it up as the conference ends
    {ok, P2Call, _} = invite(P2, Uri, []),
    {ok, 200} = bye(Host, ?config(focus, Config)),
    ok = wait_until(fun() -> got_bye(P2, P2Call) end, 15000),
    Terminated = fun(UA, S) ->
        [
            M
         || M <- notifies(UA, S),
            binary:match(hdr(M, 'subscription-state'), <<"terminated">>) =/=
                nomatch
        ]
    end,
    ok = wait_until(
        fun() -> Terminated(W, Sub) =/= [] andalso Terminated(P1, SubP) =/= [] end,
        15000
    ),
    %% the notifier's retransmit window and the owner-exit teardown have
    %% both had their chance to send a second one
    timer:sleep(3000),
    [T] = Terminated(W, Sub),
    [_] = Terminated(P1, SubP),
    ?assertEqual(
        <<"terminated;reason=noresource">>, hdr(T, 'subscription-state')
    ).

%% The focus's 2xx to an INVITE says what it is and what it serves.
%% req: R4579-01 R4579-06 R4579-08 R4579-20
invite_answer_advertises_focus(Config) ->
    R = ?config(host_2xx, Config),
    ?assertEqual(?config(conf_uri, Config), contact_uri(R)),
    ?assertNotEqual(nomatch, binary:match(hdr(R, contact), <<"isfocus">>)),
    Allow = tokens(hdr(R, allow)),
    [
        ?assert(lists:member(M, Allow), {allow, M})
     || M <- [<<"invite">>, <<"subscribe">>, <<"notify">>, <<"refer">>]
    ],
    ?assert(lists:member(<<"conference">>, tokens(hdr(R, 'allow-events')))),
    ?assert(lists:member(?CI, tokens(hdr(R, accept)))),
    ?assert(lists:member(<<"application/sdp">>, tokens(hdr(R, accept)))),
    ?assert(lists:member(<<"replaces">>, tokens(hdr(R, supported)))).

%% OPTIONS to the conference URI discovers a focus (RFC 4579 4.3).
%% req: R4579-07 R4579-01
options_advertises_focus(Config) ->
    W = ?config(watcher, Config),
    R = options(W, ?config(conf_uri, Config)),
    ?assertEqual(200, chappe_sip_msg:status(R)),
    ?assertNotEqual(nomatch, binary:match(hdr(R, contact), <<"isfocus">>)),
    ?assert(lists:member(<<"conference">>, tokens(hdr(R, 'allow-events')))).

%% ---- helpers ----

got_bye(UA, Call) ->
    [
        ok
     || {<<"BYE">>, M, _} <- ua_call(UA, requests),
        chappe_sip_msg:call_id(M) =:= Call
    ] =/= [].

notifies(UA, Sub) ->
    [M || {M, _} <- timed_notifies(UA, Sub)].

timed_notifies(UA, Sub) ->
    [
        {M, T}
     || {<<"NOTIFY">>, M, T} <- ua_call(UA, requests),
        chappe_sip_msg:call_id(M) =:= Sub
    ].

%% the first N NOTIFYs of the subscription, waiting for them
wait_notifies(UA, Sub, N) ->
    ok = wait_until(fun() -> length(notifies(UA, Sub)) >= N end, 15000),
    lists:sublist(notifies(UA, Sub), N).

info(M) ->
    chappe_sip_test_confinfo:conference_info(chappe_sip_msg:body(M)).

%% every body is checked against the schema on the way
mentions(UA, Sub, Text) ->
    lists:any(
        fun(M) ->
            _ = info(M),
            binary:match(chappe_sip_msg:body(M), Text) =/= nomatch
        end,
        notifies(UA, Sub)
    ).

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

%% a comma separated header value as lowercase tokens
tokens(undefined) ->
    [];
tokens(V) ->
    [
        string:lowercase(string:trim(T))
     || T <- binary:split(V, <<",">>, [global])
    ].

port(P) -> integer_to_binary(P).
rand_hex(N) -> binary:encode_hex(crypto:strong_rand_bytes(N), lowercase).
branch() -> <<"z9hG4bK", (rand_hex(6))/binary>>.

%% ---- UA: a process speaking raw SIP over UDP ----

invite(UA, Uri, Hdrs) -> ua_call(UA, {invite, Uri, Hdrs}).
subscribe(UA, Uri, Event, Hdrs) -> ua_call(UA, {subscribe, Uri, Event, Hdrs}).
refresh(UA, Sub, Expires) -> ua_call(UA, {refresh, Sub, Expires}).
bye(UA, CallId) -> ua_call(UA, {bye, CallId}).
options(UA, Uri) -> ua_call(UA, {options, Uri}).
ua_uri(UA) -> ua_call(UA, uri).

ua_start(Name, EP) ->
    Parent = self(),
    Pid = spawn(fun() ->
        {ok, Sock} = gen_udp:open(0, [
            binary, {active, true}, {ip, {127, 0, 0, 1}}
        ]),
        {ok, P} = inet:port(Sock),
        Parent ! {ua_ready, self()},
        ua_loop(#{
            sock => Sock,
            ep => EP,
            name => Name,
            port => P,
            reqs => [],
            seen => #{},
            dialogs => #{}
        })
    end),
    receive
        {ua_ready, Pid} -> Pid
    after 5000 -> ct:fail(ua_start)
    end.

ua_stop(UA) ->
    UA ! stop,
    ok.

ua_call(UA, Req) ->
    Ref = monitor(process, UA),
    UA ! {call, self(), Ref, Req},
    receive
        {Ref, Reply} ->
            demonitor(Ref, [flush]),
            Reply;
        {'DOWN', Ref, process, _, Why} ->
            ct:fail({ua_down, Why})
    after 20000 -> ct:fail({ua_timeout, Req})
    end.

ua_loop(S) ->
    receive
        {call, From, Ref, Req} ->
            {Reply, S1} = ua_handle(Req, S),
            From ! {Ref, Reply},
            ua_loop(S1);
        {udp, _, _, _, Bin} ->
            ua_loop(ua_incoming(Bin, S));
        stop ->
            ok
    end.

ua_handle(uri, S) ->
    {self_uri(S), S};
ua_handle(requests, #{reqs := R} = S) ->
    {lists:reverse(R), S};
ua_handle({invite, Uri, Hdrs}, S) ->
    Call = <<"inv-", (rand_hex(5))/binary, "@ct">>,
    FT = rand_hex(4),
    Bin = request(<<"INVITE">>, Uri, S, #{
        call => Call, ft => FT, to => Uri, cseq => 1, hdrs => Hdrs
    }),
    {R, S1} = transact(Bin, Call, S),
    case chappe_sip_msg:status(R) of
        200 ->
            TT = chappe_sip_msg:to_tag(R),
            Ack = request(<<"ACK">>, contact_uri(R), S1, #{
                call => Call, ft => FT, tt => TT, to => Uri, cseq => 1
            }),
            send(S1, Ack),
            D = #{ft => FT, tt => TT, to => Uri, target => contact_uri(R), cseq => 1},
            {{ok, Call, R}, add_dialog(Call, D, S1)};
        St ->
            {{error, St, R}, S1}
    end;
ua_handle({subscribe, Uri, Event, Hdrs}, S) ->
    Call = <<"sub-", (rand_hex(5))/binary, "@ct">>,
    FT = rand_hex(4),
    Defaults = [{<<"Expires">>, <<"600">>}, {<<"Accept">>, ?CI}],
    Names = [string:lowercase(N) || {N, _} <- Hdrs],
    All =
        [{<<"Event">>, Event}] ++ Hdrs ++
            [H || {N, _} = H <- Defaults, not lists:member(string:lowercase(N), Names)],
    Bin = request(<<"SUBSCRIBE">>, Uri, S, #{
        call => Call, ft => FT, to => Uri, cseq => 1, hdrs => All
    }),
    {R, S1} = transact(Bin, Call, S),
    case chappe_sip_msg:status(R) of
        St when St >= 200, St < 300 ->
            D = #{
                ft => FT,
                tt => chappe_sip_msg:to_tag(R),
                to => Uri,
                target => contact_uri(R),
                cseq => 1,
                event => Event
            },
            {{ok, Call, R}, add_dialog(Call, D, S1)};
        St ->
            {{error, St, R}, S1}
    end;
ua_handle({refresh, Call, Expires}, S) ->
    in_dialog(<<"SUBSCRIBE">>, Call, [{<<"Expires">>, integer_to_binary(Expires)}], S);
ua_handle({bye, Call}, S) ->
    in_dialog(<<"BYE">>, Call, [], S);
ua_handle({options, Uri}, S) ->
    Call = <<"opt-", (rand_hex(5))/binary, "@ct">>,
    Bin = request(<<"OPTIONS">>, Uri, S, #{
        call => Call, ft => rand_hex(4), to => Uri, cseq => 1
    }),
    transact(Bin, Call, S).

in_dialog(Method, Call, Hdrs, #{dialogs := Ds} = S) ->
    #{target := Target, cseq := C} = D = maps:get(Call, Ds),
    Ev =
        case D of
            #{event := E} -> [{<<"Event">>, E}];
            _ -> []
        end,
    Bin = request(Method, Target, S, D#{call => Call, cseq => C + 1, hdrs => Ev ++ Hdrs}),
    {R, S1} = transact(Bin, Call, add_dialog(Call, D#{cseq => C + 1}, S)),
    {{ok, chappe_sip_msg:status(R)}, S1}.

add_dialog(Call, D, #{dialogs := Ds} = S) ->
    S#{dialogs => maps:put(Call, D, Ds)}.

%% send a request and wait for its final response, answering whatever
%% arrives meanwhile
transact(Bin, Call, S) ->
    send(S, Bin),
    await_final(Call, S).

await_final(Call, #{sock := Sock} = S) ->
    receive
        {udp, Sock, _, _, <<"SIP/2.0 ", _/binary>> = Bin} ->
            {ok, M} = chappe_sip_msg:parse(Bin),
            case {chappe_sip_msg:call_id(M), chappe_sip_msg:status(M)} of
                {Call, St} when St >= 200 -> {M, S};
                _ -> await_final(Call, S)
            end;
        {udp, Sock, _, _, Bin} ->
            await_final(Call, ua_incoming(Bin, S))
    after 10000 -> exit({no_final, Call})
    end.

%% requests are answered 200 and recorded once each (a retransmission is
%% answered again, not recorded again)
ua_incoming(<<"SIP/2.0 ", _/binary>>, S) ->
    S;
ua_incoming(Bin, #{reqs := Reqs, seen := Seen} = S) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    Method = chappe_sip_msg:method(M),
    case Method of
        <<"ACK">> -> ok;
        _ -> slow_final(M, S), send(S, resp(M, 200, <<"OK">>))
    end,
    Key = {chappe_sip_msg:call_id(M), chappe_sip_msg:get(<<"cseq">>, M)},
    case maps:is_key(Key, Seen) of
        true ->
            S;
        false ->
            Now = erlang:monotonic_time(millisecond),
            S#{reqs => [{Method, M, Now} | Reqs], seen => Seen#{Key => true}}
    end.

%% a watcher slow to answer the final NOTIFY: the focus must not send a
%% second one while it waits (the owner-exit teardown would)
slow_final(M, _S) ->
    State = chappe_sip_msg:get(<<"subscription-state">>, M),
    case is_binary(State) andalso binary:match(State, <<"terminated">>) of
        {_, _} -> timer:sleep(1000);
        _ -> ok
    end.

self_uri(#{name := N, port := P}) ->
    <<"sip:", N/binary, "@127.0.0.1:", (port(P))/binary>>.

request(Method, RUri, S, #{call := Call, ft := FT, to := To, cseq := CSeq} = O) ->
    #{name := Name, port := P} = S,
    ToTag =
        case O of
            #{tt := TT} when is_binary(TT) -> <<";tag=", TT/binary>>;
            _ -> <<>>
        end,
    Display = <<(string:uppercase(Name))/binary, " Phone">>,
    Hdrs = maps:get(hdrs, O, []),
    iolist_to_binary([
        Method, <<" ">>, RUri, <<" SIP/2.0\r\n">>,
        <<"Via: SIP/2.0/UDP 127.0.0.1:">>, port(P), <<";rport;branch=">>,
            branch(), <<"\r\n">>,
        <<"Max-Forwards: 70\r\n">>,
        <<"From: \"">>, Display, <<"\" <">>, self_uri(S), <<">;tag=">>, FT,
            <<"\r\n">>,
        <<"To: <">>, To, <<">">>, ToTag, <<"\r\n">>,
        <<"Contact: <">>, self_uri(S), <<">\r\n">>,
        <<"Call-ID: ">>, Call, <<"\r\n">>,
        <<"CSeq: ">>, integer_to_binary(CSeq), <<" ">>, Method, <<"\r\n">>,
        [[K, <<": ">>, V, <<"\r\n">>] || {K, V} <- Hdrs],
        <<"Content-Length: 0\r\n\r\n">>
    ]).

resp(M, Status, Reason) ->
    To0 = chappe_sip_msg:get(<<"to">>, M),
    To =
        case chappe_sip_msg:to_tag(M) of
            undefined -> <<To0/binary, ";tag=ua">>;
            _ -> To0
        end,
    iolist_to_binary([
        <<"SIP/2.0 ">>, integer_to_binary(Status), <<" ">>, Reason, <<"\r\n">>,
        [[<<"Via: ">>, V, <<"\r\n">>] || V <- chappe_sip_msg:get_all(<<"via">>, M)],
        <<"From: ">>, chappe_sip_msg:get(<<"from">>, M), <<"\r\n">>,
        <<"To: ">>, To, <<"\r\n">>,
        <<"Call-ID: ">>, chappe_sip_msg:call_id(M), <<"\r\n">>,
        <<"CSeq: ">>, chappe_sip_msg:get(<<"cseq">>, M), <<"\r\n">>,
        <<"Content-Length: 0\r\n\r\n">>
    ]).

send(#{sock := Sock, ep := EP}, Bin) ->
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, EP, Bin).
