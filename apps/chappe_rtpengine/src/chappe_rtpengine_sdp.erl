%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Media-section helpers for subscription answers.
%%
%% The client and the session keep SDP opaque: bodies go to rtpengine
%% and come back rewritten, never parsed on the way. This module is the
%% one opt-in exception, and it exists because rtpengine has no
%% request-side selector for a single media stream.
%%
%% A subscription offer describes every media stream of the tapped
%% participants, in m-line order, carrying the source's a=label. Which
%% of those streams a consumer actually receives is decided by the
%% consumer's answer: an m-line answered with a port routes that stream
%% to that address, an m-line answered with port 0 is rejected. So
%% "fork stream L to this receiver" is one subscription answered with
%% only L's m-line active.
%%
%% streams/1 exposes the offer's m-line order and labels; fork_answer/2,3
%% builds the aligned answer. Callers that generate their own SDP can
%% ignore this module entirely.
-module(chappe_rtpengine_sdp).

-export([streams/1, fork_answer/2, fork_answer/3]).

-type stream() :: #{
    index := non_neg_integer(),
    type := binary(),
    port := non_neg_integer(),
    label := binary() | undefined,
    labels := [binary()]
}.

%% A media stream of the offer, by its a=label (any of them when the
%% siprec flag added a second) or by its 0-based m-line index.
-type selector() :: {label, binary()} | {index, non_neg_integer()}.

%% Where the selected stream is sent: the receiver's address (an IPv4
%% or IPv6 literal; IPv6 gets IN IP6 in o= and c=) and port, plus an
%% optional ptime for the answered packetization.
-type dest() :: #{
    address := binary(),
    port := pos_integer(),
    ptime => pos_integer()
}.

-export_type([stream/0, selector/0, dest/0]).

-record(sec, {
    index :: non_neg_integer(),
    type :: binary(),
    port :: non_neg_integer(),
    proto :: binary(),
    formats :: [binary()],
    labels = [] :: [binary()],
    attrs = [] :: [binary()]
}).

%% The offer's media streams, in m-line order.
-spec streams(iodata()) -> [stream()].
streams(Sdp) ->
    [public(S) || S <- sections(iolist_to_binary(Sdp))].

%% Answer a subscription offer with one stream routed to one receiver.
-spec fork_answer(iodata(), selector(), dest()) ->
    {ok, binary()} | {error, term()}.
fork_answer(Offer, Selector, Dest) ->
    fork_answer(Offer, [{Selector, Dest}]).

%% Answer a subscription offer, routing each selected stream to its own
%% receiver and rejecting every other m-line (port 0). Errors:
%% {no_such_stream, Sel}, {duplicate_stream, Sel}, {rejected_stream,
%% Sel} (the offer already has port 0 there), {bad_selector, Sel}. One entry per
%% receiver: N entries fork N streams out of one subscription, a single
%% entry forks one stream and is the shape a per-stream subscription
%% wants.
-spec fork_answer(iodata(), [{selector(), dest()}]) ->
    {ok, binary()} | {error, term()}.
fork_answer(_Offer, []) ->
    {error, no_streams_selected};
