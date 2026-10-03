%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc PIDF, the presence document (RFC 3863): render, parse, compose.
%%
%% A document is a map:
%%   #{entity := binary(),                  the presentity's URI
%%     tuples := [ptuple()],
%%     notes => [binary() | {Lang, binary()}]}
%% and a tuple
%%   #{id := binary(),
%%     basic => open | closed,              the <basic> status
%%     contact => binary(),
%%     priority => float(),                 0..1, at most 3 decimals
%%     notes => [binary() | {Lang, binary()}],
%%     timestamp => binary()}                RFC 3339, UTC
%% render/1 writes the XML declaration, the pidf namespace and a timestamp
%% on every tuple that has none (4.1.7). parse/1 reads documents with a
%% default or a prefixed pidf namespace, ignores any element it does not
%% know (other namespaces, a mustUnderstand extension: 4.2.3) and refuses
%% a DOCTYPE (no entities, no external fetch).
-module(chappe_sip_pidf).

-include_lib("xmerl/include/xmerl.hrl").

-export([render/1, parse/1, compose/2, content_type/0]).
-export_type([doc/0, ptuple/0]).

-define(NS, 'urn:ietf:params:xml:ns:pidf').
-define(NS_BIN, <<"urn:ietf:params:xml:ns:pidf">>).
-define(CT, <<"application/pidf+xml">>).

-type note() :: binary() | {binary(), binary()}.
-type ptuple() :: #{
    id := binary(),
    basic => open | closed,
    contact => binary(),
    priority => float(),
    notes => [note()],
    timestamp => binary()
}.
-type doc() :: #{entity := binary(), tuples := [ptuple()], notes => [note()]}.

-spec content_type() -> binary().
content_type() -> ?CT.

%% ---- render ----

