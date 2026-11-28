%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Reading SDP (RFC 4566) for the SIP side.
%%
%% The few facts the stack takes out of a session description: its
%% connection address and media lines (parse/1), its o= line (an
%% unchanged one means an unchanged session, RFC 3264 8), whether it puts
%% the session on hold (RFC 3264 8.4) and whether it comes from a WebRTC
%% endpoint (DTLS-SRTP with ICE, RFC 8829). rtpengine rewrites SDP; the
%% stack only changes its own offer's direction for a hold (hold/2) and
%% cuts a party's offer to what it was answered with, for a re-offer that
%% party never sees (answered/2).
-module(chappe_sip_sdp).

-export([parse/1, address/1, words/1, rtcp_address/2]).
-export([origin/1, same_version/2, on_hold/1, webrtc/1, connection/1]).
-export([sections/1, join/2, refused/1]).
-export([hold/2, next_version/1]).
-export([set_direction/2, answered/2]).

-export_type([media/0]).

%% A media line: kind, port, proto and formats, with its own connection
%% address when it has one, its direction, RTCP mux and the a=rtcp,
%% a=rtpmap, a=fmtp, a=ptime and a=maxptime it carries.
-type media() :: #{
    media := binary(),
    port := 0..65535,
    proto := binary(),
    fmts := [binary()],
    dir := sendrecv | sendonly | recvonly | inactive,
    _ => _
}.

%% Whether offer A leaves the session B as it is: the same o= line, so the
%% same version (RFC 3264 8); an SDP without one only when equal.
-spec same_version(binary(), binary()) -> boolean().
same_version(A, B) ->
    case {origin(A), origin(B)} of
        {undefined, _} -> A =:= B;
        {O, O} -> true;
        _ -> false
    end.

%% The session-level lines of an SDP (before the first m= line) and each
%% media section's lines, its m= line first, line ends dropped: what a
%% caller that moves media sections between descriptions works on.
-spec sections(iodata()) -> {[binary()], [[binary()]]}.
sections(Sdp) ->
    {Sess, Rest} = lists:splitwith(fun not_m/1, lines(Sdp)),
    {Sess, media_sections(Rest, [])}.

not_m(<<"m=", _/binary>>) -> false;
not_m(_) -> true.

lines(Sdp) ->
    binary:split(iolist_to_binary(Sdp), [<<"\r\n">>, <<"\n">>], [
        global, trim_all
    ]).

media_sections([], Acc) ->
    lists:reverse(Acc);
media_sections([M | Rest], Acc) ->
    {Own, Next} = lists:splitwith(fun not_m/1, Rest),
    media_sections(Next, [[M | Own] | Acc]).

%% RFC 3264 6: a media section refused in an answer: its m= line with port
%% 0, the rest of the line as offered.
-spec refused([binary()]) -> [binary()].
refused([<<"m=", Rest/binary>> | _]) ->
    case words(Rest) of
        [Kind, _Port | More] ->
            [iolist_to_binary(["m=", lists:join(" ", [Kind, <<"0">> | More])])];
        _ ->
            [<<"m=audio 0 RTP/AVP 0">>]
    end.

%% The SDP of session lines and media sections, CRLF line ends.
-spec join([binary()], [[binary()]]) -> binary().
join(Sess, Media) ->
    iolist_to_binary([[L, <<"\r\n">>] || L <- Sess ++ lists:append(Media)]).

%% The o= line without its "o=", or undefined.
-spec origin(iodata()) -> binary() | undefined.
origin(Sdp) ->
    case
        re:run(Sdp, <<"^o=([^\r\n]*)">>, [
            multiline, {capture, all_but_first, binary}
        ])
    of
        {match, [O]} -> O;
        nomatch -> undefined
    end.

