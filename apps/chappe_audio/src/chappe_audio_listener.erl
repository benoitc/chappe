%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% One WebSocket listener: the process that owns the listening socket,
%% and the streams opened on it.
%%
%% An acceptor linked to it takes connections one at a time and hands
%% each to a handshake process (chappe_audio_conn) under
%% chappe_audio_conn_sup. It keeps at most max_pending handshakes going:
%% past that, a new connection is closed at once, before a byte is read,
%% so a flood of idle connections costs one socket each for no longer
%% than the accept.
-module(chappe_audio_listener).
-behaviour(gen_server).

-export([start_link/1, info/1, open/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    lsock :: gen_tcp:socket(),
    acceptor :: pid(),
    cfg :: cfg()
}).

-type state() :: #state{}.

%% What a handshake and a stream need from their listener.
-type cfg() :: #{
    port := inet:port_number(),
    ip := inet:ip_address(),
    prefix := binary(),
    url := binary(),
    max_pending := pos_integer(),
    handshake_timeout := pos_integer(),
    max_handshake := pos_integer(),
    max_frame := pos_integer(),
    idle_timeout := timeout(),
    subprotocols := [binary()],
    tls := [ssl:tls_server_option()] | undefined
}.

-export_type([cfg/0]).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(#{register := Name} = Opts) ->
    gen_server:start_link({local, Name}, ?MODULE, Opts, []);
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-spec info(chappe_audio:listener()) -> map().
info(L) ->
    gen_server:call(L, info).

%% Start a stream on the listener's node, waiting for its connection.
-spec open(chappe_audio:listener(), map()) ->
    {ok, pid(), binary()} | {error, term()}.
open(L, Opts) ->
    gen_server:call(L, {open, Opts}).

-spec stop(chappe_audio:listener()) -> ok.
stop(L) ->
    gen_server:stop(L).

%% ---- gen_server ----

-spec init(map()) -> {ok, state()} | {stop, term()}.
init(Opts) ->
    process_flag(trap_exit, true),
    Ip = maps:get(ip, Opts, {127, 0, 0, 1}),
    Listen = [
        binary,
        {active, false},
        {packet, raw},
        {reuseaddr, true},
        {nodelay, true},
        {backlog, 128},
        {ip, Ip}
    ],
    case gen_tcp:listen(maps:get(port, Opts, 0), Listen) of
        {ok, LSock} ->
            {ok, Port} = inet:port(LSock),
            Cfg = cfg(Opts, Ip, Port),
            Self = self(),
            Acceptor = spawn_link(fun() -> accept(Self, LSock, Cfg, #{}) end),
            {ok, #state{lsock = LSock, acceptor = Acceptor, cfg = Cfg}};
        {error, Reason} ->
            {stop, Reason}
    end.

cfg(Opts, Ip, Port) ->
    Tls = maps:get(tls, Opts, undefined),
    Scheme =
        case Tls of
            undefined -> <<"ws">>;
            _ -> <<"wss">>
        end,
    Url = iolist_to_binary([
        Scheme, <<"://">>, host(Ip), <<":">>, integer_to_binary(Port)
    ]),
    #{
        port => Port,
        ip => Ip,
        prefix => maps:get(prefix, Opts, <<"/audio">>),
        url => maps:get(url, Opts, Url),
        max_pending => maps:get(max_pending, Opts, 64),
        handshake_timeout => maps:get(handshake_timeout, Opts, 5000),
        max_handshake => maps:get(max_handshake, Opts, 8192),
        max_frame => maps:get(max_frame, Opts, 262144),
        idle_timeout => maps:get(idle_timeout, Opts, infinity),
        subprotocols => maps:get(subprotocols, Opts, [<<"audio.drachtio.org">>]),
        tls => Tls
    }.

host({0, 0, 0, 0}) -> <<"127.0.0.1">>;
host({_, _, _, _} = Ip) -> list_to_binary(inet:ntoa(Ip));
host(Ip) -> iolist_to_binary([<<"[">>, inet:ntoa(Ip), <<"]">>]).

handle_call(info, _From, #state{cfg = Cfg} = S) ->
    {reply, maps:without([tls], Cfg), S};
handle_call({open, Opts}, _From, #state{cfg = Cfg} = S) ->
    {reply, chappe_audio_stream:start(Opts, Cfg), S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'EXIT', Pid, Reason}, #state{acceptor = Pid} = S) ->
    {stop, {acceptor, Reason}, S};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, #state{lsock = LSock}) ->
    _ = gen_tcp:close(LSock),
    ok.

%% ---- acceptor ----

%% Take a connection, start its handshake, and track the handshakes
%% going so their number stays under max_pending.
accept(Owner, LSock, #{max_pending := Max} = Cfg, Pending0) ->
    Pending = reap(Pending0),
    case gen_tcp:accept(LSock, 1000) of
        {ok, Sock} when map_size(Pending) >= Max ->
            _ = gen_tcp:close(Sock),
            accept(Owner, LSock, Cfg, Pending);
        {ok, Sock} ->
            accept(Owner, LSock, Cfg, handshake(Sock, Cfg, Pending));
        {error, timeout} ->
            accept(Owner, LSock, Cfg, Pending);
        {error, closed} ->
            exit(normal);
        {error, _} ->
            %% emfile and the like: back off a little, then go on
            timer:sleep(100),
            accept(Owner, LSock, Cfg, Pending)
    end.

handshake(Sock, Cfg, Pending) ->
    case supervisor:start_child(chappe_audio_conn_sup, [Cfg]) of
        {ok, Pid} ->
            case gen_tcp:controlling_process(Sock, Pid) of
                ok ->
                    chappe_audio_conn:go(Pid, Sock),
                    Pending#{monitor(process, Pid) => Pid};
                {error, _} ->
                    _ = gen_tcp:close(Sock),
                    exit(Pid, kill),
                    Pending
            end;
        {error, _} ->
            _ = gen_tcp:close(Sock),
            Pending
    end.

reap(Pending) ->
    receive
        {'DOWN', Mon, process, _, _} -> reap(maps:remove(Mon, Pending))
    after 0 -> Pending
    end.
