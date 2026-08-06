%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% One gen_statem per connection, owning the TCP socket.
%%
%% Inbound: init connects to mod_event_socket, then the `authenticating' state
%% answers the auth/request with the password and waits for +OK before telling
%% the owner it is ready. Outbound: the listener hands over an accepted socket,
%% the `accepting' state sends "connect", reads the initial channel data, and
%% starts the user handler. Both converge on `ready'.
%%
%% In `ready', bytes are fed to chappe_esl_parser and each frame is classified:
%% command/reply and api/response are answers to the oldest still-unanswered
%% command (FreeSWITCH replies in order, so a FIFO queue correlates them);
%% every text/event-* frame is an event delivered to the owner process as
%% {chappe_esl_event, Conn, Event}. Disconnect notices and logs are delivered as
%% {chappe_esl_disconnect, Conn} and {chappe_esl_log, Conn, Headers, Body}. Bad input from
%% the socket is logged, never thrown.
-module(chappe_esl_conn).
-behaviour(gen_statem).

-export([start_link/1]).
-export([activate/2, request/3, request/4, set_owner/2, channel/1]).
-export([stats/1, close/1]).
-export([callback_mode/0, init/1, terminate/3]).
-export([authenticating/3, accepting/3, ready/3]).

-include_lib("kernel/include/logger.hrl").

-define(CALL_TIMEOUT, 10000).

-type kind() :: api | bgapi | command.

-record(data, {
    mode :: inbound | outbound,
    socket :: gen_tcp:socket() | undefined,
    parser :: chappe_esl_parser:parser(),
    owner :: pid() | undefined,
    owner_mon :: reference() | undefined,
    password :: binary() | undefined,
    handler :: module() | undefined,
    handler_args :: term(),
    handler_pid :: pid() | undefined,
    channel :: chappe_esl_event:event() | undefined,
    pending = queue:new() :: queue:queue({gen_statem:from(), kind()}),
    stats = #{commands => 0, replies => 0, events => 0, unsolicited => 0} ::
        #{atom() => non_neg_integer()}
}).