%% RFC 3264 8.4: a session is on hold when none of its live streams
%% (a port other than 0) receives: each is sendonly or inactive. A session
%% with no live stream is not on hold.
-spec on_hold(iodata()) -> boolean().
on_hold(Sdp) ->
    {_, Media} = parse(Sdp),
    case [Dir || #{port := P, dir := Dir} <- Media, P =/= 0] of
        [] ->
            false;
        Dirs ->
            lists:all(fun(D) -> D =:= sendonly orelse D =:= inactive end, Dirs)
    end.

%% A WebRTC endpoint: a SAVPF profile (UDP/TLS/RTP/SAVPF, RTP/SAVPF) or
%% ICE candidates in the offer.
-spec webrtc(iodata()) -> boolean().
webrtc(Sdp0) ->
    Sdp = iolist_to_binary(Sdp0),
    {_, Media} = parse(Sdp),
    binary:match(Sdp, <<"a=ice-ufrag:">>) =/= nomatch orelse
        lists:any(
            fun(#{proto := Proto}) ->
                binary:match(Proto, <<"SAVPF">>) =/= nomatch
            end,
            Media
        ).

%% The address media goes to: the session c= line, else the first media
%% one. undefined when there is none or it is not an IP literal.
-spec connection(iodata()) -> inet:ip_address() | undefined.
connection(Sdp) ->
    {Sess, Media} = parse(Sdp),
    Addrs = [Sess | [maps:get(addr, M, undefined) || M <- Media]],
    case [Ip || A <- Addrs, A =/= undefined, {ok, Ip} <- [address(A)]] of
        [Ip | _] -> Ip;
        [] -> undefined
    end.

%% An IP literal out of SDP text.
-spec address(binary() | undefined) -> {ok, inet:ip_address()} | error.
address(Bin) ->
    chappe_sip_net:address(Bin).

%% Where a media line of parse/1 wants its RTCP when its a=rtcp names it
%% (RFC 3605): that port, at the attribute's address or else Ip, the
%% media's. undefined when RTCP is muxed (RFC 5761), without an a=rtcp or
%% with one that does not parse.
-spec rtcp_address(media(), inet:ip_address()) ->
    {inet:ip_address(), inet:port_number()} | undefined.
rtcp_address(#{mux := true}, _Ip) ->
    undefined;
rtcp_address(#{rtcp := V}, Ip) ->
    case words(V) of
        [P] -> rtcp_port(P, {ok, Ip});
        [P, <<"IN">>, _Family, Addr | _] -> rtcp_port(P, address(Addr));
        _ -> undefined
    end;
rtcp_address(_M, _Ip) ->
    undefined.

rtcp_port(P, {ok, Ip}) ->
    case string:to_integer(P) of
        {N, <<>>} when is_integer(N), N > 0, N =< 65535 -> {Ip, N};
        _ -> undefined
    end;
rtcp_port(_P, error) ->
    undefined.

%% {SessionAddress, [Media]} where each media is #{media, port, proto,
%% fmts, dir, addr (when it has its own c=), mux, rtcp, rtpmap, fmtp,
%% ptime, maxptime}.
-spec parse(iodata()) -> {binary() | undefined, [media()]}.
parse(Sdp) ->
    Lines = lines(Sdp),
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

%% The words of an SDP value.
-spec words(binary()) -> [binary()].
words(Bin) ->
    binary:split(Bin, <<" ">>, [global, trim_all]).

port(Bin) ->
    %% m=<media> <port>/<count>: only the base port matters for one leg
    case string:to_integer(Bin) of
        {N, _} when is_integer(N), N >= 0, N =< 65535 -> N;
        _ -> 0
    end.

%% RFC 3261 14.1 (RFC 3264 8): a new offer built from our last session
%% description carries the next o= session version
-spec next_version(binary()) -> binary().
next_version(Sdp) ->
    case
        re:run(Sdp, "^(o=\\S+ \\S+ )([0-9]+)", [
            multiline, {capture, [1, 2], index}
        ])
    of
        {match, [{S, L}, {VS, VL}]} ->
            V = binary_to_integer(binary:part(Sdp, VS, VL)),
            <<
                (binary:part(Sdp, 0, S))/binary,
                (binary:part(Sdp, S, L))/binary,
                (integer_to_binary(V + 1))/binary,
                (binary:part(Sdp, VS + VL, byte_size(Sdp) - VS - VL))/binary
            >>;
        nomatch ->
            Sdp
    end.

%% RFC 3264 8.4: hold moves every live stream to sendonly
%% (or inactive when it was recvonly); unhold reverses that. Each m= section
%% gets its own direction attribute, so a session-level one is folded into
%% them. A rejected stream (port 0) is left alone.
-spec hold(binary(), boolean()) -> binary().
hold(Sdp, Hold) ->
    Eol = eol(Sdp),
    {Session, Medias} = sections(Sdp),
    SessDir = sdp_direction(Session, <<"sendrecv">>),
    Out =
        case Medias of
            [] ->
                set_direction(Session, hold_direction(SessDir, Hold));
            _ ->
                [L || L <- Session, not is_direction(L)] ++
                    lists:append([
                        media_hold(M, SessDir, Hold)
                     || M <- Medias
                    ])
        end,
    iolist_to_binary([[L, Eol] || L <- Out]).

media_hold([M | _] = Section, SessDir, Hold) ->
    case binary:split(M, <<" ">>, [global]) of
        [_, <<"0">> | _] ->
            Section;
        _ ->
            Dir = sdp_direction(Section, SessDir),
            set_direction(Section, hold_direction(Dir, Hold))
    end.

hold_direction(<<"sendrecv">>, true) -> <<"sendonly">>;
hold_direction(<<"recvonly">>, true) -> <<"inactive">>;
hold_direction(<<"sendonly">>, false) -> <<"sendrecv">>;
hold_direction(<<"inactive">>, false) -> <<"recvonly">>;
hold_direction(Dir, _Hold) -> Dir.

sdp_direction(Lines, Default) ->
    case [D || <<"a=", D/binary>> <- Lines, is_direction(<<"a=", D/binary>>)] of
        [] -> Default;
        Dirs -> lists:last(Dirs)
    end.

is_direction(<<"a=", D/binary>>) ->
    lists:member(D, [
        <<"sendrecv">>, <<"sendonly">>, <<"recvonly">>, <<"inactive">>
    ]);
is_direction(_) ->
    false.

%% The lines of a section (or a session) with its direction attribute
%% replaced in place by a=Dir, or a=Dir added when it has none.
-spec set_direction([binary()], binary()) -> [binary()].
set_direction(Lines, Dir) ->
    Attr = <<"a=", Dir/binary>>,
    case lists:any(fun is_direction/1, Lines) of
        true ->
            {Out, _} = lists:mapfoldl(
                fun(L, Done) ->
                    case is_direction(L) of
                        true when not Done -> {[Attr], true};
                        true -> {[], Done};
                        false -> {[L], Done}
                    end
                end,
                false,
                Lines
            ),
            lists:append(Out);
        false ->
            Lines ++ [Attr]
    end.

%% the line end an SDP uses: CRLF, or LF when it has no CRLF
eol(Sdp) ->
    case binary:match(Sdp, <<"\r\n">>) of
        nomatch -> <<"\n">>;
        _ -> <<"\r\n">>
    end.

%% RFC 3264 6.1: the formats of an answer's stream are the ones the
%% offerer sends and receives on it from then on. Offer with each RTP
%% media section cut to the formats its counterpart in Answer (the
%% section at the same place) names, the a=rtpmap, a=fmtp and a=rtcp-fb
%% lines of the others dropped: a re-offer made from the offerer's own
%% SDP, which the offerer never sees, then keeps it on what it was
%% answered with (chappe_sip_b2b_replace). A format is the same codec in
%% both by its a=rtpmap, case aside and a channel count of 1 the same as
%% none, or without one by its static payload type (RFC 3551 6). A section
%% the answer refused (port 0) or has no counterpart for, or that would
%% keep no format, stays as offered; so does Offer when Answer has no
%% media.
-spec answered(binary(), binary()) -> binary().
answered(Offer, Answer) ->
    {Session, Offered} = sections(Offer),
    {_, Answered} = sections(Answer),
    case cut_media(Offered, Answered) of
        Offered ->
            Offer;
        Media ->
            Eol = eol(Offer),
            iolist_to_binary([[L, Eol] || L <- Session ++ lists:append(Media)])
    end.

cut_media([O | Os], [A | As]) -> [cut_section(O, A) | cut_media(Os, As)];
cut_media(Os, []) -> Os;
cut_media([], _As) -> [].

cut_section([MO | Lines] = O, [MA | ALines]) ->
    case {words(MO), words(MA)} of
        {[Kind, Port, Proto | Fmts], [_, APort, _ | AFmts]} when
            APort =/= <<"0">>
        ->
            Codecs = [codec(F, rtpmaps(ALines)) || F <- AFmts],
            Maps = rtpmaps(Lines),
            Keep = [F || F <- Fmts, lists:member(codec(F, Maps), Codecs)],
            case rtp(Proto) andalso Keep =/= [] andalso Keep =/= Fmts of
                true ->
                    Gone = Fmts -- Keep,
                    M = iolist_to_binary(
                        lists:join(<<" ">>, [Kind, Port, Proto | Keep])
                    ),
                    [M | [L || L <- Lines, not lists:member(fmt_of(L), Gone)]];
                false ->
                    O
            end;
        _ ->
            O
    end.

rtp(Proto) ->
    binary:match(Proto, <<"RTP">>) =/= nomatch.

%% the format an a=rtpmap, a=fmtp or a=rtcp-fb line is about
fmt_of(<<"a=rtpmap:", V/binary>>) -> first_word(V);
fmt_of(<<"a=fmtp:", V/binary>>) -> first_word(V);
fmt_of(<<"a=rtcp-fb:", V/binary>>) -> first_word(V);
fmt_of(_Line) -> undefined.

first_word(V) ->
    hd(binary:split(V, <<" ">>)).

%% #{Fmt => codec} of a section's a=rtpmap lines
rtpmaps(Lines) ->
    maps:from_list([
        {Fmt, encoding(Enc)}
     || <<"a=rtpmap:", V/binary>> <- Lines,
        [Fmt, Enc] <- [binary:split(V, <<" ">>)]
    ]).

encoding(Enc) ->
    case binary:split(string:lowercase(string:trim(Enc)), <<"/">>, [global]) of
        [Name, Rate, <<"1">>] -> <<Name/binary, "/", Rate/binary>>;
        Parts -> iolist_to_binary(lists:join(<<"/">>, Parts))
    end.

%% a format's codec: its a=rtpmap, else its static payload type's
codec(Fmt, Maps) ->
    case Maps of
        #{Fmt := Codec} -> Codec;
        #{} -> static(Fmt)
    end.

static(<<"0">>) -> <<"pcmu/8000">>;
static(<<"3">>) -> <<"gsm/8000">>;
static(<<"4">>) -> <<"g723/8000">>;
static(<<"8">>) -> <<"pcma/8000">>;
static(<<"9">>) -> <<"g722/8000">>;
static(<<"13">>) -> <<"cn/8000">>;
static(<<"18">>) -> <<"g729/8000">>;
static(Fmt) -> {pt, Fmt}.
