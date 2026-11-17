%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc multipart/mixed bodies (RFC 2046 5.1), as SIP carries them: an SDP
%% offer next to SIPREC metadata (RFC 7866 9.1) or a location.
%%
%% build/1 makes the body and the Content-Type naming its boundary;
%% parse/2 splits one back into its parts. Each part has its content type,
%% its Content-Disposition when it carries one, and its body. parse/2 is
%% total and bounded: at most ?MAX_PARTS parts, and a part whose headers
%% do not end, or a body with no closing delimiter, is {error, _}. A body
%% that is not multipart comes back as its one part.
-module(chappe_sip_multipart).

-export([build/1, parse/2, find/2, content_type/1]).

-export_type([part/0]).

-type part() :: #{
    content_type := binary(),
    body := binary(),
    disposition => binary()
}.

%% more parts than SIP has any use for are refused (resource bound)
-define(MAX_PARTS, 16).

%% The body of Parts and the Content-Type it goes with.
-spec build([part()]) -> {binary(), binary()}.
build(Parts) ->
    B = boundary_token(),
    Body = iolist_to_binary(
        [
            [
                <<"--">>,
                B,
                <<"\r\n">>,
                <<"Content-Type: ">>,
                CT,
                <<"\r\n">>,
                disposition(P),
                <<"\r\n">>,
                Bin,
                <<"\r\n">>
            ]
         || #{content_type := CT, body := Bin0} = P <- Parts,
            Bin <- [iolist_to_binary(Bin0)]
        ] ++ [<<"--">>, B, <<"--\r\n">>]
    ),
    {<<"multipart/mixed;boundary=", B/binary>>, Body}.

disposition(#{disposition := D}) ->
    [<<"Content-Disposition: ">>, D, <<"\r\n">>];
disposition(_) ->
    [].

%% the CRLF before each delimiter belongs to the delimiter (RFC 2046
%% 5.1.1), so a part's body goes as it is

%% 96 random bits, hex: never in an SDP or an XML document by chance
boundary_token() ->
    <<"chappe-",
        (binary:encode_hex(crypto:strong_rand_bytes(12), lowercase))/binary>>.

%% The Content-Type of a body we built: a multipart's, read from its
%% first delimiter line, else application/sdp (what a dialog that keeps
%% only its last body sends again in a session refresh).
-spec content_type(binary()) -> binary().
content_type(<<"--", Rest/binary>>) ->
    case binary:split(Rest, <<"\r\n">>) of
        [B, _] when byte_size(B) > 0, byte_size(B) =< 70 ->
            <<"multipart/mixed;boundary=", B/binary>>;
        _ ->
            <<"application/sdp">>
    end;
content_type(_) ->
    <<"application/sdp">>.

%% The parts of Body, given its Content-Type. A body that is not multipart
%% is one part of that type.
-spec parse(binary() | undefined, binary()) ->
    {ok, [part()]} | {error, term()}.
parse(undefined, _Body) ->
    {error, no_content_type};
parse(CT, Body) ->
    case media_type(CT) of
        <<"multipart/", _/binary>> ->
            case boundary(CT) of
                {ok, B} -> split(B, Body);
                error -> {error, no_boundary}
            end;
        Type ->
            {ok, [#{content_type => Type, body => Body}]}
    end.

%% The first part of type Type (lowercase, no parameters).
-spec find(binary(), [part()]) -> {ok, part()} | error.
find(Type, Parts) ->
    case [P || #{content_type := CT} = P <- Parts, media_type(CT) =:= Type] of
        [P | _] -> {ok, P};
        [] -> error
    end.

%% The boundary parameter of a multipart Content-Type, unquoted.
-spec boundary(binary()) -> {ok, binary()} | error.
boundary(CT) ->
    case chappe_sip_hdr:params(CT) of
        #{<<"boundary">> := B0} when is_binary(B0) ->
            case unquote(B0) of
                <<>> -> error;
                B when byte_size(B) =< 70 -> {ok, B};
                _ -> error
            end;
        _ ->
            error
    end.

unquote(<<$", Rest/binary>>) ->
    case binary:split(Rest, <<"\"">>) of
        [B, _] -> B;
        [B] -> B
    end;
unquote(B) ->
    B.

media_type(CT) ->
    [Type | _] = binary:split(CT, <<";">>),
    chappe_sip_lib:lower(chappe_sip_lib:trim(Type)).

%% Body as delimited by --B lines: the preamble is ignored, each part runs
%% up to the CRLF before the next delimiter, the epilogue after --B--
%% too.
split(B, Body) ->
    Delim = <<"--", B/binary>>,
    case binary:split(Body, Delim) of
        [_Preamble, Rest] -> parts(Delim, after_line(Rest), []);
        [_] -> {error, no_delimiter}
    end.

parts(_Delim, _Rest, Acc) when length(Acc) >= ?MAX_PARTS ->
    {error, too_many_parts};
parts(Delim, Rest, Acc) ->
    case binary:split(Rest, <<"\r\n", Delim/binary>>) of
        [Raw, <<"--", _/binary>>] ->
            add(Raw, Acc, fun(Acc1) -> {ok, lists:reverse(Acc1)} end);
        [Raw, Next] ->
            add(Raw, Acc, fun(Acc1) -> parts(Delim, after_line(Next), Acc1) end);
        [_] ->
            {error, no_close_delimiter}
    end.

add(Raw, Acc, Then) ->
    case part(Raw) of
        {ok, P} -> Then([P | Acc]);
        {error, _} = E -> E
    end.

%% what follows a delimiter on its line (transport padding) is skipped
after_line(Bin) ->
    case binary:split(Bin, <<"\n">>) of
        [_, Rest] -> Rest;
        [_] -> <<>>
    end.

part(<<"\r\n", Body/binary>>) ->
    %% no header at all
    {ok, #{content_type => <<"text/plain">>, body => Body}};
part(Raw) ->
    case binary:split(Raw, [<<"\r\n\r\n">>, <<"\n\n">>]) of
        [Head, Body] -> {ok, headers(lines(Head), #{body => Body})};
        [<<>>] -> {ok, #{content_type => <<"text/plain">>, body => <<>>}};
        [_] -> {error, part_headers}
    end.

lines(Head) ->
    binary:split(Head, [<<"\r\n">>, <<"\n">>], [global, trim_all]).

%% RFC 2046 5.1: a part with no Content-Type is text/plain
headers([], P) ->
    maps:merge(#{content_type => <<"text/plain">>}, P);
headers([L | Ls], P) ->
    case binary:split(L, <<":">>) of
        [Name, Value] ->
            headers(
                Ls,
                header(
                    chappe_sip_lib:lower(chappe_sip_lib:trim(Name)),
                    chappe_sip_lib:trim(Value),
                    P
                )
            );
        [_] ->
            headers(Ls, P)
    end.

header(<<"content-type">>, V, P) -> P#{content_type => V};
header(<<"content-disposition">>, V, P) -> P#{disposition => V};
header(_, _V, P) -> P.
