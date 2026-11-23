%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc NG protocol data model: builds command dictionaries from Erlang maps
%% with atom keys, and classifies decoded replies.
%%
%% Atom keys map to the NG wire names: underscores become hyphens
%% (call_id -> <<"call-id">>) with the irregular names handled
%% explicitly (ice -> <<"ICE">>, media_address -> <<"media address">>,
%% t38 -> <<"T.38">>, ...). Binary keys and values pass through
%% untouched, which is the escape hatch for anything unmapped.
%%
%% Atom values: under the option-word keys (flags, replace, rtcp-mux,
%% ICE, ICE-lite, DTLS, DTLS-reverse, OSRTP, T.38, record call) atoms
%% are NG option words, written with hyphens in the NG documentation,
%% so underscores become hyphens (trust_address -> <<"trust-address">>).
%% Every other atom value is sent verbatim (atom_to_binary), which
%% keeps SDES suite names, codec names and interface names intact.
%% Bencode has no floats or tuples: such a value raises
%% {bad_param, Key, Value}.
%%
%% Replies keep their wire types: rtpengine flips some fields between
%% integer and string across versions, so no coercion happens here.
-module(chappe_rtpengine_ng).

-export([
    command/2,
    encode_command/2,
    decode_reply/1,
    sdp/1,
    require/2
]).

-type params() :: #{atom() | binary() => term()}.
-type reply() :: #{binary() => term()}.
-type result() ::
    {ok, reply()}
    | {error, term(), reply()}.

-export_type([params/0, reply/0, result/0]).

%% ok when Params carries every key of Keys.
-spec require([atom()], params()) -> ok | {error, {missing_params, [atom()]}}.
require(Keys, Params) ->
    case [K || K <- Keys, not maps:is_key(K, Params)] of
        [] -> ok;
        Missing -> {error, {missing_params, Missing}}
    end.

%% Build the NG dictionary for a command.
-spec command(atom(), params()) -> #{binary() => term()}.
command(Command, Params) when is_atom(Command), is_map(Params) ->
    Dict = encode_map(undefined, Params),
    Dict#{<<"command">> => command_name(Command)}.

%% Build and bencode a command in the calling process, keeping
%% SDP-sized encoding work out of the client gen_server.
-spec encode_command(atom(), params()) -> binary().
encode_command(Command, Params) ->
    chappe_rtpengine_bencode:encode_to_binary(command(Command, Params)).

%% Classify a decoded reply dictionary: ok and pong are successes (a
%% "warning" key, when present, stays in the reply map), error carries
%% its error-reason, "load limit" (the node is shedding load) is
%% {error, load_limit, Reply}, anything else is
%% {error, {unexpected_result, R}, Reply}.
-spec decode_reply(reply()) -> result().
decode_reply(Reply) when is_map(Reply) ->
    case maps:get(<<"result">>, Reply, undefined) of
        R when R =:= <<"ok">>; R =:= <<"pong">> ->
            {ok, Reply};
        <<"error">> ->
            Reason = maps:get(<<"error-reason">>, Reply, <<"unknown">>),
            {error, Reason, Reply};
        <<"load limit">> ->
            {error, load_limit, Reply};
        Other ->
            {error, {unexpected_result, Other}, Reply}
    end.

%% The rewritten SDP from an offer/answer reply.
-spec sdp(reply()) -> binary() | undefined.
sdp(Reply) ->
    maps:get(<<"sdp">>, Reply, undefined).

%% internal

command_name(ping) ->
    <<"ping">>;
command_name(offer) ->
    <<"offer">>;
command_name(answer) ->
    <<"answer">>;
command_name(delete) ->
    <<"delete">>;
command_name(query) ->
    <<"query">>;
command_name(list) ->
    <<"list">>;
command_name(statistics) ->
    <<"statistics">>;
command_name(start_recording) ->
    <<"start recording">>;
command_name(stop_recording) ->
    <<"stop recording">>;
command_name(pause_recording) ->
    <<"pause recording">>;
command_name(block_dtmf) ->
    <<"block DTMF">>;
command_name(unblock_dtmf) ->
    <<"unblock DTMF">>;
command_name(play_dtmf) ->
    <<"play DTMF">>;
command_name(block_media) ->
    <<"block media">>;
command_name(unblock_media) ->
    <<"unblock media">>;
command_name(silence_media) ->
    <<"silence media">>;
command_name(unsilence_media) ->
    <<"unsilence media">>;
command_name(start_forwarding) ->
    <<"start forwarding">>;
command_name(stop_forwarding) ->
    <<"stop forwarding">>;
command_name(play_media) ->
    <<"play media">>;
command_name(stop_media) ->
    <<"stop media">>;
command_name(publish) ->
    <<"publish">>;
command_name(subscribe_request) ->
    <<"subscribe request">>;
command_name(subscribe_answer) ->
    <<"subscribe answer">>;
command_name(unsubscribe) ->
    <<"unsubscribe">>;
command_name(connect) ->
    <<"connect">>;
command_name(Other) ->
    binary:replace(atom_to_binary(Other, utf8), <<"_">>, <<" ">>, [global]).

ng_key(K) when is_binary(K) -> K;
ng_key(ice) -> <<"ICE">>;
ng_key(ice_lite) -> <<"ICE-lite">>;
ng_key(dtls) -> <<"DTLS">>;
ng_key(dtls_fingerprint) -> <<"DTLS-fingerprint">>;
ng_key(dtls_reverse) -> <<"DTLS-reverse">>;
ng_key(sdes) -> <<"SDES">>;
ng_key(osrtp) -> <<"OSRTP">>;
ng_key(tos) -> <<"TOS">>;
ng_key(t38) -> <<"T.38">>;
ng_key(record_call) -> <<"record call">>;
ng_key(media_address) -> <<"media address">>;
ng_key(address_family) -> <<"address family">>;
ng_key(received_from) -> <<"received from">>;
ng_key(K) when is_atom(K) -> hyphenate(K).

%% Wire keys whose atom values are NG option words.
option_key(<<"flags">>) -> true;
option_key(<<"replace">>) -> true;
option_key(<<"rtcp-mux">>) -> true;
option_key(<<"ICE">>) -> true;
option_key(<<"ICE-lite">>) -> true;
option_key(<<"DTLS">>) -> true;
option_key(<<"DTLS-reverse">>) -> true;
option_key(<<"OSRTP">>) -> true;
option_key(<<"T.38">>) -> true;
option_key(<<"record call">>) -> true;
option_key(_Key) -> false.

encode_map(Top, Map) ->
    maps:fold(
        fun(K, V, Acc) ->
            Key = ng_key(K),
            Param =
                case Top of
                    undefined -> K;
                    _ -> Top
                end,
            Acc#{Key => ng_value(Param, option_key(Key), V)}
        end,
        #{},
        Map
    ).

ng_value(_Param, _Opt, V) when is_binary(V) -> V;
ng_value(_Param, _Opt, V) when is_integer(V) -> V;
ng_value(_Param, true, V) when is_atom(V) -> hyphenate(V);
ng_value(_Param, false, V) when is_atom(V) -> atom_to_binary(V, utf8);
ng_value(Param, Opt, V) when is_list(V) -> [ng_value(Param, Opt, E) || E <- V];
ng_value(Param, _Opt, V) when is_map(V) -> encode_map(Param, V);
ng_value(Param, _Opt, V) -> erlang:error({bad_param, Param, V}).

hyphenate(A) ->
    binary:replace(atom_to_binary(A, utf8), <<"_">>, <<"-">>, [global]).
