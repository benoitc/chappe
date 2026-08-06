%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc One process per inbound out-of-dialog request.
%%
%% "A call is a process": the worker parses the raw message, runs the
%% middleware chain and the method handler, and IS the application's
%% call context. A handler that works asynchronously simply does not
%% return until it is done. Exiting without a final response means the
%% engine's monitor sends 500 (see chappe_sip_engine).
-module(chappe_sip_request_worker).

-export([start_link/1]).
-export([init/1]).

start_link(Args) ->
    proc_lib:start_link(?MODULE, init, [Args]).

init(#{
    raw := Raw,
    txn := TxnH,
    meta := Meta,
    res := Res,
    middlewares := Middlewares,
    handler := Handler
}) ->
    proc_lib:init_ack({ok, self()}),
    case parse_valid(Raw) of
        {ok, Msg} ->
            run(Msg, TxnH, Meta, Res, Middlewares, Handler);
        {error, Why} ->
            %% unparseable or missing a mandatory header (RFC 3261 8.1.1)
            logger:warning("chappe_sip: bad request (~p)", [Why]),
            _ = chappe_sip_res:send(Res, 400)
    end.

parse_valid(Raw) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, Msg} ->
            case chappe_sip_msg:validate(Msg) of
                ok -> {ok, Msg};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

run(Msg, TxnH, Meta, Res, Middlewares, Handler) ->
    case unsupported_extensions(Msg) of
        [] ->
            dispatch(Msg, TxnH, Meta, Res, Middlewares, Handler);
        Bad ->
            %% RFC 3261 8.2.2: an option-tag we do not understand in
            %% Require/Proxy-Require is a 420 listing the unsupported tags
            _ = chappe_sip_res:send(
                Res,
                420,
                #{
                    reason => <<"Bad Extension">>,
                    headers => [
                        {<<"Unsupported">>,
                            iolist_to_binary(
                                lists:join(<<", ">>, Bad)
                            )}
                    ]
                }
            )
    end.

dispatch(Msg, TxnH, Meta, Res, Middlewares, Handler) ->
    Req = chappe_sip_req:new(Msg, TxnH, Meta),
    Method = chappe_sip_msg:method(Msg),
    %% expose Res so helpers that complete the transaction directly
    %% (proxy_request) can mark it final and avoid a spurious 500
    put(chappe_sip_current_res, Res),
    Chain = chappe_sip_middleware:select(Middlewares, Method),
    try
        chappe_sip_middleware:run(Chain, Handler, Req, Res)
    catch
        Class:Reason:Stack ->
            logger:error(
                "chappe_sip request handler crashed: ~p:~p~n~p",
                [Class, Reason, Stack]
            ),
            _ = chappe_sip_res:send(Res, 500),
            exit({handler_crashed, {Class, Reason}})
    end.

%% option-tags in Require/Proxy-Require we do not support (RFC 3261 8.2.2).
%% We understand 100rel; anything else triggers a 420.
unsupported_extensions(Msg) ->
    Tags =
        option_tags(chappe_sip_msg:get_all(<<"require">>, Msg)) ++
            option_tags(chappe_sip_msg:get_all(<<"proxy-require">>, Msg)),
    [T || T <- Tags, not lists:member(T, [<<"100rel">>])].

option_tags(Values) ->
    [
        T1
     || V <- Values,
        T <- binary:split(V, <<",">>, [global]),
        T1 <- [trim(T)],
        T1 =/= <<>>
    ].

trim(B) ->
    list_to_binary(string:trim(binary_to_list(B))).
