%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The RFC 6026 Accepted state of a proxy INVITE, off the request
%% worker: after the first 2xx, forward each new 2xx (a To-tag not seen
%% yet) for 64*T1 (proxy_accepted_ms), absorb retransmissions, drain the
%% CANCELled branches, then release every client transaction.
-module(chappe_sip_proxy_accepted).

-export([start/3]).

%% Hand the client transactions (the winner's first) to the process that
%% stays in the Accepted state. Responses that reached the caller before
%% the handover go to it too.
-spec start(non_neg_integer(), binary(), [non_neg_integer()]) -> ok.
start(WinTxn, WinRaw, Others) ->
    Txns = [WinTxn | Others],
    Seen = [to_tag(WinRaw)],
    Window = chappe_sip_config:get(proxy_accepted_ms),
    Pid = spawn(fun() ->
        receive
            {chappe_sip_proxy_accepted, go} -> ok
        after 5000 -> ok
        end,
        loop(Txns, Seen, erlang:monotonic_time(millisecond) + Window)
    end),
    lists:foreach(fun(H) -> chappe_sip_engine:reg_handle(H, Pid) end, Txns),
    hand_over(Txns, Pid),
    Pid ! {chappe_sip_proxy_accepted, go},
    ok.

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

loop(Txns, Seen, Until) ->
    receive
        {chappe_sip_response, TxnH, #{status := St}, Raw} when
            St >= 200, St < 300
        ->
            Tag = to_tag(Raw),
            case lists:member(Tag, Seen) of
                true ->
                    loop(Txns, Seen, Until);
                false ->
                    %% a forked 2xx: forward with our top Via intact
                    _ = chappe_sip_engine:forward_response(Raw),
                    loop(lists:usort([TxnH | Txns]), [Tag | Seen], Until)
            end;
        {chappe_sip_response, _TxnH, _Meta, _Raw} ->
            loop(Txns, Seen, Until);
        {chappe_sip_op, _TxnH, _} ->
            loop(Txns, Seen, Until)
    after max(0, Until - erlang:monotonic_time(millisecond)) ->
        lists:foreach(fun chappe_sip_engine:finish_txn/1, Txns)
    end.

to_tag(Raw) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, M} -> chappe_sip_msg:to_tag(M);
        {error, _} -> undefined
    end.