%% The application/pidf+xml body of Doc. A tuple id given twice is kept
%% once, the first one (4.1.2).
-spec render(doc()) -> binary().
render(#{entity := Entity} = Doc) ->
    Tuples = unique(maps:get(tuples, Doc, []), []),
    iolist_to_binary([
        <<"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n">>,
        <<"<presence xmlns=\"">>,
        ?NS_BIN,
        <<"\" entity=\"">>,
        esc(Entity),
        <<"\">\n">>,
        [render_tuple(T) || T <- Tuples],
        [render_note(N, <<" ">>) || N <- maps:get(notes, Doc, [])],
        <<"</presence>\n">>
    ]).

unique([], _Seen) ->
    [];
unique([#{id := Id} = T | Rest], Seen) ->
    case lists:member(Id, Seen) of
        true -> unique(Rest, Seen);
        false -> [T | unique(Rest, [Id | Seen])]
    end.

render_tuple(#{id := Id} = T) ->
    [
        <<" <tuple id=\"">>,
        esc(Id),
        <<"\">\n  <status>">>,
        case maps:get(basic, T, undefined) of
            undefined -> <<>>;
            B -> [<<"<basic>">>, atom_to_binary(B), <<"</basic>">>]
        end,
        <<"</status>\n">>,
        render_contact(T),
        [render_note(N, <<"  ">>) || N <- maps:get(notes, T, [])],
        <<"  <timestamp>">>,
        maps:get(timestamp, T, now_stamp()),
        <<"</timestamp>\n </tuple>\n">>
    ].

render_contact(#{contact := C} = T) ->
    [
        <<"  <contact">>,
        priority_attr(maps:get(priority, T, undefined)),
        <<">">>,
        esc(C),
        <<"</contact>\n">>
    ];
render_contact(_T) ->
    <<>>.

%% 4.1.5: 0..1, at most 3 decimals; out of range, left out
priority_attr(P) when is_number(P), P >= 0, P =< 1 ->
    [
        <<" priority=\"">>,
        float_to_binary(float(P), [{decimals, 3}, compact]),
        <<"\"">>
    ];
priority_attr(_) ->
    <<>>.

render_note({Lang, Text}, Indent) ->
    [
        Indent,
        <<"<note xml:lang=\"">>,
        esc(Lang),
        <<"\">">>,
        esc(Text),
        <<"</note>\n">>
    ];
render_note(Text, Indent) ->
    [Indent, <<"<note>">>, esc(Text), <<"</note>\n">>].

%% 4.1.7: RFC 3339, UTC, capital T and Z
now_stamp() ->
    list_to_binary(
        calendar:system_time_to_rfc3339(
            erlang:system_time(millisecond),
            [{unit, millisecond}, {offset, "Z"}]
        )
    ).

esc(B) ->
    binary:replace(
        binary:replace(
            binary:replace(
                binary:replace(B, <<"&">>, <<"&amp;">>, [global]),
                <<"<">>,
                <<"&lt;">>,
                [global]
            ),
            <<">">>,
            <<"&gt;">>,
            [global]
        ),
        <<"\"">>,
        <<"&quot;">>,
        [global]
    ).

%% ---- parse ----

-spec parse(binary()) -> {ok, doc()} | {error, term()}.
parse(Bin) when is_binary(Bin) ->
    case binary:match(Bin, [<<"<!DOCTYPE">>, <<"<!ENTITY">>]) of
        nomatch -> scan(Bin);
        _ -> {error, doctype}
    end.

scan(Bin) ->
    try
        xmerl_scan:string(binary_to_list(Bin), [
            {namespace_conformant, true}, {quiet, true}
        ])
    of
        {#xmlElement{expanded_name = {?NS, presence}} = E, _Rest} ->
            presence(E);
        {#xmlElement{}, _} ->
            {error, not_pidf}
    catch
        _:Why -> {error, {xml, Why}}
    end.

presence(E) ->
    case attr(entity, E) of
        undefined ->
            {error, no_entity};
        Entity ->
            Children = children(E),
            Tuples = [T || C <- named(tuple, Children), {ok, T} <- [tuple(C)]],
            {ok, #{
                entity => Entity,
                tuples => Tuples,
                notes => [note(N) || N <- named(note, Children)]
            }}
    end.

%% a tuple without an id is not one (4.1.2)
tuple(E) ->
    case attr(id, E) of
        undefined ->
            error;
        Id ->
            Children = children(E),
            T0 = #{id => Id, notes => [note(N) || N <- named(note, Children)]},
            {ok,
                lists:foldl(fun(F, T) -> F(Children, T) end, T0, [
                    fun basic/2, fun contact/2, fun timestamp/2
                ])}
    end.

basic(Children, T) ->
    case
        [
            text(B)
         || S <- named(status, Children), B <- named(basic, children(S))
        ]
    of
        [<<"open">> | _] -> T#{basic => open};
        [<<"closed">> | _] -> T#{basic => closed};
        _ -> T
    end.

%% 4.1.5: no priority, or one out of range, is the lowest
contact(Children, T) ->
    case named(contact, Children) of
        [C | _] ->
            T#{contact => text(C), priority => priority(attr(priority, C))};
        [] ->
            T
    end.

priority(undefined) ->
    0.0;
priority(V) ->
    try binary_to_float(normalize_num(V)) of
        P when P >= 0, P =< 1 -> P;
        _ -> 0.0
    catch
        error:badarg -> 0.0
    end.

normalize_num(V) ->
    case binary:match(V, <<".">>) of
        nomatch -> <<V/binary, ".0">>;
        _ -> V
    end.

timestamp(Children, T) ->
    case named(timestamp, Children) of
        [S | _] -> T#{timestamp => text(S)};
        [] -> T
    end.

note(N) ->
    case attr('xml:lang', N) of
        undefined -> text(N);
        Lang -> {Lang, text(N)}
    end.

%% the pidf elements of that local name; anything else is ignored (4.2.3)
named(Local, Elements) ->
    [E || #xmlElement{expanded_name = {?NS, L}} = E <- Elements, L =:= Local].

children(#xmlElement{content = C}) ->
    [E || #xmlElement{} = E <- C].

text(#xmlElement{content = C}) ->
    string:trim(
        unicode:characters_to_binary([V || #xmlText{value = V} <- C])
    ).

attr(Name, #xmlElement{attributes = As}) ->
    case [V || #xmlAttribute{name = N, value = V} <- As, N =:= Name] of
        [V | _] -> unicode:characters_to_binary(V);
        [] -> undefined
    end.

%% ---- compose ----

%% The document of Entity from several (the live publications, newest
%% first): one tuple per id, the newest one; the notes of all.
-spec compose(binary(), [doc()]) -> doc().
compose(Entity, Docs) ->
    Tuples = unique(lists:append([maps:get(tuples, D, []) || D <- Docs]), []),
    Notes = lists:usort(lists:append([maps:get(notes, D, []) || D <- Docs])),
    #{entity => Entity, tuples => Tuples, notes => Notes}.
