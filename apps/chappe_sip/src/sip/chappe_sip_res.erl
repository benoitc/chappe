%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Outbound response handle for an inbound request.
%%
%% Carries the duplicate-final guard: send/2,3 refuses a second final
%% response. In M1 the sender is a fun injected by the engine layer (M2
%% wires it to the shim; tests wire it to self()).
-module(chappe_sip_res).

-export([new/2, new/3]).
-export([
    send/2, send/3,
    send_reliable/2,
    await_prack/1, await_prack/2,
    prack_res/2,
    finished/1,
    mark_final/1,
    req_txn/1
]).

-record(res, {
    txn :: non_neg_integer() | undefined,
    sender :: fun(
        (non_neg_integer() | undefined, 100..699, map()) -> ok | {error, term()}
    ),
    final = atomics:new(1, []) :: atomics:atomics_ref()
}).

-opaque res() :: #res{}.
-export_type([res/0]).

-spec new(non_neg_integer() | undefined, fun()) -> res().
new(TxnH, Sender) when is_function(Sender, 3) ->
    #res{txn = TxnH, sender = Sender}.

%% Share the duplicate-final guard with the engine so its worker monitor
%% can tell whether a final response went out.
-spec new(non_neg_integer() | undefined, fun(), atomics:atomics_ref()) ->
    res().
new(TxnH, Sender, Final) when is_function(Sender, 3) ->
    #res{txn = TxnH, sender = Sender, final = Final}.

-spec send(res(), 100..699) -> ok | {error, already_final | term()}.
send(Res, Status) ->
    send(Res, Status, #{}).

%% Opts: #{reason => binary(), headers => [{binary(), iodata()}],
%%         body => iodata()}
-spec send(res(), 100..699, map()) -> ok | {error, already_final | term()}.
send(#res{txn = TxnH, sender = Sender, final = Final}, Status, Opts) when
    Status >= 100, Status =< 699
->
    case {atomics:get(Final, 1), Status >= 200} of
        {1, _} ->
            {error, already_final};
        {0, false} ->
            % provisional
            Sender(TxnH, Status, Opts);
        {0, true} ->
            %% send first; mark final only if it actually went out, so a
            %% failed send does not suppress the worker's fallback 500
            case Sender(TxnH, Status, Opts) of
                {error, _} = Err ->
                    Err;
                R ->
                    atomics:put(Final, 1, 1),
                    R
            end
    end.

%% Send a reliable provisional (100rel). Opts as send/3 plus a To tag for
%% the early dialog. nta retransmits it until the PRACK; use await_prack/2
%% to block for the PRACK before sending the next reliable 1xx or the final.
-spec send_reliable(res(), map()) -> ok | {error, term()}.
send_reliable(Res, Opts) ->
    Status = maps:get(status, Opts, 183),
    send(Res, Status, Opts#{reliable => true}).

%% Block until the PRACK for a reliable provisional arrives (or timeout).
%% {ok, Raw}: the stack answered it 200. {offer, Raw, PrackRes}: it
%% carries an offer (RFC 3262 5), answer it with send/3 on PrackRes: a
%% 2xx whose body is your SDP answer.
-spec await_prack(res()) ->
    {ok, binary()} | {offer, binary(), res()} | {error, timeout}.
await_prack(Res) ->
    await_prack(Res, 8000).

-spec await_prack(res(), timeout()) ->
    {ok, binary()} | {offer, binary(), res()} | {error, timeout}.
await_prack(#res{txn = TxnH} = Res, Timeout) ->
    receive
        {chappe_sip_prack, TxnH, Raw} ->
            {ok, Raw};
        {chappe_sip_prack, TxnH, Raw, PrackH} ->
            {offer, Raw, prack_res(Res, PrackH)}
    after Timeout -> {error, timeout}
    end.

%% The response handle of a PRACK that carries an offer, from the handle
%% of its INVITE.
-spec prack_res(res(), non_neg_integer()) -> res().
prack_res(#res{sender = Sender}, PrackH) ->
    new(PrackH, Sender).

-spec finished(res()) -> boolean().
finished(#res{final = Final}) ->
    atomics:get(Final, 1) =:= 1.

%% Mark the response as answered without sending (used when a dialog was
%% created and the final response went out through the dialog path, so
%% the request worker's exit must not trigger a spurious 500).
-spec mark_final(res()) -> ok.
mark_final(#res{final = Final}) ->
    atomics:put(Final, 1, 1),
    ok.

-spec req_txn(res()) -> non_neg_integer() | undefined.
req_txn(#res{txn = T}) -> T.
