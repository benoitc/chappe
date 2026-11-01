%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% FreeSWITCH Event Socket client. Public API for both inbound and outbound
%% connections.
%%
%% Inbound: connect/1,2 opens a socket to mod_event_socket, authenticates, and
%% returns a connection you drive with api/2, bgapi/2, execute/4, subscribe/2,
%% and friends. The connecting process is the controlling process and receives
%% {chappe_esl_event, Conn, Event} messages; change it with
%% set_controlling_process/2.
%%
%% Outbound: start_listener/3,4 listens for dialplan socket connections and
%% runs a chappe_esl_handler per accepted channel. Each connection sends
%% `linger' after `connect' unless the listener is started with
%% #{linger => false}.
-module(chappe_esl).

%% Inbound connection.
-export([connect/1, connect/2, close/1]).
%% Commands.
-export([api/2, api/3, bgapi/2, bgapi_await/2, bgapi_await/3]).
-export([execute/3, execute/4, subscribe/2, events/3, filter/2]).
-export([myevents/2, myevents/3, nixevent/2, noevents/1]).
-export([sendevent/3, sendevent/4, sendmsg/3, sendmsg/4]).
%% Events.
-export([set_controlling_process/2]).
%% Introspection.
-export([stats/1]).
%% Outbound listener.
-export([start_listener/3, start_listener/4, stop_listener/1]).
%% Node registry.
-export([node_add/2, node_remove/1, nodes/0, node_status/1]).
-export([node_drain/1, node_resume/1, node_select/1]).
-export([node_api/2, node_bgapi/2]).
-export([node_subscribe/1, node_events/1, node_unsubscribe/1]).

-export_type([conn/0, listener_opts/0, api_error/0]).

-type conn() :: pid().
%% linger: true (default) sends `linger', a positive integer sends
%% `linger <Seconds>', false sends nothing. ip: the address to listen on
%% (every IPv4 interface by default; an IPv6 address listens on IPv6).
%% backlog: the length of the pending connection queue (128).
-type listener_opts() :: #{
    linger => boolean() | pos_integer(),
    ip => inet:ip_address(),
    backlog => pos_integer()
}.
-type api_error() ::
    timeout | closed | binary() | {unexpected_reply, term()} | inet:posix().

%% Inbound connection

%% Connect and authenticate. Opts keys: host, port, password, connect_timeout.
%% Errors: {auth_failed, ReplyText} when the password is refused,
%% {rejected, Text} when FreeSWITCH answers with text/rude-rejection (ACL),
%% {protocol_error, Reason} on a framing error, closed, timeout, or
%% {connect_failed, Reason}.
-spec connect(map()) -> {ok, conn()} | {error, term()}.
connect(Opts) when is_map(Opts) ->
    chappe_esl_inbound:connect(Opts).

-spec connect(inet:socket_address() | inet:hostname(), inet:port_number()) ->
    {ok, conn()} | {error, term()}.
