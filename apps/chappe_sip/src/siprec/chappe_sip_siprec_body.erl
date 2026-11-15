%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc What a SIPREC recording (chappe_sip_siprec) says to its recording
%% server: the body of the RS INVITE and re-INVITEs, a multipart/mixed of
%% the SDP offer (RFC 7866 7.1.1, one m-line per recorded stream with its
%% a=label) and the full metadata snapshot (RFC 7865); and the SRS's
%% answer cut back into each tap's part. Pure functions over the
%% recording's state, and the checks of chappe_sip_siprec:start/3's
%% arguments, made in the caller.
-module(chappe_sip_siprec_body).

-export([body/1, media/1, identity/3, answers/2, sdp_of/1, sdp_only/1]).
-export([srs/1, valid_opts/1, security/1, reanswer/2]).

%% The RS body: the SDP offer, a sendonly (or, paused, inactive) m-line per
%% stream with its label, and the full metadata snapshot.
-spec body(map()) -> {binary(), binary()}.
body(#{paused := Paused, version := V, opts := Opts} = St) ->
    Dir =
        case Paused of
            true -> <<"a=inactive">>;
            false -> <<"a=sendonly">>
        end,
    Sections = [
        recorded(Lines, Label, Dir)
     || #{lines := Lines, label := Label} <- media(St)
    ],
    Sess = [
        <<"v=0">>,
        <<"o=chappe ", (session_id(St))/binary, " ",
            (integer_to_binary(V))/binary, " ",
            (origin_addr(Sections))/binary>>,
        <<"s=-">>,
        <<"t=0 0">>
    ],
    Sdp = chappe_sip_sdp:join(Sess, Sections),
    Meta = chappe_sip_siprec_meta:build(metadata(St)),
    CT =
        case maps:get(legacy_content_type, Opts, false) of
            true -> <<"application/rs-metadata">>;
            false -> chappe_sip_siprec_meta:content_type()
        end,
    chappe_sip_multipart:build([
        #{content_type => <<"application/sdp">>, body => Sdp},
        #{
            content_type => CT,
            disposition => chappe_sip_siprec_meta:disposition(),
            body => Meta
        }
    ]).

