%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% A scripted SIP peer over a gen_udp socket, for suites that need to see
%% and send exact headers. A peer is a process owning its socket; a raw
%% dialog is a map the helpers thread through requests.
-module(chappe_sip_test_ua).

-export([peer/2, expect/1, expect/2]).
-export([
    recv_req/2, recv_req/3,
    recv_status/2, recv_status/3,
    recv_any/2,
    no_req/3
]).
-export([send/3, lport/1]).
-export([
    invite/3,
    dialog_from_2xx/3,
    dialog_from_invite/4,
    in_dialog/4,
    in_dialog/5,
    ack/2,
    resp/6, resp/7
]).
-export([hdr/2, hdrs/2, body/1, cseq/1, to_tag/1, status/1]).
-export([sdp/1, sdp/2, tag/0, callid/0, branch/0, pick/0]).

%% ---- peers ----

%% Spawn a peer bound to Port (0: any) on loopback; Fun(Sock) runs in it.
peer(Port, Fun) ->
    Parent = self(),
    Pid = spawn_link(fun() ->
        {ok, Sock} = gen_udp:open(Port, [
            binary,
            {active, true},
            {ip, {127, 0, 0, 1}}
        ]),
        Parent ! {peer_ready, self()},
        Fun(Sock)
    end),
    receive
        {peer_ready, Pid} -> ok
    after 2000 -> ct:fail(peer_not_ready)
    end,
    Pid.

expect(Msg) -> expect(Msg, 6000).

expect(Msg, Timeout) ->
    receive
        Msg -> ok
    after Timeout -> ct:fail({expected, Msg})
    end.

%% ---- wire ----

lport(Sock) ->
    {ok, P} = inet:port(Sock),
    P.

send(Sock, DstPort, Bin) ->
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, DstPort, Bin).

recv_req(Sock, Method) -> recv_req(Sock, Method, 6000).

%% the next request with Method; other traffic is dropped
recv_req(Sock, Method, Timeout) ->
    L = byte_size(Method),
    receive
        {udp, Sock, _, Src, <<M:L/binary, " ", _/binary>> = Bin} when
            M =:= Method
        ->
            {Bin, Src};
        {udp, Sock, _, _, _} ->
            recv_req(Sock, Method, Timeout)
    after Timeout -> ct:fail({no_req, Method})
    end.

%% fails if a Method request arrives within Timeout
no_req(Sock, Method, Timeout) ->
    L = byte_size(Method),
    receive
        {udp, Sock, _, _, <<M:L/binary, " ", _/binary>> = Bin} when
            M =:= Method
        ->
            ct:fail({unexpected, Method, Bin});
        {udp, Sock, _, _, _} ->
            no_req(Sock, Method, Timeout)
    after Timeout -> ok
    end.

recv_status(Sock, Code) -> recv_status(Sock, Code, 6000).

recv_status(Sock, Code, Timeout) ->
    CB = integer_to_binary(Code),
    receive
        {udp, Sock, _, _, <<"SIP/2.0 ", CB:3/binary, _/binary>> = Bin} -> Bin;
        {udp, Sock, _, _, _} -> recv_status(Sock, Code, Timeout)
    after Timeout -> ct:fail({no_status, Code})
    end.

%% the next final response (100 Trying skipped)
recv_any(Sock, Timeout) ->
    receive
        {udp, Sock, _, _, <<"SIP/2.0 100", _/binary>>} ->
            recv_any(Sock, Timeout);
        {udp, Sock, _, _, <<"SIP/2.0 ", _/binary>> = Bin} ->
            Bin;
        {udp, Sock, _, _, _} ->
            recv_any(Sock, Timeout)
    after Timeout -> ct:fail(no_response)
    end.

%% ---- building requests ----

