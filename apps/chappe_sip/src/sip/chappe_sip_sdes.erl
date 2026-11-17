%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc SDP security descriptions for SRTP (RFC 4568): the a=crypto lines
%% of an offered media section, read for the suites chappe_audio_srtp
%% decrypts, and the line that answers the one taken.
%%
%% select/1 takes a media section's lines and gives the first a=crypto
%% line it can take (RFC 4568 5.1.2: the first valid, supported one), as
%% the master key and salt chappe_audio_srtp:new/1 takes. What it takes:
%%   - suites AES_CM_128_HMAC_SHA1_80 and AES_CM_128_HMAC_SHA1_32 (6.2.1,
%%     6.2.2), the inline key method, a key and salt of 30 octets (6.1);
%%   - one master key, with or without a lifetime (decimal or 2^n, at most
%%     2^48) and an MKI (1 to 128 octets);
%%   - session parameters KDR=0, WSH (the replay window, from 64; 6.3.6),
%%     FEC_ORDER (declarative, no FEC is used) and any optional one (a
%%     leading "-", 6.3.7).
%% A line is skipped when it is invalid (6.1, 9.2: a key of another
%% length, a lifetime or MKI that does not parse, an unknown mandatory
%% parameter) or not supported: another suite (F8, AES-256, AEAD), several
%% master keys, a key derivation rate (KDR=1 to 24), UNENCRYPTED_SRTP,
%% UNENCRYPTED_SRTCP, UNAUTHENTICATED_SRTP (the recording stays encrypted
%% and authenticated), FEC_KEY. No line left: {error, no_crypto} when the
%% section had none, {error, unsupported} otherwise, and the stream is to
%% be refused (5.1.2, 7.1.2).
%%
%% answer/1 gives the answer's a=crypto line: the tag and suite taken, and
%% a fresh key of the answerer's (7.1.2: a key MUST be given, different
%% from the offer's); chappe receives only, so it never uses it.
-module(chappe_sip_sdes).

-export([select/1, parse/1, answer/1]).

-export_type([crypto/0, suite/0]).

%% the SRTP suites a crypto line can name that chappe decrypts
-type suite() :: aes_cm_128_hmac_sha1_80 | aes_cm_128_hmac_sha1_32.

-type crypto() :: #{
    tag := binary(),
    suite := suite(),
    key := binary(),
    salt := binary(),
    mki => binary(),
    lifetime => pos_integer(),
    window => pos_integer()
}.

-define(MAX_LIFETIME, (1 bsl 48)).
-define(MAX_WINDOW, 1024).

%% The first a=crypto line of a media section's lines that can be taken.
-spec select([binary()]) -> {ok, crypto()} | {error, no_crypto | unsupported}.
select(Lines) ->
    case [V || <<"a=crypto:", V/binary>> <- Lines] of
        [] -> {error, no_crypto};
        Values -> first(Values)
    end.

first([]) ->
    {error, unsupported};
first([V | Rest]) ->
    case parse(V) of
        {ok, C} -> {ok, C};
        {error, _} -> first(Rest)
    end.

%% One a=crypto value (past "a=crypto:"): "<tag> <suite> <key-params>
%% [<session-param>...]" (RFC 4568 9.1).
-spec parse(binary()) -> {ok, crypto()} | {error, invalid | unsupported}.
parse(Value) ->
    case chappe_sip_sdp:words(Value) of
        [Tag, Suite, KeyParams | Params] ->
            case {tag(Tag), suite(chappe_sip_lib:upper(Suite))} of
                {ok, {ok, S}} -> key_params(Tag, S, KeyParams, Params);
                {ok, unsupported} -> {error, unsupported};
                _ -> {error, invalid}
            end;
        _ ->
            {error, invalid}
    end.

%% tag = 1*9DIGIT
tag(T) when byte_size(T) >= 1, byte_size(T) =< 9 ->
    case chappe_sip_lib:all_digits(T) of
        true -> ok;
        false -> error
    end;
tag(_) ->
    error.

suite(<<"AES_CM_128_HMAC_SHA1_80">>) ->
    {ok, aes_cm_128_hmac_sha1_80};
suite(<<"AES_CM_128_HMAC_SHA1_32">>) ->
    {ok, aes_cm_128_hmac_sha1_32};
suite(S) ->
    %% crypto-suite = 1*(ALPHA / DIGIT / "_")
    case lists:all(fun suite_char/1, binary_to_list(S)) of
        true -> unsupported;
        false -> error
    end.

suite_char(C) ->
    (C >= $A andalso C =< $Z) orelse (C >= $0 andalso C =< $9) orelse C =:= $_.

