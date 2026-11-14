%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The RFC 6026 Accepted state of a proxy INVITE, off the request
%% worker: after the first 2xx, forward each new 2xx (a To-tag not seen
%% yet) for 64*T1 (proxy_accepted_ms), absorb retransmissions, drain the
%% CANCELled branches, then release every client transaction.
%%
%% One temporary process per proxied INVITE, under chappe_sip_proxy_sup.
%% It owns the client transactions it is handed (chappe_sip_engine
%% monitors it: if it crashes the engine releases them), and nothing else:
%% the call it belongs to was answered already and goes on without it.
%% Bounded: every new 2xx is forwarded (RFC 3261 16.7 step 10, RFC 6026
%% 8.4: one out for one in, no amplification), but it remembers at most
%% ?MAX_SEEN To-tags, the oldest dropped first, so a downstream element
%% sending 2xx after 2xx with new tags cannot grow it for the whole
%% window. A retransmission of a forgotten tag is forwarded again, which
%% upstream absorbs.
-module(chappe_sip_proxy_accepted).
-behaviour(gen_server).

-export([start/3, start_link/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(MAX_SEEN, 64).

-record(state, {
    txns :: [non_neg_integer()],
    seen :: [binary() | undefined]
}).
-type state() :: #state{}.

%% Hand the client transactions (the winner's first) to a new Accepted
%% process. Responses that reached the caller before the handover go to it
%% too.
-spec start(non_neg_integer(), binary(), [non_neg_integer()]) -> ok.
start(WinTxn, WinRaw, Others) ->
    Txns = [WinTxn | Others],
    case supervisor:start_child(chappe_sip_proxy_sup, [Txns, WinRaw, self()]) of
        {ok, Pid} ->
            lists:foreach(
                fun(H) -> chappe_sip_engine:reg_handle(H, Pid) end, Txns
            ),
            hand_over(Txns, Pid),
            ok;
        {error, Reason} ->
            %% no Accepted state: release the transactions now rather than
            %% leave them to nobody
            logger:warning(
                "chappe_sip_proxy_accepted: not started (~p)", [Reason]
            ),
            lists:foreach(fun chappe_sip_engine:finish_txn/1, Txns)
    end.

-spec start_link([non_neg_integer()], binary(), pid()) -> {ok, pid()}.
start_link(Txns, WinRaw, Caller) ->
    gen_server:start_link(?MODULE, {Txns, WinRaw, Caller}, []).

hand_over(Txns, Pid) ->
    receive
        {chappe_sip_response, H, _, _} = M ->
            case lists:member(H, Txns) of
                true -> Pid ! M;
                false -> ok
            end,
            hand_over(Txns, Pid)
    after 0 -> ok
    end.

-spec init({[non_neg_integer()], binary(), pid()}) -> {ok, state()}.
init({Txns, WinRaw, _Caller}) ->
    _ = erlang:send_after(
        chappe_sip_config:get(proxy_accepted_ms), self(), window_closed
    ),
    {ok, #state{txns = Txns, seen = [to_tag(WinRaw)]}}.

handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({chappe_sip_response, TxnH, #{status := St}, Raw}, S) when
    St >= 200, St < 300
->
    {noreply, two_xx(TxnH, Raw, S)};
handle_info({chappe_sip_response, _TxnH, _Meta, _Raw}, S) ->
    {noreply, S};
handle_info({chappe_sip_op, _TxnH, _}, S) ->
    {noreply, S};
handle_info(window_closed, #state{txns = Txns} = S) ->
    lists:foreach(fun chappe_sip_engine:finish_txn/1, Txns),
    {stop, normal, S};
handle_info(Other, S) ->
    logger:debug("chappe_sip_proxy_accepted: unexpected ~p", [Other]),
    {noreply, S}.

%% a 2xx with a new To-tag is a fork downstream: forward it with our top
%% Via intact
two_xx(TxnH, Raw, #state{seen = Seen} = S) ->
    Tag = to_tag(Raw),
    case lists:member(Tag, Seen) of
        true ->
            S;
        false ->
            _ = chappe_sip_engine:forward_response(Raw),
            S#state{
                txns = lists:usort([TxnH | S#state.txns]),
                seen = lists:sublist([Tag | Seen], ?MAX_SEEN)
            }
    end.

to_tag(Raw) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, M} -> chappe_sip_msg:to_tag(M);
        {error, _} -> undefined
    end.
