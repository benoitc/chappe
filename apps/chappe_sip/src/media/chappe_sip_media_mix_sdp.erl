%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc SDP for a chappe_mix conference leg.
%%
%% The mixer speaks the format of its room's rate over plain RTP/AVP: G.711
%% (PCMU or PCMA, static payload types) in an 8 kHz room, L16 at 16000 (RFC
%% 3551 4.5.11, a dynamic payload type) in a 16 kHz one. It takes packets
%% of any size and sends 20 ms ones. This module reads the remote side of a
%% leg out of an SDP (where to send, which format on which payload type,
%% whether RTCP is muxed, the far end's packet time, its telephone-event at
%% the room's clock) and writes the leg's own SDP, as an offer or as an
%% answer to an offer (RFC 3264). Anything else (SRTP, DTLS, other codecs)
%% belongs to rtpengine in front of the mixer.
-module(chappe_sip_media_mix_sdp).

-export([accept_offer/1, accept_offer/2, read_answer/2, answer/2, offer/1]).
-export([plan/3, leg_sdp/3]).

-export_type([law/0, remote/0, local/0, dtmf/0, direction/0, plan/0]).

-export([combine/2]).

%% A leg's format: G.711 at 8 kHz, L16 at 16 kHz.
-type law() :: ulaw | alaw | l16.
%% RFC 4733 telephone-event: the payload type and the event codes listed
%% in its fmtp (the DTMF digits 0 to 15 when it has none).
-type dtmf() :: #{pt := 0..127, events := [0..255]}.
%% A leg's direction seen from the room, as chappe_mix takes it, which is
%% also what the mixer's own SDP says.
-type direction() :: sendrecv | sendonly | recvonly | inactive.
%% What a leg needs from the far end's SDP. index is the m-line answered;
%% pt the payload type of the format; ptime the far end's a=ptime (20
%% when it gives none); dtmf its telephone-event at the room's clock, if
%% it has one; rtcp where its RTCP goes when a media-level a=rtcp names it
%% and RTCP is not muxed (RFC 3605).
-type remote() :: #{
    endpoint := {inet:ip_address(), inet:port_number()},
    rtcp := {inet:ip_address(), inet:port_number()} | undefined,
    law := law(),
    pt := 0..127,
    mux := boolean(),
    ptime := pos_integer(),
    dtmf := dtmf() | undefined,
    direction := direction(),
    index := non_neg_integer()
}.
%% The leg as advertised: address, RTP port, format (and its payload type
%% for L16, default 96), RTCP mux, and the telephone-event payload type to
%% offer or answer on, if any.
-type local() :: #{
    addr := inet:ip_address(),
    port := inet:port_number(),
    law := law(),
    pt => 0..127,
    mux := boolean(),
    dtmf_pt => 0..127,
    direction => direction()
}.

%% What a leg looks like before it exists (plan/3): its format, RTCP mux
%% and direction, the mute the join asks, and either the offer it answers
%% with what that offer says (answer_to, remote, ptime, dtmf, rtcp_remote)
%% or the telephone-event payload type it offers (dtmf_offer).
-type plan() :: #{
    law := law(),
    pt => 0..127,
    mux := boolean(),
    mute := boolean(),
    dir := direction(),
    answer_to => iodata(),
    remote => {inet:ip_address(), inet:port_number()},
    ptime => pos_integer(),
    dtmf => dtmf() | undefined,
    rtcp_remote => {inet:ip_address(), inet:port_number()} | undefined,
    dtmf_offer => 0..127
}.

-define(PROTO, <<"RTP/AVP">>).
%% the telephone-event payload type the mixer offers
-define(DTMF_PT, 101).
%% what the mixer puts in a packet, ms
-define(PTIME, 20).
%% the events the mixer takes (the DTMF digits and flash)
-define(DTMF_EVENTS, <<"0-16">>).
%% the payload type of an L16 leg unless the leg says otherwise
-define(L16_PT, 96).

%% accept_offer/2 for an 8 kHz room.
-spec accept_offer(iodata()) -> {ok, remote()} | {error, term()}.
accept_offer(Sdp) ->
    accept_offer(Sdp, 8000).

