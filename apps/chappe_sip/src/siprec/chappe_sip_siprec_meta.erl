%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc SIPREC recording metadata (RFC 7865), built and parsed.
%%
%% A recording session (RS) carries, next to its SDP, an XML document that
%% says what is recorded: the communication sessions (CS), the
%% participants, the media streams and which participant sends and
%% receives which stream (RFC 7865 6). The client (chappe_sip_siprec)
%% builds it; an app acting as a recording server parses it.
%%
%% The document is a map:
%% ```
%% #{datamode => complete | partial,
%%   groups => [#{id, associate_time, disassociate_time}],
%%   sessions => [#{id, sip_session_ids, group_ref, start_time,
%%                  stop_time, reasons, call_ref}],
%%   participants => [#{id, names => [#{aor, name, lang}]}],
%%   streams => [#{id, session_id, label}],
%%   session_assocs => [#{session_id, associate_time, disassociate_time}],
%%   participant_session_assocs => [#{participant_id, session_id,
%%                  associate_time, disassociate_time, params}],
%%   participant_stream_assocs => [#{participant_id, send, recv,
%%                  associate_time, disassociate_time}]}
%% '''
%% Every key but id (and the ids an association names) is optional. Times
%% are RFC 3339 binaries (RFC 7865 6.9). call_ref is chappe's own
%% extension of the session element (RFC 7865 9 allows elements of other
%% namespaces there), in the namespace ext_ns/0, so a recording server
%% finds the call in chappe's records.
%%
%% The media type is application/rs-metadata+xml (RFC 9806 replaces RFC
%% 7866's application/rs-metadata with it); is_content_type/1 also takes
%% the older name, which recorders built on RFC 7866 still send.
-module(chappe_sip_siprec_meta).

-export([build/1, parse/1, snapshot_request/1, snapshot_request/2]).
-export([new_id/0, now/0, content_type/0, is_content_type/1, disposition/0]).
-export([ns/0, ext_ns/0, senders/1]).

-export_type([doc/0, participant/0, stream/0]).

-define(NS, "urn:ietf:params:xml:ns:recording:1").
-define(EXT_NS, "https://github.com/benoitc/chappe/ns/recording").
-define(NS_B, <<?NS>>).
-define(EXT_NS_B, <<?EXT_NS>>).
%% a metadata document larger than this is refused unparsed
-define(MAX_DOC, 65536).
%% an id, a label, a name or an AOR longer than this is refused
-define(MAX_VALUE, 1024).

-type doc() :: #{
    datamode => complete | partial,
    groups => [map()],
    sessions => [map()],
    participants => [participant()],
    streams => [stream()],
    session_assocs => [map()],
    participant_session_assocs => [map()],
    participant_stream_assocs => [map()]
}.
-type participant() :: #{
    id := binary(),
    names => [#{aor := binary(), name => binary(), lang => binary()}]
}.
-type stream() :: #{
    id := binary(), session_id => binary(), label => binary()
}.

%% ---- constants ----

-spec ns() -> binary().
ns() -> <<?NS>>.

-spec ext_ns() -> binary().
ext_ns() -> <<?EXT_NS>>.

%% RFC 9806 2, 4.1.
-spec content_type() -> binary().
content_type() -> <<"application/rs-metadata+xml">>.

%% The metadata media type, by RFC 9806's name or by RFC 7866's.
-spec is_content_type(binary()) -> boolean().
is_content_type(CT) ->
    [Type | _] = binary:split(CT, <<";">>),
    lists:member(chappe_sip_lib:lower(chappe_sip_lib:trim(Type)), [
        <<"application/rs-metadata+xml">>, <<"application/rs-metadata">>
    ]).

%% RFC 7866 9: the disposition of the metadata part.
-spec disposition() -> binary().
disposition() -> <<"recording-session">>.

%% A unique id (RFC 7865 6.10): a random (version 4) UUID, base64. Nothing
%% personal goes into it.
-spec new_id() -> binary().
new_id() ->
    <<A:48, _:4, B:12, _:2, C:62>> = crypto:strong_rand_bytes(16),
    base64:encode(<<A:48, 4:4, B:12, 2:2, C:62>>).

%% Now, as RFC 7865 6.9 writes times: RFC 3339, UTC, capital T and Z.
-spec now() -> binary().
now() ->
    list_to_binary(
        calendar:system_time_to_rfc3339(
            erlang:system_time(second), [{offset, "Z"}]
        )
    ).

%% ---- build ----

%% The XML document of Doc (RFC 7865 9), elements in schema order.
-spec build(doc()) -> binary().
build(Doc) ->
    iolist_to_binary([
        <<"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n">>,
        <<"<recording xmlns='" ?NS "'>\n">>,
        el(
            <<"datamode">>,
            [],
            esc(atom_to_binary(maps:get(datamode, Doc, complete)))
        ),
        [group(G) || G <- maps:get(groups, Doc, [])],
        [session(S) || S <- maps:get(sessions, Doc, [])],
        [participant(P) || P <- maps:get(participants, Doc, [])],
        [stream(S) || S <- maps:get(streams, Doc, [])],
        [sr_assoc(A) || A <- maps:get(session_assocs, Doc, [])],
        [ps_assoc(A) || A <- maps:get(participant_session_assocs, Doc, [])],
        [pst_assoc(A) || A <- maps:get(participant_stream_assocs, Doc, [])],
        <<"</recording>\n">>
    ]).

group(#{id := Id} = G) ->
    el(<<"group">>, [{<<"group_id">>, Id}], times(G)).

session(#{id := Id} = S) ->
    el(<<"session">>, [{<<"session_id">>, Id}], [
        [text(<<"sipSessionID">>, V) || V <- maps:get(sip_session_ids, S, [])],
        [reason(R) || R <- maps:get(reasons, S, [])],
        opt(<<"group-ref">>, group_ref, S),
        opt(<<"start-time">>, start_time, S),
        opt(<<"stop-time">>, stop_time, S),
        case S of
            #{call_ref := Ref} ->
                [
                    <<"<call-ref xmlns='" ?EXT_NS "'>">>,
                    esc(Ref),
                    <<"</call-ref>">>
                ];
            _ ->
                []
        end
    ]).

reason(#{cause := Cause} = R) ->
    el(
        <<"reason">>,
        [{<<"cause">>, integer_to_binary(Cause)}] ++
            [{<<"protocol">>, P} || #{protocol := P} <- [R]],
        esc(maps:get(text, R, <<>>))
    ).

participant(#{id := Id} = P) ->
    el(<<"participant">>, [{<<"participant_id">>, Id}], [
        name_id(N)
     || N <- maps:get(names, P, [])
    ]).

name_id(#{aor := Aor} = N) ->
    Name =
        case N of
            #{name := V} ->
                el(
                    <<"name">>,
                    [{<<"xml:lang">>, L} || #{lang := L} <- [N]],
                    esc(V)
                );
            _ ->
                []
        end,
    el(<<"nameID">>, [{<<"aor">>, Aor}], Name).

stream(#{id := Id} = S) ->
    el(
        <<"stream">>,
        [{<<"stream_id">>, Id}] ++
            [{<<"session_id">>, Sid} || #{session_id := Sid} <- [S]],
        opt(<<"label">>, label, S)
    ).

sr_assoc(#{session_id := Sid} = A) ->
    el(<<"sessionrecordingassoc">>, [{<<"session_id">>, Sid}], times(A)).

ps_assoc(#{participant_id := P, session_id := S} = A) ->
    el(
        <<"participantsessionassoc">>,
        [{<<"participant_id">>, P}, {<<"session_id">>, S}],
        [
            times(A),
            [
                el(<<"param">>, [{<<"pname">>, K}, {<<"pval">>, V}], [])
             || {K, V} <- maps:get(params, A, [])
            ]
        ]
    ).

pst_assoc(#{participant_id := P} = A) ->
    el(<<"participantstreamassoc">>, [{<<"participant_id">>, P}], [
        [text(<<"send">>, Id) || Id <- maps:get(send, A, [])],
        [text(<<"recv">>, Id) || Id <- maps:get(recv, A, [])],
        times(A)
    ]).

times(M) ->
    [
        opt(<<"associate-time">>, associate_time, M),
        opt(<<"disassociate-time">>, disassociate_time, M)
    ].

opt(Name, Key, M) ->
    case M of
        #{Key := V} -> text(Name, V);
        _ -> []
    end.

text(Name, V) -> el(Name, [], esc(V)).

el(Name, Attrs, Content) ->
    As = [[<<" ">>, K, <<"=\"">>, esc(V), <<"\"">>] || {K, V} <- Attrs],
    case iolist_size(Content) of
        0 -> [<<"<">>, Name, As, <<"/>\n">>];
        _ -> [<<"<">>, Name, As, <<">">>, Content, <<"</">>, Name, <<">\n">>]
    end.

esc(V) -> chappe_sip_lib:xml_escape(V).

%% RFC 7865 7: the snapshot request of a recording server, with its reason
%% when given.
-spec snapshot_request(binary() | undefined) -> binary().
snapshot_request(Reason) ->
    iolist_to_binary([
        <<"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n">>,
        <<"<requestsnapshot xmlns='" ?NS "'>">>,
        case Reason of
            undefined -> [];
            _ -> [<<"<requestreason>">>, esc(Reason), <<"</requestreason>">>]
        end,
        <<"</requestsnapshot>\n">>
    ]).

%% Whether a request body is a snapshot request (RFC 7866 9.2): {ok,
%% Reason} when its Content-Type is the metadata's and it parses as one,
%% `no' otherwise.
-spec snapshot_request(binary() | undefined, binary()) ->
    {ok, binary() | undefined} | no.
