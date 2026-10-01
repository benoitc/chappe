%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc SDP for a chappe_mix conference leg.
%%
%% The mixer speaks one thing: G.711 (PCMU or PCMA) over plain RTP/AVP in
%% 20 ms frames. This module reads the remote side of a leg out of an SDP
%% (where to send, which law, whether RTCP is muxed) and writes the leg's
%% own SDP, as an offer or as an answer to an offer (RFC 3264). Anything
%% else (SRTP, DTLS, other codecs) belongs to rtpengine in front of the
%% mixer.
-module(chappe_sip_media_mix_sdp).

-export([accept_offer/1, read_answer/2, answer/2, offer/1]).

-export_type([law/0, remote/0, local/0]).

-type law() :: ulaw | alaw.
%% What a leg needs from the far end's SDP. index is the m-line answered.
-type remote() :: #{
    endpoint := {inet:ip_address(), inet:port_number()},
    law := law(),
    mux := boolean(),
    index := non_neg_integer()
}.
%% The leg as advertised: address, RTP port, law and RTCP mux.
-type local() :: #{
    addr := inet:ip_address(),
    port := inet:port_number(),
    law := law(),
    mux := boolean()
}.

-define(PROTO, <<"RTP/AVP">>).

%% Pick the leg's codec and far end out of an offer: the first audio
%% m-line on RTP/AVP with a live port and a G.711 payload type, the law in
%% the offer's order of preference.
-spec accept_offer(iodata()) -> {ok, remote()} | {error, term()}.
accept_offer(Sdp) ->
    {SessAddr, Media} = parse(Sdp),
    pick(SessAddr, Media).

%% Read the far end out of the answer to an offer made with Law.
-spec read_answer(iodata(), law()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
read_answer(Sdp, Law) ->
    {SessAddr, Media} = parse(Sdp),
    case pick(SessAddr, Media) of
        {ok, #{law := Law, endpoint := Endpoint}} -> {ok, Endpoint};
        {ok, #{law := Other}} -> {error, {law_mismatch, Other}};
        {error, _} = Err -> Err
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
%% it is open, so it offers the law it opened the leg with.
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

audio(#{port := Port, law := Law, mux := Mux}) ->
    Pt = integer_to_binary(pt(Law)),
    [
        [<<"m=audio ">>, integer_to_binary(Port), <<" ">>, ?PROTO, <<" ">>],
        [Pt, crlf()],
        [<<"a=rtpmap:">>, Pt, <<" ">>, encoding(Law), <<"/8000\r\n">>],
        <<"a=ptime:20\r\n">>,
        <<"a=sendrecv\r\n">>,
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
pick_stream(I, #{port := Port, fmts := Fmts} = M, SessAddr) ->
    case [L || F <- Fmts, L <- [law(F)], L =/= undefined] of
        [] ->
            {error, no_common_codec};
        [Law | _] ->
            case address(maps:get(addr, M, SessAddr)) of
                {ok, Ip} ->
                    {ok, #{
                        endpoint => {Ip, Port},
                        law => Law,
                        mux => maps:get(mux, M, false),
                        index => I
                    }};
                error ->
                    {error, no_connection_address}
            end
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
    {Sess, lists:reverse(Rev)}.

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
line(_Other, Acc) ->
    Acc.

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
