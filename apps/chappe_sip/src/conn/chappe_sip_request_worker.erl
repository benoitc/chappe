%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc One process per inbound out-of-dialog request.
%%
%% "A call is a process": the worker parses the raw message, runs the
%% middleware chain and the method handler, and IS the application's
%% call context. A handler that works asynchronously simply does not
%% return until it is done. Exiting without a final response means the
%% engine's monitor sends 500 (see chappe_sip_engine).
%%
%% Extensions: as a UAS (the default) the worker answers 420 to an option
%% tag in Require it does not support, and ignores Proxy-Require (RFC 3261
%% 8.2.2.3). A route registered with `proxy => true', and the in-dialog
%% forwarding of a dialog we record-routed, act as a proxy instead: Require
%% is the UAS's business and only Proxy-Require is checked (16.3 step 5,
%% where we support no proxy extension). ACK and CANCEL are never checked.
-module(chappe_sip_request_worker).

-include("chappe_sip.hrl").

-export([start_link/1]).
-export([init/1]).

start_link(Args) ->
    proc_lib:start_link(?MODULE, init, [Args]).

init(
    #{
        raw := Raw,
        txn := TxnH,
        meta := Meta0,
        res := Res,
        middlewares := Middlewares,
        handler := Handler
    } = Args
) ->
    proc_lib:init_ack({ok, self()}),
    %% the route's extra option tags ride on the request, so a dialog it
    %% creates accepts them in Require too
    Meta = Meta0#{
        option_tags => maps:get(option_tags, Args, []),
        role => maps:get(role, Args, uas)
    },
    case parse_valid(Raw) of
        {ok, Msg} ->
            %% the call this request starts (or a request of its own)
            Meta1 = Meta#{call_ref => chappe_sip_call:new_ref()},
            run(
                Msg, TxnH, open_cdr(Msg, TxnH, Meta1), Res, Middlewares, Handler
            );
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
            case chappe_sip_lib:lower(Scheme) of
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
    case unsupported_extensions(Msg, Meta) of
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
            %% RFC 3261 8.2.2.3 (16.3 step 5 for a proxy): an option tag
            %% we do not understand is a 420 listing the unsupported tags
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

dispatch(Msg, TxnH, Meta0, Res, Middlewares, Handler) ->
    {CallRef, Meta} = maps:take(call_ref, Meta0),
    Req = chappe_sip_req:new(Msg, TxnH, Meta, CallRef),
    Method = chappe_sip_msg:method(Msg),
    %% expose Res so helpers that complete the transaction directly
    %% (proxy_request) can mark it final and avoid a spurious 500
    put(chappe_sip_current_res, Res),
    Chain = chappe_sip_middleware:select(Middlewares, Method),
    try
        chappe_sip_middleware:run(Chain, Handler, Req, Res)
    catch
        exit:Reason when
            Reason =:= normal orelse
                (is_tuple(Reason) andalso tuple_size(Reason) =:= 2 andalso
                    element(1, Reason) =:= shutdown)
        ->
            %% a handler done with the request may end its process; after
            %% a final response that is no crash. Without one the engine
            %% still answers 500 when the worker is gone.
            case chappe_sip_res:finished(Res) of
                true -> exit(Reason);
                false -> crashed(exit, Reason, [], Res)
            end;
        Class:Reason:Stack ->
            crashed(Class, Reason, Stack, Res)
    end.

-spec crashed(error | exit | throw, term(), list(), chappe_sip_res:res()) ->
    no_return().
crashed(Class, Reason, Stack, Res) ->
    logger:error(
        "chappe_sip request handler crashed: ~p:~p~n~p",
        [Class, Reason, Stack]
    ),
    _ = chappe_sip_res:send(Res, 500),
    exit({handler_crashed, {Class, Reason}}).

%% An INVITE starting a call opens its call record, driven by this worker
%% until a dialog takes it over; its id rides on the request (meta cdr).
%% A HEP capture server learns the call_ref of its Call-ID.
open_cdr(Msg, TxnH, #{call_ref := CallRef} = Meta) ->
    _ =
        chappe_sip_msg:method(Msg) =:= <<"INVITE">> andalso
            chappe_sip_msg:to_tag(Msg) =:= undefined andalso
            chappe_sip_hep:correlate(chappe_sip_msg:call_id(Msg), CallRef, uas),
    case
        chappe_sip_msg:method(Msg) =:= <<"INVITE">> andalso
            chappe_sip_msg:to_tag(Msg) =:= undefined andalso
            chappe_sip_cdr:active()
    of
        true ->
            Role =
                case maps:get(role, Meta, uas) of
                    proxy -> proxy;
                    _ -> uas
                end,
            Id = chappe_sip_cdr:open(
                Role,
                #{
                    txn => TxnH,
                    call_ref => CallRef,
                    call_id => chappe_sip_msg:call_id(Msg),
                    from => chappe_sip_msg:get(<<"from">>, Msg),
                    to => chappe_sip_msg:get(<<"to">>, Msg),
                    request_uri => chappe_sip_msg:uri(Msg),
                    remote_tag => chappe_sip_msg:from_tag(Msg),
                    transport => maps:get(transport, Meta, undefined),
                    source => source(Meta)
                },
                self()
            ),
            Meta#{cdr => Id};
        false ->
            Meta
    end.

source(#{source_ip := Ip, source_port := Port}) when
    is_binary(Ip), is_integer(Port)
->
    <<Ip/binary, ":", (integer_to_binary(Port))/binary>>;
source(#{source_ip := Ip}) when is_binary(Ip) ->
    Ip;
source(_Meta) ->
    undefined.

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

identity(undefined) ->
    true;
identity(Enc) ->
    chappe_sip_lib:lower(chappe_sip_lib:trim(Enc)) =:= <<"identity">>.

known_type(undefined) ->
    %% no Content-Type on a body: RFC 3261 20.15 requires one
    false;
known_type(CT) ->
    [Type | _] = binary:split(CT, <<";">>),
    lists:member(chappe_sip_lib:lower(chappe_sip_lib:trim(Type)), [
        <<"application/sdp">>,
        <<"multipart/mixed">>,
        <<"multipart/alternative">>
    ]).

%% The option tags the request needs that we do not support: those of
%% Require for a UAS, of Proxy-Require for a proxy; none for ACK and CANCEL,
%% which must not carry them and whose values are ignored (8.2.2.3).
unsupported_extensions(Msg, Meta) ->
    case chappe_sip_msg:method(Msg) of
        M when M =:= <<"ACK">>; M =:= <<"CANCEL">> ->
            [];
        _ ->
            case maps:get(role, Meta, uas) of
                proxy ->
                    chappe_sip_msg:option_tags(<<"proxy-require">>, Msg);
                uas ->
                    Supported =
                        chappe_sip_config:get(supported_option_tags) ++
                            maps:get(option_tags, Meta, []),
                    [
                        T
                     || T <- chappe_sip_msg:option_tags(<<"require">>, Msg),
                        not lists:member(T, lower_all(Supported))
                    ]
            end
    end.

lower_all(Tags) ->
    [chappe_sip_lib:lower(T) || T <- Tags].
