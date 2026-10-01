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

-include("chappe_sip.hrl").

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
    case request_uri(chappe_sip_msg:uri(Msg)) of
        ok ->
            run_1(Msg, TxnH, Meta, Res, Middlewares, Handler);
        {Status, Reason} ->
            _ = chappe_sip_res:send(Res, Status, #{reason => Reason})
    end.

%% RFC 3261 8.2.2.1: a scheme we do not serve is a 416. tel and urn
%% (urn:service:sos, RFC 5031) reach the handler with sip and sips. A SIP
%% URI with an @ must have a user (19.1.1).
request_uri(Uri) ->
    case binary:split(Uri, <<":">>) of
        [Scheme, Rest] ->
            case string:lowercase(Scheme) of
                S when S =:= <<"sip">>; S =:= <<"sips">> -> sip_user(Rest);
                S when S =:= <<"tel">>; S =:= <<"urn">> -> ok;
                _ -> {416, <<"Unsupported URI Scheme">>}
            end;
        _ ->
            {416, <<"Unsupported URI Scheme">>}
    end.

sip_user(<<"@", _/binary>>) -> {400, <<"Empty User In Request-URI">>};
sip_user(_) -> ok.

run_1(Msg, TxnH, Meta, Res, Middlewares, Handler) ->
    case unsupported_extensions(Msg) of
        [] ->
            case body_understood(Msg) of
                true ->
                    dispatch(Msg, TxnH, Meta, Res, Middlewares, Handler);
                false ->
                    %% RFC 3261 8.2.3: a session body we cannot read is a
                    %% 415 listing the types we take
                    _ = chappe_sip_res:send(Res, 415, #{
                        reason => <<"Unsupported Media Type">>,
                        headers => [
                            {<<"Accept">>, ?ACCEPT},
                            {<<"Accept-Encoding">>, <<"identity">>}
                        ]
                    })
            end;
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

%% The body of an INVITE sets up the session: an SDP offer, possibly in a
%% multipart with other parts (SIPREC metadata, a PIDF-LO location). Any
%% other type, or an encoding, is not something we can answer, unless its
%% Content-Disposition says handling=optional (RFC 3261 8.2.3, 20.11).
body_understood(Msg) ->
    case {chappe_sip_msg:method(Msg), chappe_sip_msg:body(Msg)} of
        {<<"INVITE">>, Body} when Body =/= <<>> ->
            optional(chappe_sip_msg:get(<<"content-disposition">>, Msg)) orelse
                (identity(chappe_sip_msg:get(<<"content-encoding">>, Msg)) andalso
                    known_type(chappe_sip_msg:get(<<"content-type">>, Msg)));
        _ ->
            true
    end.

optional(undefined) ->
    false;
optional(Disposition) ->
    re:run(Disposition, ";\\s*handling\\s*=\\s*optional", [caseless]) =/=
        nomatch.

identity(undefined) -> true;
identity(Enc) -> string:lowercase(string:trim(Enc)) =:= <<"identity">>.

known_type(undefined) ->
    %% no Content-Type on a body: RFC 3261 20.15 requires one
    false;
known_type(CT) ->
    [Type | _] = binary:split(CT, <<";">>),
    lists:member(string:lowercase(string:trim(Type)), [
        <<"application/sdp">>,
        <<"multipart/mixed">>,
        <<"multipart/alternative">>
    ]).

%% option-tags in Require/Proxy-Require we do not support (RFC 3261 8.2.2).
%% We understand ?SUPPORTED_TAGS (100rel, replaces, timer, and for REFER
%% tdialog and norefersub); anything else is a 420.
unsupported_extensions(Msg) ->
    Tags =
        option_tags(chappe_sip_msg:get_all(<<"require">>, Msg)) ++
            option_tags(chappe_sip_msg:get_all(<<"proxy-require">>, Msg)),
    [T || T <- Tags, not lists:member(T, ?SUPPORTED_TAGS)].

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