fork_answer(Offer, Routes) ->
    Sections = sections(iolist_to_binary(Offer)),
    case resolve(Routes, Sections, #{}) of
        {ok, ByIndex} ->
            [#{address := First} | _] = [D || {_, D} <- Routes],
            Body = [answer_section(S, ByIndex) || S <- Sections],
            {ok, iolist_to_binary([session(First), Body])};
        {error, _} = Error ->
            Error
    end.

%% internal

resolve([], _Sections, Acc) ->
    {ok, Acc};
resolve([{Selector, Dest} | T], Sections, Acc) ->
    case find(Selector, Sections) of
        {ok, #sec{index = I}} when is_map_key(I, Acc) ->
            {error, {duplicate_stream, Selector}};
        {ok, #sec{port = 0}} ->
            %% the offerer already rejected this m-line
            {error, {rejected_stream, Selector}};
        {ok, #sec{index = I}} ->
            resolve(T, Sections, Acc#{I => Dest});
        error ->
            {error, {no_such_stream, Selector}};
        {error, _} = Error ->
            Error
    end;
resolve([Route | _], _Sections, _Acc) ->
    {error, {bad_route, Route}}.

find({index, I}, Sections) ->
    case [S || #sec{index = J} = S <- Sections, J =:= I] of
        [S | _] -> {ok, S};
        [] -> error
    end;
find({label, L}, Sections) ->
    case [S || #sec{labels = Ls} = S <- Sections, lists:member(L, Ls)] of
        [S | _] -> {ok, S};
        [] -> error
    end;
find(Selector, _Sections) ->
    {error, {bad_selector, Selector}}.

session(Address) ->
    [
        <<"v=0\r\n">>,
        <<"o=- 1 1 ">>,
        addr(Address),
        <<"\r\n">>,
        <<"s=chappe-fork\r\n">>,
        <<"c=">>,
        addr(Address),
        <<"\r\n">>,
        <<"t=0 0\r\n">>
    ].

%% "IN IP6 addr" for an IPv6 literal (it has a colon), else IN IP4.
addr(Address) ->
    case binary:match(Address, <<":">>) of
        nomatch -> [<<"IN IP4 ">>, Address];
        _ -> [<<"IN IP6 ">>, Address]
    end.

%% An accepted stream echoes the offered profile and format list at the
%% receiver's address; a rejected one keeps its m-line (the answer must
%% stay aligned with the offer) with port 0.
answer_section(#sec{index = I} = S, ByIndex) ->
    case maps:find(I, ByIndex) of
        {ok, Dest} -> accepted(S, Dest);
        error -> rejected(S)
    end.

accepted(#sec{} = S, #{address := Address, port := Port} = Dest) ->
    [
        mline(S, Port),
        <<"c=">>,
        addr(Address),
        <<"\r\n">>,
        [[<<"a=">>, A, <<"\r\n">>] || A <- S#sec.attrs, keep_attr(A)],
        ptime(Dest),
        <<"a=recvonly\r\n">>
    ].

rejected(#sec{} = S) ->
    [mline(S, 0), <<"a=inactive\r\n">>].

mline(#sec{type = Type, proto = Proto, formats = Fmts}, Port) ->
    [
        <<"m=">>,
        Type,
        <<" ">>,
        integer_to_binary(Port),
        <<" ">>,
        Proto,
        [[<<" ">>, F] || F <- Fmts],
        <<"\r\n">>
    ].

ptime(#{ptime := P}) -> [<<"a=ptime:">>, integer_to_binary(P), <<"\r\n">>];
ptime(_Dest) -> [].

%% Only the format descriptions carry over into the answer; direction,
%% labels and rtcp attributes belong to the offerer.
keep_attr(<<"rtpmap:", _/binary>>) -> true;
keep_attr(<<"fmtp:", _/binary>>) -> true;
keep_attr(_Attr) -> false.

public(#sec{index = I, type = Type, port = Port, labels = Labels}) ->
    #{
        index => I,
        type => Type,
        port => Port,
        label => first_label(Labels),
        labels => Labels
    }.

first_label([]) -> undefined;
first_label([L | _]) -> L.

sections(Bin) ->
    Lines = [
        L
     || L <- binary:split(Bin, [<<"\r\n">>, <<"\n">>], [global]), L =/= <<>>
    ],
    lists:reverse(collect(Lines, undefined, [], 0)).

collect([], undefined, Acc, _I) ->
    Acc;
collect([], Cur, Acc, _I) ->
    [close(Cur) | Acc];
collect([<<"m=", Rest/binary>> | T], Cur, Acc, I) ->
    collect(T, open(Rest, I), push(Cur, Acc), I + 1);
collect([_Line | T], undefined, Acc, I) ->
    collect(T, undefined, Acc, I);
collect([<<"a=label:", L/binary>> | T], Cur, Acc, I) ->
    collect(T, Cur#sec{labels = [L | Cur#sec.labels]}, Acc, I);
collect([<<"a=", A/binary>> | T], Cur, Acc, I) ->
    collect(T, Cur#sec{attrs = [A | Cur#sec.attrs]}, Acc, I);
collect([_Line | T], Cur, Acc, I) ->
    collect(T, Cur, Acc, I).

push(undefined, Acc) -> Acc;
push(Cur, Acc) -> [close(Cur) | Acc].

open(Rest, I) ->
    case binary:split(Rest, <<" ">>, [global]) of
        [Type, Port, Proto | Fmts] ->
            #sec{
                index = I,
                type = Type,
                port = to_port(Port),
                proto = Proto,
                formats = Fmts
            };
        _ ->
            #sec{index = I, type = Rest, port = 0, proto = <<>>, formats = []}
    end.

%% "m=audio 30010/2 RTP/AVP 0" (a port count) keeps only the port.
to_port(Port) ->
    [P | _] = binary:split(Port, <<"/">>),
    try
        binary_to_integer(P)
    catch
        error:badarg -> 0
    end.

close(#sec{labels = Labels, attrs = Attrs} = S) ->
    S#sec{labels = lists:reverse(Labels), attrs = lists:reverse(Attrs)}.
