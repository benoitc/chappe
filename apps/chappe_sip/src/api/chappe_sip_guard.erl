%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc A middleware that turns away unwanted requests before any handler
%% runs: scanners by User-Agent, sources outside an allow list or inside a
%% deny list, and sources sending faster than a rate.
%%
%%   ok = chappe_sip:use(chappe_sip_guard:new(#{
%%       user_agents => [<<"friendly-scanner">>, <<"^sipvicious">>],
%%       deny => [<<"192.0.2.0/24">>],
%%       rate => #{rate => 20, burst => 40},
%%       action => 403
%%   })).
%%
%% Opts:
%%   user_agents => [Regex]  a User-Agent matching one (caseless) is
%%                           turned away
%%   allow => [Cidr]         when set, only these sources pass
%%   deny => [Cidr]          these sources are turned away
%%   rate => #{rate := number(), burst => pos_integer()}
%%                           a token bucket per source address: rate
%%                           requests a second, burst at once (default
%%                           twice the rate)
%%   action => 403 | 503 | drop (default 403)
%%   block_ms => non_neg_integer()  with drop, how long the stack then
%%                           discards every request from that source
%%                           before making a transaction of it (default
%%                           30000; 0 blocks nothing)
%%
%% drop sends no response. The request that tripped the guard is ended
%% without a word (chappe_sip_engine:discard/1), and its source goes on the
%% stack's blocklist for block_ms, so a flood from it costs no transaction
%% (UDP, TCP and TLS; over WebSocket each request reaches the guard). A
%% request whose source address is unknown passes the deny list and the
%% rate limit, and fails a non-empty allow list.
-module(chappe_sip_guard).

-export([new/1, init_table/0]).
-export_type([opts/0]).

-type opts() :: #{
    user_agents => [iodata()],
    allow => [binary()],
    deny => [binary()],
    rate => #{rate := number(), burst => pos_integer()},
    action => 403 | 503 | drop,
    block_ms => non_neg_integer()
}.
-type verdict() :: pass | {block, user_agent | source | rate}.

-define(TAB, chappe_sip_guard).
-define(BLOCK_MS, 30000).
%% buckets idle long enough to be full again are swept every this many
%% checks
-define(SWEEP_EVERY, 1024).

%% The table of the rate buckets, owned by chappe_sip_sup.
-spec init_table() -> ok.
init_table() ->
    _ = ets:new(?TAB, [
        named_table, public, set, {write_concurrency, true}
    ]),
    ok.

%% A middleware for chappe_sip:use/1,2.
-spec new(opts()) -> chappe_sip_middleware:mw().
new(Opts) ->
    Guard = compile(Opts),
    Action =
        case maps:get(action, Opts, 403) of
            drop -> {drop, maps:get(block_ms, Opts, ?BLOCK_MS)};
            A -> A
        end,
    fun(Req, Res, Next) ->
        case check(Guard, Req) of
            pass ->
                Next();
            {block, Why} ->
                chappe_sip_metrics:guard_blocked(Why),
                logger:debug(
                    "chappe_sip_guard: ~p from ~p turned away (~p)",
                    [
                        chappe_sip_req:method(Req),
                        chappe_sip_req:source_ip(Req),
                        Why
                    ]
                ),
                turn_away(Action, Req, Res)
        end
    end.

-spec check(map(), chappe_sip_req:req()) -> verdict().
check(G, Req) ->
    Ip = source(Req),
    case user_agent_denied(G, Req) of
        true ->
            {block, user_agent};
        false ->
            case source_denied(G, Ip) of
                true ->
                    {block, source};
                false ->
                    case take_token(G, Ip) of
                        true -> pass;
                        false -> {block, rate}
                    end
            end
    end.

turn_away({drop, BlockMs}, Req, Res) ->
    %% nothing on the wire, and no 500 when the worker ends
    ok = chappe_sip_res:mark_final(Res),
    case chappe_sip_res:req_txn(Res) of
        undefined -> ok;
        TxnH -> chappe_sip_engine:discard(TxnH)
    end,
    case chappe_sip_req:source_ip(Req) of
        Ip when is_binary(Ip), BlockMs > 0 ->
            chappe_sip_engine:block_source(Ip, BlockMs);
        _ ->
            ok
    end;
turn_away(503, _Req, Res) ->
    _ = chappe_sip_res:send(Res, 503, #{reason => <<"Service Unavailable">>}),
    ok;
turn_away(_Forbidden, _Req, Res) ->
    _ = chappe_sip_res:send(Res, 403, #{reason => <<"Forbidden">>}),
    ok.

%% ---- checks ----

compile(Opts) ->
    Nets = fun(Key) ->
        [N || C <- maps:get(Key, Opts, []), {ok, N} <- [chappe_sip_net:cidr(C)]]
    end,
    Rate =
        case maps:get(rate, Opts, undefined) of
            #{rate := R} = RO when is_number(R), R > 0 ->
                {R, maps:get(burst, RO, max(1, round(R * 2)))};
            _ ->
                undefined
        end,
    #{
        id => make_ref(),
        user_agents => [
            Re
         || P <- maps:get(user_agents, Opts, []),
            {ok, Re} <- [re:compile(P, [caseless])]
        ],
        allow => Nets(allow),
        deny => Nets(deny),
        rate => Rate
    }.

user_agent_denied(#{user_agents := []}, _Req) ->
    false;
user_agent_denied(#{user_agents := Res}, Req) ->
    case chappe_sip_req:get(<<"user-agent">>, Req) of
        undefined -> false;
        UA -> lists:any(fun(Re) -> re:run(UA, Re) =/= nomatch end, Res)
    end.

source_denied(#{allow := Allow}, undefined) ->
    Allow =/= [];
source_denied(#{allow := Allow, deny := Deny}, Ip) ->
    (Allow =/= [] andalso
        not lists:any(fun(N) -> chappe_sip_net:in_net(Ip, N) end, Allow)) orelse
        lists:any(fun(N) -> chappe_sip_net:in_net(Ip, N) end, Deny).

source(Req) ->
    case chappe_sip_net:address(chappe_sip_req:source_ip(Req)) of
        {ok, Ip} -> Ip;
        error -> undefined
    end.

%% ---- token bucket ----

take_token(#{rate := undefined}, _Ip) ->
    true;
take_token(_G, undefined) ->
    true;
take_token(#{rate := {Rate, Burst}, id := Id}, Ip) ->
    Now = erlang:monotonic_time(millisecond),
    Key = {Id, Ip},
    {Tokens0, Last} =
        case ets:lookup(?TAB, Key) of
            [{_, T, L}] -> {T, L};
            [] -> {float(Burst), Now}
        end,
    Tokens = min(float(Burst), Tokens0 + (Now - Last) * Rate / 1000),
    maybe_sweep(Id, Now - round(Burst * 1000 / Rate)),
    case Tokens >= 1.0 of
        true ->
            true = ets:insert(?TAB, {Key, Tokens - 1.0, Now}),
            true;
        false ->
            true = ets:insert(?TAB, {Key, Tokens, Now}),
            false
    end.

%% drop the buckets of this guard idle since before Cutoff: they are full
%% again, the same as no bucket
maybe_sweep(Id, Cutoff) ->
    N = ets:update_counter(?TAB, {Id, checks}, 1, {{Id, checks}, 0, 0}),
    case N rem ?SWEEP_EVERY of
        0 ->
            _ = ets:select_delete(?TAB, [
                {{{Id, '_'}, '_', '$1'}, [{'<', '$1', Cutoff}], [true]}
            ]),
            ok;
        _ ->
            ok
    end.