%% every recorded stream, in offer order
-spec media(map()) -> [map()].
media(#{streams := Ss}) ->
    lists:append([M || #{media := M} <- Ss]).

%% RFC 7866 7.1.1: each recorded stream sendonly with its a=label; a
%% paused one inactive (7.1.1.1)
recorded([M | Rest], Label, Dir) ->
    Kept = [L || L <- Rest, not dir_or_label(L)],
    [M | Kept] ++ [Dir, <<"a=label:", Label/binary>>].

dir_or_label(<<"a=sendonly">>) -> true;
dir_or_label(<<"a=recvonly">>) -> true;
dir_or_label(<<"a=sendrecv">>) -> true;
dir_or_label(<<"a=inactive">>) -> true;
dir_or_label(<<"a=label:", _/binary>>) -> true;
dir_or_label(_) -> false.

session_id(#{cs_id := Id}) ->
    <<N:32, _/binary>> = crypto:hash(sha256, Id),
    integer_to_binary(N).

%% o= names the address the media comes from: the first stream's c=
origin_addr([[_M | Lines] | _]) ->
    case [A || <<"c=", A/binary>> <- Lines] of
        [A | _] -> A;
        [] -> <<"IN IP4 0.0.0.0">>
    end;
origin_addr([]) ->
    <<"IN IP4 0.0.0.0">>.

%% The full snapshot (RFC 7865 8.1): the call as one CS, every participant
%% it had (the ones gone with their disassociate-time), the streams, and
%% who sends and receives each. Only what the metadata option allows.
metadata(
    #{cs_id := Cs, start := Start, call_ref := CallRef, opts := Opts} = St
) ->
    Allow = maps:get(metadata, Opts, #{}),
    Ps = maps:get(participants, St),
    StreamIds = fun(Leg) ->
        [
            Id
         || #{party := L, media := M} <- maps:get(streams, St),
            L =:= Leg,
            #{id := Id} <- M
        ]
    end,
    Session0 = #{id => Cs, start_time => Start},
    Session =
        case maps:get(call_ref, Allow, true) of
            true -> Session0#{call_ref => CallRef};
            false -> Session0
        end,
    #{
        datamode => complete,
        sessions => [Session],
        participants => [
            #{id => Id, names => [name_id(P, Allow)]}
         || #{id := Id} = P <- Ps
        ],
        streams => [
            #{id => Id, session_id => Cs, label => L}
         || #{id := Id, label := L} <- media(St)
        ],
        session_assocs => [#{session_id => Cs, associate_time => Start}],
        participant_session_assocs => [
            times(P, #{participant_id => Id, session_id => Cs})
         || #{id := Id} = P <- Ps
        ],
        participant_stream_assocs => [
            times(P, #{
                participant_id => Id,
                send => StreamIds(Leg),
                recv => lists:append([StreamIds(O) || O <- others(Leg, St)])
            })
         || #{id := Id, party := Leg} = P <- Ps
        ]
    }.

others(Leg, #{streams := Ss}) ->
    [L || #{party := L} <- Ss, L =/= Leg].

name_id(P, Allow) ->
    Aor =
        case maps:get(aors, Allow, true) of
            true -> maps:get(aor, P);
            false -> <<"sip:anonymous@anonymous.invalid">>
        end,
    case {maps:get(names, Allow, true), P} of
        {true, #{name := Name}} -> #{aor => Aor, name => Name};
        _ -> #{aor => Aor}
    end.

times(P, A) ->
    A1 = A#{associate_time => maps:get(since, P)},
    case P of
        #{until := U} -> A1#{disassociate_time => U};
        _ -> A1
    end.

%% who a party is in the metadata: the app's name for it, else its leg's
%% name-addr
-spec identity(a | b, binary() | undefined, map()) -> map().
identity(Leg, Addr, Opts) ->
    case maps:get(participants, Opts, #{}) of
        #{Leg := Who} ->
            maps:with([aor, name], Who);
        _ ->
            from_addr(Addr)
    end.

from_addr(undefined) ->
    #{aor => <<"sip:anonymous@anonymous.invalid">>};
from_addr(Addr) ->
    case chappe_sip_hdr:name_addr(Addr) of
        {ok, #{uri := Uri} = NA} ->
            case maps:get(display, NA, <<>>) of
                <<>> -> #{aor => Uri};
                Name -> #{aor => Uri, name => Name}
            end;
        _ ->
            #{aor => <<"sip:anonymous@anonymous.invalid">>}
    end.

%% The SRS's answer, cut into each tap's part: the answer's session lines
%% with the m-lines of that tap's streams, in offer order (RFC 3264 6: the
%% answer has as many m-lines as the offer). {error, bad_answer} when it
%% has fewer.
-spec answers(binary(), [map()]) ->
    {ok, [{term(), binary()}]} | {error, bad_answer}.
answers(Answer, Streams) ->
    {Sess, Media} = chappe_sip_sdp:sections(sdp_of(Answer)),
    Need = lists:sum([length(M) || #{media := M} <- Streams]),
    case length(Media) >= Need of
        false -> {error, bad_answer};
        true -> {ok, cut(Streams, Sess, Media)}
    end.

cut([], _Sess, _Media) ->
    [];
cut([#{media := M, tap := Tap} | Rest], Sess, Media) ->
    {Mine, Others} = lists:split(length(M), Media),
    [{Tap, chappe_sip_sdp:join(Sess, Mine)} | cut(Rest, Sess, Others)].

%% The answer to an offer of the recording server: the recorded streams as
%% they are, and an m-line past them refused with port 0, so it has as many
%% as the offer (RFC 3264 6). error when the offer has fewer than the
%% session: it removed a stream (8).
-spec reanswer(binary(), map()) -> {ok, binary()} | error.
reanswer(Offer, St) ->
    {_CT, Body} = body(St),
    {Sess, Mine} = chappe_sip_sdp:sections(sdp_only(sdp_of(Body))),
    {_, Theirs} = chappe_sip_sdp:sections(sdp_of(Offer)),
    case length(Theirs) >= length(Mine) of
        true ->
            Extra = lists:nthtail(length(Mine), Theirs),
            {ok,
                chappe_sip_sdp:join(
                    Sess, Mine ++ [chappe_sip_sdp:refused(M) || M <- Extra]
                )};
        false ->
            error
    end.

%% the SDP of a body that may be a multipart with metadata
-spec sdp_of(binary()) -> binary().
sdp_of(<<"v=", _/binary>> = Sdp) ->
    Sdp;
sdp_of(Body) ->
    case binary:match(Body, <<"\r\nv=0">>) of
        {Pos, _} -> binary:part(Body, Pos + 2, byte_size(Body) - Pos - 2);
        nomatch -> Body
    end.

%% the SDP part of our multipart body
-spec sdp_only(binary()) -> binary().
sdp_only(Sdp) ->
    case binary:split(Sdp, <<"\r\n--">>) of
        [S, _] -> <<S/binary, "\r\n">>;
        [S] -> S
    end.

%% RFC 7866 12, for chappe_sip_siprec:init/1: {ok, Srtp} when the RS can be
%% as secure as the call (Srtp: its taps must be SRTP), {error,
%% {insecure_srs, tls}} when the call has a TLS leg and the SRS is not
%% reached over TLS
-spec security(map()) -> {ok, boolean()} | {error, {insecure_srs, tls}}.
security(#{source := {room, _}}) ->
    {ok, false};
security(#{opts := #{allow_downgrade := true}}) ->
    {ok, false};
security(#{call_ref := CallRef, srs := Srs, opts := Opts}) ->
    Legs = [leg_security(D) || {dialog, D} <- chappe_sip_call:local(CallRef)],
    Tls = lists:member(tls, lists:append(Legs)),
    Srtp = lists:member(srtp, lists:append(Legs)),
    RsTls =
        chappe_sip_uri:is_secure(Srs) orelse
            case Opts of
                #{proxy := P} when is_binary(P) -> chappe_sip_uri:is_secure(P);
                _ -> false
            end,
    case Tls andalso not RsTls of
        true -> {error, {insecure_srs, tls}};
        false -> {ok, Srtp}
    end.

%% what makes a leg of the call secure: tls when its dialog was formed over
%% TLS (our sips: Contact there), srtp when its media is; the RS dialogs of
%% recordings (+sip.src, +sip.srs) are not legs of the call
leg_security(D) ->
    try {chappe_sip_dialog:local_contact(D), chappe_sip_dialog:remote_sdp(D)} of
        {Contact, Sdp} when is_binary(Contact) ->
            case binary:match(Contact, [<<"+sip.src">>, <<"+sip.srs">>]) of
                nomatch ->
                    [tls || chappe_sip_uri:is_secure(Contact)] ++
                        [srtp || savp(Sdp)];
                _ ->
                    []
            end;
        _ ->
            []
    catch
        exit:_ -> []
    end.

savp(Sdp) ->
    {_, Media} = chappe_sip_sdp:parse(Sdp),
    lists:any(
        fun(#{proto := P}) -> binary:match(P, <<"SAVP">>) =/= nomatch end,
        Media
    ).

%% The recording server's URI: a sip: or sips: URI, or the siprec_srs
%% config for default.
-spec srs(binary() | default) -> {ok, binary()} | {error, no_srs | badarg}.
srs(default) ->
    case chappe_sip_config:get(siprec_srs) of
        undefined -> {error, no_srs};
        Uri -> srs(Uri)
    end;
srs(<<"sip:", _/binary>> = Uri) ->
    {ok, Uri};
srs(<<"sips:", _/binary>> = Uri) ->
    {ok, Uri};
srs(_) ->
    {error, badarg}.

%% start/3's options, each of a known key and of its type.
-spec valid_opts(map()) -> boolean().
valid_opts(Opts) ->
    lists:all(fun valid_opt/1, maps:to_list(Opts)).

valid_opt({owner, P}) ->
    is_pid(P);
valid_opt({call_ref, R}) ->
    chappe_sip_call:valid(R);
valid_opt({answer_timeout, T}) ->
    is_integer(T) andalso T > 0;
valid_opt({participants, M}) ->
    is_map(M) andalso lists:all(fun valid_party/1, maps:to_list(M));
valid_opt({metadata, M}) ->
    is_map(M) andalso lists:all(fun is_boolean/1, maps:values(M));
valid_opt({legacy_content_type, B}) ->
    is_boolean(B);
valid_opt({headers, H}) ->
    is_list(H);
valid_opt({codec, C}) ->
    is_map(C);
valid_opt({ptime, P}) ->
    is_integer(P) andalso P > 0;
valid_opt({allow_downgrade, B}) ->
    is_boolean(B);
valid_opt({K, _}) ->
    lists:member(K, [from, proxy, auth, flow]).

valid_party({Leg, #{aor := Aor} = P}) when Leg =:= a; Leg =:= b; Leg =:= room ->
    is_binary(Aor) andalso is_binary(maps:get(name, P, <<>>));
valid_party(_) ->
    false.
