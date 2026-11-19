%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The message code of the WebSocket transaction layer, with no state.
%%
%% Builds what chappe_sip_ws_transport sends (responses, the CANCEL and the
%% ACK of a non-2xx final, the top Via of an originated request) and reads
%% what it matches on (the Via branch, CSeq, RAck, Content-Length). Every
%% function here is pure, except that a new branch or a minted To-tag is
%% random.
-module(chappe_sip_ws_msg).

-export([frame/1, content_length/1, rack/1, peer_100rel/1, tag_of/1]).
-export([via_branch/1, cseq_method/1, req_seq/1, request_method/1]).
-export([insert_via/3, ensure_via/2, new_branch/0]).
-export([build_cancel/2, build_ack/2, build_response/7]).
-ifdef(TEST).
-export([add_received/2, record_route/3, reason/1]).
-endif.

-export_type([peer/0]).

%% the source of a request, as the connection reports it
-type peer() :: {inet:ip_address(), inet:port_number()} | term().

%% RFC 7118 4.2: a SIP message goes out in a text frame when it is valid
%% UTF-8 and in a binary frame otherwise (a binary body, say).
-spec frame(binary()) -> {text | binary, binary()}.
frame(Raw) ->
    case unicode:characters_to_binary(Raw) of
        Raw -> {text, Raw};
        _ -> {binary, Raw}
    end.

%% RFC 3261 18.3 / 20.14: the body is what Content-Length says. A WS message
%% frames the SIP message, so the header may be absent; when present it is
%% one non-negative integer equal to the body size.
-spec content_length(chappe_sip_msg:msg()) -> ok | binary().
content_length(Msg) ->
    Size = byte_size(chappe_sip_msg:body(Msg)),
    case chappe_sip_msg:get_all(<<"content-length">>, Msg) of
        [] ->
            ok;
        [V] ->
            case string:to_integer(string:trim(V)) of
                {Size, <<>>} -> ok;
                _ -> <<"Bad Content-Length">>
            end;
        _ ->
            <<"Bad Content-Length">>
    end.

%% The RSeq and CSeq numbers of a PRACK's RAck (RFC 3262 7.2).
-spec rack(chappe_sip_msg:msg()) -> {ok, integer(), integer()} | error.
rack(Msg) ->
    case chappe_sip_msg:get(<<"rack">>, Msg) of
        undefined ->
            error;
        V ->
            case words(V) of
                [R, C, _Method] ->
                    try
                        {ok, binary_to_integer(R), binary_to_integer(C)}
                    catch
                        _:_ -> error
                    end;
                _ ->
                    error
            end
    end.

%% The request offered or required 100rel (RFC 3262 3).
-spec peer_100rel(chappe_sip_msg:msg()) -> boolean().
peer_100rel(Msg) ->
    Tokens = [
        string:lowercase(string:trim(Tok))
     || H <- [<<"supported">>, <<"require">>],
        V <- chappe_sip_msg:get_all(H, Msg),
        Tok <- binary:split(V, <<",">>, [global])
    ],
    lists:member(<<"100rel">>, Tokens).