snapshot_request(undefined, _Body) ->
    no;
snapshot_request(CT, Body) ->
    case is_content_type(CT) andalso parse(Body) of
        {ok, {snapshot_request, Reason}} -> {ok, Reason};
        _ -> no
    end.

%% ---- parse ----

%% A metadata document (RFC 7865 9): {ok, Doc}, or {ok, {snapshot_request,
%% Reason}} for a recording server's request (RFC 7865 7). Elements of
%% other namespaces are skipped, save chappe's call-ref. A document with a
%% DTD, over 64 KiB, in another namespace (RFC 7865 6.11) or with an
%% element missing its required id is {error, _}.
-spec parse(binary()) ->
    {ok, doc() | {snapshot_request, binary() | undefined}} | {error, term()}.
parse(Bin) when is_binary(Bin), byte_size(Bin) > ?MAX_DOC ->
    {error, too_large};
parse(Bin) when is_binary(Bin) ->
    case binary:match(Bin, [<<"<!DOCTYPE">>, <<"<!ENTITY">>]) of
        nomatch -> scan(Bin);
        _ -> {error, doctype}
    end;
parse(_) ->
    {error, badarg}.

scan(Bin) ->
    try
        case
            xmerl_sax_parser:stream(Bin, [
                {event_fun, fun sax/3}, {event_state, [{root, [], []}]}
            ])
        of
            {ok, [{root, [], [Root]}], _Rest} -> root(Root);
            {ok, _, _} -> {error, no_document};
            {_Error, _Loc, Why0, _Tail, _State} -> {error, {xml, Why0}}
        end
    catch
        error:{missing, _} = Why -> {error, Why};
        error:{too_long, _} = Why -> {error, Why};
        _:Why -> {error, {xml, Why}}
    end.

