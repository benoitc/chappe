%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Lazy SIP message model.
%%
%% The engine (sofia nta) has already validated transactions, so this
%% module splits a message into start line, ordered raw headers and body,
%% and deep-parses only on demand through parsed/2. Untouched messages
%% re-encode byte-faithfully: header entries keep the exact raw name and
%% the exact raw value bytes (including folding), and encode/1 emits them
%% verbatim. That property is what makes B2BUA header passthrough safe.
-module(chappe_sip_msg).

-export([parse/1, encode/1, validate/1]).
-export([type/1, method/1, uri/1, set_uri/2, status/1, reason/1, body/1]).
-export([get/2, get_all/2, has/2, set/3, add/3, remove/2, set_body/2]).
-export([all_headers/1, drop_first/2, prepend/3, decr_max_forwards/1]).
-export([parsed/2, option_tags/2, is_token/1]).
-export([
    call_id/1,
    cseq/1,
    from/1,
    to/1,
    from_tag/1,
    to_tag/1,
    can_form_dialog/1
]).
-export([new_request/3, new_response/3]).

-record(sip_msg, {
    type :: request | response,
    method :: binary() | undefined,
    uri :: binary() | undefined,
    version = <<"SIP/2.0">> :: binary(),
    status :: 100..699 | undefined,
    reason :: binary() | undefined,
    %% [{NormalizedName, RawName, RawValueBytes}] in wire order.
    %% RawValueBytes are the exact bytes after the colon, folding
    %% included; get/2 unfolds and trims. A malformed line with no colon
    %% is kept as {<<>>, RawLine, no_colon}.
    headers = [] :: [{binary(), binary(), binary() | no_colon}],
    body = <<>> :: binary()
}).

-opaque msg() :: #sip_msg{}.
-export_type([msg/0]).

%% Every compact form in the IANA SIP header field registry: RFC 3261 7.3.3
%% and the extensions that define one.
compact(<<"a">>) -> <<"accept-contact">>;
compact(<<"b">>) -> <<"referred-by">>;
compact(<<"c">>) -> <<"content-type">>;
compact(<<"d">>) -> <<"request-disposition">>;
compact(<<"e">>) -> <<"content-encoding">>;
compact(<<"f">>) -> <<"from">>;
compact(<<"i">>) -> <<"call-id">>;
compact(<<"j">>) -> <<"reject-contact">>;
compact(<<"k">>) -> <<"supported">>;
compact(<<"l">>) -> <<"content-length">>;
compact(<<"m">>) -> <<"contact">>;
compact(<<"n">>) -> <<"identity-info">>;
compact(<<"o">>) -> <<"event">>;
compact(<<"r">>) -> <<"refer-to">>;
compact(<<"s">>) -> <<"subject">>;
compact(<<"t">>) -> <<"to">>;
compact(<<"u">>) -> <<"allow-events">>;
compact(<<"v">>) -> <<"via">>;
compact(<<"x">>) -> <<"session-expires">>;
compact(<<"y">>) -> <<"identity">>;
compact(Name) -> Name.

norm(Name) ->
    compact(chappe_sip_lib:lower(Name)).

%% ---- parse ----

%% parse/1 is total: any input yields {ok, _} or {error, _}, never a throw, so
%% a crafted packet cannot crash the request worker (RFC 4475 robustness).
-spec parse(binary()) -> {ok, msg()} | {error, term()}.
parse(Bin) ->
    try
        do_parse(Bin)
    catch
        _:_ -> {error, malformed}
    end.

do_parse(Bin) ->
    case binary:split(Bin, <<"\r\n\r\n">>) of
        [Head, Body] -> parse_head(Head, Body);
        [Head] -> parse_head(Head, <<>>)
    end.