connect(Host, Port) ->
    connect(#{host => Host, port => Port}).

%% Close a connection.
-spec close(conn()) -> ok.
close(Conn) ->
    chappe_esl_conn:close(Conn).

%% Commands

%% Run a blocking api command, returning its response body. A body starting
%% with -ERR returns {error, Text} (trailing newline trimmed). No reply within
%% Timeout (default 10 s) returns {error, timeout}; the caller does not exit.
-spec api(conn(), iodata()) -> {ok, binary()} | {error, api_error()}.
api(Conn, Command) ->
    api(Conn, Command, 10000).

-spec api(conn(), iodata(), timeout()) ->
    {ok, binary()} | {error, api_error()}.
api(Conn, Command, Timeout) ->
    chappe_esl_conn:request(
        Conn, [<<"api ">>, Command, <<"\n\n">>], api, Timeout
    ).

%% Run a background api command, returning its Job-UUID. The result arrives
%% later as a BACKGROUND_JOB event.
-spec bgapi(conn(), iodata()) -> {ok, binary()} | {error, term()}.
bgapi(Conn, Command) ->
    chappe_esl_conn:request(Conn, [<<"bgapi ">>, Command, <<"\n\n">>], bgapi).

%% Run a background api command and wait for the BACKGROUND_JOB result. Call
%% this from the controlling process (it consumes the matching event).
-spec bgapi_await(conn(), iodata()) -> {ok, binary()} | {error, term()}.
bgapi_await(Conn, Command) ->
    bgapi_await(Conn, Command, 30000).

-spec bgapi_await(conn(), iodata(), timeout()) ->
    {ok, binary()} | {error, term()}.
bgapi_await(Conn, Command, Timeout) ->
    case subscribe(Conn, [<<"BACKGROUND_JOB">>]) of
        ok ->
            case bgapi(Conn, Command) of
                {ok, JobId} -> await_job(Conn, JobId, deadline(Timeout), []);
                Error -> Error
            end;
        Error ->
            Error
    end.

%% Execute a dialplan application on a channel (sendmsg with event-lock).
-spec execute(conn(), iodata(), iodata()) -> ok | {error, term()}.
execute(Conn, App, Args) ->
    sendmsg(Conn, undefined, execute_headers(App, Args)).

-spec execute(conn(), iodata(), iodata(), iodata()) -> ok | {error, term()}.
execute(Conn, Uuid, App, Args) ->
    sendmsg(Conn, Uuid, execute_headers(App, Args)).

%% Send a raw sendmsg with the given headers to a channel (or the current
%% outbound channel when Uuid is undefined).
-spec sendmsg(conn(), iodata() | undefined, [{iodata(), iodata()}]) ->
    ok | {error, term()}.
sendmsg(Conn, Uuid, Headers) ->
    sendmsg(Conn, Uuid, Headers, <<>>).

%% sendmsg with a body (for example the text of a `sendmsg' that carries
%% `call-command: execute' and an argument too long for a header). The
%% Content-Length header is added; set Content-Type in Headers.
-spec sendmsg(conn(), iodata() | undefined, [{iodata(), iodata()}], iodata()) ->
    ok | {error, term()}.
sendmsg(Conn, Uuid, Headers, Body) ->
    Head =
        case Uuid of
            undefined -> <<"sendmsg\n">>;
            _ -> [<<"sendmsg ">>, Uuid, <<"\n">>]
        end,
    chappe_esl_conn:request(Conn, [Head, message(Headers, Body)], command).

%% Subscribe to events in the plain format.
-spec subscribe(conn(), [atom() | iodata()]) -> ok | {error, term()}.
subscribe(Conn, Events) ->
    events(Conn, plain, Events).

%% Subscribe to events in a given format (plain | json | xml).
-spec events(conn(), plain | json | xml, [atom() | iodata()]) ->
    ok | {error, term()}.
events(Conn, Format, Events) ->
    chappe_esl_conn:request(
        Conn,
        [<<"event ">>, format(Format), <<" ">>, join(Events), <<"\n\n">>],
        command
    ).

%% Set an event filter.
-spec filter(conn(), iodata()) -> ok | {error, term()}.
filter(Conn, Filter) ->
    chappe_esl_conn:request(Conn, [<<"filter ">>, Filter, <<"\n\n">>], command).

%% Inject an event into FreeSWITCH.
-spec sendevent(conn(), iodata(), [{iodata(), iodata()}]) ->
    ok | {error, term()}.
sendevent(Conn, Name, Headers) ->
    sendevent(Conn, Name, Headers, <<>>).

%% Inject an event with a body. The Content-Length header is added.
-spec sendevent(conn(), iodata(), [{iodata(), iodata()}], iodata()) ->
    ok | {error, term()}.
sendevent(Conn, Name, Headers, Body) ->
    chappe_esl_conn:request(
        Conn,
        [<<"sendevent ">>, Name, <<"\n">>, message(Headers, Body)],
        command
    ).

%% Receive only the events of one channel, in the given format. On an
%% outbound connection use myevents/2: it applies to the connected channel.
-spec myevents(conn(), plain | json | xml) -> ok | {error, term()}.
myevents(Conn, Format) ->
    chappe_esl_conn:request(
        Conn, [<<"myevents ">>, format(Format), <<"\n\n">>], command
    ).

-spec myevents(conn(), plain | json | xml, iodata()) -> ok | {error, term()}.
myevents(Conn, Format, Uuid) ->
    chappe_esl_conn:request(
        Conn,
        [<<"myevents ">>, format(Format), <<" ">>, Uuid, <<"\n\n">>],
        command
    ).

%% Stop receiving the given events (the reverse of events/3).
-spec nixevent(conn(), [atom() | iodata()]) -> ok | {error, term()}.
nixevent(Conn, Events) ->
    chappe_esl_conn:request(
        Conn, [<<"nixevent ">>, join(Events), <<"\n\n">>], command
    ).

%% Stop receiving every event subscribed so far.
-spec noevents(conn()) -> ok | {error, term()}.
noevents(Conn) ->
    chappe_esl_conn:request(Conn, <<"noevents\n\n">>, command).

%% Events

%% Change the process that receives {chappe_esl_event, Conn, Event} messages.
%% On an inbound connection the link moves with it: the old controlling
%% process is unlinked and the new one linked.
-spec set_controlling_process(conn(), pid()) -> ok.
set_controlling_process(Conn, Pid) ->
    chappe_esl_conn:set_owner(Conn, Pid).

%% Per-connection counters: commands sent, replies matched, events delivered,
%% and unsolicited replies.
-spec stats(conn()) -> #{atom() => non_neg_integer()}.
stats(Conn) ->
    chappe_esl_conn:stats(Conn).

%% Outbound listener

%% Listen for outbound (dialplan socket) connections on Port and run Handler
%% (a chappe_esl_handler module) per accepted channel. Returns a reference for
%% stop_listener/1.
-spec start_listener(inet:port_number(), module(), term()) ->
    {ok, term()} | {error, term()}.
start_listener(Port, Handler, HandlerArgs) ->
    start_listener(Port, Handler, HandlerArgs, #{}).

-spec start_listener(inet:port_number(), module(), term(), listener_opts()) ->
    {ok, term()} | {error, term()}.
start_listener(Port, Handler, HandlerArgs, ListenerOpts) ->
    Keys = [linger, ip, backlog],
    case [K || K <- Keys, not valid_listener_opt(K, ListenerOpts)] of
        [] ->
            Opts = (maps:with(Keys, ListenerOpts))#{
                ref => Port,
                port => Port,
                handler => Handler,
                handler_args => HandlerArgs
            },
            case chappe_esl_sup:start_listener(Opts) of
                {ok, _Pid} -> {ok, Port};
                {error, {already_started, _}} -> {error, already_started};
                {error, Reason} -> {error, Reason}
            end;
        [Bad | _] ->
            {error, {bad_option, Bad}}
    end.

-spec stop_listener(term()) -> ok | {error, term()}.
stop_listener(Ref) ->
    chappe_esl_sup:stop_listener(Ref).

%% Node registry

%% Register a FreeSWITCH node and start monitoring it. Opts: host (required),
%% port (8021), password (<<"ClueCon">>), tags ([]), weight (1),
%% max_sessions (infinity), sip_uri (undefined, kept for the caller),
%% events (extra event names), probes (api commands run as health checks),
%% heartbeat_interval_ms (20000, match the node's event-heartbeat-interval),
%% probe_interval_ms (5000), probe_timeout_ms (2000), connect_timeout_ms
%% (2000), backoff_min_ms (500), backoff_max_ms (30000).
-spec node_add(chappe_esl_nodes:name(), map()) -> ok | {error, term()}.
node_add(Name, Opts) ->
    chappe_esl_nodes:add(Name, Opts).

-spec node_remove(chappe_esl_nodes:name()) -> ok | {error, not_found}.
node_remove(Name) ->
    chappe_esl_nodes:remove(Name).

%% Every registered node and its state: connecting, up, draining or down.
-spec nodes() -> [{chappe_esl_nodes:name(), chappe_esl_node:state()}].
nodes() ->
    chappe_esl_nodes:list().

%% A node's state, settings and load (sessions, max_sessions,
%% sessions_per_sec, idle_cpu, uptime_ms, calls, heartbeat_at, probe_at).
-spec node_status(chappe_esl_nodes:name()) -> {ok, map()} | {error, not_found}.
node_status(Name) ->
    chappe_esl_nodes:status(Name).

%% Keep a node connected and monitored but stop selecting it.
-spec node_drain(chappe_esl_nodes:name()) -> ok | {error, not_found}.
node_drain(Name) ->
    chappe_esl_nodes:drain(Name).

-spec node_resume(chappe_esl_nodes:name()) -> ok | {error, not_found}.
node_resume(Name) ->
    chappe_esl_nodes:resume(Name).

%% Pick an up node: #{policy => least_sessions | idle_cpu | weighted,
%% tags => [Tag]}.
-spec node_select(chappe_esl_nodes:select_opts()) ->
    {ok, chappe_esl_nodes:name()} | {error, none_up}.
node_select(Opts) ->
    chappe_esl_nodes:select(Opts).

%% api and bgapi on a node's connection; {error, down} when it is not up.
-spec node_api(chappe_esl_nodes:name(), iodata()) ->
    {ok, binary()} | {error, term()}.
node_api(Name, Cmd) ->
    chappe_esl_nodes:api(Name, Cmd).

-spec node_bgapi(chappe_esl_nodes:name(), iodata()) ->
    {ok, binary()} | {error, term()}.
node_bgapi(Name, Cmd) ->
    chappe_esl_nodes:bgapi(Name, Cmd).

%% Receive {chappe_esl_node, Name, up | down | draining | {load, Load}} for
%% one node, or every node with `all'.
-spec node_subscribe(chappe_esl_nodes:name() | all) -> ok.
node_subscribe(Name) ->
    chappe_esl_nodes:subscribe(Name).

%% Receive {chappe_esl_node, Name, {event, Event}} for the node's events.
-spec node_events(chappe_esl_nodes:name() | all) -> ok.
node_events(Name) ->
    chappe_esl_nodes:events(Name).

-spec node_unsubscribe(chappe_esl_nodes:name() | all) -> ok.
node_unsubscribe(Name) ->
    chappe_esl_nodes:unsubscribe(Name).

%% internal

%% An option left out takes its default, which is valid.
valid_listener_opt(Key, Opts) ->
    case Opts of
        #{Key := Value} -> valid_listener_value(Key, Value);
        #{} -> true
    end.

valid_listener_value(linger, L) when is_boolean(L) -> true;
valid_listener_value(linger, L) -> is_integer(L) andalso L > 0;
valid_listener_value(ip, Ip) -> inet:is_ip_address(Ip);
valid_listener_value(backlog, N) -> is_integer(N) andalso N > 0.

header_lines(Headers) ->
    [[K, <<": ">>, V, <<"\n">>] || {K, V} <- Headers].

%% Header lines, then the blank line, then the body sized by Content-Length.
message(Headers, Body) ->
    case iolist_size(Body) of
        0 ->
            [header_lines(Headers), <<"\n">>];
        N ->
            Length = {<<"Content-Length">>, integer_to_binary(N)},
            [header_lines(Headers ++ [Length]), <<"\n">>, Body]
    end.

format(Format) when
    Format =:= plain; Format =:= json; Format =:= xml
->
    atom_to_binary(Format, latin1).

execute_headers(App, Args) ->
    [
        {<<"call-command">>, <<"execute">>},
        {<<"execute-app-name">>, App},
        {<<"execute-app-arg">>, Args},
        {<<"event-lock">>, <<"true">>}
    ].

join(Events) ->
    lists:join(<<" ">>, [to_binary(E) || E <- Events]).

to_binary(E) when is_atom(E) -> atom_to_binary(E, latin1);
to_binary(E) -> E.

deadline(infinity) ->
    infinity;
deadline(Timeout) ->
    erlang:monotonic_time(millisecond) + Timeout.

remaining(infinity) ->
    infinity;
remaining(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

await_job(Conn, JobId, Deadline, Stash) ->
    receive
        {chappe_esl_event, Conn, Event} = Msg ->
            case is_job(Event, JobId) of
                true ->
                    requeue(Stash),
                    {ok, chappe_esl_event:body(Event)};
                false ->
                    await_job(Conn, JobId, Deadline, [Msg | Stash])
            end;
        %% The connection died: wake the wait (otherwise a `infinity' deadline
        %% would block forever on a job event that can never arrive). Requeue
        %% the notice so the owner's own loop still sees it.
        {chappe_esl_disconnect, Conn} = Msg ->
            requeue(Stash),
            self() ! Msg,
            {error, disconnected};
        {chappe_esl_closed, Conn} = Msg ->
            requeue(Stash),
            self() ! Msg,
            {error, closed}
    after remaining(Deadline) ->
        requeue(Stash),
        {error, timeout}
    end.

is_job(Event, JobId) ->
    chappe_esl_event:name(Event) =:= <<"BACKGROUND_JOB">> andalso
        chappe_esl_event:header(<<"Job-UUID">>, Event) =:= JobId.

requeue(Stash) ->
    lists:foreach(fun(Msg) -> self() ! Msg end, lists:reverse(Stash)).