root({{?NS_B, <<"recording">>}, _, Cs}) ->
    recording(Cs);
root({{?NS_B, <<"requestsnapshot">>}, _, Cs}) ->
    {ok, {snapshot_request, first_text(<<"requestreason">>, Cs)}};
root(_) ->
    {error, not_recording_metadata}.

%% The SAX events into a tree of {{Ns, Local}, Attrs, Children}, a text
%% node being a binary among the children. Names stay binaries: a
%% document from a peer never makes atoms.
sax({startElement, Uri, Local, _QName, Attrs}, _Loc, Stack) ->
    [{{bin(Uri), bin(Local)}, [attr_kv(A) || A <- Attrs], []} | Stack];
sax({endElement, _Uri, _Local, _QName}, _Loc, [
    {Name, As, Cs}, {PName, PAs, PCs} | Rest
]) ->
    [{PName, PAs, [{Name, As, lists:reverse(Cs)} | PCs]} | Rest];
sax({characters, Chars}, _Loc, [{Name, As, Cs} | Rest]) ->
    [{Name, As, [bin(Chars) | Cs]} | Rest];
sax(_Event, _Loc, Stack) ->
    Stack.

attr_kv({"http://www.w3.org/XML/1998/namespace", _Prefix, Name, Value}) ->
    {<<"xml:", (bin(Name))/binary>>, bin(Value)};
attr_kv({_Uri, _Prefix, Name, Value}) ->
    {bin(Name), bin(Value)}.

bin(S) -> unicode:characters_to_binary(S).

recording(Cs) ->
    Mode =
        case first_text(<<"datamode">>, Cs) of
            <<"partial">> -> partial;
            _ -> complete
        end,
    {ok, #{
        datamode => Mode,
        groups => [p_group(E) || E <- named(<<"group">>, Cs)],
        sessions => [p_session(E) || E <- named(<<"session">>, Cs)],
        participants => [
            p_participant(E)
         || E <- named(<<"participant">>, Cs)
        ],
        streams => [p_stream(E) || E <- named(<<"stream">>, Cs)],
        session_assocs => [
            p_times(E, #{session_id => req(<<"session_id">>, E)})
         || E <- named(<<"sessionrecordingassoc">>, Cs)
        ],
        participant_session_assocs => [
            p_psa(E)
         || E <- named(<<"participantsessionassoc">>, Cs)
        ],
        participant_stream_assocs => [
            p_pst(E)
         || E <- named(<<"participantstreamassoc">>, Cs)
        ]
    }}.

