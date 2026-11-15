%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% A fake chappe_cluster for the lab's own proofs (MODE=proofs): each fault
%% must make the checker fail against a fake with the matching bug. Test
%% code only: it lives in test/lab, is never part of the app, and a lab
%% node runs it instead of chappe_cluster only with CLB_BACKEND=fake.
%%
%% One lock server on lab@n1 grants leases that expire by a wall clock, and
%% a renewer on every node renews them and tells holders `lost'. Holders
%% take the server's expiry as their deadline. FAKE_MODE picks the bugs:
%%
%%   naive     the server frees a key as soon as its holder's node drops,
%%             and holders hear lost only once their deadline has passed;
%%   careful   the server waits for the expiry, and holders hear lost
%%             renew_ms / 2 before their deadline, as chappe_cluster does;
%%   skewtrust careful, but a takeover is judged by the claimant's clock;
%%   lazylost  careful, but the renewer looks at deadlines every renew_ms,
%%             so a holder waking from a pause acts before it hears lost.
%%
%% None checks a lease before a side effect (no valid/1), and its
%% singletons stop their child on lost, slowly; so a paused holder, a
%% skewed claimant and a slow-stopping singleton can still double own. The
%% server keeps no state across a restart: a kill of n1 resets its fences.
-module(chappe_cluster_lab_fake).

-export([start/0]).
-export([claim/2, fence/1, release/1, singleton/2, singleton_fence/1]).

-define(SERVER, {chappe_cluster_lab_fake_lock, 'lab@n1'}).
-define(RENEWER, chappe_cluster_lab_fake_renewer).
%% no grant while the nodes connect
-define(WARMUP_MS, 8000).

%% @doc Start the fake on this node: the server on n1, a renewer everywhere.
-spec start() -> ok.
start() ->
    _ = spawn(fun() ->
        case node() of
            'lab@n1' -> spawn_link(fun server/0);
            _ -> ok
        end,
        spawn_link(fun renewer/0),
        receive
            stop -> ok
        end
    end),
    ok.

env(K, D) ->
    case os:getenv(K) of
        false -> D;
        "" -> D;
        V -> V
    end.

int(K, D) -> list_to_integer(env(K, integer_to_list(D))).
lease_ms() -> int("CLB_LEASE_MS", 6000).
renew_ms() -> int("CLB_RENEW_MS", 2000).
mode() -> env("FAKE_MODE", "naive").
careful() -> lists:member(mode(), ["careful", "skewtrust", "lazylost"]).

tick_ms() ->
    case mode() of
        "lazylost" -> renew_ms();
        _ -> 100
    end.
now_ms() -> erlang:system_time(millisecond).

%% ---- the lock server on n1 ----

server() ->
    register(chappe_cluster_lab_fake_lock, self()),
    Ready = erlang:monotonic_time(millisecond) + ?WARMUP_MS,
    server_loop(#{}, 0, Ready).

server_loop(Keys, Seq, Ready) ->
    receive
        {claim, From, Key, Pid, At} ->
            case erlang:monotonic_time(millisecond) < Ready of
                true ->
                    reply(From, {error, no_quorum}),
                    server_loop(Keys, Seq, Ready);
                false ->
                    {Keys1, Seq1} = grant(From, Key, Pid, At, Keys, Seq),
                    server_loop(Keys1, Seq1, Ready)
            end;
        {renew, From, Pids} ->
            Exp = now_ms() + lease_ms(),
            Keys1 = maps:map(
                fun(_, {P, S, E, M}) ->
                    case lists:member(P, Pids) of
                        true -> {P, S, Exp, M};
                        false -> {P, S, E, M}
                    end
                end,
                Keys
            ),
            reply(From, {ok, Exp}),
            server_loop(Keys1, Seq, Ready);
        {release, Key, S} ->
            case Keys of
                #{Key := {_, S, _, _}} ->
                    server_loop(maps:remove(Key, Keys), Seq, Ready);
                #{} ->
                    server_loop(Keys, Seq, Ready)
            end;
        {'DOWN', Mon, process, _, _} ->
            Keys1 = maps:filter(fun(_, {_, _, _, M}) -> M =/= Mon end, Keys),
            server_loop(Keys1, Seq, Ready)
    end.

grant(From, Key, Pid, At, Keys, Seq) ->
    Now =
        case mode() of
            "skewtrust" -> At;
            _ -> now_ms()
        end,
    case Keys of
        #{Key := {_, _, Exp, _}} when Exp > Now ->
            reply(From, {error, {owned, Key}}),
            {Keys, Seq};
        #{} ->
            Mon =
                case careful() of
                    true -> none;
                    false -> erlang:monitor(process, Pid)
                end,
            Exp = Now + lease_ms(),
            reply(From, {ok, Seq + 1, Exp}),
            {Keys#{Key => {Pid, Seq + 1, Exp, Mon}}, Seq + 1}
    end.

reply({Pid, Ref}, R) -> Pid ! {Ref, R}.

call(Msg, Timeout) ->
    Ref = erlang:monitor(process, ?SERVER),
    ?SERVER ! setelement(2, Msg, {self(), Ref}),
    receive
        {Ref, Reply} ->
            erlang:demonitor(Ref, [flush]),
            Reply;
        {'DOWN', Ref, _, _, _} ->
            {error, no_quorum}
    after Timeout ->
        erlang:demonitor(Ref, [flush]),
        {error, no_quorum}
    end.

%% ---- the renewer on every node ----

renewer() ->
    register(?RENEWER, self()),
    erlang:send_after(renew_ms(), self(), renew),
    erlang:send_after(tick_ms(), self(), tick),
    renewer_loop([]).

renewer_loop(Leases) ->
    receive
        {track, Lease, Exp} ->
            renewer_loop([{Lease, Exp} | Leases]);
        {untrack, #{key := K, seq := S}} ->
            renewer_loop([
                L
             || {#{key := K1, seq := S1}, _} = L <- Leases, {K1, S1} =/= {K, S}
            ]);
        renew ->
            erlang:send_after(renew_ms(), self(), renew),
            Pids = [P || {#{pid := P}, _} <- Leases],
            case call({renew, x, Pids}, renew_ms() div 2) of
                {ok, Exp} -> renewer_loop([{L, Exp} || {L, _} <- Leases]);
                _ -> renewer_loop(Leases)
            end;
        tick ->
            erlang:send_after(tick_ms(), self(), tick),
            Early =
                case careful() of
                    true -> renew_ms() div 2;
                    false -> 0
                end,
            Now = now_ms(),
            {Gone, Kept} = lists:partition(
                fun({_, D}) -> Now >= D - Early end, Leases
            ),
            [P ! {chappe_cluster, L, lost} || {#{pid := P} = L, _} <- Gone],
            renewer_loop(Kept)
    end.

%% ---- the facade the lab calls ----

-spec claim(term(), map()) -> {ok, map()} | {error, term()}.
claim(Key, Opts) ->
    Pid = maps:get(pid, Opts, self()),
    case call({claim, x, Key, Pid, now_ms()}, 2000) of
        {ok, Seq, Exp} ->
            Lease = #{key => Key, seq => Seq, pid => Pid},
            ?RENEWER ! {track, Lease, Exp},
            {ok, Lease};
        {error, _} = E ->
            E
    end.

-spec fence(map()) -> {default, 1, pos_integer()}.
fence(#{seq := S}) -> {default, 1, S}.

-spec release(map()) -> ok.
release(#{key := K, seq := S} = Lease) ->
    ?RENEWER ! {untrack, Lease},
    ?SERVER ! {release, K, S},
    ok.

%% ---- singletons: contend every 200 ms, stop the child on lost ----

-spec singleton(atom(), map()) -> ok.
singleton(Name, Spec) ->
    _ = spawn(fun() -> contender(Name, Spec) end),
    ok.

-spec singleton_fence(atom()) -> {ok, term()} | none.
singleton_fence(Name) ->
    Ref = make_ref(),
    contender_name(Name) ! {fence, self(), Ref},
    receive
        {Ref, F} -> F
    after 5000 -> none
    end.

contender_name(Name) ->
    list_to_atom("chappe_cluster_lab_fake_single_" ++ atom_to_list(Name)).

contender(Name, Spec) ->
    register(contender_name(Name), self()),
    process_flag(trap_exit, true),
    contend(Name, Spec, none).

contend(Name, Spec, none) ->
    receive
        {fence, From, Ref} ->
            From ! {Ref, none},
            contend(Name, Spec, none)
    after 200 ->
        case claim({chappe_cluster_singleton, Name}, #{}) of
            {ok, Lease} ->
                #{start := {M, F, A}} = Spec,
                {ok, Child} = apply(M, F, A),
                contend(Name, Spec, {Lease, Child});
            _ ->
                contend(Name, Spec, none)
        end
    end;
contend(Name, Spec, {Lease, Child} = Held) ->
    receive
        {fence, From, Ref} ->
            From ! {Ref, {ok, fence(Lease)}},
            contend(Name, Spec, Held);
        {chappe_cluster, Lease, lost} ->
            exit(Child, shutdown),
            receive
                {'EXIT', Child, _} -> ok
            end,
            contend(Name, Spec, none);
        {'EXIT', Child, _} ->
            release(Lease),
            contend(Name, Spec, none)
    end.
