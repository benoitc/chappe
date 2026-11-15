%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The HTTP/1.1 side of the opening handshake (RFC 6455 4.1, 4.2.1), as
%% pure functions: parse the upgrade request, find the stream id in its
%% path and the token in its query or Authorization header, and build
%% the refusals. The upgrade itself is checked by ws_h1_upgrade.
%%
%% Nothing here throws on what a peer sends: a request that does not
%% parse is {error, bad_request}.
-module(chappe_audio_http).

-export([parse/1, route/2, token/1, refuse/1]).

-export_type([request/0]).

-type request() :: #{
    method := binary(),
    path := binary(),
    query := binary(),
    headers := [{binary(), binary()}]
}.

%% The request line and the headers, once all have arrived (more until
%% then), and the bytes after them.
-spec parse(binary()) ->
    {ok, request(), binary()} | more | {error, bad_request}.
parse(Bin) ->
    try erlang:decode_packet(http_bin, Bin, []) of
        {more, _} ->
            more;
        %% RFC 6455 4.2.1: HTTP/1.1 or higher, a Request-URI or an
        %% absolute URI holding the resource name
        {ok, {http_request, Method, Uri, {1, Minor}}, Rest} when Minor >= 1 ->
            case target(Uri) of
                {ok, Target} -> headers(Rest, method(Method), Target, []);
                error -> {error, bad_request}
            end;
        {ok, _, _} ->
            {error, bad_request};
        {error, _} ->
            {error, bad_request}
    catch
        error:_ -> {error, bad_request}
    end.

headers(Bin, Method, Target, Acc) ->
    case erlang:decode_packet(httph_bin, Bin, []) of
        {more, _} ->
            more;
        {ok, http_eoh, Rest} ->
            {Path, Query} = split_target(Target),
            Req = #{
                method => Method,
                path => Path,
                query => Query,
                headers => lists:reverse(Acc)
            },
            {ok, Req, Rest};
        {ok, {http_header, _, Name, _, Value}, Rest} ->
            headers(Rest, Method, Target, [{name(Name), Value} | Acc]);
        {ok, _, _} ->
            {error, bad_request};
        {error, _} ->
            {error, bad_request}
    end.

target({abs_path, Target}) -> {ok, Target};
target({absoluteURI, _Scheme, _Host, _Port, Target}) -> {ok, Target};
target(_) -> error.

method(M) when is_atom(M) -> atom_to_binary(M);
method(M) -> M.

name(N) when is_atom(N) -> string:lowercase(atom_to_binary(N));
name(N) -> string:lowercase(N).

split_target(Target) ->
    case binary:split(Target, <<"?">>) of
        [Path, Query] -> {Path, Query};
        [Path] -> {Path, <<>>}
    end.

%% The stream id in Path under Prefix: Prefix/Id exactly, one segment.
-spec route(binary(), binary()) -> {ok, binary()} | error.
route(Prefix, Path) ->
    N = byte_size(Prefix),
    case Path of
        <<Prefix:N/binary, "/", Id/binary>> when Id =/= <<>> ->
            case binary:match(Id, <<"/">>) of
                nomatch -> {ok, Id};
                _ -> error
            end;
        _ ->
            error
    end.

%% The token the client presents: the `token' query parameter, else an
%% `Authorization: Bearer' token, else the password of an
%% `Authorization: Basic' header (what mod_audio_fork sends from its
%% MOD_AUDIO_BASIC_AUTH_* channel variables).
-spec token(request()) -> binary() | undefined.
token(#{query := Query, headers := Headers}) ->
    case query_token(Query) of
        undefined ->
            auth_token(proplists:get_value(<<"authorization">>, Headers));
        Token ->
            Token
    end.

query_token(<<>>) ->
    undefined;
query_token(Query) ->
    try uri_string:dissect_query(Query) of
        Pairs when is_list(Pairs) ->
            case lists:keyfind(<<"token">>, 1, Pairs) of
                {_, T} when is_binary(T) -> T;
                _ -> undefined
            end;
        _ ->
            undefined
    catch
        error:_ -> undefined
    end.

auth_token(undefined) ->
    undefined;
auth_token(Value) ->
    case binary:split(string:trim(Value), <<" ">>) of
        [Scheme, Cred] -> scheme(string:lowercase(Scheme), string:trim(Cred));
        _ -> undefined
    end.

scheme(<<"bearer">>, Token) ->
    Token;
scheme(<<"basic">>, Cred) ->
    try base64:decode(Cred) of
        Plain ->
            case binary:split(Plain, <<":">>) of
                [_User, Password] -> Password;
                _ -> undefined
            end
    catch
        error:_ -> undefined
    end;
scheme(_, _) ->
    undefined.

%% A refusal before the upgrade; the connection closes after it.
-spec refuse(400 | 401 | 404 | 405 | 503) -> iodata().
refuse(Status) ->
    [
        <<"HTTP/1.1 ">>,
        integer_to_binary(Status),
        <<" ">>,
        reason(Status),
        <<"\r\ncontent-length: 0\r\nconnection: close\r\n">>,
        extra(Status),
        <<"\r\n">>
    ].

reason(400) -> <<"Bad Request">>;
reason(401) -> <<"Unauthorized">>;
reason(404) -> <<"Not Found">>;
reason(405) -> <<"Method Not Allowed">>;
reason(503) -> <<"Service Unavailable">>.

extra(401) -> <<"www-authenticate: Bearer\r\n">>;
extra(405) -> <<"allow: GET\r\n">>;
extra(_) -> <<>>.
