%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Structured parsers for the headers that need more than raw bytes.
%%
%% Everything else in a SIP message stays an opaque binary (the lazy
%% model: sofia already validated the message). Scope matches
%% drachtio-sip: via, cseq, name-addr headers (to, from, contact, route,
%% record-route, refer-to), digest auth headers, and RFC 3891 Replaces.
-module(chappe_sip_hdr).

-export([
    via/1,
    cseq/1,
    name_addr/1,
    name_addr_list/1,
    split_list/1,
    auth/1,
    params/1
]).
-export([
    replaces/1,
    replaces_value/1,
    refer_to_replaces/1,
    escape/1,
    unescape/1
]).
-export([
    refer_to/1,
    refer_to_value/1,
    referred_by/1,
    referred_by_value/1,
    target_dialog/1,
    target_dialog_value/1,
    event/1,
    subscription_state/1
]).

-export_type([replaces/0, refer_to/0, target_dialog/0, sub_state/0]).

%% A parsed Subscription-State (RFC 6665 8.2.3): the state, lowercased (an
%% atom for the three RFC 6665 defines), and the parameters it names.
-type sub_state() :: #{
    state := active | pending | terminated | binary(),
    expires := non_neg_integer() | undefined,
    reason := binary() | undefined,
    retry_after := non_neg_integer() | undefined
}.

%% A parsed Refer-To (RFC 3515 2.1). uri is the URI as written; target is
%% it without the method param and the headers part; method is the method
%% param (RFC 3261 19.1.1), INVITE when absent; headers are the URI headers,
%% unescaped; replaces is the Replaces among them, parsed (RFC 3891 6.1).
-type refer_to() :: #{
    uri := binary(),
    target := binary(),
    scheme := binary(),
    method := binary(),
    headers := [{binary(), binary()}],
    replaces := replaces() | undefined,
    params := #{binary() => binary() | true},
    display => binary()
}.

%% RFC 4538 Target-Dialog, tags from the recipient's point of view
-type target_dialog() :: #{
    call_id := binary(),
    local_tag := binary(),
    remote_tag := binary()
}.

%% RFC 3891 dialog identity, as written by the sender of the Replaces
-type replaces() :: #{
    call_id := binary(),
    to_tag := binary(),
    from_tag := binary(),
    early_only := boolean()
}.

%% a Replaces value longer than this is refused unscanned
-define(MAX_REPLACES, 4096).

%% Via: SIP/2.0/UDP host:port;branch=...;rport
%% -> #{proto := binary(), host := binary(), port => 1..65535,
%%      params := #{binary() => binary() | true}}
-spec via(binary()) -> {ok, map()} | {error, term()}.
via(Bin0) ->
    Bin = trim(Bin0),
    case Bin of
        <<"SIP/2.0/", Rest/binary>> ->
            case binary:split(Rest, <<" ">>) of
                [Proto, HostPart0] ->
                    {HostPart, Params, _} = split_semi_params(trim(HostPart0)),
                    case parse_hostport(HostPart) of
                        {error, _} = E ->
                            E;
                        {Host, Port} ->
                            V0 = #{
                                proto => Proto,
                                host => Host,
                                params => Params
                            },
                            {ok, maybe_put(port, Port, V0)}
                    end;
                _ ->
                    {error, bad_via}
            end;
        _ ->
            {error, bad_via}
    end.

