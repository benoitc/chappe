%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The typed auxiliary NG commands of a media session: playback, DTMF,
%% media blocking and silencing, recording, forwarding and subscriptions.
%% Each is chappe_rtpengine_session:cmd/3 with the command's name and
%% defaults; the session process injects the call-id and tags and
%% resolves the party sugar.
-module(chappe_rtpengine_cmd).

-export([
    play_media/2,
    stop_media/1,
    play_dtmf/2,
    block_dtmf/1,
    unblock_dtmf/1,
    block_media/1,
    block_media/2,
    unblock_media/1,
    unblock_media/2,
    silence_media/1,
    silence_media/2,
    unsilence_media/1,
    unsilence_media/2,
    start_recording/1,
    stop_recording/1,
    start_forwarding/2,
    stop_forwarding/1,
    stop_forwarding/2,
    subscribe_request/2,
    subscribe_answer/2,
    unsubscribe/2
]).

%% Announcement or prompt to the from-tag party by default; pass
%% party => caller | callee | all (or label) to pick the leg. Provide
%% the audio as file, blob (raw bytes), blob64 (base64) or db_id, and
%% loop with repeat_times. The reply may carry duration in ms.
-spec play_media(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
play_media(Session, Params) ->
    chappe_rtpengine_session:cmd(Session, play_media, Params).

-spec stop_media(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
stop_media(Session) ->
    chappe_rtpengine_session:cmd(Session, stop_media, #{}).

%% Params: code (digit), and optionally duration, volume, pause.
-spec play_dtmf(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
play_dtmf(Session, Params) ->
    chappe_rtpengine_session:cmd(Session, play_dtmf, Params).

-spec block_dtmf(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
block_dtmf(Session) ->
    chappe_rtpengine_session:cmd(Session, block_dtmf, #{}).

-spec unblock_dtmf(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
unblock_dtmf(Session) ->
    chappe_rtpengine_session:cmd(Session, unblock_dtmf, #{}).

%% Media blocking and silencing, the ducking primitives. Blocking
%% stops a party's packets entirely; silencing keeps them flowing but
%% replaces the audio with silence. With no options the whole call is
%% affected. Target one direction with party => caller | callee: the
%% party's tag goes out as from-tag together with the directional
%% flag, which rtpengine requires for per-party media control. Raw NG
%% keys (label, address, to_tag, flags, ...) pass through and win.
-spec block_media(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
block_media(Session) ->
    block_media(Session, #{}).

-spec block_media(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
block_media(Session, Opts) ->
    chappe_rtpengine_session:cmd(Session, block_media, Opts).

-spec unblock_media(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
unblock_media(Session) ->
    unblock_media(Session, #{}).

-spec unblock_media(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
unblock_media(Session, Opts) ->
    chappe_rtpengine_session:cmd(Session, unblock_media, Opts).

-spec silence_media(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
silence_media(Session) ->
    silence_media(Session, #{}).

-spec silence_media(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
silence_media(Session, Opts) ->
    chappe_rtpengine_session:cmd(Session, silence_media, Opts).

-spec unsilence_media(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
unsilence_media(Session) ->
    unsilence_media(Session, #{}).

-spec unsilence_media(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
unsilence_media(Session, Opts) ->
    chappe_rtpengine_session:cmd(Session, unsilence_media, Opts).

-spec start_recording(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
start_recording(Session) ->
    chappe_rtpengine_session:cmd(Session, start_recording, #{}).

-spec stop_recording(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
stop_recording(Session) ->
    chappe_rtpengine_session:cmd(Session, stop_recording, #{}).

%% Forward the call's PCM to the recording daemon over TCP/TLS, apart from
%% call recording. With no options the whole call; party => caller |
%% callee (or the raw selection keys of block_media/2) picks one
%% direction.
-spec start_forwarding(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
start_forwarding(Session, Opts) ->
    chappe_rtpengine_session:cmd(Session, start_forwarding, Opts).

-spec stop_forwarding(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
stop_forwarding(Session) ->
    stop_forwarding(Session, #{}).

-spec stop_forwarding(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
stop_forwarding(Session, Opts) ->
    chappe_rtpengine_session:cmd(Session, stop_forwarding, Opts).

%% Media subscriptions are how a consumer (a recorder, an STT feed, a
%% conference mixer leg, a listen-in party) taps this call's media.
%% subscribe request returns an SDP offer describing the source
%% streams plus a to-tag naming the subscription; answer it with the
%% consumer's SDP. No from-tag is injected on subscription commands:
%% pass party => caller | callee (or from_tags => [Tag]) to tap one
%% participant, or flags => [all] for everyone. Control the output
%% with codec => #{mask => [...], transcode => [...]} and ptime.
%%
%% The offer describes every media stream of the tapped participants,
%% so a participant with N streams (a SIPREC recording offer, one
%% m-line per party) is tapped as N streams in m-line order. rtpengine
%% has no request-side selector for one of them: the answer decides,
%% by giving that m-line a port and rejecting the rest. Build it with
%% chappe_rtpengine_sdp:fork_answer/3 to send one stream to one receiver.
%%
%% holder => pid() makes the subscription that process's: the session
%% monitors it and unsubscribes when it exits, however it exits, so a
%% consumer that crashes leaves no fork running. unsubscribe/2 of the
%% to-tag releases it.
-spec subscribe_request(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
subscribe_request(Session, Params) ->
    chappe_rtpengine_session:cmd(Session, subscribe_request, Params).

-spec subscribe_answer(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
subscribe_answer(Session, Params) ->
    case chappe_rtpengine_ng:require([to_tag, sdp], Params) of
        ok -> chappe_rtpengine_session:cmd(Session, subscribe_answer, Params);
        {error, _} = Error -> Error
    end.

-spec unsubscribe(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
unsubscribe(Session, Params) ->
    case chappe_rtpengine_ng:require([to_tag], Params) of
        ok -> chappe_rtpengine_session:cmd(Session, unsubscribe, Params);
        {error, _} = Error -> Error
    end.
