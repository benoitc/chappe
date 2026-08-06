%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc FreeSWITCH / ESL backend adapter for chappe_sip_media.
%%
%% FreeSWITCH terminates a media leg over SIP, so media does not flow through
%% chappe_sip: the application originates a UAC leg from chappe_sip to
%% FreeSWITCH (chappe_sip:create_uac), bridges its inbound dialog to that leg, and
%% this adapter drives the resulting FreeSWITCH channel over ESL. A session is
%% the pairing of a configured FreeSWITCH node and that channel UUID; control
%% operations (conference, play, record, dtmf) are ESL commands against the
%% channel. Because the media rides the real SIP leg, offer/answer (SDP
%% rewriting) do not apply here.
%%
%% ESL connections are owned by chappe_sip_media_esl_mgr, one per node, opened lazily.
-module(chappe_sip_media_freeswitch).

-export([
    configure/1,
    start/2,
    offer/4,
    answer/4,
    play/2,
    record/2,
    stop_record/1,
    dtmf/2,
    conference/3,
    subscribe/2,
    subscribe_answer/2,
    unsubscribe/2,
    duck/2,
    unduck/2,
    stop/1,
    info/1
]).

-export_type([identity/0, ref/0]).

-type identity() :: #{call_id := binary(), _ => _}.
-type ref() :: #{node := atom(), uuid := binary()}.

%% Bring up the ESL control manager for the configured FreeSWITCH nodes.
-spec configure([map()]) -> ok | {error, term()}.
configure(Nodes) ->
    Spec = #{
        id => chappe_sip_media_esl_mgr,
        start => {chappe_sip_media_esl_mgr, start_link, [Nodes]},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [chappe_sip_media_esl_mgr]
    },
    case chappe_sip_media_sup:start_child(Spec) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, _} = Err -> Err
    end.

%% A session names the FreeSWITCH node and the channel UUID to control (the
%% UUID of the leg the application originated / bridged toward FreeSWITCH).
-spec start(identity(), map()) -> {ok, ref()} | {error, term()}.
start(_Id, Opts) ->
    case {maps:get(node, Opts, undefined), maps:get(uuid, Opts, undefined)} of
        {undefined, _} -> {error, no_node};
        {_, undefined} -> {error, no_channel};
        {Node, Uuid} -> {ok, #{node => Node, uuid => Uuid}}
    end.

%% Media rides the SIP leg on this backend; there is no SDP to rewrite.
-spec offer(ref(), identity(), iodata(), map()) -> {error, unsupported}.
offer(_Ref, _Id, _Sdp, _Opts) ->
    {error, unsupported}.

-spec answer(ref(), identity(), iodata(), map()) -> {error, unsupported}.
answer(_Ref, _Id, _Sdp, _Opts) ->
    {error, unsupported}.

-spec play(ref(), map()) -> ok | {error, term()}.
play(Ref, #{file := File}) ->
    execute(Ref, <<"playback">>, File);
play(_Ref, _Media) ->
    {error, {missing, file}}.

-spec record(ref(), map()) -> ok | {error, term()}.
record(#{uuid := Uuid} = Ref, #{path := Path}) ->
    api(Ref, [<<"uuid_record ">>, Uuid, <<" start ">>, Path]);
record(_Ref, _Opts) ->
    {error, {missing, path}}.

-spec stop_record(ref()) -> ok | {error, term()}.
stop_record(#{uuid := Uuid} = Ref) ->
    api(Ref, [<<"uuid_record ">>, Uuid, <<" stop all">>]).

-spec dtmf(ref(), map()) -> ok | {error, term()}.
dtmf(Ref, #{digits := Digits}) ->
    execute(Ref, <<"send_dtmf">>, Digits);
dtmf(_Ref, _Params) ->
    {error, {missing, digits}}.

%% Join the channel to a named conference.
-spec conference(ref(), binary(), map()) -> ok | {error, term()}.
conference(Ref, Room, _Opts) ->
    execute(Ref, <<"conference">>, Room).

%% Media subscription and ducking are rtpengine capabilities (they operate on
%% anchored RTP); FreeSWITCH media rides its own leg.
-spec subscribe(ref(), map()) -> {error, {unsupported, subscribe}}.
subscribe(_Ref, _Opts) ->
    {error, {unsupported, subscribe}}.

-spec subscribe_answer(ref(), map()) -> {error, {unsupported, subscribe}}.
subscribe_answer(_Ref, _Params) ->
    {error, {unsupported, subscribe}}.

-spec unsubscribe(ref(), map()) -> {error, {unsupported, subscribe}}.
unsubscribe(_Ref, _Params) ->
    {error, {unsupported, subscribe}}.

-spec duck(ref(), map()) -> {error, {unsupported, duck}}.
duck(_Ref, _Opts) ->
    {error, {unsupported, duck}}.

-spec unduck(ref(), map()) -> {error, {unsupported, duck}}.
unduck(_Ref, _Opts) ->
    {error, {unsupported, duck}}.

%% The SIP dialog owns the leg lifecycle; tearing the media down is the BYE.
-spec stop(ref()) -> ok.
stop(_Ref) ->
    ok.

-spec info(ref()) -> ref().
info(Ref) ->
    Ref.

%% internal

execute(#{node := Node, uuid := Uuid}, App, Args) ->
    case chappe_sip_media_esl_mgr:conn(Node) of
        {ok, Conn} -> chappe_esl:execute(Conn, Uuid, App, Args);
        {error, _} = Err -> Err
    end.

api(#{node := Node}, Command) ->
    case chappe_sip_media_esl_mgr:conn(Node) of
        {ok, Conn} ->
            case chappe_esl:api(Conn, Command) of
                {ok, _} -> ok;
                {error, _} = Err -> Err
            end;
        {error, _} = Err ->
            Err
    end.