%% RFC 4568 6.1: several master keys (each with an MKI) are not taken
key_params(Tag, Suite, KeyParams, Params) ->
    case binary:split(KeyParams, <<";">>, [global]) of
        [One] ->
            case key_param(One) of
                {ok, Key} -> session(Params, Key#{tag => Tag, suite => Suite});
                {error, _} = E -> E
            end;
        _ ->
            {error, unsupported}
    end.

%% "inline:" key||salt ["|" lifetime] ["|" MKI ":" length]
key_param(<<Method:6/binary, ":", Info/binary>>) ->
    case chappe_sip_lib:lower(Method) of
        <<"inline">> -> key_info(binary:split(Info, <<"|">>, [global]));
        _ -> {error, unsupported}
    end;
key_param(_) ->
    {error, unsupported}.

key_info([KeySalt | Rest]) ->
    case {key_salt(KeySalt), lifetime_mki(Rest)} of
        {{ok, Key, Salt}, {ok, Extra}} ->
            {ok, maps:merge(#{key => Key, salt => Salt}, Extra)};
        _ ->
            {error, invalid}
    end.

%% 30 octets once decoded, the base64 padding discarded (6.1, 6.2.1)
key_salt(B64) ->
    Bare = string:trim(B64, trailing, "="),
    try base64:decode(Bare, #{padding => false}) of
        <<Key:16/binary, Salt:14/binary>> -> {ok, Key, Salt};
        _ -> error
    catch
        error:_ -> error
    end.

lifetime_mki([]) ->
    {ok, #{}};
lifetime_mki([One]) ->
    case binary:match(One, <<":">>) of
        nomatch -> with(lifetime(One), lifetime, #{});
        _ -> with(mki(One), mki, #{})
    end;
lifetime_mki([Life, Mki]) ->
    case lifetime(Life) of
        {ok, L} -> with(mki(Mki), mki, #{lifetime => L});
        error -> error
    end;
lifetime_mki(_) ->
    error.

with({ok, V}, K, M) -> {ok, M#{K => V}};
with(error, _K, _M) -> error.

%% lifetime = ["2^"] 1*(DIGIT), no leading zero, at most the suite's 2^48
lifetime(<<"2^", N/binary>>) ->
    case number(N) of
        {ok, E} when E =< 48 -> {ok, 1 bsl E};
        _ -> error
    end;
lifetime(N) ->
    case number(N) of
        {ok, L} when L >= 1, L =< ?MAX_LIFETIME -> {ok, L};
        _ -> error
    end.

%% mki = mki-value ":" mki-length, the length 1 to 128 octets and the
%% value one that fits in it
mki(B) ->
    case binary:split(B, <<":">>) of
        [V, L] ->
            case {number(V), number(L)} of
                {{ok, Val}, {ok, Len}} when
                    Len >= 1, Len =< 128, Val < 1 bsl (Len * 8)
                ->
                    {ok, <<Val:(Len * 8)>>};
                _ ->
                    error
            end;
        _ ->
            error
    end.

%% a decimal with no leading zero (RFC 4568 6.1)
number(<<"0">>) ->
    {ok, 0};
number(<<"0", _/binary>>) ->
    error;
number(B) when byte_size(B) >= 1, byte_size(B) =< 20 ->
    case chappe_sip_lib:all_digits(B) of
        true -> {ok, binary_to_integer(B)};
        false -> error
    end;
number(_) ->
    error.

%% RFC 4568 6.3
session([], C) ->
    {ok, C};
session([<<"KDR=", N/binary>> | Rest], C) ->
    case number(N) of
        {ok, 0} -> session(Rest, C);
        {ok, R} when R =< 24 -> {error, unsupported};
        _ -> {error, invalid}
    end;
session([<<"WSH=", N/binary>> | Rest], C) ->
    case number(N) of
        {ok, W} when W >= 64 ->
            session(Rest, C#{window => min(W, ?MAX_WINDOW)});
        _ ->
            {error, invalid}
    end;
session([<<"FEC_ORDER=", T/binary>> | Rest], C) ->
    case lists:member(T, [<<"FEC_SRTP">>, <<"SRTP_FEC">>]) of
        true -> session(Rest, C);
        false -> {error, invalid}
    end;
session([<<"FEC_KEY=", _/binary>> | _], _C) ->
    {error, unsupported};
session([P | _], _C) when
    P =:= <<"UNENCRYPTED_SRTP">>;
    P =:= <<"UNENCRYPTED_SRTCP">>;
    P =:= <<"UNAUTHENTICATED_SRTP">>
->
    {error, unsupported};
session([<<"-", _/binary>> | Rest], C) ->
    session(Rest, C);
session([_Unknown | _], _C) ->
    {error, invalid}.

%% The answer's a=crypto line for the one taken.
-spec answer(crypto()) -> binary().
answer(#{tag := Tag, suite := Suite}) ->
    Key = base64:encode(crypto:strong_rand_bytes(30)),
    <<"a=crypto:", Tag/binary, " ", (suite_name(Suite))/binary, " inline:",
        Key/binary>>.

suite_name(aes_cm_128_hmac_sha1_80) -> <<"AES_CM_128_HMAC_SHA1_80">>;
suite_name(aes_cm_128_hmac_sha1_32) -> <<"AES_CM_128_HMAC_SHA1_32">>.
