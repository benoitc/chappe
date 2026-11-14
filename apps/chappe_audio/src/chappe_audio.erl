%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% chappe_audio: take a call's audio in from FreeSWITCH.
%%
%% A listener is a WebSocket server for mod_audio_fork and
%% mod_audio_stream. You open a stream on it for each fork you start: the
%% stream gives you a URL with its own path and token, you hand that URL
%% to the fork, and the audio comes to the stream's owner as messages.
%%
%% ```
%% {ok, L} = chappe_audio:listen(#{port => 8090, ip => {0, 0, 0, 0},
%%                                 url => <<"ws://10.0.0.5:8090">>}),
%% {ok, Stream, Url} = chappe_audio:open(L, #{ref => CallRef}),
%% ok = chappe_mrf:fork_audio(Ep, Url, #{mix => mono, rate => 8000}),
%% receive {chappe_audio, Stream, {frame, Pcm}, CallRef} -> ... end.
%% '''
%%
%% Events, to the owner (the caller of open/2 unless `owner' says
%% otherwise): {chappe_audio, Stream, Event}, or with a ref
%% {chappe_audio, Stream, Event, Ref}. Event is:
%%
%% - {connected, #{path, peer, subprotocol}}: the fork connected;
%% - {text, Bin}: a text message, the fork's metadata first;
%% - {frame, Pcm}: one message of 16-bit signed little-endian PCM at the
%%   stream's format, the two channels interleaved when stereo;
%% - closed: the stream is gone, always the last event.
%%
%% The stream and the listener are pids: they work from any node. A
%% stream lives on its listener's node, and streams/1 finds a call's
%% streams on every node through pg.
-module(chappe_audio).

-export([listen/1, listener_info/1, stop_listener/1]).
-export([open/1, open/2, close/1, info/1, set_owner/2, send_text/2]).
-export([streams/1, levels/2]).

-export_type([listener/0, stream/0, listen_opts/0, open_opts/0]).

-type listener() :: pid() | atom() | {atom(), node()}.
-type stream() :: pid().

%% port (default 0, any), ip (default 127.0.0.1: nothing is exposed
%% unless you say so), url: the base URL a fork reaches the listener at
%% (default ws://ip:port; set it when FreeSWITCH sees another address),
%% prefix: the path streams live under (default /audio), tls: ssl server
%% options for wss, max_pending: handshakes going at once (default 64),
%% handshake_timeout: ms for the upgrade request (default 5000),
%% max_handshake: bytes for it (default 8192), max_frame: bytes for one
%% message, past which the connection is closed with 1009 (default
%% 262144), idle_timeout: ms without a message before the connection is
%% closed (default infinity: a paused fork sends nothing),
%% subprotocols: those the listener accepts (default
%% [<<"audio.drachtio.org">>], mod_audio_fork's).
-type listen_opts() :: #{
    port => inet:port_number(),
    ip => inet:ip_address(),
    url => binary(),
    prefix => binary(),
    tls => [ssl:tls_server_option()],
    max_pending => pos_integer(),
    handshake_timeout => pos_integer(),
    max_handshake => pos_integer(),
    max_frame => pos_integer(),
    idle_timeout => timeout(),
    subprotocols => [binary()]
}.

%% owner: the process that gets the events (default the caller), ref:
%% the app's opaque binary for the call, in every event and the pg
%% group, format: the rate and channels the fork was started with
%% (default 8000 and 1), max_queue: the bound on events waiting at the
%% owner (default 500, 10 s of 20 ms frames), connect_timeout: ms to
%% wait for the fork (default 30000).
-type open_opts() :: #{
    owner => pid(),
    ref => binary(),
    format => #{rate => pos_integer(), channels => 1 | 2},
    max_queue => pos_integer(),
    connect_timeout => pos_integer()
}.

-spec listen(listen_opts()) -> {ok, listener()} | {error, term()}.
listen(Opts) when is_map(Opts) ->
    case check_listen(maps:to_list(Opts)) of
        ok -> supervisor:start_child(chappe_audio_listener_sup, [Opts]);
        Err -> Err
    end;
listen(_) ->
    {error, badarg}.

-spec listener_info(listener()) -> map().
listener_info(L) ->
    chappe_audio_listener:info(L).

-spec stop_listener(listener()) -> ok.
stop_listener(L) ->
    chappe_audio_listener:stop(L).

%% Open a stream on the default listener (the `listener' env).
-spec open(open_opts()) -> {ok, stream(), binary()} | {error, term()}.
open(Opts) ->
    open(chappe_audio_listener, Opts).

%% Open a stream on L; returns it and the URL to give the fork.
-spec open(listener(), open_opts()) ->
    {ok, stream(), binary()} | {error, term()}.
open(L, Opts) when is_map(Opts) ->
    case check_open(maps:to_list(Opts)) of
        ok ->
            try
                chappe_audio_listener:open(L, Opts#{
                    owner => maps:get(owner, Opts, self())
                })
            catch
                exit:{noproc, _} -> {error, no_listener}
            end;
        Err ->
            Err
    end;
open(_L, _Opts) ->
    {error, badarg}.

%% Close the connection (1000) and stop the stream; the owner gets
%% closed.
-spec close(stream()) -> ok.
close(Stream) ->
    try
        chappe_audio_stream:close(Stream)
    catch
        exit:_ -> ok
    end.

%% The stream's state and counters: id, ref, phase (waiting, claimed,
%% connected, closing), format, frames, bytes, texts, dropped (past the
%% bound), bad_frames (not a whole number of samples), and once
%% connected path, peer and subprotocol.
-spec info(stream()) -> map().
info(Stream) ->
    chappe_audio_stream:info(Stream).

-spec set_owner(stream(), pid()) -> ok | {error, badarg}.
set_owner(Stream, Pid) when is_pid(Pid) ->
    chappe_audio_stream:set_owner(Stream, Pid);
set_owner(_Stream, _Pid) ->
    {error, badarg}.

%% Send a text message to the fork (mod_audio_fork and mod_audio_stream
%% take JSON commands this way).
-spec send_text(stream(), binary()) -> ok | {error, term()}.
send_text(Stream, Text) when is_binary(Text) ->
    chappe_audio_stream:send_text(Stream, Text);
send_text(_Stream, _Text) ->
    {error, badarg}.

%% The streams of a call, on every node.
-spec streams(binary()) -> [stream()].
streams(Ref) when is_binary(Ref) ->
    pg:get_members(chappe_audio_lib:scope(), {chappe_audio, Ref}).

%% The RMS level of each channel of a frame in dBFS, -inf for silence
%% (as the atom '-inf'): what the demo prints as a caller speaks.
-spec levels(binary(), 1 | 2) -> [float() | '-inf'].
levels(Pcm, Channels) ->
    chappe_audio_pcm:levels(Pcm, Channels).

%% ---- argument checks, in the caller ----

check_listen(Opts) ->
    check(Opts, fun listen_opt/2).

check_open(Opts) ->
    check(Opts, fun open_opt/2).

check([], _Ok) ->
    ok;
check([{K, V} | T], Ok) ->
    case Ok(K, V) of
        true -> check(T, Ok);
        false -> {error, {bad_option, K}}
    end.

listen_opt(port, P) ->
    is_integer(P) andalso P >= 0 andalso P < 65536;
listen_opt(ip, Ip) ->
    is_tuple(Ip);
listen_opt(url, B) ->
    is_binary(B);
listen_opt(prefix, B) ->
    is_binary(B);
listen_opt(tls, L) ->
    is_list(L);
listen_opt(max_pending, N) ->
    pos(N);
listen_opt(handshake_timeout, N) ->
    pos(N);
listen_opt(max_handshake, N) ->
    pos(N);
listen_opt(max_frame, N) ->
    pos(N);
listen_opt(idle_timeout, infinity) ->
    true;
listen_opt(idle_timeout, N) ->
    pos(N);
listen_opt(subprotocols, L) ->
    is_list(L) andalso lists:all(fun is_binary/1, L);
listen_opt(_, _) ->
    false.

open_opt(owner, P) -> is_pid(P);
open_opt(ref, R) -> is_binary(R);
open_opt(format, F) -> is_map(F) andalso format_ok(F);
open_opt(max_queue, N) -> pos(N);
open_opt(connect_timeout, N) -> pos(N);
open_opt(_, _) -> false.

pos(N) -> is_integer(N) andalso N > 0.

format_ok(F) ->
    Rate = maps:get(rate, F, 8000),
    Ch = maps:get(channels, F, 1),
    is_integer(Rate) andalso Rate > 0 andalso (Ch =:= 1 orelse Ch =:= 2) andalso
        maps:size(maps:without([rate, channels], F)) =:= 0.
