%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% One audio stream: the process a fork's WebSocket connection feeds.
%%
%% It starts waiting, registered under its id on this node for the
%% handshake to find (chappe_audio_registry), and in the pg group
%% {chappe_audio, Ref} of the `chappe_audio' scope when it has a ref. A
%% handshake that passes the path and token checks claims it (one
%% connection per stream), then hands it the socket; the stream starts
%% the ws_session on it and links to it, so either going takes the
%% other. Unclaimed after connect_timeout, it closes.
%%
%% Events go to the owner, which the stream monitors:
%% {chappe_audio, Stream, Event}, with or without a ref (ref/1 reads
%% it). Event is {connected, Info}, {text, Bin} (the metadata a fork
%% sends first, and any text after it), {frame, Pcm} (one binary
%% message of L16 audio, interleaved when stereo), and {closed, Why},
%% last. Why is normal (close/1), peer_closed (the fork closed the
%% connection, or it ended for a reason the stream cannot tell), timeout
%% (no fork connected in time), too_large (a message over max_frame,
%% answered with 1009), idle (nothing for idle_timeout, closed with 1001)
%% or {error, Reason} (the session could not start). When the owner dies
%% the stream sends nothing: there is no one to tell.
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
-export([close/1, info/1, ref/1, set_owner/2, send_text/2]).
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
    bad = 0 :: non_neg_integer(),
    %% store => default: the recording the frames are written to
    store = none :: default | none,
    rec :: chappe_audio_store:rec() | undefined,
    rec_dropped = 0 :: non_neg_integer(),
    recording :: binary() | undefined,
    %% why the stream ends, once something decided it
    why :: why() | undefined,
    %% idle_timeout: when the last message came in, and its timer
    last_in = 0 :: integer(),
    idle_timer :: reference() | undefined
}).

-type why() ::
    normal | peer_closed | timeout | too_large | idle | {error, term()}.
-export_type([why/0]).

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

-spec ref(pid()) -> binary() | undefined.
ref(Stream) ->
    gen_server:call(Stream, ref).

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
            chappe_audio_pg:join({chappe_audio, Ref}, self()),
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
        store = maps:get(store, Opts, none),
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
    {stop, normal, ok, finish(S, normal)};
handle_call(close, _From, #state{phase = connected} = S) ->
    {reply, ok, closing(1000, normal, S)};
handle_call(close, _From, S) ->
    {reply, ok, S};
handle_call(info, _From, S) ->
    {reply, info_map(S), S};
handle_call(ref, _From, S) ->
    {reply, S#state.ref, S};
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
    {stop, normal, finish(S, {error, attach_failed})};
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
handle_info(
    {chappe_audio_ws, Session, too_large}, #state{session = Session} = S
) ->
    {noreply, closing(1009, too_large, S)};
handle_info({'EXIT', Session, _Reason}, #state{session = Session} = S) ->
    {stop, normal, finish(S#state{session = undefined}, peer_closed)};
handle_info({timeout, Timer, idle}, #state{idle_timer = Timer} = S) ->
    {noreply, idle(S)};
handle_info({timeout, Timer, _}, #state{timer = Timer} = S) ->
    %% unclaimed, unattached, or a close the peer never completed
    _ = S#state.session =/= undefined andalso exit(S#state.session, kill),
    {stop, normal, finish(S, timeout)};
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
    %% the parser holds up to twice max_frame, so that the handler sees a
    %% message over it and the stream can say why it closes; past that
    %% the parser cuts the connection itself (1009, reported peer_closed)
    Accept = #{
        parser_opts => #{max_frame => 2 * Max, max_message => 2 * Max},
        idle_timeout => infinity
    },
    Handler = #{stream => self(), max => Max},
    case ws:accept(T, H, Req, chappe_audio_ws, Handler, Accept) of
        {ok, Session} ->
            link(Session),
            _ = Rest =/= <<>> andalso (Session ! raw(T, H, Rest)),
            Info = maps:with([path, peer, subprotocol], Conn),
            S1 = record(S#state{
                phase = connected,
                session = Session,
                conn = Info,
                last_in = now_ms(),
                idle_timer = idle_timer(Idle)
            }),
            event(S1, {connected, Info}),
            {noreply, S1};
        {error, Reason} ->
            _ = T:close(H),
            {stop, normal, finish(S, {error, Reason})}
    end.

%% Close the connection with Code, and end with Why once it is closed.
closing(Code, Why, #state{session = Session} = S) ->
    ok = ws:close(Session, Code, <<>>),
    cancel(S#state.timer),
    Timer = erlang:start_timer(?CLOSE_TIMEOUT, self(), close),
    S#state{phase = closing, timer = Timer, why = Why}.

%% idle_timeout: the stream's own clock, since the session's would close
%% without saying why.
idle_timer(infinity) -> undefined;
idle_timer(Ms) -> erlang:start_timer(Ms, self(), idle).

idle(#state{phase = connected, cfg = #{idle_timeout := Ms}} = S) ->
    case now_ms() - S#state.last_in of
        Quiet when Quiet >= Ms ->
            closing(1001, idle, S#state{idle_timer = undefined});
        Quiet ->
            S#state{idle_timer = erlang:start_timer(Ms - Quiet, self(), idle)}
    end;
idle(S) ->
    S#state{idle_timer = undefined}.

now_ms() ->
    erlang:monotonic_time(millisecond).

raw(ws_transport_gen_tcp, H, Bin) -> {tcp, H, Bin};
raw(ws_transport_ssl, H, Bin) -> {ssl, H, Bin}.

%% One binary message: L16 samples, so a whole number of sample frames.
frame(Pcm, #state{channels = Ch} = S) when byte_size(Pcm) rem (2 * Ch) =/= 0 ->
    S#state{bad = S#state.bad + 1};
frame(Pcm, S) ->
    S1 = S#state{
        frames = S#state.frames + 1,
        bytes = S#state.bytes + byte_size(Pcm),
        last_in = now_ms()
    },
    deliver({frame, Pcm}, store(Pcm, S1)).

%% store => default: a recording in the store, owned by the stream, under
%% the stream's ref (its id when it has none). A store that cannot open
%% one leaves the stream going without it.
record(#state{store = default} = S) ->
    Meta = #{
        call_ref => ref_or_id(S),
        source => fork,
        format => #{rate => S#state.rate, channels => S#state.channels}
    },
    Opts = #{owner => self(), max_queue => S#state.max_queue},
    case chappe_audio_store:open(Meta, Opts) of
        {ok, Rec} ->
            S#state{rec = Rec};
        {error, Reason} ->
            logger:warning("chappe_audio stream ~s: no recording: ~p", [
                S#state.id, Reason
            ]),
            S
    end;
record(S) ->
    S.

ref_or_id(#state{ref = undefined, id = Id}) -> Id;
ref_or_id(#state{ref = Ref}) -> Ref.

store(_Pcm, #state{rec = undefined} = S) ->
    S;
store(Pcm, #state{rec = Rec} = S) ->
    case chappe_audio_store:write(Rec, Pcm) of
        ok -> S;
        dropped -> S#state{rec_dropped = S#state.rec_dropped + 1}
    end.

text(Text, S) ->
    deliver({text, Text}, S#state{texts = S#state.texts + 1, last_in = now_ms()}).

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

%% Finish the recording, then the last event, never dropped: why it
%% ends is what decided it first, else Why.
finish(#state{why = undefined} = S, Why) ->
    finish(S#state{why = Why}, Why);
finish(#state{rec = undefined, why = Why} = S, _) ->
    event(S, {closed, Why}),
    S;
finish(#state{rec = Rec} = S, Why) ->
    S1 =
        case chappe_audio_store:close(Rec, #{}) of
            {ok, Id} -> S#state{rec = undefined, recording = Id};
            {error, _} -> S#state{rec = undefined}
        end,
    finish(S1, Why).

event(#state{owner = Owner} = S, Event) ->
    Owner ! msg(S, Event),
    ok.

msg(_S, Event) -> {chappe_audio, self(), Event}.

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
        bad_frames => S#state.bad,
        recording => recording(S),
        recording_dropped => S#state.rec_dropped
    }).

%% the writer while it writes, the id once it is done
recording(#state{rec = undefined, recording = Id}) -> Id;
recording(#state{rec = Rec}) -> chappe_audio_store:writer(Rec).

cancel(undefined) ->
    ok;
cancel(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.