%% The tag of a From or To value, <<>> when it has none.
-spec tag_of(binary()) -> binary().
tag_of(NameAddr) ->
    case chappe_sip_hdr:name_addr(NameAddr) of
        {ok, #{params := P}} -> maps:get(<<"tag">>, P, <<>>);
        _ -> <<>>
    end.

%% ---- matching ----

-spec via_branch(chappe_sip_msg:msg()) -> binary().
via_branch(Msg) ->
    case chappe_sip_msg:get(<<"via">>, Msg) of
        undefined ->
            <<>>;
        V ->
            case
                re:run(
                    V,
                    <<"branch=([^;\\s,]+)">>,
                    [{capture, [1], binary}]
                )
            of
                {match, [B]} -> B;
                _ -> <<>>
            end
    end.

-spec cseq_method(chappe_sip_msg:msg()) -> binary() | undefined.
cseq_method(Msg) ->
    case chappe_sip_msg:cseq(Msg) of
        {ok, #{method := M}} -> M;
        _ -> undefined
    end.

-spec req_seq(chappe_sip_msg:msg()) -> integer().
req_seq(Msg) ->
    case chappe_sip_msg:cseq(Msg) of
        {ok, #{seq := N}} -> N;
        _ -> 1
    end.

-spec request_method(binary()) -> binary().
request_method(Raw) ->
    case binary:split(Raw, <<" ">>) of
        [Method, _] -> Method;
        _ -> <<>>
    end.

%% ---- Via ----

%% RFC 3261 18.2.1: add received when the sent-by host is not the source
%% address (a WS client's is a .invalid name, so in practice always); RFC
%% 3581 4: fill in rport, and add received, when the client asked with a
%% bare rport. An rport the client did not ask for is not added, and a
%% received or rport value it put there itself is replaced, never repeated.
-spec add_received(binary(), peer()) -> binary().
add_received(Via, {IP, Port}) when is_tuple(IP), is_integer(Port) ->
    IPb = list_to_binary(inet:ntoa(IP)),
    [SentBy | Params] = binary:split(Via, <<";">>, [global]),
    Names = [param_name(P) || P <- Params],
    WantsRport = lists:member(<<"rport">>, Names),
    Kept = [
        P
     || P <- Params,
        not lists:member(param_name(P), [<<"received">>, <<"rport">>])
    ],
    Received =
        case WantsRport orelse sent_by_host(SentBy) =/= IPb of
            true -> [<<"received=", IPb/binary>>];
            false -> []
        end,
    Rport =
        case WantsRport of
            true -> [<<"rport=", (integer_to_binary(Port))/binary>>];
            false -> []
        end,
    iolist_to_binary(lists:join(<<";">>, [SentBy | Kept ++ Received ++ Rport]));
add_received(Via, _Peer) ->
    Via.

param_name(P) ->
    [Name | _] = binary:split(P, <<"=">>),
    string:lowercase(string:trim(Name)).

%% the host of "SIP/2.0/WS host[:port]" (an IPv6 reference keeps no brackets)
sent_by_host(SentBy) ->
    case words(SentBy) of
        [_Proto, HostPort | _] ->
            case HostPort of
                <<"[", Rest/binary>> ->
                    hd(binary:split(Rest, <<"]">>));
                _ ->
                    hd(binary:split(HostPort, <<":">>))
            end;
        _ ->
            <<>>
    end.

words(V) ->
    binary:split(string:trim(V), [<<" ">>, <<"\t">>], [global, trim_all]).

%% Add a Via with a fresh branch after the request line, unless one is
%% already present. Used for UAC-built stateless requests (e.g. a 2xx ACK).
-spec ensure_via(binary(), ws | wss) -> binary().
ensure_via(Raw, Proto) ->
    case binary:match(Raw, <<"\r\nVia:">>) of
        nomatch -> insert_via(Raw, Proto, new_branch());
        _ -> Raw
    end.

-spec insert_via(binary(), ws | wss, binary()) -> binary().
insert_via(Raw, Proto, Branch) ->
    T =
        case Proto of
            wss -> <<"WSS">>;
            _ -> <<"WS">>
        end,
    Via =
        <<"Via: SIP/2.0/", T/binary, " ", (node_id())/binary, ";branch=",
            Branch/binary, "\r\n">>,
    case binary:split(Raw, <<"\r\n">>) of
        [ReqLine, Rest] -> <<ReqLine/binary, "\r\n", Via/binary, Rest/binary>>;
        [_] -> <<Via/binary, Raw/binary>>
    end.

-spec new_branch() -> binary().
new_branch() ->
    <<"z9hG4bK", (hex(6))/binary>>.

%% a stable-ish node identifier for our WS Via sent-by (RFC 7118 allows a
%% .invalid name; responses route by the connection, not by resolving it)
node_id() ->
    <<"chappe.invalid">>.

hex(N) ->
    binary:encode_hex(crypto:strong_rand_bytes(N), lowercase).

%% ---- CANCEL and ACK ----

%% CANCEL built from the original request: same top Via/branch, R-URI,
%% From, To (no to-tag), Call-ID, Route, CSeq number with method CANCEL.
-spec build_cancel(binary(), iodata()) -> {ok, binary()} | error.
build_cancel(Raw, Hdrs) ->
    same_branch(<<"CANCEL">>, Raw, request, Hdrs).

%% RFC 3261 17.1.1.3: the ACK of a non-2xx final has the INVITE's Request-URI,
%% top Via (so its branch), From, Call-ID, CSeq number and Route, and the To
%% of the response.
-spec build_ack(binary(), chappe_sip_msg:msg()) -> {ok, binary()} | error.
build_ack(Raw, Resp) ->
    same_branch(<<"ACK">>, Raw, Resp, <<>>).

%% A request on the transaction of Raw (its branch), with the To of the
%% request or of a response to it.
same_branch(Method, Raw, ToOf, Hdrs) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, M} ->
            Routes = [
                [<<"Route: ">>, R, <<"\r\n">>]
             || R <- chappe_sip_msg:get_all(<<"route">>, M)
            ],
            {ok,
                iolist_to_binary([
                    Method,
                    <<" ">>,
                    chappe_sip_msg:uri(M),
                    <<" SIP/2.0\r\nVia: ">>,
                    chappe_sip_msg:get(<<"via">>, M),
                    <<"\r\n">>,
                    Routes,
                    <<"Max-Forwards: 70\r\nFrom: ">>,
                    chappe_sip_msg:get(<<"from">>, M),
                    <<"\r\nTo: ">>,
                    chappe_sip_msg:get(<<"to">>, to_source(ToOf, M)),
                    <<"\r\nCall-ID: ">>,
                    chappe_sip_msg:call_id(M),
                    <<"\r\nCSeq: ">>,
                    integer_to_binary(req_seq(M)),
                    <<" ">>,
                    Method,
                    <<"\r\n">>,
                    Hdrs,
                    <<"Content-Length: 0\r\n\r\n">>
                ])};
        {error, _} ->
            error
    end.

to_source(request, M) -> M;
to_source(Resp, _M) -> Resp.

%% ---- responses ----

%% Headers the request lacks are left out, so a request missing one can
%% still be answered 400 (RFC 3261 8.2.2).
-spec build_response(
    chappe_sip_msg:msg(),
    100..699,
    binary(),
    iodata(),
    binary(),
    binary(),
    peer()
) -> binary().
build_response(ReqMsg, Status, Reason, Headers, Body, ToTag, Peer) ->
    iolist_to_binary(
        [
            <<"SIP/2.0 ">>,
            integer_to_binary(Status),
            <<" ">>,
            reason(Status, Reason),
            <<"\r\n">>,
            via_lines(chappe_sip_msg:get_all(<<"via">>, ReqMsg), Peer),
            record_route(Status, ReqMsg, Headers),
            hdr(<<"From">>, chappe_sip_msg:get(<<"from">>, ReqMsg)),
            hdr(<<"To">>, to_value(ReqMsg, Status, ToTag)),
            hdr(<<"Call-ID">>, chappe_sip_msg:call_id(ReqMsg)),
            hdr(<<"CSeq">>, chappe_sip_msg:get(<<"cseq">>, ReqMsg)),
            Headers,
            <<"Content-Length: ">>,
            integer_to_binary(byte_size(Body)),
            <<"\r\n\r\n">>,
            Body
        ]
    ).

%% RFC 3261 8.2.6.2: every response except 100 carries a To-tag. If the
%% caller gave none (an error final via shed), mint one, as nta does on UDP.
to_value(ReqMsg, Status, ToTag) ->
    To0 = chappe_sip_msg:get(<<"to">>, ReqMsg),
    case chappe_sip_msg:to_tag(ReqMsg) of
        undefined when Status > 100, is_binary(To0) ->
            Tag =
                case ToTag of
                    <<>> -> chappe_sip_dialog:gen_tag();
                    _ -> ToTag
                end,
            <<To0/binary, ";tag=", Tag/binary>>;
        _ ->
            To0
    end.

%% RFC 3261 18.2.1 / RFC 7118: stamp received/rport on the top Via
via_lines([Top | Rest], Peer) ->
    [
        [<<"Via: ">>, add_received(Top, Peer), <<"\r\n">>]
        | [[<<"Via: ">>, V, <<"\r\n">>] || V <- Rest]
    ];
via_lines([], _Peer) ->
    [].

hdr(_Name, undefined) -> [];
hdr(Name, Value) -> [Name, <<": ">>, Value, <<"\r\n">>].

%% RFC 3261 12.1.1: a UAS copies the request's Record-Route into the
%% responses that can make a dialog (101-299), unless the caller already
%% put them in its headers.
-spec record_route(100..699, chappe_sip_msg:msg(), iodata()) -> iolist().
record_route(Status, ReqMsg, Headers) when Status > 100, Status < 300 ->
    case
        binary:match(
            string:lowercase(iolist_to_binary(Headers)), <<"record-route:">>
        )
    of
        nomatch ->
            [
                [<<"Record-Route: ">>, RR, <<"\r\n">>]
             || RR <- chappe_sip_msg:get_all(<<"record-route">>, ReqMsg)
            ];
        _ ->
            []
    end;
record_route(_Status, _ReqMsg, _Headers) ->
    [].

reason(Status, <<>>) -> reason(Status);
reason(_Status, Reason) -> Reason.

-spec reason(100..699) -> binary().
reason(100) -> <<"Trying">>;
reason(180) -> <<"Ringing">>;
reason(183) -> <<"Session Progress">>;
reason(200) -> <<"OK">>;
reason(202) -> <<"Accepted">>;
reason(400) -> <<"Bad Request">>;
reason(404) -> <<"Not Found">>;
reason(405) -> <<"Method Not Allowed">>;
reason(408) -> <<"Request Timeout">>;
reason(481) -> <<"Call/Transaction Does Not Exist">>;
reason(486) -> <<"Busy Here">>;
reason(487) -> <<"Request Terminated">>;
reason(500) -> <<"Server Internal Error">>;
reason(503) -> <<"Service Unavailable">>;
reason(_) -> <<"OK">>.
