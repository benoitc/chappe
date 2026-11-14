%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc What a SIPREC recording (chappe_sip_siprec) says to its recording
%% server: the body of the RS INVITE and re-INVITEs, a multipart/mixed of
%% the SDP offer (RFC 7866 7.1.1, one m-line per recorded stream with its
%% a=label) and the full metadata snapshot (RFC 7865); and the SRS's
%% answer cut back into each tap's part. Pure functions over the
%% recording's state.
-module(chappe_sip_siprec_body).

-export([body/1, media/1, identity/3, answers/2, sdp_of/1, sdp_only/1]).

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