%% An initial INVITE from the peer on Sock to the engine. Opts:
%% call_id, from_tag, headers, body (default an SDP), cseq, ruri.
invite(Sock, _EnginePort, Opts) ->
    P = integer_to_binary(lport(Sock)),
    Body = maps:get(body, Opts, sdp(<<"caller">>)),
    CT =
        case Body of
            <<>> -> [];
            _ -> [{<<"Content-Type">>, <<"application/sdp">>}]
        end,
    build(
        <<"INVITE">>,
        maps:get(ruri, Opts, <<"sip:app@127.0.0.1">>),
        [
            {<<"Via">>,
                <<"SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=",
                    (maps:get(branch, Opts, branch()))/binary>>},
            {<<"Max-Forwards">>, <<"70">>},
            {<<"From">>,
                <<"<sip:caller@127.0.0.1:", P/binary, ">;tag=",
                    (maps:get(from_tag, Opts))/binary>>},
            {<<"To">>, <<"<sip:app@127.0.0.1>">>},
            {<<"Contact">>, <<"<sip:caller@127.0.0.1:", P/binary, ">">>},
            {<<"Call-ID">>, maps:get(call_id, Opts)},
            {<<"CSeq">>, <<
                (integer_to_binary(maps:get(cseq, Opts, 1)))/binary, " INVITE"
            >>}
        ] ++
            maps:get(headers, Opts, []) ++ CT,
        Body
    ).

%% The raw dialog of the calling peer once the engine answered 2xx.
dialog_from_2xx(Sock, InviteBin, R200) ->
    {ok, I} = chappe_sip_msg:parse(InviteBin),
    {ok, R} = chappe_sip_msg:parse(R200),
    #{
        sock => Sock,
        call_id => chappe_sip_msg:call_id(I),
        from => chappe_sip_msg:get(<<"from">>, I),
        to => chappe_sip_msg:get(<<"to">>, R),
        target => contact_uri(R),
        cseq => cseq_num(I),
        invite_cseq => cseq_num(I)
    }.

%% The raw dialog of the called peer, from the INVITE it received and the
%% To tag it answers with.
dialog_from_invite(Sock, InviteBin, ToTag, _Src) ->
    {ok, I} = chappe_sip_msg:parse(InviteBin),
    #{
        sock => Sock,
        call_id => chappe_sip_msg:call_id(I),
        from => <<
            (chappe_sip_msg:get(<<"to">>, I))/binary, ";tag=", ToTag/binary
        >>,
        to => chappe_sip_msg:get(<<"from">>, I),
        target => contact_uri(I),
        cseq => 100,
        invite_cseq => cseq_num(I)
    }.

