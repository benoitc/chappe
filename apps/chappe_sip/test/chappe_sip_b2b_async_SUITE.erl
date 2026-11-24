%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% relay_async/2's process, as chappe-erlang-patterns asks of every
%% process: it runs under chappe_sip_b2b_sup, the call ends when its
%% owner dies, a crash of its own ends the call cleanly, it is driven and
%% found from another node, and a flood of offers on one leg stays
%% bounded. Real SIP on loopback, through the fake rtpengine.
-module(chappe_sip_b2b_async_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([notify_death_keeps_call/1]).
-export([
    supervised/1,
    owner_death_hangs_up/1,
    relay_crash_ends_call/1,
    from_another_node/1,
    offer_flood_bounded/1
]).

-define(UA, chappe_sip_test_ua).

all() ->
    [
        supervised,
        owner_death_hangs_up,
        notify_death_keeps_call,
        relay_crash_ends_call,
        from_another_node,
        offer_flood_bounded
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

end_per_testcase(_Case, _Config) ->
    _ =
        case whereis(async_test_rtpe) of
            undefined ->
                ok;
            Rtpe ->
                unregister(async_test_rtpe),
                chappe_sip_test_rtpe:stop(Rtpe)
        end,
    _ = [unregister(async_test) || whereis(async_test) =/= undefined],
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% The relay is a temporary child of chappe_sip_b2b_relays, gone with
%% its call.
supervised(_Config) ->
    {EP, CP} = setup(#{}),
    callee(CP, fun(_Sock) -> ok end),
    caller(EP, fun(Sock, D) ->
        receive
            hang_up -> ok
        end,
        {Bye, _} = ?UA:in_dialog(D, <<"BYE">>, [], <<>>),
        ?UA:send(Sock, EP, Bye)
    end),
    {Relay, Ref} = got(b2b),
    ?assert(lists:member(Relay, relays())),
    caller_pid() ! hang_up,
    receive
        {chappe_sip_b2b, Ref, {done, {done, a_bye}}} -> ok
    after 5000 -> ct:fail(no_done)
    end,
    ok = wait_until(fun() -> not lists:member(Relay, relays()) end).

%% The owner dies: both legs get a BYE, the rtpengine session is
%% deleted, and nothing serves the call any more.
owner_death_hangs_up(_Config) ->
    Owner = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    {EP, CP} = setup(#{owner => Owner}),
    callee(CP, fun(_Sock) -> ok end),
    caller(EP, fun(_Sock, _D) -> ok end),
    {Relay, _} = got(b2b),
    #{call_ref := CallRef} = got(legs),
    exit(Owner, kill),
    _ = got(callee_bye),
    _ = got(caller_bye),
    ok = wait_until(fun() -> not is_process_alive(Relay) end),
    ok = wait_until(fun() ->
        maps:get(b2b, chappe_sip_call:lookup(CallRef)) =:= []
    end).

%% Without an owner option the call has none: the notify process (often
%% the handler that made the call) may end, and the call goes on.
notify_death_keeps_call(_Config) ->
    Notify = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    {EP, CP} = setup(#{notify => Notify}),
    callee(CP, fun(_Sock) -> ok end),
    caller(EP, fun(_Sock, _D) -> ok end),
    {Relay, _} = B2b = got(b2b),
    exit(Notify, kill),
    no_bye(1000),
    ?assert(is_process_alive(Relay)),
    ?assertMatch(#{media := anchor}, chappe_sip_b2b:info(B2b)),
    ok = chappe_sip_b2b:hangup(B2b, #{}).

no_bye(Ms) ->
    receive
        {callee_bye, B} -> ct:fail({unexpected_bye, B});
        {caller_bye, B} -> ct:fail({unexpected_bye, B})
    after Ms -> ok
    end.

%% The relay itself is killed: its dialogs see their owner go and end
%% the call, so neither party is left on a dead call.
relay_crash_ends_call(_Config) ->
    {EP, CP} = setup(#{}),
    callee(CP, fun(_Sock) -> ok end),
    caller(EP, fun(_Sock, _D) -> ok end),
    {Relay, _} = got(b2b),
    exit(Relay, kill),
    _ = got(callee_bye),
    _ = got(caller_bye),
    ?assertNot(lists:member(Relay, relays())).

%% A peer node finds the call by its call_ref (pg), asks it for its
%% state and hangs it up.
from_another_node(_Config) ->
    ok = chappe_sip_test_dist:ensure(),
    Paths = lists:append([["-pa", P] || P <- code:get_path()]),
    {ok, Peer, Node} = peer:start_link(#{
        name => peer:random_name(),
        args => Paths
    }),
    try
        {ok, _} = erpc:call(Node, pg, start, [chappe_sip]),
        {EP, CP} = setup(#{}),
        callee(CP, fun(_Sock) -> ok end),
        caller(EP, fun(_Sock, _D) -> ok end),
        B2b = got(b2b),
        #{call_ref := CallRef} = got(legs),
        ok = wait_until(fun() ->
            maps:get(b2b, erpc:call(Node, chappe_sip_call, lookup, [CallRef])) =:=
                [B2b]
        end),
        ?assertMatch(
            #{media := anchor, call_ref := CallRef},
            erpc:call(Node, chappe_sip_b2b, info, [B2b])
        ),
        ok = erpc:call(Node, chappe_sip_b2b, hangup, [B2b, #{}]),
        _ = got(callee_bye),
        _ = got(caller_bye)
    after
        peer:stop(Peer)
    end.

%% A flood of re-INVITE offers on leg A while B sits on the first: one is
%% relayed, every other one is answered 500 with Retry-After at once
%% (RFC 3261 14.2), and nothing piles up in the relay.
offer_flood_bounded(_Config) ->
    {EP, CP} = setup(#{}),
    %% B takes the first re-INVITE and never answers it
    callee(CP, fun(_Sock) -> ok end, silent),
    caller(EP, fun(Sock, D) ->
        _ = lists:foldl(
            fun(N, Di) ->
                Sdp = ?UA:sdp(<<"caller">>, integer_to_binary(N)),
                {Inv, D1} = ?UA:in_dialog(Di, <<"INVITE">>, [], Sdp),
                ?UA:send(Sock, EP, Inv),
                D1
            end,
            D,
            lists:seq(1, 50)
        ),
        tell({flood_answers, count_500(Sock, 0)})
    end),
    {Relay, _} = got(b2b),
    N500 = got(flood_answers),
    ct:log("500s: ~p", [N500]),
    ?assert(N500 >= 45),
    {message_queue_len, Q} = erlang:process_info(Relay, message_queue_len),
    ?assert(Q < 5).

%% ---- helpers ----

%% the app bridges every INVITE to the callee port, anchored, and hands
%% the call to relay_async/2 with Opts; the handler returns at once
setup(Opts) ->
    register(async_test_rtpe, chappe_sip_test_rtpe:start(spawn(fun sink/0))),
    EP = ?UA:pick(),
    CP = ?UA:pick(),
    ok = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>
    }),
    Test = self(),
    register(async_test, Test),
    Callee = <<"sip:callee@127.0.0.1:", (integer_to_binary(CP))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(
            Req,
            Res,
            Callee,
            #{media => anchor}
        ),
        Test ! {legs, Legs},
        {ok, B2b} = chappe_sip_b2b:relay_async(
            Legs, maps:merge(#{notify => Test}, Opts)
        ),
        Test ! {b2b, B2b}
    end),
    {EP, CP}.

sink() ->
    receive
        _ -> sink()
    end.

tell(Msg) ->
    case whereis(async_test) of
        undefined -> ok;
        Pid -> Pid ! Msg
    end.

callee(CP, Fun) ->
    callee(CP, Fun, answer).

%% the callee answers the INVITE; then re-INVITEs are answered, or left
%% unanswered (silent), and a BYE is callee_bye
callee(CP, Fun, Mode) ->
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Tag = ?UA:tag(),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                200,
                <<"OK">>,
                Tag,
                [contact(Sock)],
                ?UA:sdp(<<"callee">>)
            )
        ),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        Fun(Sock),
        serve(Sock, Tag, Mode, callee_bye)
    end).

serve(Sock, Tag, Mode, ByeTag) ->
    receive
        {udp, Sock, _, Src, <<"BYE ", _/binary>> = B} ->
            ?UA:send(Sock, Src, ?UA:resp(B, 200, <<"OK">>, Tag, [], <<>>)),
            tell({ByeTag, B}),
            serve(Sock, Tag, Mode, ByeTag);
        {udp, Sock, _, Src, <<"INVITE ", _/binary>> = I} when Mode =:= answer ->
            ?UA:send(
                Sock,
                Src,
                ?UA:resp(
                    I,
                    200,
                    <<"OK">>,
                    Tag,
                    [contact(Sock)],
                    ?UA:sdp(<<"callee">>, <<"2">>)
                )
            ),
            serve(Sock, Tag, Mode, ByeTag);
        {udp, Sock, _, _, _} ->
            serve(Sock, Tag, Mode, ByeTag)
    end.

caller(EP, Fun) ->
    Test = self(),
    ?UA:peer(0, fun(Sock) ->
        Test ! {caller_pid, self()},
        Inv = ?UA:invite(Sock, EP, #{
            call_id => ?UA:callid(),
            from_tag => ?UA:tag()
        }),
        ?UA:send(Sock, EP, Inv),
        R = ?UA:recv_status(Sock, 200),
        D = ?UA:dialog_from_2xx(Sock, Inv, R),
        ?UA:ack(D, EP),
        Fun(Sock, D),
        serve(Sock, <<>>, answer, caller_bye)
    end).

caller_pid() -> got(caller_pid).

%% the 500s the flood got, until the line is quiet for 2 s
count_500(Sock, N) ->
    receive
        {udp, Sock, _, _, <<"SIP/2.0 500", _/binary>>} ->
            count_500(Sock, N + 1);
        {udp, Sock, _, _, _} ->
            count_500(Sock, N)
    after 2000 -> N
    end.

contact(Sock) ->
    {<<"Contact">>,
        <<"<sip:peer@127.0.0.1:", (integer_to_binary(?UA:lport(Sock)))/binary,
            ">">>}.

got(Tag) ->
    receive
        {Tag, V} -> V
    after 10000 -> ct:fail({missing, Tag})
    end.

relays() ->
    [
        P
     || {_, P, _, _} <- supervisor:which_children(chappe_sip_b2b_relays),
        is_pid(P)
    ].

wait_until(F) -> wait_until(F, 50).

wait_until(_F, 0) ->
    ct:fail(condition_never_met);
wait_until(F, N) ->
    case F() of
        true ->
            ok;
        false ->
            timer:sleep(100),
            wait_until(F, N - 1)
    end.
