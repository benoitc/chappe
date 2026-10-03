%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc SDP for a chappe_mix conference leg.
%%
%% The mixer speaks one thing: G.711 (PCMU or PCMA) over plain RTP/AVP. It
%% takes packets of any size and sends 20 ms ones. This module reads the
%% remote side of a leg out of an SDP (where to send, which law, whether
%% RTCP is muxed, the far end's packet time) and writes the leg's
%% own SDP, as an offer or as an answer to an offer (RFC 3264). Anything
%% else (SRTP, DTLS, other codecs) belongs to rtpengine in front of the
%% mixer.
-module(chappe_sip_media_mix_sdp).

-export([accept_offer/1, read_answer/2, answer/2, offer/1]).

-export_type([law/0, remote/0, local/0, dtmf/0, direction/0]).

-export([combine/2]).

-type law() :: ulaw | alaw.
%% RFC 4733 telephone-event: the payload type and the event codes listed
%% in its fmtp (the DTMF digits 0 to 15 when it has none).
-type dtmf() :: #{pt := 0..127, events := [0..255]}.
%% A leg's direction seen from the room, as chappe_mix takes it, which is
%% also what the mixer's own SDP says.
-type direction() :: sendrecv | sendonly | recvonly | inactive.
%% What a leg needs from the far end's SDP. index is the m-line answered;
%% ptime the far end's a=ptime (20 when it gives none); dtmf its
%% telephone-event, if it has one; rtcp where its RTCP goes when a
%% media-level a=rtcp names it and RTCP is not muxed (RFC 3605).
-type remote() :: #{
    endpoint := {inet:ip_address(), inet:port_number()},
    rtcp := {inet:ip_address(), inet:port_number()} | undefined,
    law := law(),
    mux := boolean(),
    ptime := pos_integer(),
    dtmf := dtmf() | undefined,
    direction := direction(),
    index := non_neg_integer()
}.
%% The leg as advertised: address, RTP port, law, RTCP mux, and the
%% telephone-event payload type to offer or answer on, if any.
-type local() :: #{
    addr := inet:ip_address(),
    port := inet:port_number(),
    law := law(),
    mux := boolean(),
    dtmf_pt => 0..127,
    direction => direction()
}.

-define(PROTO, <<"RTP/AVP">>).
%% what the mixer puts in a packet, ms
-define(PTIME, 20).
%% the telephone-event payload type the mixer offers, and the events it
%% takes (the DTMF digits and flash)
-define(DTMF_PT, 101).
-define(DTMF_EVENTS, <<"0-16">>).

%% Pick the leg's codec and far end out of an offer: the first audio
%% m-line on RTP/AVP with a live port and a G.711 payload type, the law in
%% the offer's order of preference. An a=maxptime under 20 ms is refused:
%% the mixer only sends 20 ms packets (RFC 4566 6).
-spec accept_offer(iodata()) -> {ok, remote()} | {error, term()}.
accept_offer(Sdp) ->
    {SessAddr, Media} = parse(Sdp),
    pick(SessAddr, Media).

%% Read the far end out of the answer to an offer made with Law: where
%% to send, and the telephone-event it took, if any.
-spec read_answer(iodata(), law()) ->
    {ok, #{
        endpoint := {inet:ip_address(), inet:port_number()},
        rtcp := {inet:ip_address(), inet:port_number()} | undefined,
        dtmf := dtmf() | undefined,
        direction := direction()
    }}
    | {error, term()}.
