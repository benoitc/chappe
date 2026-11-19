%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Bencode codec for the rtpengine NG protocol.
%%
%% Encoding is canonical: dictionary keys are emitted in ascending raw
%% byte order, as required by bencode, and a map whose atom and binary
%% keys collide once converted is an error (duplicate_key). Decoding is
%% tolerant of unsorted dictionaries and preserves wire types (strings
%% decode to binaries, dictionaries to maps with binary keys), but
%% rejects non-canonical numbers: integers and string lengths with
%% leading zeros, negative zero, or a plus sign. Nesting is bounded to
%% 64 containers (too_deep), so a hostile peer cannot exhaust the
%% stack.
-module(chappe_rtpengine_bencode).

-export([
    encode_to_binary/1,
    decode/1
]).
-ifdef(TEST).
-export([encode/1, decode_prefix/1, decode_stream/1]).
-endif.

-define(MAX_DEPTH, 64).
%% A partial value: the reason decode/1 reports, and a lower bound on
%% the bytes still needed.
-define(MORE(Reason, Need), throw({incomplete, Reason, Need})).

-type value() ::
    integer()
    | binary()
    | atom()
    | [value()]
    | #{binary() | atom() => value()}.

-export_type([value/0]).

-spec encode(value()) -> iodata().
encode(I) when is_integer(I) ->
    [$i, integer_to_binary(I), $e];
encode(B) when is_binary(B) ->
    [integer_to_binary(byte_size(B)), $:, B];
encode(A) when is_atom(A) ->
    encode(atom_to_binary(A, utf8));
encode(M) when is_map(M) ->
    Pairs = lists:keysort(1, [{key_bin(K), V} || {K, V} <- maps:to_list(M)]),
    ok = no_duplicate_keys(Pairs),
    [$d, [[encode(K), encode(V)] || {K, V} <- Pairs], $e];
encode(L) when is_list(L) ->
    [$l, [encode(E) || E <- L], $e].

-spec encode_to_binary(value()) -> binary().
encode_to_binary(V) ->
    iolist_to_binary(encode(V)).

-spec decode(binary()) -> {ok, value()} | {error, term()}.
decode(Bin) when is_binary(Bin) ->
    try dec(Bin, 0) of
        {Value, <<>>} -> {ok, Value};
        {_Value, Rest} -> {error, {trailing_bytes, byte_size(Rest)}}
    catch
        throw:{incomplete, Reason, _Need} -> {error, Reason};
        throw:Reason -> {error, Reason}
    end.

%% internal

key_bin(K) when is_binary(K) -> K;
key_bin(K) when is_atom(K) -> atom_to_binary(K, utf8).

no_duplicate_keys([{K, _}, {K, _} | _]) ->
    erlang:error({duplicate_key, K});
no_duplicate_keys([_ | T]) ->
    no_duplicate_keys(T);
no_duplicate_keys([]) ->
    ok.

dec(<<>>, _Depth) ->
    ?MORE(unexpected_end, 1);
dec(<<$i, Rest/binary>>, _Depth) ->
    dec_int(Rest);
dec(<<$l, Rest/binary>>, Depth) ->
    nest(Depth),
    dec_list(Rest, Depth + 1, []);