%% Presence of the mandatory header fields (RFC 3261 8.1.1) and, on a
%% request, a CSeq of `1*DIGIT LWS Method' whose method is the request's
%% (8.1.1.5, 20.16). A message failing this cannot be dispatched, so the
%% ingress answers 400. Used on the WS ingress (no sofia to validate) and as
%% a backstop on the engine ingress. Max-Forwards is not required: a UAS
%% takes a request without one (RFC 2543 peers, RFC 4475 3.4.1) and a proxy
%% adds it (16.6 step 3).
-spec validate(msg()) -> ok | {error, missing_header | bad_cseq}.
validate(#sip_msg{} = M) ->
    Mandatory = [<<"via">>, <<"from">>, <<"to">>, <<"call-id">>, <<"cseq">>],
    case lists:all(fun(H) -> get(H, M) =/= undefined end, Mandatory) of
        true -> validate_cseq(M);
        false -> {error, missing_header}
    end.

validate_cseq(#sip_msg{type = response}) ->
    ok;
validate_cseq(#sip_msg{method = Method} = M) ->
    case split_cseq(get(<<"cseq">>, M)) of
        {Seq, Method} when Seq =< 16#FFFFFFFF -> ok;
        _ -> {error, bad_cseq}
    end.

%% "1*DIGIT LWS Method"; clean/1 has already unfolded the LWS
split_cseq(Value) ->
    case digits(Value, <<>>) of
        {<<>>, _} ->
            error;
        {Digits, <<C, _/binary>> = Rest} when C =:= $\s; C =:= $\t ->
            Method = chappe_sip_lib:trim(Rest),
            case is_token(Method) of
                true -> {binary_to_integer(Digits), Method};
                false -> error
            end;
        _ ->
            error
    end.

digits(<<D, Rest/binary>>, Acc) when D >= $0, D =< $9 ->
    digits(Rest, <<Acc/binary, D>>);
digits(Rest, Acc) ->
    {Acc, Rest}.

%% RFC 3261 25.1 token: 1*(alphanum / "-" / "." / "!" / "%" / "*" / "_" /
%% "+" / "`" / "'" / "~")
-spec is_token(binary()) -> boolean().
is_token(<<>>) ->
    false;
is_token(Bin) ->
    lists:all(fun token_char/1, binary_to_list(Bin)).

token_char(C) when C >= $a, C =< $z -> true;
token_char(C) when C >= $A, C =< $Z -> true;
token_char(C) when C >= $0, C =< $9 -> true;
token_char(C) -> lists:member(C, "-.!%*_+`'~").

