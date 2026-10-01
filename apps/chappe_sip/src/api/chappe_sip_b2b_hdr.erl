%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The headers a B2BUA carries from one leg to the other: the Reason of a
%% BYE or CANCEL (RFC 3326), the request headers copied from A to B with
%% Privacy: none always kept (RFC 3323), and the headers of B's 2xx copied
%% to A's. Split out of chappe_sip_b2b, which owns the call flow.
-module(chappe_sip_b2b_hdr).

-export([
    reason_headers/1,
    proxy_request_headers/2,
    proxy_response_headers/2
]).

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
    Hdrs ++ privacy_none(Msg, Hdrs).

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