read_answer(Sdp, Law) ->
    {SessAddr, Media} = parse(Sdp),
    case pick(SessAddr, Media) of
        {ok, #{law := Law} = R} ->
            {ok, maps:with([endpoint, rtcp, dtmf, direction], R)};
        {ok, #{law := Other}} ->
            {error, {law_mismatch, Other}};
        {error, _} = Err ->
            Err
    end.

%% Answer Offer for Local: the chosen m-line carries the leg, every other
%% m-line is rejected with port 0, as RFC 3264 6 asks.
-spec answer(iodata(), local()) -> binary().
answer(Offer, #{addr := Addr} = Local) ->
    {_, Media} = parse(Offer),
    {ok, #{index := Chosen}} = accept_offer(Offer),
    Lines = lists:map(
        fun
            ({I, _M}) when I =:= Chosen ->
                audio(Local);
            ({_I, #{media := Kind, proto := Proto, fmts := Fmts}}) ->
                [<<"m=">>, Kind, <<" 0 ">>, Proto, <<" ">>, first(Fmts), crlf()]
        end,
        lists:enumerate(0, Media)
    ),
    iolist_to_binary([session(Addr), Lines]).

%% A one-codec offer for Local: the mixer cannot change a leg's law once
%% it is open, so it offers the law it opened the leg with, and
%% telephone-event when Local has a dtmf_pt.
-spec offer(local()) -> binary().
offer(#{addr := Addr} = Local) ->
    iolist_to_binary([session(Addr), audio(Local)]).

%% internal: writing

session(Addr) ->
    Id = integer_to_binary(erlang:unique_integer([positive])),
    [
        <<"v=0\r\n">>,
        [<<"o=chappe ">>, Id, <<" 1 ">>, addr_line(Addr), crlf()],
        <<"s=chappe\r\n">>,
        [<<"c=">>, addr_line(Addr), crlf()],
        <<"t=0 0\r\n">>
    ].

audio(#{port := Port, law := Law, mux := Mux} = Local) ->
    Pt = integer_to_binary(pt(Law)),
    {Fmts, Dtmf} =
        case maps:find(dtmf_pt, Local) of
            {ok, D} ->
                Te = integer_to_binary(D),
                {[Pt, <<" ">>, Te], [
                    [<<"a=rtpmap:">>, Te, <<" telephone-event/8000\r\n">>],
                    [<<"a=fmtp:">>, Te, <<" ">>, ?DTMF_EVENTS, crlf()]
                ]};
            error ->
                {Pt, []}
        end,
    [
        [<<"m=audio ">>, integer_to_binary(Port), <<" ">>, ?PROTO, <<" ">>],
        [Fmts, crlf()],
        [<<"a=rtpmap:">>, Pt, <<" ">>, encoding(Law), <<"/8000\r\n">>],
        Dtmf,
        [<<"a=ptime:">>, integer_to_binary(?PTIME), crlf()],
        [
            <<"a=">>,
            atom_to_binary(maps:get(direction, Local, sendrecv)),
            crlf()
        ],
        case Mux of
            true -> <<"a=rtcp-mux\r\n">>;
            false -> <<>>
        end
    ].

addr_line(Addr) when tuple_size(Addr) =:= 8 ->
    [<<"IN IP6 ">>, inet:ntoa(Addr)];
addr_line(Addr) ->
    [<<"IN IP4 ">>, inet:ntoa(Addr)].

crlf() -> <<"\r\n">>.

first([F | _]) -> F;
first([]) -> <<"0">>.

pt(ulaw) -> 0;
pt(alaw) -> 8.

encoding(ulaw) -> <<"PCMU">>;
encoding(alaw) -> <<"PCMA">>.

%% internal: reading

pick(SessAddr, Media) ->
    Audio = [
        {I, M}
     || {I, #{media := <<"audio">>, port := P} = M} <- lists:enumerate(
            0, Media
        ),
        P > 0
    ],
    case Audio of
        [] -> {error, no_audio};
        [{I, M} | _] -> pick_stream(I, M, SessAddr)
    end.

pick_stream(_I, #{proto := Proto}, _SessAddr) when Proto =/= ?PROTO ->
    {error, {unsupported_proto, Proto}};
pick_stream(_I, #{maxptime := Max}, _SessAddr) when Max < ?PTIME ->
    {error, {maxptime, Max}};
pick_stream(I, #{port := Port, fmts := Fmts} = M, SessAddr) ->
    case [L || F <- Fmts, L <- [law(F)], L =/= undefined] of
        [] ->
            {error, no_common_codec};
        [Law | _] ->
            case address(maps:get(addr, M, SessAddr)) of
                {ok, Ip} ->
                    {ok, #{
                        endpoint => {Ip, Port},
                        rtcp => rtcp(M, Ip),
                        law => Law,
                        mux => maps:get(mux, M, false),
                        ptime => maps:get(ptime, M, ?PTIME),
                        dtmf => dtmf(M),
                        direction => room_side(maps:get(dir, M, sendrecv)),
                        index => I
                    }};
                error ->
                    {error, no_connection_address}
            end
    end.

%% The far end's direction seen from the room: what it only sends, the
%% room only takes.
room_side(sendonly) -> recvonly;
room_side(recvonly) -> sendonly;
room_side(Dir) -> Dir.

%% What both sides allow: the room sends only when both say it may, and
%% takes only when both say it may.
-spec combine(direction(), direction()) -> direction().
combine(A, B) ->
    direction(sends(A) andalso sends(B), takes(A) andalso takes(B)).

sends(D) -> D =:= sendrecv orelse D =:= sendonly.
takes(D) -> D =:= sendrecv orelse D =:= recvonly.

direction(true, true) -> sendrecv;
direction(true, false) -> sendonly;
direction(false, true) -> recvonly;
direction(false, false) -> inactive.

%% The RTCP address of a media-level a=rtcp: its port, and its address
%% or else the media's. Muxed RTCP stays on the RTP port.
rtcp(#{mux := true}, _Ip) ->
    undefined;
rtcp(#{rtcp := V}, Ip) ->
    case words(V) of
        [P] -> rtcp_port(P, {ok, Ip});
        [P, <<"IN">>, _Family, Addr | _] -> rtcp_port(P, address(Addr));
        _ -> undefined
    end;
rtcp(_M, _Ip) ->
    undefined.

rtcp_port(P, {ok, Ip}) ->
    case string:to_integer(P) of
        {N, <<>>} when is_integer(N), N > 0, N =< 65535 -> {Ip, N};
        _ -> undefined
    end;
rtcp_port(_P, error) ->
    undefined.

%% The first telephone-event/8000 among the m-line's formats.
dtmf(#{fmts := Fmts} = M) ->
    Maps = maps:get(rtpmap, M, #{}),
    case
        [
            F
         || F <- Fmts,
            string:lowercase(maps:get(F, Maps, <<>>)) =:=
                <<"telephone-event/8000">>
        ]
    of
        [F | _] ->
            case string:to_integer(F) of
                {Pt, <<>>} when is_integer(Pt), Pt >= 0, Pt =< 127 ->
                    #{
                        pt => Pt,
                        events => events(maps:find(F, maps:get(fmtp, M, #{})))
                    };
                _ ->
                    undefined
            end;
        [] ->
            undefined
    end.

%% An events list, e.g. "0-15,32,36-37" (RFC 4733 7.1.1); no fmtp means
%% the DTMF digits 0 to 15 (2.5.1.1). Codes outside 0..255 and anything
%% that does not parse are left out.
events(error) ->
    lists:seq(0, 15);
events({ok, V}) ->
    lists:usort(
        lists:append([
            range(binary:split(string:trim(Item), <<"-">>))
         || Item <- binary:split(V, <<",">>, [global, trim_all])
        ])
    ).

range([A, B]) ->
    case {code(A), code(B)} of
        {X, Y} when is_integer(X), is_integer(Y), X =< Y -> lists:seq(X, Y);
        _ -> []
    end;
range([A]) ->
    case code(A) of
        X when is_integer(X) -> [X];
        _ -> []
    end;
range(_) ->
    [].

code(Bin) ->
    case string:to_integer(string:trim(Bin)) of
        {N, <<>>} when is_integer(N), N >= 0, N =< 255 -> N;
        _ -> undefined
    end.

law(<<"0">>) -> ulaw;
law(<<"8">>) -> alaw;
law(_) -> undefined.

address(undefined) ->
    error;
address(Bin) ->
    case inet:parse_strict_address(binary_to_list(Bin)) of
        {ok, Ip} -> {ok, Ip};
        {error, _} -> error
    end.

%% {SessionAddress, [Media]} where each media is #{media, port, proto,
%% fmts, addr (when it has its own c=), mux}.
parse(Sdp) ->
    Lines = binary:split(iolist_to_binary(Sdp), [<<"\r\n">>, <<"\n">>], [
        global, trim_all
    ]),
    {Sess, Rev} = lists:foldl(fun line/2, {undefined, []}, Lines),
    %% a session-level direction holds for the m-lines without their own
    SessDir = session_dir(Lines),
    {Sess, [maps:merge(#{dir => SessDir}, M) || M <- lists:reverse(Rev)]}.

session_dir([<<"m=", _/binary>> | _]) ->
    sendrecv;
session_dir([L | Ls]) ->
    case dir_attr(L) of
        undefined -> session_dir(Ls);
        Dir -> Dir
    end;
session_dir([]) ->
    sendrecv.

dir_attr(<<"a=sendrecv">>) -> sendrecv;
dir_attr(<<"a=sendonly">>) -> sendonly;
dir_attr(<<"a=recvonly">>) -> recvonly;
dir_attr(<<"a=inactive">>) -> inactive;
dir_attr(_) -> undefined.

line(<<"m=", Rest/binary>>, {Sess, Media}) ->
    case words(Rest) of
        [Kind, Port, Proto | Fmts] ->
            M = #{
                media => Kind,
                port => port(Port),
                proto => Proto,
                fmts => Fmts
            },
            {Sess, [M | Media]};
        _ ->
            {Sess, Media}
    end;
line(<<"c=", Rest/binary>>, {Sess, Media}) ->
    case {conn_addr(Rest), Media} of
        {undefined, _} -> {Sess, Media};
        {Addr, []} -> {Addr, Media};
        {Addr, [M | Ms]} -> {Sess, [M#{addr => Addr} | Ms]}
    end;
line(<<"a=rtcp-mux", _/binary>>, {Sess, [M | Ms]}) ->
    {Sess, [M#{mux => true} | Ms]};
line(<<"a=", _/binary>> = L, {Sess, [M | Ms]}) when
    L =:= <<"a=sendrecv">>;
    L =:= <<"a=sendonly">>;
    L =:= <<"a=recvonly">>;
    L =:= <<"a=inactive">>
->
    {Sess, [M#{dir => dir_attr(L)} | Ms]};
line(<<"a=rtcp:", V/binary>>, {Sess, [M | Ms]}) ->
    %% media level only: RFC 3605 2.1 forbids it at session level
    {Sess, [M#{rtcp => V} | Ms]};
line(<<"a=rtpmap:", V/binary>>, {Sess, [M | Ms]}) ->
    {Sess, [put_fmt(rtpmap, V, M) | Ms]};
line(<<"a=fmtp:", V/binary>>, {Sess, [M | Ms]}) ->
    {Sess, [put_fmt(fmtp, V, M) | Ms]};
line(<<"a=ptime:", V/binary>>, {Sess, [M | Ms]}) ->
    {Sess, [put_ms(ptime, V, M) | Ms]};
line(<<"a=maxptime:", V/binary>>, {Sess, [M | Ms]}) ->
    {Sess, [put_ms(maxptime, V, M) | Ms]};
line(_Other, Acc) ->
    Acc.

%% a=rtpmap:<fmt> <rest> and a=fmtp:<fmt> <rest>, kept by format.
put_fmt(Key, V, M) ->
    case binary:split(V, <<" ">>) of
        [Fmt, Rest] ->
            M#{Key => maps:put(Fmt, string:trim(Rest), maps:get(Key, M, #{}))};
        _ ->
            M
    end.

%% A packet time in ms; RFC 4566 allows a fraction, the mixer rounds it.
put_ms(Key, V, M) ->
    case string:to_float(V) of
        {F, _} when is_float(F), F > 0 ->
            M#{Key => max(1, round(F))};
        _ ->
            case string:to_integer(V) of
                {N, _} when is_integer(N), N > 0 -> M#{Key => N};
                _ -> M
            end
    end.

conn_addr(Rest) ->
    case words(Rest) of
        [<<"IN">>, _Family, Addr | _] ->
            %% a multicast c= may carry /ttl; unicast is what a leg uses
            hd(binary:split(Addr, <<"/">>));
        _ ->
            undefined
    end.

words(Bin) ->
    binary:split(Bin, <<" ">>, [global, trim_all]).

port(Bin) ->
    %% m=<media> <port>/<count>: only the base port matters for one leg
    case string:to_integer(Bin) of
        {N, _} when is_integer(N), N >= 0, N =< 65535 -> N;
        _ -> 0
    end.
