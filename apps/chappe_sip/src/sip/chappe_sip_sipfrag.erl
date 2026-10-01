%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc message/sipfrag bodies (RFC 3420).
%%
%% A sipfrag is a piece of a SIP message: an optional start line, headers,
%% and an optional body after a blank line. The refer event package (RFC
%% 3515 2.4.5) sends one per NOTIFY, starting with the status line of the
%% referenced request ("SIP/2.0 200 OK").
-module(chappe_sip_sipfrag).

-export([build/1, build/2, build/3, parse/1, content_type/0, reason/1]).

-export_type([frag/0]).

%% status/reason for a status-line fragment, method/uri for a request-line
%% one, neither for a headers-only fragment
-type frag() :: #{
    status => 100..699,
    reason => binary(),
    method => binary(),
    uri => binary(),
    headers := [{binary(), binary()}],
    body := binary()
}.

%% the refer package's NOTIFY Content-Type (RFC 3515 2.4.5, RFC 3420 3)
-spec content_type() -> binary().
content_type() ->
    <<"message/sipfrag;version=2.0">>.

%% "SIP/2.0 <Status> <default reason>\r\n"
-spec build(100..699) -> binary().
build(Status) ->
    build(Status, reason(Status)).

-spec build(100..699, binary()) -> binary().
build(Status, Reason) ->
    build(Status, Reason, []).

%% a status line followed by headers (a Warning from the referenced
%% response, for instance)
-spec build(100..699, binary(), [{binary(), iodata()}]) -> binary().
build(Status, Reason, Headers) when
    is_integer(Status), Status >= 100, Status =< 699
->
    iolist_to_binary([
        <<"SIP/2.0 ">>,
        integer_to_binary(Status),
        <<" ">>,
        Reason,
        <<"\r\n">>,
        [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Headers]
    ]).

%% Parse a sipfrag body. Headers keep their names as written.
-spec parse(term()) -> {ok, frag()} | {error, malformed}.
parse(Bin) when is_binary(Bin), Bin =/= <<>> ->
    {Head, Body} =
        case binary:split(Bin, <<"\r\n\r\n">>) of
            [H, B] -> {H, B};
            [H] -> {H, <<>>}
        end,
    Lines = [L || L <- binary:split(Head, <<"\r\n">>, [global]), L =/= <<>>],
    try frag(Lines) of
        {ok, F} -> {ok, F#{body => Body}};
        error -> {error, malformed}
    catch
        _:_ -> {error, malformed}
    end;
parse(_) ->
    {error, malformed}.

frag([<<"SIP/2.0 ", Rest/binary>> | Hs]) ->
    case binary:split(Rest, <<" ">>) of
        [Code, Reason] -> status(Code, Reason, Hs);
        [Code] -> status(Code, <<>>, Hs)
    end;
frag([First | Hs] = Lines) ->
    case binary:split(First, <<" ">>, [global]) of
        [Method, Uri, <<"SIP/2.0">>] ->
            with_headers(Hs, #{method => Method, uri => Uri});
        _ ->
            with_headers(Lines, #{})
    end;
frag([]) ->
    error.

status(<<A, B, C>> = Code, Reason, Hs) when
    A >= $1, A =< $6, B >= $0, B =< $9, C >= $0, C =< $9
->
    with_headers(Hs, #{status => binary_to_integer(Code), reason => Reason});
status(_Code, _Reason, _Hs) ->
    error.

with_headers(Lines, Acc) ->
    Hs = [header(L) || L <- Lines],
    case lists:member(error, Hs) of
        true -> error;
        false -> {ok, Acc#{headers => Hs}}
    end.

header(Line) ->
    case binary:split(Line, <<":">>) of
        [N, V] when N =/= <<>> -> {trim(N), trim(V)};
        _ -> error
    end.

trim(B) -> string:trim(B, both, " \t").

%% RFC 3261 21 reason phrases for the codes a referenced request reports
-spec reason(100..699) -> binary().
reason(100) -> <<"Trying">>;
reason(180) -> <<"Ringing">>;
reason(181) -> <<"Call Is Being Forwarded">>;
reason(182) -> <<"Queued">>;
reason(183) -> <<"Session Progress">>;
reason(200) -> <<"OK">>;
reason(202) -> <<"Accepted">>;
reason(400) -> <<"Bad Request">>;
reason(403) -> <<"Forbidden">>;
reason(404) -> <<"Not Found">>;
reason(408) -> <<"Request Timeout">>;
reason(480) -> <<"Temporarily Unavailable">>;
reason(481) -> <<"Call/Transaction Does Not Exist">>;
reason(486) -> <<"Busy Here">>;
reason(487) -> <<"Request Terminated">>;
reason(488) -> <<"Not Acceptable Here">>;
reason(500) -> <<"Server Internal Error">>;
reason(503) -> <<"Service Unavailable">>;
reason(600) -> <<"Busy Everywhere">>;
reason(603) -> <<"Declined">>;
reason(_) -> <<"Unknown">>.