%% ACK for the peer's 2xx-answered INVITE (its CSeq number)
ack(#{invite_cseq := N} = D, DstPort) ->
    send(maps:get(sock, D), DstPort, raw(D, <<"ACK">>, N, [], <<>>)).

in_dialog(D, Method, Headers, Body) ->
    in_dialog(D, Method, Headers, Body, #{}).

%% An in-dialog request; returns {Bin, D1} with the CSeq advanced.
in_dialog(#{cseq := C} = D, Method, Headers, Body, _Opts) ->
    N = C + 1,
    D1 =
        case Method of
            <<"INVITE">> -> D#{cseq := N, invite_cseq := N};
            _ -> D#{cseq := N}
        end,
    {raw(D1, Method, N, Headers, Body), D1}.

raw(
    #{sock := Sock, call_id := Call, from := From, to := To, target := T},
    Method,
    N,
    Headers,
    Body
) ->
    P = integer_to_binary(lport(Sock)),
    CT =
        case Body of
            <<>> -> [];
            _ -> [{<<"Content-Type">>, <<"application/sdp">>}]
        end,
    Contact =
        case Method of
            <<"ACK">> -> [];
            _ -> [{<<"Contact">>, <<"<sip:peer@127.0.0.1:", P/binary, ">">>}]
        end,
    build(
        Method,
        T,
        [
            {<<"Via">>,
                <<"SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=",
                    (branch())/binary>>},
            {<<"Max-Forwards">>, <<"70">>},
            {<<"From">>, From},
            {<<"To">>, To},
            {<<"Call-ID">>, Call},
            {<<"CSeq">>, <<(integer_to_binary(N))/binary, " ", Method/binary>>}
        ] ++
            Contact ++ Headers ++ CT,
        Body
    ).

build(Method, RUri, Headers, Body) ->
    iolist_to_binary(
        [
            Method,
            <<" ">>,
            RUri,
            <<" SIP/2.0\r\n">>,
            [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Headers],
            <<"Content-Length: ">>,
            integer_to_binary(byte_size(Body)),
            <<"\r\n\r\n">>,
            Body
        ]
    ).

resp(ReqBin, Status, Reason, ToTag, Extra, Body) ->
    resp(ReqBin, Status, Reason, ToTag, Extra, Body, <<"application/sdp">>).

%% A response echoing Via/From/To/Call-ID/CSeq; tags To when untagged.
resp(ReqBin, Status, Reason, ToTag, Extra, Body, CType) ->
    {ok, Msg} = chappe_sip_msg:parse(ReqBin),
    Vias = chappe_sip_msg:get_all(<<"via">>, Msg),
    From = chappe_sip_msg:get(<<"from">>, Msg),
    To0 = chappe_sip_msg:get(<<"to">>, Msg),
    To =
        case chappe_sip_msg:to_tag(Msg) of
            undefined when Status > 100 ->
                <<To0/binary, ";tag=", ToTag/binary>>;
            _ ->
                To0
        end,
    CT =
        case Body of
            <<>> -> [];
            _ -> [[<<"Content-Type: ">>, CType, <<"\r\n">>]]
        end,
    iolist_to_binary(
        [
            <<"SIP/2.0 ">>,
            integer_to_binary(Status),
            <<" ">>,
            Reason,
            <<"\r\n">>,
            [[<<"Via: ">>, V, <<"\r\n">>] || V <- Vias],
            <<"From: ">>,
            From,
            <<"\r\n">>,
            <<"To: ">>,
            To,
            <<"\r\n">>,
            <<"Call-ID: ">>,
            chappe_sip_msg:call_id(Msg),
            <<"\r\n">>,
            <<"CSeq: ">>,
            chappe_sip_msg:get(<<"cseq">>, Msg),
            <<"\r\n">>,
            [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Extra],
            CT,
            <<"Content-Length: ">>,
            integer_to_binary(byte_size(Body)),
            <<"\r\n\r\n">>,
            Body
        ]
    ).

%% ---- reading ----

hdr(Bin, Name) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    chappe_sip_msg:get(Name, M).

hdrs(Bin, Name) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    chappe_sip_msg:get_all(Name, M).

body(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    chappe_sip_msg:body(M).

status(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    chappe_sip_msg:status(M).

cseq(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    {ok, C} = chappe_sip_msg:cseq(M),
    C.

to_tag(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    chappe_sip_msg:to_tag(M).

cseq_num(Msg) ->
    {ok, #{seq := N}} = chappe_sip_msg:cseq(Msg),
    N.

contact_uri(Msg) ->
    {ok, #{uri := U}} = chappe_sip_hdr:name_addr(
        chappe_sip_msg:get(<<"contact">>, Msg)
    ),
    U.

%% ---- values ----

sdp(Marker) -> sdp(Marker, <<"0">>).

%% Version is the o= session version (RFC 3264 8: unchanged means no change)
sdp(Marker, Version) ->
    <<"v=0\r\no=", Marker/binary, " 1 ", Version/binary,
        " IN IP4 127.0.0.1\r\n"
        "s=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio 40000 RTP/AVP 0\r\n">>.

tag() -> binary:encode_hex(crypto:strong_rand_bytes(5), lowercase).

callid() ->
    <<"st-", (binary:encode_hex(crypto:strong_rand_bytes(4)))/binary, "@ct">>.

branch() ->
    <<"z9hG4bK", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>.

pick() -> chappe_sip_test_port:pick().
