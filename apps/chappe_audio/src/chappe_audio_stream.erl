%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% One audio stream: the process a fork's WebSocket connection feeds.
%%
%% It starts waiting, registered under its id on this node for the
%% handshake to find (chappe_audio_registry), and in the pg group
%% {chappe_audio, Ref} of the `chappe' scope when it has a ref. A
%% handshake that passes the path and token checks claims it (one
%% connection per stream), then hands it the socket; the stream starts
%% the ws_session on it and links to it, so either going takes the
%% other. Unclaimed after connect_timeout, it closes.
%%
%% Events go to the owner, which the stream monitors:
%% {chappe_audio, Stream, Event}, or {chappe_audio, Stream, Event, Ref}
%% with a ref. Event is {connected, Info}, {text, Bin} (the metadata a
%% fork sends first, and any text after it), {frame, Pcm} (one binary
%% message of L16 audio, interleaved when stereo), and closed, last.
%%
%% The bound: a frame or a text is dropped, and counted in info/1, when
%% the owner already has max_queue messages waiting (read directly for a
%% local owner; for a remote one, when the distribution buffer is full)
%% or when the stream itself is max_queue messages behind. Memory stays
%% flat whatever the fork sends and however slow the owner reads.
%%
%% When the owner dies the stream closes the connection (1001) and
%% stops. When the stream crashes the link takes the session down and
%% the fork sees the connection close; the call goes on.
-module(chappe_audio_stream).
-behaviour(gen_server).

-export([start/2, claim/1, attach/2, attach_failed/1]).
-export([close/1, info/1, set_owner/2, send_text/2]).
-export([start_link/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% a claimed stream gets its socket within this, or gives up
-define(ATTACH_TIMEOUT, 5000).
%% how long a closing connection may take before the stream stops anyway
-define(CLOSE_TIMEOUT, 5000).

-record(state, {
    id :: binary(),
    owner :: pid(),
    owner_mon :: reference(),
    ref :: binary() | undefined,
    rate :: pos_integer(),
    channels :: 1 | 2,
    max_queue :: pos_integer(),
    cfg :: chappe_audio_listener:cfg(),
    phase = waiting :: waiting | claimed | connected | closing,
    timer :: reference() | undefined,
    session :: pid() | undefined,
    conn = #{} :: map(),
    frames = 0 :: non_neg_integer(),
    bytes = 0 :: non_neg_integer(),
    texts = 0 :: non_neg_integer(),
    dropped = 0 :: non_neg_integer(),
    bad = 0 :: non_neg_integer()
}).

-type state() :: #state{}.

%% Start a stream under chappe_audio_stream_sup (called on the
%% listener's node); returns it and the URL the fork connects to.
-spec start(map(), chappe_audio_listener:cfg()) ->
    {ok, pid(), binary()} | {error, term()}.
start(Opts, #{url := Base, prefix := Prefix} = Cfg) ->
    Id = chappe_audio_lib:id(),
    Token = chappe_audio_lib:token(),
    Url =
        <<Base/binary, Prefix/binary, "/", Id/binary, "?token=", Token/binary>>,
    case
        supervisor:start_child(chappe_audio_stream_sup, [
            Opts#{id => Id, token_hash => chappe_audio_lib:token_hash(Token)},
            Cfg,
            Url
        ])
    of
        {ok, Pid} -> {ok, Pid, Url};
        {error, _} = Err -> Err
    end.

-spec start_link(map(), chappe_audio_listener:cfg(), binary()) ->
    {ok, pid()}.
start_link(Opts, Cfg, _Url) ->
    gen_server:start_link(?MODULE, {Opts, Cfg}, []).

%% A handshake takes the stream: ok once, {error, taken} after.
-spec claim(pid()) -> ok | {error, taken}.
claim(Stream) ->
    try
        gen_server:call(Stream, claim, 2000)
    catch
        exit:_ -> {error, taken}
    end.

-spec attach(pid(), map()) -> ok.
attach(Stream, Conn) ->
    gen_server:cast(Stream, {attach, Conn}).

-spec attach_failed(pid()) -> ok.
attach_failed(Stream) ->
    gen_server:cast(Stream, attach_failed).

-spec close(pid()) -> ok.
close(Stream) ->
    gen_server:call(Stream, close).

-spec info(pid()) -> map().
info(Stream) ->
    gen_server:call(Stream, info).

-spec set_owner(pid(), pid()) -> ok.
set_owner(Stream, Pid) ->
    gen_server:call(Stream, {set_owner, Pid}).

-spec send_text(pid(), binary()) -> ok | {error, not_connected}.
send_text(Stream, Text) ->
    gen_server:call(Stream, {send_text, Text}).

%% ---- gen_server ----

-spec init({map(), chappe_audio_listener:cfg()}) -> {ok, state()}.
init({#{id := Id, token_hash := Hash, owner := Owner} = Opts, Cfg}) ->
    process_flag(trap_exit, true),
    ok = chappe_audio_registry:register(Id, Hash),
    Ref = maps:get(ref, Opts, undefined),
    _ =
        Ref =/= undefined andalso
            pg:join(chappe_audio_lib:scope(), {chappe_audio, Ref}, self()),
    Format = maps:get(format, Opts, #{}),
    Timer = erlang:start_timer(
        maps:get(connect_timeout, Opts, 30000), self(), connect
    ),
    {ok, #state{
        id = Id,
        owner = Owner,
        owner_mon = monitor(process, Owner),
        ref = Ref,
        rate = maps:get(rate, Format, 8000),
        channels = maps:get(channels, Format, 1),
        max_queue = maps:get(max_queue, Opts, 500),
        cfg = Cfg,
        timer = Timer
    }}.

handle_call(claim, _From, #state{phase = waiting} = S) ->
    cancel(S#state.timer),
    Timer = erlang:start_timer(?ATTACH_TIMEOUT, self(), attach),
    {reply, ok, S#state{phase = claimed, timer = Timer}};
handle_call(claim, _From, S) ->
    {reply, {error, taken}, S};
handle_call(close, _From, #state{session = undefined} = S) ->
    {stop, normal, ok, finish(S)};
handle_call(close, _From, #state{phase = connected, session = Session} = S) ->
    ok = ws:close(Session, 1000, <<>>),
    Timer = erlang:start_timer(?CLOSE_TIMEOUT, self(), close),
    {reply, ok, S#state{phase = closing, timer = Timer}};
handle_call(close, _From, S) ->
    {reply, ok, S};
handle_call(info, _From, S) ->
    {reply, info_map(S), S};
handle_call({set_owner, Pid}, _From, #state{owner_mon = Mon} = S) ->
    demonitor(Mon, [flush]),
    {reply, ok, S#state{owner = Pid, owner_mon = monitor(process, Pid)}};
handle_call({send_text, Text}, _From, #state{phase = connected} = S) ->
    {reply, ws:send(S#state.session, {text, Text}), S};
handle_call({send_text, _}, _From, S) ->
    {reply, {error, not_connected}, S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({attach, Conn}, #state{phase = claimed} = S) ->
    cancel(S#state.timer),
    connect(Conn, S#state{timer = undefined});
handle_cast(attach_failed, S) ->
    {stop, normal, finish(S)};
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(
    {chappe_audio_ws, Session, {binary, Pcm}}, #state{session = Session} = S
) ->
    {noreply, frame(Pcm, S)};
handle_info(
    {chappe_audio_ws, Session, {text, Text}}, #state{session = Session} = S
) ->
    {noreply, text(Text, S)};
handle_info({'EXIT', Session, _Reason}, #state{session = Session} = S) ->
    {stop, normal, finish(S#state{session = undefined})};
handle_info({timeout, Timer, _}, #state{timer = Timer} = S) ->
    %% unclaimed, unattached, or a close the peer never completed
    _ = S#state.session =/= undefined andalso exit(S#state.session, kill),
    {stop, normal, finish(S)};
handle_info({'DOWN', Mon, process, _, _}, #state{owner_mon = Mon} = S) ->
    %% nobody to tell: close the connection and go
    _ =
        S#state.session =/= undefined andalso
            ws:close(S#state.session, 1001, <<>>),
    {stop, normal, S};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    ok.

%% ---- internal ----

%% Start the WebSocket session on the socket the handshake answered 101
%% on, and feed it the bytes that came after the request.
connect(#{transport := T, handle := H, rest := Rest} = Conn, S) ->
    #{max_frame := Max, idle_timeout := Idle} = S#state.cfg,
    Req = maps:with([path, headers, peer], Conn),
    Accept = #{
        parser_opts => #{max_frame => Max, max_message => Max},
        idle_timeout => Idle
    },
    case ws:accept(T, H, Req, chappe_audio_ws, #{stream => self()}, Accept) of
        {ok, Session} ->
            link(Session),
            _ = Rest =/= <<>> andalso (Session ! raw(T, H, Rest)),
            Info = maps:with([path, peer, subprotocol], Conn),
            S1 = S#state{phase = connected, session = Session, conn = Info},
            event(S1, {connected, Info}),
            {noreply, S1};
        {error, _} ->
            _ = T:close(H),
            {stop, normal, finish(S)}
    end.

raw(ws_transport_gen_tcp, H, Bin) -> {tcp, H, Bin};
raw(ws_transport_ssl, H, Bin) -> {ssl, H, Bin}.

%% One binary message: L16 samples, so a whole number of sample frames.
frame(Pcm, #state{channels = Ch} = S) when byte_size(Pcm) rem (2 * Ch) =/= 0 ->
    S#state{bad = S#state.bad + 1};
frame(Pcm, S) ->
    S1 = S#state{
        frames = S#state.frames + 1, bytes = S#state.bytes + byte_size(Pcm)
    },
    deliver({frame, Pcm}, S1).

text(Text, S) ->
    deliver({text, Text}, S#state{texts = S#state.texts + 1}).

deliver(Event, #state{max_queue = Max} = S) ->
    case behind(Max) of
        true ->
            S#state{dropped = S#state.dropped + 1};
        false ->
            case chappe_audio_lib:send(S#state.owner, msg(S, Event), Max) of
                ok -> S;
                dropped -> S#state{dropped = S#state.dropped + 1}
            end
    end.

behind(Max) ->
    {message_queue_len, N} = process_info(self(), message_queue_len),
    N >= Max.

%% The last event; never dropped.
finish(S) ->
    event(S, closed),
    S.

event(#state{owner = Owner} = S, Event) ->
    Owner ! msg(S, Event),
    ok.

msg(#state{ref = undefined}, Event) -> {chappe_audio, self(), Event};
msg(#state{ref = Ref}, Event) -> {chappe_audio, self(), Event, Ref}.

info_map(S) ->
    maps:merge(S#state.conn, #{
        id => S#state.id,
        ref => S#state.ref,
        owner => S#state.owner,
        phase => S#state.phase,
        format => #{rate => S#state.rate, channels => S#state.channels},
        frames => S#state.frames,
        bytes => S#state.bytes,
        texts => S#state.texts,
        dropped => S#state.dropped,
        bad_frames => S#state.bad
    }).

cancel(undefined) ->
    ok;
cancel(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.