%% CSeq: 314159 INVITE -> #{seq := integer(), method := binary()}
-spec cseq(binary()) -> {ok, map()} | {error, term()}.
cseq(Bin) ->
    case binary:split(trim(Bin), [<<" ">>, <<"\t">>]) of
        [SeqBin, Method] ->
            case all_digits(SeqBin) andalso binary_to_integer(SeqBin) of
                %% RFC 3261 20.16: a 32-bit unsigned integer, 1*DIGIT
                Seq when is_integer(Seq), Seq < (1 bsl 32) ->
                    {ok, #{seq => Seq, method => trim(Method)}};
                _ ->
                    {error, bad_cseq}
            end;
        _ ->
            {error, bad_cseq}
    end.

all_digits(<<>>) ->
    false;
all_digits(Bin) ->
    lists:all(fun(D) -> D >= $0 andalso D =< $9 end, binary_to_list(Bin)).

%% name-addr or addr-spec with header params:
%%   "Display" <sip:a@b>;tag=x  |  <sip:a@b>;x  |  sip:a@b;tag=x
%% -> #{display => binary(), uri := binary(), params := map()}
%% Note: for the bare addr-spec form, ";" params belong to the HEADER,
%% not the URI (RFC 3261 20.10 ambiguity resolved as drachtio does).
-spec name_addr(binary()) -> {ok, map()} | {error, term()}.
name_addr(Bin0) ->
    Bin = trim(Bin0),
    case Bin of
        <<"\"", Rest/binary>> ->
            %% quoted display name: close at the first UNescaped quote so a
            %% quoted-pair (\" \\) inside the name is not mistaken for the end
            case split_quoted(Rest) of
                {Display, After} ->
                    with_angle(trim(After), #{display => Display});
                error ->
                    {error, bad_name_addr}
            end;
        <<"<", _/binary>> ->
            with_angle(Bin, #{});
        _ ->
            case binary:match(Bin, <<"<">>) of
                {Pos, _} ->
                    %% unquoted display name up to <
                    Display = trim(binary:part(Bin, 0, Pos)),
                    Rest = binary:part(Bin, Pos, byte_size(Bin) - Pos),
                    with_angle(Rest, #{display => Display});
                nomatch ->
                    %% bare addr-spec; header params after first ;
                    {Uri, Params, _} = split_semi_params(Bin),
                    {ok, #{uri => Uri, params => Params}}
            end
    end.

with_angle(<<"<", Rest/binary>>, Acc) ->
    case binary:split(Rest, <<">">>) of
        [Uri, After] ->
            {_, Params, _} = split_semi_params(trim(After)),
            {ok, Acc#{uri => Uri, params => Params}};
        _ ->
            {error, bad_name_addr}
    end;
with_angle(_, _) ->
    {error, bad_name_addr}.

%% Comma-separated name-addr list (Contact, Route, Record-Route).
%% Commas inside quoted strings and inside <> are not separators.
-spec name_addr_list(binary()) -> {ok, [map()]} | {error, term()}.
name_addr_list(Bin) ->
    Parts = split_commas(Bin),
    Res = [name_addr(P) || P <- Parts, trim(P) =/= <<>>],
    case [E || {error, _} = E <- Res] of
        [] -> {ok, [M || {ok, M} <- Res]};
        [E | _] -> E
    end.

%% The elements of a comma-joined header value (Route, Record-Route,
%% Contact...), split outside quotes and angle brackets and trimmed.
-spec split_list(binary()) -> [binary()].
split_list(Bin) ->
    [T || P <- split_commas(Bin), T <- [trim(P)], T =/= <<>>].

%% Digest challenge/credentials:
%%   Digest realm="r", nonce="n", qop="auth", algorithm=MD5
%% -> #{scheme := binary(), params := #{binary() => binary()}}
%% Quoted values are unquoted.
-spec auth(binary()) -> {ok, map()} | {error, term()}.
auth(Bin0) ->
    Bin = trim(Bin0),
    case binary:split(Bin, <<" ">>) of
        [Scheme, Rest] ->
            Pairs = split_commas(Rest),
            Params =
                lists:foldl(
                    fun(Pair, Acc) ->
                        case binary:split(trim(Pair), <<"=">>) of
                            [K, V] -> Acc#{lower(trim(K)) => unquote(trim(V))};
                            _ -> Acc
                        end
                    end,
                    #{},
                    Pairs
                ),
            {ok, #{scheme => Scheme, params => Params}};
        _ ->
            {error, bad_auth}
    end.

%% generic ;k=v;flag params of a header value -> map
-spec params(binary()) -> #{binary() => binary() | true}.
params(Bin) ->
    {_, Params, _} = split_semi_params(Bin),
    Params.

%% RFC 3891 Replaces value: callid *(SEMI replaces-param)
%%   98732@sip.example.com;to-tag=r33th4x0r;from-tag=ff87ff;early-only
%% Both tags are required; unknown generic params are ignored. Total: any
%% input that is not a well-formed value (including a non-binary or one
%% longer than 4096 bytes) is {error, malformed}, never an exception.
-spec replaces(term()) -> {ok, replaces()} | {error, malformed}.
replaces(Bin) when is_binary(Bin), byte_size(Bin) =< ?MAX_REPLACES ->
    try
        parse_replaces(Bin)
    catch
        _:_ -> {error, malformed}
    end;
replaces(_) ->
    {error, malformed}.

%% Build a Replaces value. early_only defaults to false.
-spec replaces_value(#{
    call_id := binary(),
    to_tag := binary(),
    from_tag := binary(),
    early_only => boolean()
}) -> binary().
replaces_value(#{call_id := C, to_tag := T, from_tag := F} = R) ->
    Early =
        case maps:get(early_only, R, false) of
            true -> <<";early-only">>;
            false -> <<>>
        end,
    <<C/binary, ";to-tag=", T/binary, ";from-tag=", F/binary, Early/binary>>.

%% The Replaces carried as an escaped URI header in a Refer-To value
%% (RFC 3891 section 6.1), e.g.
%%   <sip:dave@example.org?Replaces=12345%40h%3Bto-tag%3D1%3Bfrom-tag%3D2>
%% {error, no_replaces} when the URI has no Replaces header.
-spec refer_to_replaces(term()) ->
    {ok, replaces()} | {error, no_replaces | malformed}.
refer_to_replaces(Bin) when is_binary(Bin) ->
    try name_addr(Bin) of
        {ok, #{uri := Uri}} -> uri_replaces(Uri);
        _ -> {error, malformed}
    catch
        _:_ -> {error, malformed}
    end;
refer_to_replaces(_) ->
    {error, malformed}.

%% Escape a value for use as a SIP URI header value (RFC 3261 hvalue): what
%% is not unreserved or hnv-unreserved becomes %XX.
-spec escape(binary()) -> binary().
escape(Bin) ->
    <<<<(escape_byte(C))/binary>> || <<C>> <= Bin>>.

%% Undo %XX escaping. A truncated or non-hex escape is {error, malformed}.
-spec unescape(term()) -> {ok, binary()} | {error, malformed}.
unescape(Bin) when is_binary(Bin) ->
    unescape(Bin, <<>>);
unescape(_) ->
    {error, malformed}.

%% Refer-To value -> refer_to(). A URI with no scheme, a malformed name-addr,
%% a bad escape, or a malformed Replaces is {error, malformed}; the scheme is
%% not checked (the recipient answers 416 to one it cannot reach).
-spec refer_to(term()) -> {ok, refer_to()} | {error, malformed}.
refer_to(Bin) when is_binary(Bin) ->
    try name_addr(Bin) of
        {ok, #{uri := Uri} = NA} -> refer_to_uri(Uri, NA);
        _ -> {error, malformed}
    catch
        _:_ -> {error, malformed}
    end;
refer_to(_) ->
    {error, malformed}.

refer_to_uri(Uri, NA) ->
    case binary:split(Uri, <<":">>) of
        [Scheme, Rest] when Scheme =/= <<>>, Rest =/= <<>> ->
            {Main, Hdrs} =
                case binary:split(Uri, <<"?">>) of
                    [M, H] -> {M, H};
                    [M] -> {M, <<>>}
                end,
            {Target, Method} = uri_method(Main),
            case uri_headers(Hdrs) of
                {ok, Headers} ->
                    with_replaces(
                        Headers,
                        #{
                            uri => Uri,
                            target => Target,
                            scheme => lower(Scheme),
                            method => Method,
                            headers => Headers,
                            params => maps:get(params, NA)
                        },
                        NA
                    );
                error ->
                    {error, malformed}
            end;
        _ ->
            {error, malformed}
    end.

%% split off the method uri-param; every other param stays in the target
uri_method(Main) ->
    {Base, Params} =
        case binary:split(Main, <<";">>) of
            [B, Ps] -> {B, binary:split(Ps, <<";">>, [global])};
            [B] -> {B, []}
        end,
    {Keep, Method} = lists:foldr(
        fun(P, {Acc, M}) ->
            case binary:split(P, <<"=">>) of
                [K, V] ->
                    case lower(K) of
                        <<"method">> -> {Acc, upper(V)};
                        _ -> {[P | Acc], M}
                    end;
                _ ->
                    {[P | Acc], M}
            end
        end,
        {[], <<"INVITE">>},
        Params
    ),
    {iolist_to_binary(lists:join(<<";">>, [Base | Keep])), Method}.

uri_headers(<<>>) ->
    {ok, []};
uri_headers(Hdrs) ->
    Pairs = [
        binary:split(H, <<"=">>)
     || H <- binary:split(Hdrs, <<"&">>, [global])
    ],
    Res = [
        case {P, unescape(V)} of
            {[N, _], {ok, U}} when N =/= <<>> -> {N, U};
            _ -> error
        end
     || [_, V] = P <- Pairs
    ],
    case length(Res) =:= length(Pairs) andalso not lists:member(error, Res) of
        true -> {ok, Res};
        false -> error
    end.

with_replaces(Headers, RT, NA) ->
    RT1 = maps:merge(RT, maps:with([display], NA)),
    case [V || {N, V} <- Headers, lower(N) =:= <<"replaces">>] of
        [] ->
            {ok, RT1#{replaces => undefined}};
        [V] ->
            case replaces(V) of
                {ok, R} -> {ok, RT1#{replaces => R}};
                {error, _} -> {error, malformed}
            end;
        _ ->
            {error, malformed}
    end.

%% Build a Refer-To value: <uri;method=M?Name=escaped&...>. A replaces map is
%% appended as the escaped Replaces header (RFC 3891 6.1). The method param
%% is left out when not given (the recipient reads INVITE).
-spec refer_to_value(#{
    uri := binary(),
    method => binary(),
    replaces => replaces(),
    headers => [{binary(), binary()}],
    display => binary()
}) -> binary().
refer_to_value(#{uri := Uri} = RT) ->
    MethodParam =
        case maps:get(method, RT, undefined) of
            undefined -> <<>>;
            M -> <<";method=", M/binary>>
        end,
    Headers =
        maps:get(headers, RT, []) ++
            case maps:get(replaces, RT, undefined) of
                undefined -> [];
                R -> [{<<"Replaces">>, replaces_value(R)}]
            end,
    Query =
        case Headers of
            [] ->
                <<>>;
            _ ->
                Parts = [
                    <<N/binary, "=", (escape(V))/binary>>
                 || {N, V} <- Headers
                ],
                <<"?", (iolist_to_binary(lists:join(<<"&">>, Parts)))/binary>>
        end,
    <<
        (display_prefix(RT))/binary,
        "<",
        Uri/binary,
        MethodParam/binary,
        Query/binary,
        ">"
    >>.

display_prefix(#{display := D}) when D =/= <<>> -> <<"\"", D/binary, "\" ">>;
display_prefix(_) -> <<>>.

%% Referred-By (RFC 3892 3): referrer-uri *(SEMI (cid / generic-param)).
%% cid is a quoted msg-id (id-left "@" id-right); the quotes are dropped.
-spec referred_by(term()) ->
    {ok, #{
        uri := binary(),
        params := map(),
        display => binary(),
        cid => binary()
    }}
    | {error, malformed}.
referred_by(Bin) when is_binary(Bin) ->
    try name_addr(Bin) of
        {ok, #{params := P} = NA} ->
            case maps:take(<<"cid">>, P) of
                error ->
                    {ok, NA};
                {Cid, P1} ->
                    case clean_msg_id(Cid) of
                        {ok, Id} -> {ok, NA#{cid => Id, params => P1}};
                        error -> {error, malformed}
                    end
            end;
        _ ->
            {error, malformed}
    catch
        _:_ -> {error, malformed}
    end;
referred_by(_) ->
    {error, malformed}.

clean_msg_id(<<"\"", Rest/binary>>) ->
    case binary:split(Rest, <<"\"">>) of
        [Id, <<>>] ->
            case binary:split(Id, <<"@">>) of
                [L, R] when L =/= <<>>, R =/= <<>> -> {ok, Id};
                _ -> error
            end;
        _ ->
            error
    end;
clean_msg_id(_) ->
    error.

-spec referred_by_value(#{
    uri := binary(), display => binary(), cid => binary()
}) -> binary().
referred_by_value(#{uri := Uri} = RB) ->
    Cid =
        case maps:get(cid, RB, undefined) of
            undefined -> <<>>;
            C -> <<";cid=\"", C/binary, "\"">>
        end,
    <<(display_prefix(RB))/binary, "<", Uri/binary, ">", Cid/binary>>.

%% Target-Dialog (RFC 4538 7): callid;local-tag=..;remote-tag=.. A value
%% missing either tag is {error, malformed}: section 4 says to ignore it.
-spec target_dialog(term()) -> {ok, target_dialog()} | {error, malformed}.
target_dialog(Bin) when is_binary(Bin) ->
    [CallId0 | _] = binary:split(Bin, <<";">>),
    CallId = trim(CallId0),
    P = params(Bin),
    case {is_callid(CallId), P} of
        {true, #{<<"local-tag">> := L, <<"remote-tag">> := R}} when
            is_binary(L), is_binary(R), L =/= <<>>, R =/= <<>>
        ->
            {ok, #{call_id => CallId, local_tag => L, remote_tag => R}};
        _ ->
            {error, malformed}
    end;
target_dialog(_) ->
    {error, malformed}.

-spec target_dialog_value(target_dialog()) -> binary().
target_dialog_value(#{call_id := C, local_tag := L, remote_tag := R}) ->
    <<C/binary, ";local-tag=", L/binary, ";remote-tag=", R/binary>>.

%% Event (RFC 6665 8.2.1): the event type and the id param, the two parts
%% that identify a subscription (compared byte by byte).
-spec event(term()) ->
    {ok, #{type := binary(), id := binary() | undefined}} | {error, malformed}.
event(Bin) when is_binary(Bin) ->
    [Type0 | _] = binary:split(Bin, <<";">>),
    case trim(Type0) of
        <<>> ->
            {error, malformed};
        Type ->
            Id =
                case maps:get(<<"id">>, params(Bin), undefined) of
                    V when is_binary(V) -> V;
                    _ -> undefined
                end,
            {ok, #{type => Type, id => Id}}
    end;
event(_) ->
    {error, malformed}.

%% Subscription-State (RFC 6665 8.2.3): active / pending / terminated with
%% expires, reason (lowercased) and retry-after. A parameter that is not a
%% number where one is due is left undefined.
-spec subscription_state(term()) -> {ok, sub_state()} | {error, malformed}.
subscription_state(Bin) when is_binary(Bin) ->
    {Main, Params, _} = split_semi_params(Bin),
    case lower(trim(Main)) of
        <<>> ->
            {error, malformed};
        Value ->
            {ok, #{
                state => sub_state_value(Value),
                expires => seconds(maps:get(<<"expires">>, Params, undefined)),
                reason =>
                    case maps:get(<<"reason">>, Params, undefined) of
                        R when is_binary(R) -> lower(R);
                        _ -> undefined
                    end,
                retry_after => seconds(
                    maps:get(<<"retry-after">>, Params, undefined)
                )
            }}
    end;
subscription_state(_) ->
    {error, malformed}.

sub_state_value(<<"active">>) -> active;
sub_state_value(<<"pending">>) -> pending;
sub_state_value(<<"terminated">>) -> terminated;
sub_state_value(Other) -> Other.

seconds(V) when is_binary(V) ->
    try binary_to_integer(V) of
        N when N >= 0 -> N;
        _ -> undefined
    catch
        error:badarg -> undefined
    end;
seconds(_) ->
    undefined.

%% internal

parse_replaces(Bin) ->
    [CallId0 | Params] = binary:split(Bin, <<";">>, [global]),
    CallId = trim(CallId0),
    case is_callid(CallId) of
        true ->
            replaces_params(Params, #{call_id => CallId, early_only => false});
        false ->
            {error, malformed}
    end.

replaces_params([], #{to_tag := _, from_tag := _} = R) ->
    {ok, R};
replaces_params([], _R) ->
    {error, malformed};
replaces_params([P | Rest], R) ->
    case replaces_param(trim(P)) of
        skip ->
            replaces_params(Rest, R);
        early_only ->
            replaces_params(Rest, R#{early_only => true});
        {Key, Tag} when not is_map_key(Key, R) ->
            replaces_params(Rest, R#{Key => Tag});
        _ ->
            {error, malformed}
    end.

replaces_param(<<>>) ->
    skip;
replaces_param(P) ->
    case binary:split(P, <<"=">>) of
        [K] ->
            flag_param(lower(trim(K)));
        [K, V] ->
            valued_param(lower(trim(K)), trim(V))
    end.

flag_param(<<"early-only">>) -> early_only;
flag_param(<<"to-tag">>) -> error;
flag_param(<<"from-tag">>) -> error;
flag_param(K) -> generic(K, <<>>).

valued_param(<<"to-tag">>, V) -> tag_param(to_tag, V);
valued_param(<<"from-tag">>, V) -> tag_param(from_tag, V);
valued_param(<<"early-only">>, _V) -> error;
valued_param(K, V) -> generic(K, V).

tag_param(Key, V) ->
    case V =/= <<>> andalso all_bytes(fun is_token_char/1, V) of
        true -> {Key, V};
        false -> error
    end.

%% generic-param: a token name; the value only has to be free of CTLs
generic(K, V) ->
    case
        K =/= <<>> andalso all_bytes(fun is_token_char/1, K) andalso
            all_bytes(fun(C) -> C >= 16#20 andalso C =/= 16#7F end, V)
    of
        true -> skip;
        false -> error
    end.

%% RFC 3261 callid = word [ "@" word ]
is_callid(CallId) ->
    case binary:split(CallId, <<"@">>, [global]) of
        [W] -> is_word(W);
        [W1, W2] -> is_word(W1) andalso is_word(W2);
        _ -> false
    end.

is_word(W) ->
    W =/= <<>> andalso all_bytes(fun is_word_char/1, W).

all_bytes(F, Bin) ->
    lists:all(F, binary_to_list(Bin)).

is_token_char(C) when C >= $a, C =< $z -> true;
is_token_char(C) when C >= $A, C =< $Z -> true;
is_token_char(C) when C >= $0, C =< $9 -> true;
is_token_char(C) -> lists:member(C, "-.!%*_+`'~").

is_word_char(C) ->
    is_token_char(C) orelse lists:member(C, "()<>:\\\"/[]?{}").

uri_replaces(Uri) ->
    case binary:split(Uri, <<"?">>) of
        [_, Headers] ->
            find_replaces(binary:split(Headers, <<"&">>, [global]));
        [_] ->
            {error, no_replaces}
    end.

find_replaces([]) ->
    {error, no_replaces};
find_replaces([H | Rest]) ->
    case binary:split(H, <<"=">>) of
        [Name, Val] ->
            case lower(Name) of
                <<"replaces">> -> escaped_replaces(Val);
                _ -> find_replaces(Rest)
            end;
        _ ->
            find_replaces(Rest)
    end.

escaped_replaces(Val) ->
    case unescape(Val) of
        {ok, Raw} -> replaces(Raw);
        {error, _} = E -> E
    end.

unescape(<<>>, Acc) ->
    {ok, Acc};
unescape(<<"%", H, L, Rest/binary>>, Acc) ->
    case {hex(H), hex(L)} of
        {Hi, Lo} when is_integer(Hi), is_integer(Lo) ->
            unescape(Rest, <<Acc/binary, (Hi * 16 + Lo)>>);
        _ ->
            {error, malformed}
    end;
unescape(<<"%", _/binary>>, _Acc) ->
    {error, malformed};
unescape(<<C, Rest/binary>>, Acc) ->
    unescape(Rest, <<Acc/binary, C>>).

hex(C) when C >= $0, C =< $9 -> C - $0;
hex(C) when C >= $a, C =< $f -> C - $a + 10;
hex(C) when C >= $A, C =< $F -> C - $A + 10;
hex(_) -> error.

%% RFC 3261 hvalue: unreserved (alphanum, mark) and hnv-unreserved pass
escape_byte(C) when C >= $a, C =< $z -> <<C>>;
escape_byte(C) when C >= $A, C =< $Z -> <<C>>;
escape_byte(C) when C >= $0, C =< $9 -> <<C>>;
escape_byte(C) ->
    case lists:member(C, "-_.!~*'()[]/?:+$") of
        true -> <<C>>;
        false -> <<"%", (binary:encode_hex(<<C>>))/binary>>
    end.

split_semi_params(Bin) ->
    case binary:split(Bin, <<";">>) of
        [Main] ->
            {Main, #{}, []};
        [Main, ParamsBin] ->
            Parts = binary:split(ParamsBin, <<";">>, [global]),
            {Params, Order} =
                lists:foldl(
                    fun
                        (<<>>, Acc) ->
                            Acc;
                        (Part, {Acc, Ord}) ->
                            case binary:split(Part, <<"=">>) of
                                [K, V] ->
                                    {Acc#{lower(trim(K)) => trim(V)}, [K | Ord]};
                                [K] ->
                                    {Acc#{lower(trim(K)) => true}, [K | Ord]}
                            end
                    end,
                    {#{}, []},
                    Parts
                ),
            {Main, Params, lists:reverse(Order)}
    end.

%% RFC 3261 quoted-string: close at the first quote not preceded by a
%% backslash; escaped bytes are kept verbatim (byte-faithful display name).
split_quoted(Bin) -> split_quoted(Bin, <<>>).

split_quoted(<<"\\", C, R/binary>>, Acc) ->
    split_quoted(R, <<Acc/binary, "\\", C>>);
split_quoted(<<"\"", R/binary>>, Acc) ->
    {Acc, R};
split_quoted(<<C, R/binary>>, Acc) ->
    split_quoted(R, <<Acc/binary, C>>);
split_quoted(<<>>, _Acc) ->
    error.

parse_hostport(<<"[", Rest/binary>>) ->
    case binary:split(Rest, <<"]">>) of
        [V6, <<>>] ->
            {<<"[", V6/binary, "]">>, undefined};
        [V6, <<":", P/binary>>] ->
            case port(P) of
                {ok, Port} -> {<<"[", V6/binary, "]">>, Port};
                error -> {error, bad_port}
            end;
        _ ->
            {error, bad_host}
    end;
parse_hostport(HostPort) ->
    case binary:split(HostPort, <<":">>) of
        [Host] ->
            {Host, undefined};
        [Host, P] ->
            case port(trim(P)) of
                {ok, Port} -> {Host, Port};
                error -> {error, bad_port}
            end
    end.

%% a valid transport port (RFC 3261 uses 1..65535)
port(Bin) ->
    try binary_to_integer(Bin) of
        N when N >= 1, N =< 65535 -> {ok, N};
        _ -> error
    catch
        _:_ -> error
    end.

%% split on commas not inside quotes or <>
split_commas(Bin) ->
    split_commas(Bin, 0, 0, false, [], []).

split_commas(<<>>, _Start, _I, _Q, Cur, Acc) ->
    lists:reverse([iolist_to_binary(lists:reverse(Cur)) | Acc]);
split_commas(<<C, Rest/binary>>, Start, I, InQ, Cur, Acc) ->
    case C of
        $" ->
            split_commas(Rest, Start, I + 1, not InQ, [C | Cur], Acc);
        $< when not InQ -> split_angle(Rest, [C | Cur], Acc, Start, I);
        $, when not InQ ->
            split_commas(
                Rest,
                I + 1,
                I + 1,
                InQ,
                [],
                [iolist_to_binary(lists:reverse(Cur)) | Acc]
            );
        _ ->
            split_commas(Rest, Start, I + 1, InQ, [C | Cur], Acc)
    end.

split_angle(<<>>, Cur, Acc, _Start, _I) ->
    lists:reverse([iolist_to_binary(lists:reverse(Cur)) | Acc]);
split_angle(<<$>, Rest/binary>>, Cur, Acc, Start, I) ->
    split_commas(Rest, Start, I + 1, false, [$> | Cur], Acc);
split_angle(<<C, Rest/binary>>, Cur, Acc, Start, I) ->
    split_angle(Rest, [C | Cur], Acc, Start, I).

%% byte-wise, so a header value that is not UTF-8 cannot raise
trim(B) -> trim_trailing(trim_leading(B)).

trim_leading(<<C, R/binary>>) when C =:= $\s; C =:= $\t -> trim_leading(R);
trim_leading(B) -> B.

trim_trailing(<<>>) ->
    <<>>;
trim_trailing(B) ->
    case binary:last(B) of
        C when C =:= $\s; C =:= $\t ->
            trim_trailing(binary:part(B, 0, byte_size(B) - 1));
        _ ->
            B
    end.

lower(B) -> <<<<(lower_byte(C))>> || <<C>> <= B>>.

lower_byte(C) when C >= $A, C =< $Z -> C + 32;
lower_byte(C) -> C.

upper(B) -> <<<<(upper_byte(C))>> || <<C>> <= B>>.

upper_byte(C) when C >= $a, C =< $z -> C - 32;
upper_byte(C) -> C.

unquote(<<"\"", Rest/binary>>) ->
    case binary:split(Rest, <<"\"">>) of
        [V, _] -> V;
        _ -> Rest
    end;
unquote(B) ->
    B.

maybe_put(_K, undefined, M) -> M;
maybe_put(K, V, M) -> M#{K => V}.
