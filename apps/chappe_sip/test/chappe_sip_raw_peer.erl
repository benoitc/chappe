%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% A far-end SIP peer on a raw UDP socket, for suites that must assert the
%% exact status code and headers chappe puts on the wire.
%%
%% The socket is active and owned by the calling process, so requests and
%% responses are picked out of the mailbox by selective receive: a response
%% is matched by its CSeq number and method, a request by its method, and
%% anything else stays queued for a later receive.
%%
%% As a caller it forms a dialog with the engine (invite/3 + ack/3) and then
%% sends in-dialog requests with a CSeq it counts itself. As a callee it
%% answers requests the engine sends it (reply/5).
-module(chappe_sip_raw_peer).

-export([open/1, close/1, port/1]).
-export([invite/3, ack/3, cancel/2, request/4, send_raw/2]).
-export([recv_response/3, recv_final/3, recv_request/2, no_request/3]).
-export([reply/5, reply/6]).
-export([header/2, headers/2, status/1, body/1, sdp/1, uri/1]).

-type peer() :: #{
    sock := gen_udp:socket(),
    lport := inet:port_number(),
    ep := inet:port_number(),
    call => binary(),
    ft => binary(),
    tt => binary(),
    cseq => pos_integer()
}.
-export_type([peer/0]).

%% A peer that talks to the engine listening on EP.
-spec open(inet:port_number()) -> peer().
open(EP) ->
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    {ok, LP} = inet:port(Sock),
    #{sock => Sock, lport => LP, ep => EP}.