p_group(E) ->
    p_times(E, #{id => req(<<"group_id">>, E)}).

p_session({_, _, Cs} = E) ->
    S0 = #{
        id => req(<<"session_id">>, E),
        sip_session_ids => [text(T) || T <- named(<<"sipSessionID">>, Cs)],
        reasons => [p_reason(R) || R <- named(<<"reason">>, Cs)]
    },
    S1 = put_text(group_ref, <<"group-ref">>, Cs, S0),
    S2 = put_text(start_time, <<"start-time">>, Cs, S1),
    S3 = put_text(stop_time, <<"stop-time">>, Cs, S2),
    case [text(R) || {{?EXT_NS_B, <<"call-ref">>}, _, _} = R <- Cs] of
        [Ref | _] -> S3#{call_ref => Ref};
        [] -> S3
    end.

p_reason(R) ->
    M = #{text => text(R)},
    M1 =
        case attr(<<"cause">>, R) of
            undefined -> M;
            C -> M#{cause => chappe_sip_lib:to_int(C, 0)}
        end,
    case attr(<<"protocol">>, R) of
        undefined -> M1;
        P -> M1#{protocol => P}
    end.

p_participant({_, _, Cs} = E) ->
    #{
        id => req(<<"participant_id">>, E),
        names => [p_name(N) || N <- named(<<"nameID">>, Cs)]
    }.

p_name({_, _, Cs} = N) ->
    M = #{aor => req(<<"aor">>, N)},
    case named(<<"name">>, Cs) of
        [Name | _] ->
            M1 = M#{name => text(Name)},
            case attr(<<"xml:lang">>, Name) of
                undefined -> M1;
                L -> M1#{lang => L}
            end;
        [] ->
            M
    end.

p_stream({_, _, Cs} = E) ->
    S0 = #{id => req(<<"stream_id">>, E)},
    S1 =
        case attr(<<"session_id">>, E) of
            undefined -> S0;
            Sid -> S0#{session_id => Sid}
        end,
    put_text(label, <<"label">>, Cs, S1).

p_psa({_, _, Cs} = E) ->
    Params = [
        {req(<<"pname">>, P), req(<<"pval">>, P)}
     || P <- named(<<"param">>, Cs)
    ],
    p_times(E, #{
        participant_id => req(<<"participant_id">>, E),
        session_id => req(<<"session_id">>, E),
        params => Params
    }).

p_pst({_, _, Cs} = E) ->
    p_times(E, #{
        participant_id => req(<<"participant_id">>, E),
        send => [text(T) || T <- named(<<"send">>, Cs)],
        recv => [text(T) || T <- named(<<"recv">>, Cs)]
    }).

p_times({_, _, Cs}, M) ->
    put_text(
        disassociate_time,
        <<"disassociate-time">>,
        Cs,
        put_text(associate_time, <<"associate-time">>, Cs, M)
    ).

put_text(Key, Local, Cs, M) ->
    case first_text(Local, Cs) of
        undefined -> M;
        V -> M#{Key => V}
    end.

first_text(Local, Cs) ->
    case named(Local, Cs) of
        [E | _] -> text(E);
        [] -> undefined
    end.

%% the elements of the recording namespace of that local name; others,
%% and text between elements, are skipped (the schema's xs:any)
named(Local, Children) ->
    [E || {{?NS_B, L}, _, _} = E <- Children, L =:= Local].

text({_, _, Cs}) ->
    bounded(text, string:trim(iolist_to_binary([T || T <- Cs, is_binary(T)]))).

req(Name, E) ->
    case attr(Name, E) of
        undefined -> error({missing, Name});
        V -> V
    end.

attr(Name, {_, As, _}) ->
    case lists:keyfind(Name, 1, As) of
        {_, V} -> bounded(Name, V);
        false -> undefined
    end.

bounded(_Name, V) when byte_size(V) =< ?MAX_VALUE -> V;
bounded(Name, _V) -> error({too_long, Name}).

%% ---- reading a document ----

%% Who each stream carries, for a recording server: per stream, its label
%% and the participants that send it, by the participant-stream
%% associations still in force (no disassociate-time).
-spec senders(doc()) ->
    [
        #{
            stream_id := binary(),
            label => binary(),
            participants := [participant()]
        }
    ].
senders(Doc) ->
    Ps = maps:from_list([
        {Id, P}
     || #{id := Id} = P <- maps:get(participants, Doc, [])
    ]),
    Assocs = [
        A
     || A <- maps:get(participant_stream_assocs, Doc, []),
        not maps:is_key(disassociate_time, A)
    ],
    [
        maps:merge(
            maps:with([label], S),
            #{
                stream_id => Id,
                participants => [
                    maps:get(Pid, Ps, #{id => Pid})
                 || #{participant_id := Pid, send := Send} <- Assocs,
                    lists:member(Id, Send)
                ]
            }
        )
     || #{id := Id} = S <- maps:get(streams, Doc, [])
    ].
