%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% NG protocol data model: builds command dictionaries from Erlang maps
%% with atom keys, and classifies decoded replies.
%%
%% Atom keys map to the NG wire names: underscores become hyphens
%% (call_id -> <<"call-id">>) with the irregular casings handled
%% explicitly (ice -> <<"ICE">>). Binary keys and values pass through
%% untouched, which is the escape hatch for anything unmapped.
%%
%% Replies keep their wire types: rtpengine flips some fields between
%% integer and string across versions, so no coercion happens here.
-module(chappe_rtpengine_ng).

-export([
    command/2,
    encode_command/2,
    decode_reply/1,
    sdp/1
]).

-type params() :: #{atom() | binary() => term()}.
-type reply() :: #{binary() => term()}.
-type result() ::
    {ok, reply()}
    | {error, term(), reply()}.

-export_type([params/0, reply/0, result/0]).

%% Build the NG dictionary for a command.
-spec command(atom(), params()) -> #{binary() => term()}.
command(Command, Params) when is_atom(Command), is_map(Params) ->
    Dict = maps:fold(
        fun(K, V, Acc) -> Acc#{ng_key(K) => ng_value(V)} end,
        #{},
        Params
    ),
    Dict#{<<"command">> => command_name(Command)}.

%% Build and bencode a command in the calling process, keeping
%% SDP-sized encoding work out of the client gen_server.
-spec encode_command(atom(), params()) -> binary().
encode_command(Command, Params) ->
    chappe_rtpengine_bencode:encode_to_binary(command(Command, Params)).

%% Classify a decoded reply dictionary.
-spec decode_reply(reply()) -> result().
decode_reply(Reply) when is_map(Reply) ->
    case maps:get(<<"result">>, Reply, undefined) of
        R when R =:= <<"ok">>; R =:= <<"pong">> ->
            {ok, Reply};
        <<"error">> ->
            Reason = maps:get(<<"error-reason">>, Reply, <<"unknown">>),
            {error, Reason, Reply};
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
ng_key(dtls) -> <<"DTLS">>;
ng_key(sdes) -> <<"SDES">>;
ng_key(osrtp) -> <<"OSRTP">>;
ng_key(record_call) -> <<"record call">>;
ng_key(K) when is_atom(K) -> hyphenate(K).

ng_value(V) when is_binary(V) -> V;
ng_value(V) when is_integer(V) -> V;
ng_value(V) when is_atom(V) -> hyphenate(V);
ng_value(V) when is_list(V) -> [ng_value(E) || E <- V];
ng_value(V) when is_map(V) ->
    maps:fold(fun(K, E, Acc) -> Acc#{ng_key(K) => ng_value(E)} end, #{}, V).

hyphenate(A) ->
    binary:replace(atom_to_binary(A, utf8), <<"_">>, <<"-">>, [global]).