-spec close(peer()) -> ok.
close(#{sock := S}) -> gen_udp:close(S).

-spec port(peer()) -> inet:port_number().
port(#{lport := P}) -> P.

%% Our Contact URI.
-spec uri(peer()) -> binary().
uri(#{lport := P}) ->
    <<"sip:peer@127.0.0.1:", (integer_to_binary(P))/binary>>.

%% Send an initial INVITE. Opts: body (default an SDP), headers, call_id.
%% Returns the peer carrying the dialog identity (no to-tag yet).
-spec invite(peer(), binary(), map()) -> peer().
invite(Peer, Marker, Opts) ->
    Call = maps:get(call_id, Opts, callid()),
    FT = <<"pt", (hex(3))/binary>>,
    Branch = <<"z9hG4bK", (hex(6))/binary>>,
    P1 = Peer#{call => Call, ft => FT, cseq => 1, branch => Branch},
    Body = maps:get(body, Opts, sdp(Marker)),
    Hdrs = maps:get(headers, Opts, []),
    send_raw(P1, build(<<"INVITE">>, P1, 1, Hdrs, Body, Branch)),
    P1.

%% CANCEL the initial INVITE (same branch and CSeq number, RFC 3261 9.1).
-spec cancel(peer(), [{binary(), binary()}]) -> ok.
cancel(#{branch := Branch} = Peer, Hdrs) ->
    send_raw(
        Peer, build(<<"CANCEL">>, maps:remove(tt, Peer), 1, Hdrs, <<>>, Branch)
    ).

%% ACK the 2xx to the INVITE with CSeq N (optionally carrying an answer).
-spec ack(peer(), pos_integer(), binary()) -> ok.
ack(Peer, N, Body) ->
    send_raw(Peer, build(<<"ACK">>, Peer, N, [], Body)).

%% Send an in-dialog request with the next CSeq. Returns {CSeq, Peer}.
-spec request(peer(), binary(), [{binary(), binary()}], binary()) ->
    {pos_integer(), peer()}.
request(#{cseq := C} = Peer, Method, Hdrs, Body) ->
    N = C + 1,
    P1 = Peer#{cseq => N},
    send_raw(P1, build(Method, P1, N, Hdrs, Body)),
    {N, P1}.

-spec send_raw(peer(), iodata()) -> ok.
send_raw(#{sock := S, ep := EP}, Bin) ->
    ok = gen_udp:send(S, {127, 0, 0, 1}, EP, Bin).

%% The next response (provisional or final) to the request CSeq N Method.
-spec recv_response(peer(), pos_integer(), binary()) -> chappe_sip_msg:msg().
recv_response(#{sock := S}, N, Method) ->
    CSeq = <<(integer_to_binary(N))/binary, " ", Method/binary>>,
    Deadline = erlang:monotonic_time(millisecond) + 6000,
    recv_response_1(S, CSeq, Deadline, []).

recv_response_1(S, CSeq, Deadline, Saved) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {udp, S, _, _, <<"SIP/2.0 ", _/binary>> = Bin} = Msg ->
            {ok, M} = chappe_sip_msg:parse(Bin),
            case chappe_sip_msg:get(<<"cseq">>, M) of
                CSeq ->
                    requeue(Saved),
                    M;
                _ ->
                    %% not ours: keep it for a later receive
                    recv_response_1(S, CSeq, Deadline, [Msg | Saved])
            end
    after Left ->
        requeue(Saved),
        error({no_response, CSeq})
    end.

requeue(Saved) ->
    [self() ! M || M <- lists:reverse(Saved)],
    ok.

%% The final response to CSeq N Method, skipping provisionals.
-spec recv_final(peer(), pos_integer(), binary()) -> chappe_sip_msg:msg().
recv_final(Peer, N, Method) ->
    M = recv_response(Peer, N, Method),
    case chappe_sip_msg:status(M) of
        S when S < 200 -> recv_final(Peer, N, Method);
        _ -> M
    end.

%% The next request of Method the engine sends us: {Bin, Msg, SrcPort}.
-spec recv_request(peer(), binary()) ->
    {binary(), chappe_sip_msg:msg(), inet:port_number()}.
recv_request(#{sock := S}, Method) ->
    L = byte_size(Method),
    receive
        {udp, S, _, Src, <<M:L/binary, " ", _/binary>> = Bin} when
            M =:= Method
        ->
            {ok, Msg} = chappe_sip_msg:parse(Bin),
            {Bin, Msg, Src}
    after 6000 -> error({no_request, Method})
    end.

%% Assert no request of Method arrives within T ms.
-spec no_request(peer(), binary(), timeout()) -> ok.
no_request(#{sock := S}, Method, T) ->
    L = byte_size(Method),
    receive
        {udp, S, _, _, <<M:L/binary, " ", _/binary>> = Bin} when
            M =:= Method
        ->
            error({unexpected_request, Bin})
    after T -> ok
    end.

%% Answer a request the engine sent us.
-spec reply(peer(), binary(), inet:port_number(), integer(), binary()) -> ok.
reply(Peer, ReqBin, Src, Status, Body) ->
    reply(Peer, ReqBin, Src, Status, [], Body).

-spec reply(
    peer(),
    binary(),
    inet:port_number(),
    integer(),
    [{binary(), binary()}],
    binary()
) -> ok.
reply(#{sock := S} = Peer, ReqBin, Src, Status, Hdrs, Body) ->
    {ok, Msg} = chappe_sip_msg:parse(ReqBin),
    Vias = chappe_sip_msg:get_all(<<"via">>, Msg),
    From = chappe_sip_msg:get(<<"from">>, Msg),
    To0 = chappe_sip_msg:get(<<"to">>, Msg),
    To =
        case chappe_sip_msg:to_tag(Msg) of
            undefined when Status > 100 ->
                <<To0/binary, ";tag=",
                    (maps:get(ft, Peer, <<"peer">>))/binary>>;
            _ ->
                To0
        end,
    CT =
        case Body of
            <<>> -> [];
            _ -> [<<"Content-Type: application/sdp\r\n">>]
        end,
    Bin = iolist_to_binary([
        <<"SIP/2.0 ">>,
        integer_to_binary(Status),
        <<" Reason\r\n">>,
        [[<<"Via: ">>, V, <<"\r\n">>] || V <- Vias],
        <<"From: ">>,
        From,
        <<"\r\nTo: ">>,
        To,
        <<"\r\nCall-ID: ">>,
        chappe_sip_msg:call_id(Msg),
        <<"\r\nCSeq: ">>,
        chappe_sip_msg:get(<<"cseq">>, Msg),
        <<"\r\nContact: <">>,
        uri(Peer),
        <<">\r\n">>,
        [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Hdrs],
        CT,
        <<"Content-Length: ">>,
        integer_to_binary(byte_size(Body)),
        <<"\r\n\r\n">>,
        Body
    ]),
    ok = gen_udp:send(S, {127, 0, 0, 1}, Src, Bin).

%% ---- message accessors ----

-spec header(binary(), chappe_sip_msg:msg()) -> binary() | undefined.
header(Name, M) -> chappe_sip_msg:get(Name, M).

-spec headers(binary(), chappe_sip_msg:msg()) -> [binary()].
headers(Name, M) -> chappe_sip_msg:get_all(Name, M).

-spec status(chappe_sip_msg:msg()) -> integer().
status(M) -> chappe_sip_msg:status(M).

-spec body(chappe_sip_msg:msg()) -> binary().
body(M) -> chappe_sip_msg:body(M).

%% A distinguishable SDP: Marker goes in the o= username.
-spec sdp(binary()) -> binary().
sdp(Marker) ->
    <<"v=0\r\no=", Marker/binary,
        " 0 0 IN IP4 127.0.0.1\r\ns=-\r\n"
        "c=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio 40000 RTP/AVP 0\r\n"
        "a=sendrecv\r\n">>.

%% ---- internal ----

build(Method, Peer, N, Hdrs, Body) ->
    build(Method, Peer, N, Hdrs, Body, <<"z9hG4bK", (hex(6))/binary>>).

build(
    Method, #{lport := LP, call := Call, ft := FT} = Peer, N, Hdrs, Body, Branch
) ->
    P = integer_to_binary(LP),
    To =
        case maps:get(tt, Peer, undefined) of
            undefined -> <<"<sip:app@127.0.0.1>">>;
            TT -> <<"<sip:app@127.0.0.1>;tag=", TT/binary>>
        end,
    CT =
        case Body of
            <<>> -> [];
            _ -> [<<"Content-Type: application/sdp\r\n">>]
        end,
    iolist_to_binary([
        Method,
        <<" sip:app@127.0.0.1 SIP/2.0\r\n">>,
        <<"Via: SIP/2.0/UDP 127.0.0.1:">>,
        P,
        <<";rport;branch=">>,
        Branch,
        <<"\r\nMax-Forwards: 70\r\n">>,
        <<"From: <sip:peer@127.0.0.1:">>,
        P,
        <<">;tag=">>,
        FT,
        <<"\r\nTo: ">>,
        To,
        <<"\r\nContact: <">>,
        uri(Peer),
        <<">\r\nCall-ID: ">>,
        Call,
        <<"\r\nCSeq: ">>,
        integer_to_binary(N),
        <<" ">>,
        Method,
        <<"\r\n">>,
        [[Nm, <<": ">>, V, <<"\r\n">>] || {Nm, V} <- Hdrs],
        CT,
        <<"Content-Length: ">>,
        integer_to_binary(byte_size(Body)),
        <<"\r\n\r\n">>,
        Body
    ]).

callid() -> <<"raw-", (hex(5))/binary, "@ct">>.

hex(N) -> binary:encode_hex(crypto:strong_rand_bytes(N), lowercase).