%% Pick the leg's format and far end out of an offer, for a room of Rate:
%% the first audio m-line on RTP/AVP with a live port, then at 8000 the
%% first G.711 payload type in the offer's order of preference, at 16000
%% the first whose rtpmap is L16/16000 (mono), and the telephone-event at
%% that clock. A PCMU-only offer to a 16 kHz room is no_common_codec: put
%% rtpengine in front (chappe_sip_media:mixer_params/2). An a=maxptime
%% under 20 ms is refused: the mixer only sends 20 ms packets (RFC 4566 6).
-spec accept_offer(iodata(), 8000 | 16000) -> {ok, remote()} | {error, term()}.
accept_offer(Sdp, Rate) ->
    {SessAddr, Media} = chappe_sip_sdp:parse(Sdp),
    pick(SessAddr, Media, Rate).

%% Read the far end out of the answer to an offer made with Law (l16: in
%% a 16 kHz room): where to send, the payload type it took and the
%% telephone-event it took, if any.
-spec read_answer(iodata(), law()) ->
    {ok, #{
        endpoint := {inet:ip_address(), inet:port_number()},
        rtcp := {inet:ip_address(), inet:port_number()} | undefined,
        pt := 0..127,
        dtmf := dtmf() | undefined,
        direction := direction()
    }}
    | {error, term()}.