parse_head(Head, Body) ->
    case binary:split(Head, <<"\r\n">>) of
        [StartLine, HeaderBlock] ->
            case parse_start(StartLine) of
                {ok, M0} ->
                    case parse_headers(HeaderBlock) of
                        {ok, Headers} ->
                            {ok, M0#sip_msg{headers = Headers, body = Body}};
                        error ->
                            {error, malformed}
                    end;
                E ->
                    E
            end;
        [StartLine] ->
            case parse_start(StartLine) of
                {ok, M0} -> {ok, M0#sip_msg{body = Body}};
                E -> E
            end
    end.

%% The SIP-Version is case-insensitive (RFC 3261 7.1): a status line may
%% start "sip/2.0".
parse_start(<<V:7/binary, " ", Rest/binary>> = Line) ->
    case chappe_sip_lib:lower(V) of
        <<"sip/2.0">> -> parse_status(Rest);
        _ -> parse_request(Line)
    end;
parse_start(Line) ->
    parse_request(Line).

parse_status(Rest) ->
    case Rest of
        <<S1, S2, S3, " ", Reason/binary>> when
            S1 >= $1, S1 =< $6, S2 >= $0, S2 =< $9, S3 >= $0, S3 =< $9
        ->
            Status = (S1 - $0) * 100 + (S2 - $0) * 10 + (S3 - $0),
            {ok, #sip_msg{type = response, status = Status, reason = Reason}};
        <<S1, S2, S3>> when
            S1 >= $1,
            S1 =< $6,
            S2 >= $0,
            S2 =< $9,
            S3 >= $0,
            S3 =< $9
        ->
            Status = (S1 - $0) * 100 + (S2 - $0) * 10 + (S3 - $0),
            {ok, #sip_msg{type = response, status = Status, reason = <<>>}};
        _ ->
            {error, bad_status_line}
    end.

%% Request-Line = Method SP Request-URI SP SIP-Version (7.1); the method is
%% a case-sensitive token, the version case-insensitive.
parse_request(Line) ->
    case binary:split(Line, <<" ">>, [global]) of
        [Method, Uri, Version] ->
            case is_token(Method) andalso chappe_sip_lib:lower(Version) of
                <<"sip/2.0">> ->
                    {ok, #sip_msg{type = request, method = Method, uri = Uri}};
                _ ->
                    {error, bad_request_line}
            end;
        _ ->
            {error, bad_request_line}
    end.

%% Splits the header block into entries, keeping folded continuation
%% lines (leading SP/HT) inside the previous entry's raw value. A header
%% name that is not a token (RFC 3261 7.3.1, 25.1) makes the message
%% malformed.
parse_headers(Block) ->
    Lines = binary:split(Block, <<"\r\n">>, [global]),
    Hs = fold_lines(Lines, []),
    case lists:all(fun valid_name/1, Hs) of
        true -> {ok, lists:reverse(Hs)};
        false -> error
    end.

valid_name({_, _, no_colon}) -> true;
valid_name({_, RawName, _}) -> is_token(chappe_sip_lib:trim(RawName)).

fold_lines([], Acc) ->
    Acc;
fold_lines([Line | Rest], Acc) ->
    case Line of
        <<C, _/binary>> when C =:= $\s; C =:= $\t ->
            %% continuation of the previous header
            case Acc of
                [{N, RN, RV} | Tail] ->
                    fold_lines(Rest, [
                        {N, RN, <<RV/binary, "\r\n", Line/binary>>} | Tail
                    ]);
                [] ->
                    fold_lines(Rest, Acc)
            end;
        <<>> ->
            fold_lines(Rest, Acc);
        _ ->
            case binary:split(Line, <<":">>) of
                [RawName, RawValue] ->
                    fold_lines(Rest, [
                        {norm(chappe_sip_lib:trim(RawName)), RawName, RawValue}
                        | Acc
                    ]);
                _ ->
                    %% garbage line; keep it opaque to stay byte-faithful
                    fold_lines(Rest, [{<<>>, Line, no_colon} | Acc])
            end
    end.

%% ---- encode ----

-spec encode(msg()) -> iodata().
encode(#sip_msg{} = M) ->
    [
        start_line(M),
        [
            case E of
                {_, RawName, no_colon} -> [RawName, "\r\n"];
                {_, RawName, RawValue} -> [RawName, ":", RawValue, "\r\n"]
            end
         || E <- M#sip_msg.headers
        ],
        "\r\n",
        M#sip_msg.body
    ].

start_line(#sip_msg{type = request, method = Me, uri = U, version = V}) ->
    [Me, " ", U, " ", V, "\r\n"];
start_line(#sip_msg{type = response, version = V, status = S, reason = R}) ->
    [V, " ", integer_to_binary(S), " ", R, "\r\n"].

%% ---- accessors ----

-spec type(msg()) -> request | response.
type(#sip_msg{type = T}) -> T.

-spec method(msg()) -> binary() | undefined.
method(#sip_msg{method = M}) -> M.

-spec uri(msg()) -> binary() | undefined.
uri(#sip_msg{uri = U}) -> U.

%% Replace the Request-URI of a request (a proxy retargeting, RFC 3261 16.6).
-spec set_uri(binary(), msg()) -> msg().
set_uri(Uri, #sip_msg{type = request} = M) when is_binary(Uri) ->
    M#sip_msg{uri = Uri}.

-spec status(msg()) -> 100..699 | undefined.
status(#sip_msg{status = S}) -> S.

-spec reason(msg()) -> binary() | undefined.
reason(#sip_msg{reason = R}) -> R.

-spec body(msg()) -> binary().
body(#sip_msg{body = B}) -> B.

%% First matching header value, unfolded and trimmed. Accepts any case
%% and compact names.
-spec get(binary(), msg()) -> binary() | undefined.
get(Name, #sip_msg{headers = Hs}) ->
    N = norm(Name),
    case lists:keyfind(N, 1, Hs) of
        {_, _, no_colon} -> undefined;
        {_, _, RV} -> clean(RV);
        false -> undefined
    end.

-spec get_all(binary(), msg()) -> [binary()].
get_all(Name, #sip_msg{headers = Hs}) ->
    N = norm(Name),
    [clean(RV) || {N1, _, RV} <- Hs, N1 =:= N, RV =/= no_colon].

-spec has(binary(), msg()) -> boolean().
has(Name, M) ->
    get(Name, M) =/= undefined.

%% All headers in wire order as {NormalizedName, OriginalName, CleanValue}.
%% Used by header-proxying to copy across legs. Malformed (no-colon) lines
%% are skipped.
-spec all_headers(msg()) -> [{binary(), binary(), binary()}].
all_headers(#sip_msg{headers = Hs}) ->
    [{Norm, Name, clean(RV)} || {Norm, Name, RV} <- Hs, RV =/= no_colon].

%% Replace all occurrences (or append if absent) with a canonical entry.
-spec set(binary(), iodata(), msg()) -> msg().
set(Name, Value, #sip_msg{headers = Hs} = M) ->
    N = norm(Name),
    Entry = {N, canonical_name(Name), iolist_to_binary([" ", Value])},
    case lists:keymember(N, 1, Hs) of
        true ->
            %% replace the first occurrence in place, drop the rest
            M#sip_msg{headers = replace_in_place(N, Entry, Hs)};
        false ->
            M#sip_msg{headers = Hs ++ [Entry]}
    end.

replace_in_place(N, Entry, Hs) ->
    {_, Out} =
        lists:foldl(
            fun
                ({N1, _, _}, {false, Acc}) when N1 =:= N ->
                    {true, [Entry | Acc]};
                ({N1, _, _}, {true, Acc}) when N1 =:= N -> {true, Acc};
                (E, {D, Acc}) ->
                    {D, [E | Acc]}
            end,
            {false, []},
            Hs
        ),
    lists:reverse(Out).

-spec add(binary(), iodata(), msg()) -> msg().
add(Name, Value, #sip_msg{headers = Hs} = M) ->
    V = iolist_to_binary([" ", Value]),
    M#sip_msg{headers = Hs ++ [{norm(Name), canonical_name(Name), V}]}.

-spec remove(binary(), msg()) -> msg().
remove(Name, #sip_msg{headers = Hs} = M) ->
    N = norm(Name),
    M#sip_msg{headers = [E || {N1, _, _} = E <- Hs, N1 =/= N]}.

%% Drop only the FIRST occurrence of a header (proxy Via handling).
-spec drop_first(binary(), msg()) -> msg().
drop_first(Name, #sip_msg{headers = Hs} = M) ->
    N = norm(Name),
    M#sip_msg{headers = drop_first_1(N, Hs)}.

drop_first_1(_N, []) -> [];
drop_first_1(N, [{N, _, _} | Rest]) -> Rest;
drop_first_1(N, [H | Rest]) -> [H | drop_first_1(N, Rest)].

%% Prepend a header (used to insert Record-Route / Route on top).
-spec prepend(binary(), iodata(), msg()) -> msg().
prepend(Name, Value, #sip_msg{headers = Hs} = M) ->
    Entry = {norm(Name), canonical_name(Name), iolist_to_binary([" ", Value])},
    M#sip_msg{headers = [Entry | Hs]}.

%% Decrement Max-Forwards (proxy). A request without one passes the check
%% (RFC 3261 16.3 step 3) and the copy gets Max-Forwards: 70 (16.6 step 3).
-spec decr_max_forwards(msg()) -> {ok, msg()} | {error, loop_detected}.
decr_max_forwards(M) ->
    case get(<<"max-forwards">>, M) of
        undefined ->
            {ok, set(<<"Max-Forwards">>, <<"70">>, M)};
        V ->
            N =
                try
                    binary_to_integer(V)
                catch
                    _:_ -> 70
                end,
            case N =< 0 of
                true ->
                    {error, loop_detected};
                false ->
                    {ok, set(<<"Max-Forwards">>, integer_to_binary(N - 1), M)}
            end
    end.

%% Sets the body and refreshes Content-Length.
-spec set_body(iodata(), msg()) -> msg().
set_body(Body, M) ->
    B = iolist_to_binary(Body),
    set(
        <<"Content-Length">>,
        integer_to_binary(byte_size(B)),
        M#sip_msg{body = B}
    ).

%% ---- structured access ----

%% Deep-parse a header on demand. Names as in drachtio-sip.
-spec parsed(binary(), msg()) -> {ok, term()} | {error, term()}.
parsed(Name, M) ->
    N = norm(Name),
    case {N, get(N, M)} of
        {_, undefined} -> {error, no_header};
        {<<"via">>, V} -> chappe_sip_hdr:via(V);
        {<<"cseq">>, V} -> chappe_sip_hdr:cseq(V);
        {<<"from">>, V} -> chappe_sip_hdr:name_addr(V);
        {<<"to">>, V} -> chappe_sip_hdr:name_addr(V);
        {<<"refer-to">>, V} -> chappe_sip_hdr:name_addr(V);
        {<<"replaces">>, V} -> chappe_sip_hdr:replaces(V);
        {<<"contact">>, V} -> chappe_sip_hdr:name_addr_list(V);
        {<<"route">>, V} -> chappe_sip_hdr:name_addr_list(V);
        {<<"record-route">>, V} -> chappe_sip_hdr:name_addr_list(V);
        {<<"www-authenticate">>, V} -> chappe_sip_hdr:auth(V);
        {<<"proxy-authenticate">>, V} -> chappe_sip_hdr:auth(V);
        {<<"authorization">>, V} -> chappe_sip_hdr:auth(V);
        {<<"proxy-authorization">>, V} -> chappe_sip_hdr:auth(V);
        {_, V} -> {ok, V}
    end.

%% The option tags listed in every Name header (Require, Proxy-Require,
%% Supported...), lowercased (see chappe_sip_hdr:option_tags/1).
-spec option_tags(binary(), msg()) -> [binary()].
option_tags(Name, M) ->
    chappe_sip_hdr:option_tags(get_all(Name, M)).

%% ---- conveniences ----

-spec call_id(msg()) -> binary() | undefined.
call_id(M) -> get(<<"call-id">>, M).

-spec cseq(msg()) -> {ok, map()} | {error, term()}.
cseq(M) -> parsed(<<"cseq">>, M).

-spec from(msg()) -> {ok, map()} | {error, term()}.
from(M) -> parsed(<<"from">>, M).

-spec to(msg()) -> {ok, map()} | {error, term()}.
to(M) -> parsed(<<"to">>, M).

-spec from_tag(msg()) -> binary() | undefined.
from_tag(M) -> tag(from(M)).

-spec to_tag(msg()) -> binary() | undefined.
to_tag(M) -> tag(to(M)).

tag({ok, #{params := P}}) ->
    case maps:get(<<"tag">>, P, undefined) of
        true -> undefined;
        V -> V
    end;
tag(_) ->
    undefined.

%% INVITE or SUBSCRIBE without a To tag starts a dialog.
-spec can_form_dialog(msg()) -> boolean().
can_form_dialog(#sip_msg{type = request, method = Me} = M) when
    Me =:= <<"INVITE">>; Me =:= <<"SUBSCRIBE">>
->
    to_tag(M) =:= undefined;
can_form_dialog(_) ->
    false.

%% ---- builders ----

-spec new_request(binary(), binary(), [{binary(), iodata()}]) -> msg().
new_request(Method, Uri, Headers) ->
    lists:foldl(
        fun({N, V}, M) -> add(N, V, M) end,
        #sip_msg{type = request, method = Method, uri = Uri},
        Headers
    ).

-spec new_response(100..699, binary(), [{binary(), iodata()}]) -> msg().
new_response(Status, Reason, Headers) ->
    lists:foldl(
        fun({N, V}, M) -> add(N, V, M) end,
        #sip_msg{type = response, status = Status, reason = Reason},
        Headers
    ).

%% ---- internal ----

%% unfold and trim a raw header value, byte-wise so a non-UTF-8 value
%% cannot raise
clean(RV) ->
    Unfolded = binary:replace(
        RV,
        [<<"\r\n ">>, <<"\r\n\t">>],
        <<" ">>,
        [global]
    ),
    chappe_sip_lib:trim(Unfolded).

%% Preserve the caller's spelling for added headers.
canonical_name(Name) ->
    iolist_to_binary(Name).
