%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The headers a B2BUA carries from one leg to the other: the Reason of a
%% BYE or CANCEL (RFC 3326), the request headers copied from A to B with
%% Privacy: none always kept and, as a privacy service, the identifying
%% ones removed (RFC 3323), and the headers of B's 2xx copied to A's.
%% Split out of chappe_sip_b2b, which owns the call flow.
-module(chappe_sip_b2b_hdr).

-export([
    reason_headers/1,
    proxy_request_headers/2,
    proxy_response_headers/2,
    b_from/2,
    valid_from/1,
    caller/1
]).
-export([privacy/2, privacy_unsupported/2, privacy_failure/1]).

%% RFC 3323 5.3: the informational headers a user agent adds that a
%% privacy service removes under user (and header) privacy
-define(USER_INFO_HEADERS, [
    <<"subject">>,
    <<"call-info">>,
    <<"organization">>,
    <<"user-agent">>,
    <<"reply-to">>,
    <<"in-reply-to">>
]).
%% RFC 3325 9.3: what id privacy removes
-define(ID_HEADERS, [<<"p-asserted-identity">>, <<"p-preferred-identity">>]).

%% RFC 3326: the Reason headers of a BYE or CANCEL, to repeat on the other
%% leg (nothing for a teardown that had no request). Section 2: one value
%% per protocol, so a second one of the same protocol is dropped.
reason_headers(Req) ->
    try chappe_sip_req:get_all(<<"reason">>, Req) of
        Values ->
            Split = [
                string:trim(V)
             || H <- Values, V <- split_values(H, false, <<>>, [])
            ],
            [{<<"Reason">>, V} || V <- one_per_protocol(Split, [], [])]
    catch
        error:_ -> []
    end.

%% the comma separated values of a header line, commas in quotes kept
split_values(<<>>, _InQ, Cur, Acc) ->
    lists:reverse([Cur | Acc]);