dec(<<$d, Rest/binary>>, Depth) ->
    nest(Depth),
    dec_dict(Rest, Depth + 1, #{});
dec(<<C, _/binary>> = Bin, _Depth) when C >= $0, C =< $9 ->
    dec_str(Bin);
dec(_, _Depth) ->
    throw(invalid).

%% A container opened at depth MAX_DEPTH would hold values one level
%% deeper than allowed.
nest(Depth) when Depth >= ?MAX_DEPTH -> throw(too_deep);
nest(_Depth) -> ok.

dec_int(Bin) ->
    case binary:split(Bin, <<"e">>) of
        [Digits, Rest] ->
            case canonical_int(Digits) of
                true -> {binary_to_integer(Digits), Rest};
                false -> throw({bad_integer, Digits})
            end;
        [Digits] ->
            %% no terminator yet: only incomplete when what we have
            %% so far could still become a canonical integer
            case int_prefix(Digits) of
                true -> ?MORE(unterminated_integer, 1);
                false -> throw({bad_integer, Digits})
            end
    end.

%% "0", or an optional minus then a non-zero digit and more digits.
canonical_int(<<"0">>) -> true;
canonical_int(<<"-", Rest/binary>>) -> canonical_nonzero(Rest);
canonical_int(Digits) -> canonical_nonzero(Digits).

canonical_nonzero(<<C, Rest/binary>>) when C >= $1, C =< $9 -> digits(Rest);
canonical_nonzero(_) -> false.

int_prefix(<<>>) -> true;
int_prefix(<<"-">>) -> true;
int_prefix(Digits) -> canonical_int(Digits).

dec_str(Bin) ->
    case binary:split(Bin, <<":">>) of
        [Digits, Rest] ->
            Len =
                case canonical_len(Digits) of
                    true -> binary_to_integer(Digits);
                    false -> throw({bad_length, Digits})
                end,
            case Rest of
                <<Str:Len/binary, Tail/binary>> ->
                    {Str, Tail};
                _ ->
                    ?MORE(truncated_string, Len - byte_size(Rest))
            end;
        [Digits] ->
            %% no colon yet: a canonical digit run is an unfinished
            %% length prefix, anything else can never parse
            case canonical_len(Digits) of
                true -> ?MORE(truncated_string, 1);
                false -> throw(bad_string)
            end
    end.

canonical_len(<<"0">>) -> true;
canonical_len(Digits) -> canonical_nonzero(Digits).

digits(<<>>) -> true;
digits(<<C, Rest/binary>>) when C >= $0, C =< $9 -> digits(Rest);
digits(_) -> false.

dec_list(<<$e, Rest/binary>>, _Depth, Acc) ->
    {lists:reverse(Acc), Rest};
dec_list(<<>>, _Depth, _Acc) ->
    ?MORE(unterminated_list, 1);
dec_list(Bin, Depth, Acc) ->
    {V, Rest} = dec(Bin, Depth),
    dec_list(Rest, Depth, [V | Acc]).

dec_dict(<<$e, Rest/binary>>, _Depth, Acc) ->
    {Acc, Rest};
dec_dict(<<>>, _Depth, _Acc) ->
    ?MORE(unterminated_dict, 1);
dec_dict(Bin, Depth, Acc) ->
    {K, Rest0} = dec(Bin, Depth),
    is_binary(K) orelse throw({bad_dict_key, K}),
    {V, Rest1} = dec(Rest0, Depth),
    dec_dict(Rest1, Depth, Acc#{K => V}).

-ifdef(TEST).
%% Decode one value from the head of a byte stream (NG over TCP):
%% returns the value and the unconsumed rest, `incomplete` when the
%% buffer ends mid-value, or an error for input that can never parse.
-spec decode_prefix(binary()) ->
    {ok, value(), binary()} | incomplete | {error, term()}.
decode_prefix(Bin) when is_binary(Bin) ->
    case decode_stream(Bin) of
        {more, _Need} -> incomplete;
        Other -> Other
    end.

%% Like decode_prefix/1, but a partial value reports a lower bound on
%% the number of further bytes it needs ({more, N}). A stream reader
%% waits for at least that many before trying again, which keeps a
%% large value arriving in many segments linear instead of rescanning
%% the whole buffer per segment.
-spec decode_stream(binary()) ->
    {ok, value(), binary()} | {more, pos_integer()} | {error, term()}.
decode_stream(Bin) when is_binary(Bin) ->
    try dec(Bin, 0) of
        {Value, Rest} -> {ok, Value, Rest}
    catch
        throw:{incomplete, _Reason, Need} -> {more, Need};
        throw:Reason -> {error, Reason}
    end.
-endif.