read_answer(Sdp, Law) ->
    {SessAddr, Media} = chappe_sip_sdp:parse(Sdp),
    case pick(SessAddr, Media, rate(Law)) of
        {ok, #{law := Law} = R} ->
            {ok, maps:with([endpoint, rtcp, pt, dtmf, direction], R)};
        {ok, #{law := Other}} ->
            {error, {law_mismatch, Other}};
        {error, _} = Err ->
            Err
    end.

%% Answer Offer for Local: the chosen m-line carries the leg, every other
%% m-line is rejected with port 0, as RFC 3264 6 asks.
-spec answer(iodata(), local()) -> binary().
answer(Offer, #{addr := Addr, law := Law} = Local) ->
    {_, Media} = chappe_sip_sdp:parse(Offer),
    {ok, #{index := Chosen}} = accept_offer(Offer, rate(Law)),
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

%% The plan of a join's leg in a room of Rate (Opts: the join's sdp, law,
%% mute, direction): answering an offer fixes the format and its payload
%% type, RTCP mux, far end and direction (what the offer allows and the
%% join asks, both); offering uses L16 at 16 kHz, else the join's law or
%% Law, and muxes.
-spec plan(map(), 8000 | 16000, ulaw | alaw) -> {ok, plan()} | {error, term()}.
plan(#{sdp := Offer} = Opts, Rate, _Law) ->
    case accept_offer(Offer, Rate) of
        {ok, #{direction := Dir} = R} ->
            {ok, (maps:with([law, pt, mux, ptime, dtmf], R))#{
                rtcp_remote => maps:get(rtcp, R),
                remote => maps:get(endpoint, R),
                answer_to => Offer,
                mute => maps:get(mute, Opts, false),
                dir => combine(maps:get(direction, Opts, sendrecv), Dir)
            }};
        {error, _} = Err ->
            Err
    end;
plan(Opts, Rate, Law) ->
    {ok,
        maps:merge(offer_codec(Rate, maps:get(law, Opts, Law)), #{
            mux => true,
            %% offered; the leg takes it when the answer does
            dtmf_offer => ?DTMF_PT,
            mute => maps:get(mute, Opts, false),
            dir => maps:get(direction, Opts, sendrecv)
        })}.

%% what the mixer offers: L16 at 16 kHz, on its payload type, a law at
%% 8 kHz
offer_codec(16000, _Law) -> #{law => l16, pt => ?L16_PT};
offer_codec(8000, Law) -> #{law => Law}.

%% The SDP of a planned leg advertised at Addr and Port: the answer to
%% the offer it answers, or its offer.
-spec leg_sdp(plan(), inet:ip_address(), inet:port_number()) -> binary().
leg_sdp(Plan, Addr, Port) ->
    Local0 = maps:merge(maps:with([pt], Plan), #{
        addr => Addr,
        port => Port,
        law => maps:get(law, Plan),
        mux => maps:get(mux, Plan),
        direction => maps:get(dir, Plan)
    }),
    Local =
        case Plan of
            #{dtmf := #{pt := Pt}} -> Local0#{dtmf_pt => Pt};
            #{dtmf_offer := Pt} -> Local0#{dtmf_pt => Pt};
            _ -> Local0
        end,
    case maps:find(answer_to, Plan) of
        {ok, Offer} -> answer(Offer, Local);
        error -> offer(Local)
    end.

%% A one-codec offer for Local: the mixer cannot change a leg's format
%% once it is open, so it offers the one it opened the leg with, and
%% telephone-event at its clock when Local has a dtmf_pt.
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
    Pt = integer_to_binary(maps:get(pt, Local, pt(Law))),
    Clock = integer_to_binary(rate(Law)),
    {Fmts, Dtmf} =
        case maps:find(dtmf_pt, Local) of
            {ok, D} ->
                Te = integer_to_binary(D),
                {[Pt, <<" ">>, Te], [
                    [
                        <<"a=rtpmap:">>,
                        Te,
                        <<" telephone-event/">>,
                        Clock,
                        crlf()
                    ],
                    [<<"a=fmtp:">>, Te, <<" ">>, ?DTMF_EVENTS, crlf()]
                ]};
            error ->
                {Pt, []}
        end,
    [
        [<<"m=audio ">>, integer_to_binary(Port), <<" ">>, ?PROTO, <<" ">>],
        [Fmts, crlf()],
        [<<"a=rtpmap:">>, Pt, <<" ">>, encoding(Law), <<"/">>, Clock, crlf()],
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
pt(alaw) -> 8;
pt(l16) -> ?L16_PT.

encoding(ulaw) -> <<"PCMU">>;
encoding(alaw) -> <<"PCMA">>;
encoding(l16) -> <<"L16">>.

rate(l16) -> 16000;
rate(_Law) -> 8000.

%% internal: reading

pick(SessAddr, Media, Rate) ->
    Audio = [
        {I, M}
     || {I, #{media := <<"audio">>, port := P} = M} <- lists:enumerate(
            0, Media
        ),
        P > 0
    ],
    case Audio of
        [] -> {error, no_audio};
        [{I, M} | _] -> pick_stream(I, M, SessAddr, Rate)
    end.

pick_stream(_I, #{proto := Proto}, _SessAddr, _Rate) when Proto =/= ?PROTO ->
    {error, {unsupported_proto, Proto}};
pick_stream(_I, #{maxptime := Max}, _SessAddr, _Rate) when Max < ?PTIME ->
    {error, {maxptime, Max}};
pick_stream(I, #{port := Port} = M, SessAddr, Rate) ->
    case codecs(M, Rate) of
        [] ->
            {error, no_common_codec};
        [{Law, Pt} | _] ->
            case chappe_sip_sdp:address(maps:get(addr, M, SessAddr)) of
                {ok, Ip} ->
                    {ok, #{
                        endpoint => {Ip, Port},
                        rtcp => chappe_sip_sdp:rtcp_address(M, Ip),
                        law => Law,
                        pt => Pt,
                        mux => maps:get(mux, M, false),
                        ptime => maps:get(ptime, M, ?PTIME),
                        dtmf => dtmf(M, Rate),
                        direction => room_side(maps:get(dir, M, sendrecv)),
                        index => I
                    }};
                error ->
                    {error, no_connection_address}
            end
    end.

%% The formats of the m-line the room's rate can take, in the offer's
%% order: G.711 by its static payload type at 8000, L16 at 16000 (mono)
%% by its rtpmap at 16000.
codecs(#{fmts := Fmts}, 8000) ->
    [{L, Pt} || F <- Fmts, {L, Pt} <- [law(F)], L =/= undefined];
codecs(#{fmts := Fmts} = M, 16000) ->
    Maps = maps:get(rtpmap, M, #{}),
    [
        {l16, Pt}
     || F <- Fmts,
        lists:member(string:lowercase(maps:get(F, Maps, <<>>)), [
            <<"l16/16000">>, <<"l16/16000/1">>
        ]),
        Pt <- [payload_type(F)],
        Pt =/= undefined
    ].

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

%% The first telephone-event at the room's clock among the m-line's
%% formats (RFC 4733 2.4: its rate is the unit of its timestamps and
%% durations, so it must be the audio's).
dtmf(#{fmts := Fmts} = M, Rate) ->
    Maps = maps:get(rtpmap, M, #{}),
    Want = <<"telephone-event/", (integer_to_binary(Rate))/binary>>,
    case [F || F <- Fmts, string:lowercase(maps:get(F, Maps, <<>>)) =:= Want] of
        [F | _] ->
            case payload_type(F) of
                undefined ->
                    undefined;
                Pt ->
                    #{
                        pt => Pt,
                        events => events(maps:find(F, maps:get(fmtp, M, #{})))
                    }
            end;
        [] ->
            undefined
    end.

payload_type(F) ->
    case string:to_integer(F) of
        {Pt, <<>>} when is_integer(Pt), Pt >= 0, Pt =< 127 -> Pt;
        _ -> undefined
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

law(<<"0">>) -> {ulaw, 0};
law(<<"8">>) -> {alaw, 8};
law(_) -> {undefined, undefined}.