split_values(<<$", R/binary>>, InQ, Cur, Acc) ->
    split_values(R, not InQ, <<Cur/binary, $">>, Acc);
split_values(<<$,, R/binary>>, false, Cur, Acc) ->
    split_values(R, false, <<>>, [Cur | Acc]);
split_values(<<C, R/binary>>, InQ, Cur, Acc) ->
    split_values(R, InQ, <<Cur/binary, C>>, Acc).

one_per_protocol([], _Seen, Acc) ->
    lists:reverse(Acc);
one_per_protocol([V | Rest], Seen, Acc) ->
    [Proto | _] = binary:split(V, <<";">>),
    P = string:lowercase(string:trim(Proto)),
    case lists:member(P, Seen) of
        true -> one_per_protocol(Rest, Seen, Acc);
        false -> one_per_protocol(Rest, [P | Seen], [V | Acc])
    end.

%% B's From: the `from' option, else A's display name and URI without A's
%% tag (the B leg adds its own), anonymous under user or header privacy
%% (RFC 3323 4.1.1.3).
-spec b_from(chappe_sip_req:req(), map()) -> binary().
b_from(Req, Opts) ->
    case maps:find(from, Opts) of
        {ok, From} ->
            From;
        error ->
            Levels = privacy(Req, Opts),
            case
                not lists:member(<<"none">>, Levels) andalso
                    user_privacy(Levels)
            of
                true -> <<"\"Anonymous\" <sip:anonymous@anonymous.invalid>">>;
                false -> caller(chappe_sip_req:get(<<"from">>, Req))
            end
    end.

%% Whether the `from' option, if any, can go on the wire: it goes out raw,
%% so one CRLF in it would add headers to the INVITE. Checked before any
%% leg or transport is chosen.
-spec valid_from(map()) -> boolean().
valid_from(#{from := From}) -> chappe_sip_hdr:valid_name_addr(From);
valid_from(_Opts) -> true.

%% A From or To value as a name-addr with its parameters (the tag) left
%% out: the identity a new INVITE presents for that party.
-spec caller(binary() | undefined) -> binary().
caller(From) ->
    case chappe_sip_hdr:name_addr(From) of
        {ok, #{display := D, uri := U}} when D =/= <<>> ->
            %% name_addr/1 keeps a quoted name's escapes as they are
            <<"\"", D/binary, "\" <", U/binary, ">">>;
        {ok, #{uri := U}} ->
            <<"<", U/binary, ">">>;
        {error, _} ->
            <<"\"Anonymous\" <sip:anonymous@anonymous.invalid>">>
    end.

%% default headers never copied verbatim between legs
excluded() ->
    [
        <<"via">>,
        <<"route">>,
        <<"record-route">>,
        <<"cseq">>,
        <<"call-id">>,
        <<"from">>,
        <<"to">>,
        <<"contact">>,
        <<"content-length">>,
        <<"max-forwards">>,
        <<"content-type">>,
        <<"authorization">>,
        <<"proxy-authorization">>,
        <<"www-authenticate">>,
        <<"proxy-authenticate">>,
        %% each leg negotiates its own session timer (RFC 4028 4)
        <<"session-expires">>,
        <<"min-se">>
    ].

%% on top of those, a 2xx's extensions and capabilities are B's, not ours
excluded_response() ->
    [<<"require">>, <<"supported">>, <<"allow">>, <<"rseq">>].

proxy_request_headers(Req, Opts) ->
    Msg = chappe_sip_req:msg(Req),
    Hdrs = copy(Msg, maps:get(proxy_request_headers, Opts, []), []),
    Private = private_headers(privacy(Req, Opts)),
    [
        {N, V}
     || {N, V} <- Hdrs, not lists:member(string:lowercase(N), Private)
    ] ++ privacy_none(Msg, Hdrs).

%% ---- the privacy service (RFC 3323 5) ----

%% The priv-values of the request's Privacy header the b2bua applies, as a
%% privacy service (Opts privacy => true | #{session => boolean()}): none,
%% header, user, id, critical, and session when the app anonymizes the
%% media. [] when the b2bua is no privacy service.
-spec privacy(chappe_sip_req:req(), map()) -> [binary()].
privacy(Req, Opts) ->
    case service(Opts) of
        off ->
            [];
        Supported ->
            [T || T <- privacy_tokens(Req), lists:member(T, Supported)]
    end.

%% RFC 3323 5: with critical, the priv-values the service cannot apply
%% (the request then fails with 500); [] when it can apply them all, when
%% critical is absent, or when the b2bua is no privacy service.
-spec privacy_unsupported(chappe_sip_req:req(), map()) -> [binary()].
privacy_unsupported(Req, Opts) ->
    case service(Opts) of
        off ->
            [];
        Supported ->
            Tokens = privacy_tokens(Req),
            case lists:member(<<"critical">>, Tokens) of
                true -> [T || T <- Tokens, not lists:member(T, Supported)];
                false -> []
            end
    end.

%% RFC 3323 5: the reason phrase of that 500 says privacy failed and names
%% the priv-values not supported
-spec privacy_failure([binary()]) -> binary().
privacy_failure(Unsupported) ->
    iolist_to_binary([
        <<"Privacy Failure: ">>,
        lists:join(<<", ">>, Unsupported),
        <<" not supported">>
    ]).

service(Opts) ->
    Base = [
        <<"none">>, <<"header">>, <<"user">>, <<"id">>, <<"critical">>
    ],
    case maps:get(privacy, Opts, false) of
        true -> Base;
        #{session := true} -> Base ++ [<<"session">>];
        #{} -> Base;
        _ -> off
    end.

%% the lowercase priv-values of every Privacy header, in order, once each
privacy_tokens(Req) ->
    Values = chappe_sip_msg:get_all(<<"privacy">>, chappe_sip_req:msg(Req)),
    Tokens = [
        string:lowercase(string:trim(T))
     || V <- Values, T <- binary:split(V, [<<";">>, <<",">>], [global])
    ],
    dedup([T || T <- Tokens, T =/= <<>>], []).

dedup([], Acc) ->
    lists:reverse(Acc);
dedup([T | Rest], Acc) ->
    case lists:member(T, Acc) of
        true -> dedup(Rest, Acc);
        false -> dedup(Rest, [T | Acc])
    end.

%% user privacy, or header privacy which implies it (RFC 3323 4.2)
user_privacy(Levels) ->
    lists:member(<<"user">>, Levels) orelse lists:member(<<"header">>, Levels).

%% the headers of A the applied levels keep from B; none asks for nothing
%% (RFC 3323 5: no privacy function at all)
private_headers(Levels) ->
    case lists:member(<<"none">>, Levels) of
        true ->
            [];
        false ->
            User =
                case user_privacy(Levels) of
                    true -> ?USER_INFO_HEADERS;
                    false -> []
                end,
            Id =
                case lists:member(<<"id">>, Levels) of
                    true -> ?ID_HEADERS;
                    false -> []
                end,
            User ++ Id
    end.

%% RFC 3323 4.2, 5: Privacy: none goes to B as it came, whatever else is
%% copied; an intermediary must not drop or change it
privacy_none(Msg, Copied) ->
    Privacy = chappe_sip_msg:get_all(<<"privacy">>, Msg),
    Has = lists:any(
        fun(V) ->
            lists:member(
                <<"none">>,
                [
                    string:lowercase(string:trim(T))
                 || T <- binary:split(V, [<<";">>, <<",">>], [global])
                ]
            )
        end,
        Privacy
    ),
    Already = [N || {N, _} <- Copied, string:lowercase(N) =:= <<"privacy">>],
    case Has andalso Already =:= [] of
        true -> [{<<"Privacy">>, V} || V <- Privacy];
        false -> []
    end.

%% headers copied from B's 2xx to A's
proxy_response_headers(undefined, _Opts) ->
    [];
proxy_response_headers(BMsg, Opts) ->
    copy(
        BMsg,
        maps:get(proxy_response_headers, Opts, []),
        excluded_response()
    ).

copy(_Msg, [], _Extra) ->
    [];
copy(Msg, all, Extra) ->
    copy_all(Msg, Extra);
copy(Msg, {all, Exclude}, Extra) ->
    copy_all(Msg, Extra ++ [string:lowercase(N) || N <- Exclude]);
copy(Msg, Names, _Extra) when is_list(Names) ->
    copy_named(Msg, Names).

copy_named(Msg, Names) ->
    lists:flatten(
        [[{N, V} || V <- chappe_sip_msg:get_all(N, Msg)] || N <- Names]
    ).

copy_all(Msg, ExtraExclude) ->
    Exclude = excluded() ++ ExtraExclude,
    [
        {Name, Value}
     || {Norm, Name, Value} <- chappe_sip_msg:all_headers(Msg),
        not lists:member(Norm, Exclude)
    ].
