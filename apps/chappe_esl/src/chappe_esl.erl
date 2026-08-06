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
%% Outbound: start_listener/3 listens for dialplan socket connections and runs
%% a chappe_esl_handler per accepted channel.
-module(chappe_esl).

%% Inbound connection.
-export([connect/1, connect/2, close/1]).
%% Commands.
-export([api/2, api/3, bgapi/2, bgapi_await/2, bgapi_await/3]).
-export([execute/3, execute/4, subscribe/2, events/3, filter/2, sendevent/3]).
-export([sendmsg/3]).
%% Events.
-export([set_controlling_process/2]).
%% Introspection.
-export([stats/1]).
%% Outbound listener.
-export([start_listener/3, stop_listener/1]).

-export_type([conn/0]).

-type conn() :: pid().

%% Inbound connection

%% Connect and authenticate. Opts keys: host, port, password, connect_timeout.
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

%% Run a blocking api command, returning its response body.
-spec api(conn(), iodata()) -> {ok, binary()} | {error, term()}.
api(Conn, Command) ->
    api(Conn, Command, 10000).

-spec api(conn(), iodata(), timeout()) -> {ok, binary()} | {error, term()}.
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
    Head =
        case Uuid of
            undefined -> <<"sendmsg\n">>;
            _ -> [<<"sendmsg ">>, Uuid, <<"\n">>]
        end,
    chappe_esl_conn:request(
        Conn, [Head, header_lines(Headers), <<"\n">>], command
    ).

%% Subscribe to events in the plain format.
-spec subscribe(conn(), [atom() | iodata()]) -> ok | {error, term()}.
subscribe(Conn, Events) ->
    events(Conn, plain, Events).

%% Subscribe to events in a given format (plain | json | xml).
-spec events(conn(), plain | json | xml, [atom() | iodata()]) ->
    ok | {error, term()}.
events(Conn, Format, Events) ->
    FmtBin = atom_to_binary(Format, latin1),
    List = join(Events),
    chappe_esl_conn:request(
        Conn, [<<"event ">>, FmtBin, <<" ">>, List, <<"\n\n">>], command
    ).

%% Set an event filter.
-spec filter(conn(), iodata()) -> ok | {error, term()}.
filter(Conn, Filter) ->
    chappe_esl_conn:request(Conn, [<<"filter ">>, Filter, <<"\n\n">>], command).

%% Inject an event into FreeSWITCH.
-spec sendevent(conn(), iodata(), [{iodata(), iodata()}]) ->
    ok | {error, term()}.
sendevent(Conn, Name, Headers) ->
    chappe_esl_conn:request(
        Conn,
        [<<"sendevent ">>, Name, <<"\n">>, header_lines(Headers), <<"\n">>],
        command
    ).

%% Events

%% Change the process that receives {chappe_esl_event, Conn, Event} messages.
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
    Opts = #{
        ref => Port,
        port => Port,
        handler => Handler,
        handler_args => HandlerArgs
    },
    case chappe_esl_sup:start_listener(Opts) of
        {ok, _Pid} -> {ok, Port};
        {error, {already_started, _}} -> {error, already_started};
        {error, Reason} -> {error, Reason}
    end.

-spec stop_listener(term()) -> ok | {error, term()}.
stop_listener(Ref) ->
    chappe_esl_sup:stop_listener(Ref).

%% internal

header_lines(Headers) ->
    [[K, <<": ">>, V, <<"\n">>] || {K, V} <- Headers].

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
            end
    after remaining(Deadline) ->
        requeue(Stash),
        {error, timeout}
    end.

is_job(Event, JobId) ->
    chappe_esl_event:name(Event) =:= <<"BACKGROUND_JOB">> andalso
        chappe_esl_event:header(<<"Job-UUID">>, Event) =:= JobId.

requeue(Stash) ->
    lists:foreach(fun(Msg) -> self() ! Msg end, lists:reverse(Stash)).