-spec start_link(map()) -> gen_statem:start_ret().
start_link(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

%% Hand an accepted socket to an outbound connection (called by the listener
%% after transferring socket ownership to this process).
-spec activate(pid(), gen_tcp:socket()) -> ok.
activate(Conn, Socket) ->
    gen_statem:cast(Conn, {activate, Socket}).

%% Send a command and wait for its reply. Kind selects how the reply is read.
-spec request(pid(), iodata(), kind()) -> term().
request(Conn, Bytes, Kind) ->
    request(Conn, Bytes, Kind, ?CALL_TIMEOUT).

-spec request(pid(), iodata(), kind(), timeout()) -> term().
request(Conn, Bytes, Kind, Timeout) ->
    gen_statem:call(Conn, {request, iolist_to_binary(Bytes), Kind}, Timeout).

%% Change the process that receives event messages.
-spec set_owner(pid(), pid()) -> ok.
set_owner(Conn, Pid) ->
    gen_statem:call(Conn, {set_owner, Pid}, ?CALL_TIMEOUT).

%% The initial channel-data event (outbound connections only).
-spec channel(pid()) -> chappe_esl_event:event() | undefined.
channel(Conn) ->
    gen_statem:call(Conn, channel, ?CALL_TIMEOUT).

%% Per-connection counters (commands sent, replies matched, events delivered,
%% unsolicited replies).
-spec stats(pid()) -> #{atom() => non_neg_integer()}.
stats(Conn) ->
    gen_statem:call(Conn, stats, ?CALL_TIMEOUT).

-spec close(pid()) -> ok.
close(Conn) ->
    gen_statem:stop(Conn, normal, ?CALL_TIMEOUT).

callback_mode() ->
    state_functions.

init(#{mode := inbound} = Opts) ->
    Owner = maps:get(owner, Opts),
    Host = maps:get(host, Opts),
    Port = maps:get(port, Opts),
    Timeout = maps:get(connect_timeout, Opts, 5000),
    case gen_tcp:connect(Host, Port, sockopts(), Timeout) of
        {ok, Socket} ->
            Data = #data{
                mode = inbound,
                socket = Socket,
                parser = chappe_esl_parser:new(),
                owner = Owner,
                owner_mon = monitor(process, Owner),
                password = maps:get(password, Opts, <<"ClueCon">>)
            },
            {ok, authenticating, Data};
        {error, Reason} ->
            {stop, {connect_failed, Reason}}
    end;
init(#{mode := outbound} = Opts) ->
    process_flag(trap_exit, true),
    Data = #data{
        mode = outbound,
        parser = chappe_esl_parser:new(),
        handler = maps:get(handler, Opts),
        handler_args = maps:get(handler_args, Opts, undefined)
    },
    {ok, accepting, Data}.

%% inbound: authenticate

authenticating(info, {tcp, S, Bytes}, #data{socket = S} = Data) ->
    feed(Bytes, Data);
authenticating(info, {tcp_closed, S}, #data{socket = S} = Data) ->
    notify(Data, {chappe_esl_auth_error, self(), closed}),
    {stop, normal, Data};
authenticating(info, {tcp_error, S, Reason}, #data{socket = S} = Data) ->
    notify(Data, {chappe_esl_auth_error, self(), Reason}),
    {stop, normal, Data};
authenticating(internal, {frame, Frame}, Data) ->
    handle_auth_frame(chappe_esl_event:decode(Frame), Data);
authenticating({call, _From}, _Msg, Data) ->
    {keep_state, Data, [postpone]};
authenticating(_Type, _Msg, Data) ->
    {keep_state, Data}.

handle_auth_frame({auth_request, _}, #data{socket = S, password = Pw} = Data) ->
    ok = gen_tcp:send(S, <<"auth ", Pw/binary, "\n\n">>),
    {keep_state, Data};
handle_auth_frame({reply, Text, _}, Data) ->
    case is_ok(Text) of
        true ->
            notify(Data, {chappe_esl_ready, self()}),
            {next_state, ready, Data};
        false ->
            notify(Data, {chappe_esl_auth_error, self(), {auth_failed, Text}}),
            {stop, normal, Data}
    end;
handle_auth_frame(_Other, Data) ->
    {keep_state, Data}.

%% outbound: accept

accepting(cast, {activate, Socket}, Data) ->
    ok = inet:setopts(Socket, [{active, once}]),
    ok = gen_tcp:send(Socket, <<"connect\n\n">>),
    {keep_state, Data#data{socket = Socket}};
accepting(info, {tcp, S, Bytes}, #data{socket = S} = Data) ->
    feed(Bytes, Data);
accepting(info, {tcp_closed, S}, #data{socket = S} = Data) ->
    {stop, normal, Data};
accepting(info, {tcp_error, S, _Reason}, #data{socket = S} = Data) ->
    {stop, normal, Data};
accepting(internal, {frame, Frame}, Data) ->
    Channel = chappe_esl_event:channel(Frame),
    start_handler(Channel, Data);
accepting({call, _From}, _Msg, Data) ->
    {keep_state, Data, [postpone]};
accepting(_Type, _Msg, Data) ->
    {keep_state, Data}.

start_handler(Channel, #data{handler = Mod, handler_args = Args} = Data) ->
    Conn = self(),
    Pid = spawn_link(fun() -> Mod:handle_channel(Conn, Channel, Args) end),
    Data1 = Data#data{
        channel = Channel,
        owner = Pid,
        handler_pid = Pid,
        owner_mon = monitor(process, Pid)
    },
    {next_state, ready, Data1}.

%% ready (both modes)

ready({call, From}, {request, Bytes, Kind}, Data) ->
    ready_request(From, Bytes, Kind, Data);
ready({call, From}, {set_owner, Pid}, Data) ->
    {keep_state, replace_owner(Pid, Data), [{reply, From, ok}]};
ready({call, From}, channel, #data{channel = Ch} = Data) ->
    {keep_state, Data, [{reply, From, Ch}]};
ready({call, From}, stats, #data{stats = Stats} = Data) ->
    {keep_state, Data, [{reply, From, Stats}]};
ready(info, {tcp, S, Bytes}, #data{socket = S} = Data) ->
    feed(Bytes, Data);
ready(info, {tcp_closed, S}, #data{socket = S} = Data) ->
    notify(Data, {chappe_esl_closed, self()}),
    {stop, normal, Data};
ready(info, {tcp_error, S, _Reason}, #data{socket = S} = Data) ->
    notify(Data, {chappe_esl_closed, self()}),
    {stop, normal, Data};
ready(info, {'DOWN', Mon, process, _Pid, _R}, #data{owner_mon = Mon} = Data) ->
    {stop, normal, Data};
ready(info, {'EXIT', Pid, _R}, #data{handler_pid = Pid} = Data) ->
    {stop, normal, Data};
ready(internal, {frame, Frame}, Data) ->
    {keep_state, handle_ready_frame(chappe_esl_event:decode(Frame), Data)};
ready(_Type, _Msg, Data) ->
    {keep_state, Data}.

ready_request(From, Bytes, Kind, #data{socket = S, pending = Q} = Data) ->
    case gen_tcp:send(S, Bytes) of
        ok ->
            Data1 = bump(commands, Data),
            {keep_state, Data1#data{pending = queue:in({From, Kind}, Q)}};
        {error, Reason} ->
            {keep_state, Data, [{reply, From, {error, Reason}}]}
    end.

handle_ready_frame({api, _} = Dec, Data) ->
    reply_head(Dec, Data);
handle_ready_frame({reply, _, _} = Dec, Data) ->
    reply_head(Dec, Data);
handle_ready_frame({event, Event}, Data) ->
    notify(Data, {chappe_esl_event, self(), Event}),
    bump(events, Data);
handle_ready_frame({disconnect, _, _}, Data) ->
    notify(Data, {chappe_esl_disconnect, self()}),
    Data;
handle_ready_frame({log, H, B}, Data) ->
    notify(Data, {chappe_esl_log, self(), H, B}),
    Data;
handle_ready_frame(_Other, Data) ->
    Data.

reply_head(Decoded, #data{pending = Q} = Data) ->
    case queue:out(Q) of
        {{value, {From, Kind}}, Q1} ->
            gen_statem:reply(From, translate(Kind, Decoded)),
            bump(replies, Data#data{pending = Q1});
        {empty, _} ->
            ?LOG_WARNING("chappe_esl_conn: unsolicited reply ~p", [Decoded]),
            bump(unsolicited, Data)
    end.

bump(Key, #data{stats = Stats} = Data) ->
    Data#data{stats = maps:update_with(Key, fun(N) -> N + 1 end, Stats)}.

terminate(_Reason, _State, #data{socket = Socket, pending = Q}) ->
    fail_pending(Q),
    close_socket(Socket),
    ok.

%% internal

sockopts() ->
    [binary, {packet, raw}, {active, once}, {nodelay, true}].

feed(Bytes, #data{parser = P0} = Data) ->
    {Frames, P1} = chappe_esl_parser:feed(Bytes, P0),
    case chappe_esl_parser:overflowed(P1) of
        true ->
            ?LOG_WARNING(
                "chappe_esl_conn: frame exceeds max_frame_bytes; closing"
            ),
            {stop, {shutdown, frame_too_large}, Data#data{parser = P1}};
        false ->
            arm(Data),
            Events = [{next_event, internal, {frame, F}} || F <- Frames],
            {keep_state, Data#data{parser = P1}, Events}
    end.

arm(#data{socket = undefined}) ->
    ok;
arm(#data{socket = S}) ->
    _ = inet:setopts(S, [{active, once}]),
    ok.

replace_owner(Pid, #data{owner_mon = Old} = Data) ->
    _ = demonitor_if(Old),
    Data#data{owner = Pid, owner_mon = monitor(process, Pid)}.

demonitor_if(undefined) -> ok;
demonitor_if(Ref) -> demonitor(Ref, [flush]).

notify(#data{owner = undefined}, _Msg) ->
    ok;
notify(#data{owner = Pid}, Msg) ->
    Pid ! Msg,
    ok.

fail_pending(Q) ->
    lists:foreach(
        fun({From, _Kind}) -> gen_statem:reply(From, {error, closed}) end,
        queue:to_list(Q)
    ).

close_socket(undefined) -> ok;
close_socket(Socket) -> gen_tcp:close(Socket).

translate(api, {api, Body}) ->
    {ok, Body};
translate(api, {reply, Text, _}) ->
    {ok, Text};
translate(bgapi, {reply, Text, H}) ->
    case job_uuid(Text, H) of
        undefined -> {error, Text};
        Uuid -> {ok, Uuid}
    end;
translate(command, {reply, Text, _}) ->
    ok_or_error(Text);
translate(command, {api, Body}) ->
    {ok, Body};
translate(_Kind, Other) ->
    {error, {unexpected_reply, Other}}.

is_ok(<<"+OK", _/binary>>) -> true;
is_ok(_) -> false.

ok_or_error(Text) ->
    case is_ok(Text) of
        true -> ok;
        false -> {error, Text}
    end.

job_uuid(Text, Headers) ->
    case maps:get(<<"Job-UUID">>, Headers, undefined) of
        undefined -> job_uuid_from_text(Text);
        Uuid -> Uuid
    end.

job_uuid_from_text(Text) ->
    case binary:split(Text, <<"Job-UUID: ">>) of
        [_, Rest] ->
            string:trim(Rest);
        [_] ->
            case is_ok(Text) of
                true -> undefined;
                false -> undefined
            end
    end.
