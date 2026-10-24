%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% One gen_statem per FreeSWITCH node, under chappe_esl_nodes. It owns the
%% node's inbound connection (a chappe_esl_conn it is the controlling process
%% of) and keeps the node's row in the registry table.
%%
%% States:
%% - `connecting': the first connection attempt;
%% - `up': authenticated, subscribed to `event json HEARTBEAT
%%   BACKGROUND_JOB CHANNEL_CREATE CHANNEL_HANGUP_COMPLETE' (plus the
%%   configured `events'), and the first probes passed. The row shows
%%   `draining' instead while the node is drained: still monitored and
%%   usable for api, skipped by select;
%% - `down': the connection failed or was lost; the next attempt runs after
%%   an exponential backoff with jitter, reset once the node is up again.
%%
%% Load comes from HEARTBEAT (Session-Count, Max-Sessions,
%% Session-Per-Sec-Last, Idle-CPU, Uptime-msec), from CHANNEL_CREATE /
%% CHANNEL_HANGUP_COMPLETE between heartbeats, and from the probes. Every
%% probe_interval_ms a probe process runs the probe commands (`status',
%% `show calls count', `sofia status' by default) on the connection; one
%% failure, or no HEARTBEAT for twice heartbeat_interval_ms, marks the node
%% down, closes the connection and reconnects.
-module(chappe_esl_node).
-behaviour(gen_statem).

-export([start_link/2, validate/1, backoff/3, parse_status/1]).
-export([callback_mode/0, init/1, handle_event/4, terminate/3]).

-export_type([state/0, config/0]).

-include_lib("kernel/include/logger.hrl").

-type state() :: connecting | up | draining | down.
-type config() :: #{
    host := inet:socket_address() | inet:hostname(),
    port := inet:port_number(),
    password := binary(),
    tags := [term()],
    weight := non_neg_integer(),
    max_sessions := pos_integer() | infinity,
    sip_uri := binary() | undefined,
    events := [binary()],
    probes := [binary()],
    heartbeat_interval_ms := pos_integer(),
    probe_interval_ms := pos_integer(),
    probe_timeout_ms := pos_integer(),
    connect_timeout_ms := pos_integer(),
    backoff_min_ms := pos_integer(),
    backoff_max_ms := pos_integer()
}.

-define(EVENTS, [
    <<"HEARTBEAT">>,
    <<"BACKGROUND_JOB">>,
    <<"CHANNEL_CREATE">>,
    <<"CHANNEL_HANGUP_COMPLETE">>
]).

-record(data, {
    name :: term(),
    config :: config(),
    conn :: pid() | undefined,
    attempt = 0 :: non_neg_integer(),
    drain = false :: boolean(),
    load = #{} :: map(),
    probe :: {reference(), reference()} | undefined,
    since :: integer()
}).

-spec start_link(term(), config()) -> gen_statem:start_ret().
start_link(Name, Config) ->
    gen_statem:start_link(?MODULE, {Name, Config}, []).

%% Check node options and fill the defaults.
-spec validate(map()) -> {ok, config()} | {error, term()}.
validate(#{host := Host} = Opts) ->
    Config = strings(maps:merge(defaults(), Opts#{host := host(Host)})),
    case [K || K := V <- Config, not valid(K, V)] of
        [] ->
            Lists = [events, probes],
            {ok,
                maps:merge(
                    Config, #{K => bins(maps:get(K, Config)) || K <- Lists}
                )};
        [Bad | _] ->
            {error, {bad_option, Bad}}
    end;
validate(Opts) when is_map(Opts) ->
    {error, {missing_option, host}};
validate(_) ->
    {error, badarg}.

%% The wait before attempt N + 1 (N >= 1): Min * 2^(N-1) capped at Max,
%% then a random point in its upper half, so nodes that fail together do not
%% reconnect together.
-spec backoff(pos_integer(), pos_integer(), pos_integer()) -> pos_integer().
backoff(N, Min, Max) ->
    Ceil = min(Max, Min bsl min(N - 1, 30)),
    Half = Ceil div 2,
    Half + rand:uniform(max(1, Ceil - Half)).

%% The session counts in an `api status' body.
-spec parse_status(binary()) -> map().
parse_status(Body) ->
    Lines = binary:split(Body, <<"\n">>, [global, trim_all]),
    lists:foldl(fun status_line/2, #{}, Lines).

callback_mode() ->
    handle_event_function.

init({Name, Config}) ->
    process_flag(trap_exit, true),
    Data = #data{name = Name, config = Config, since = now_ms()},
    publish(connecting, Data),
    {ok, connecting, Data, [{next_event, internal, connect}]}.

%% connecting and down: one attempt at a time

handle_event(internal, connect, _State, Data) ->
    connect(Data);
handle_event({timeout, reconnect}, connect, _State, Data) ->
    connect(Data);
handle_event(info, {chappe_esl_ready, Conn}, State, #data{conn = Conn} = Data) ->
    ready(State, Data);
handle_event(
    info,
    {chappe_esl_auth_error, Conn, Reason},
    State,
    #data{conn = Conn} = Data
) ->
    fail(State, {auth, Reason}, Data);
handle_event({timeout, auth}, Conn, State, #data{conn = Conn} = Data) ->
    fail(State, auth_timeout, Data);
%% up
handle_event(
    info, {chappe_esl_event, Conn, Event}, up, #data{conn = Conn} = Data
) ->
    event(chappe_esl_event:name(Event), Event, Data);
handle_event({timeout, heartbeat}, _, up, Data) ->
    fail(up, heartbeat_timeout, Data);
handle_event({timeout, probe}, _, up, #data{probe = undefined} = Data) ->
    {keep_state, start_probe(Data)};
handle_event(info, {Tag, Result}, State, #data{probe = {Tag, Ref}} = Data) ->
    demonitor(Ref, [flush]),
    probed(State, Result, Data#data{probe = undefined});
handle_event(
    info, {'DOWN', Ref, process, _, Why}, State, #data{probe = {_, Ref}} = Data
) ->
    probed(State, {crashed, Why}, Data#data{probe = undefined});
handle_event(info, {Closed, Conn}, State, #data{conn = Conn} = Data) when
    Closed =:= chappe_esl_closed; Closed =:= chappe_esl_disconnect
->
    fail(State, closed, Data);
handle_event(info, {'EXIT', Conn, Reason}, State, #data{conn = Conn} = Data) ->
    fail(State, {exit, Reason}, Data);
%% any state
handle_event({call, From}, {drain, Drain}, State, Data0) ->
    Data = Data0#data{drain = Drain},
    publish(State, Data),
    State =:= up andalso Drain =/= Data0#data.drain andalso announce(up, Data),
    {keep_state, Data, [{reply, From, ok}]};
handle_event({call, From}, _Msg, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, unknown_call}}]};
handle_event(_Type, _Msg, _State, _Data) ->
    keep_state_and_data.

terminate(_Reason, State, #data{name = Name} = Data) ->
    close(Data),
    State =:= up andalso announce(down, Data),
    _ = ets:delete(chappe_esl_nodes, Name),
    ok.

%% connection

connect(#data{config = C} = Data) ->
    Opts = #{
        mode => inbound,
        owner => self(),
        host => maps:get(host, C),
        port => maps:get(port, C),
        password => maps:get(password, C),
        connect_timeout => maps:get(connect_timeout_ms, C)
    },
    case chappe_esl_conn:start_link(Opts) of
        {ok, Conn} ->
            Auth = {{timeout, auth}, maps:get(connect_timeout_ms, C), Conn},
            {keep_state, Data#data{conn = Conn}, [Auth]};
        {error, Reason} ->
            retry(Reason, Data)
    end.

%% Authenticated: subscribe, then run the probes once. The node is up only
%% when they pass, so a FreeSWITCH still loading its modules (the event
%% socket loads before mod_sofia) is not offered for calls.
ready(State, #data{conn = Conn, config = C} = Data) ->
    Events = ?EVENTS ++ (maps:get(events, C) -- ?EVENTS),
    case chappe_esl:events(Conn, json, Events) of
        ok ->
            {keep_state, start_probe(Data), [{{timeout, auth}, cancel}]};
        {error, Reason} ->
            fail(State, {subscribe, Reason}, Data)
    end.

go_up(#data{config = C} = Data0) ->
    Data = Data0#data{attempt = 0, since = now_ms()},
    ?LOG_NOTICE("chappe_esl_node ~p up", [Data#data.name]),
    publish(up, Data),
    announce(up, Data),
    {next_state, up, Data, [
        heartbeat_timer(C),
        {{timeout, probe}, maps:get(probe_interval_ms, C), probe}
    ]}.

%% Close the connection and wait for the next attempt.
fail(State, Reason, Data0) ->
    Data = close(Data0),
    ?LOG_WARNING("chappe_esl_node ~p down: ~p", [Data#data.name, Reason]),
    Result = retry(Reason, Data#data{since = now_ms(), load = #{}}),
    State =:= up andalso announce(down, Data),
    Result.

retry(_Reason, #data{attempt = N0, config = C} = Data0) ->
    N = N0 + 1,
    Data = Data0#data{attempt = N, conn = undefined},
    Wait = backoff(N, maps:get(backoff_min_ms, C), maps:get(backoff_max_ms, C)),
    publish(down, Data),
    {next_state, down, Data, [
        {{timeout, auth}, cancel},
        {{timeout, heartbeat}, cancel},
        {{timeout, probe}, cancel},
        {{timeout, reconnect}, Wait, connect}
    ]}.

close(#data{conn = undefined} = Data) ->
    Data;
close(#data{conn = Conn, probe = Probe} = Data) ->
    unlink(Conn),
    try
        chappe_esl_conn:close(Conn)
    catch
        exit:_ -> ok
    end,
    _ = cancel_probe(Probe),
    Data#data{conn = undefined, probe = undefined}.

cancel_probe(undefined) ->
    ok;
cancel_probe({Tag, Ref}) ->
    demonitor(Ref, [flush]),
    receive
        {Tag, _} -> ok
    after 0 -> ok
    end.

%% events

event(<<"HEARTBEAT">>, Event, #data{config = C} = Data0) ->
    Data = load(heartbeat_load(Event), Data0),
    forward(Event, Data),
    publish(up, Data),
    announce({load, Data#data.load}, Data),
    {keep_state, Data, [heartbeat_timer(C)]};
event(<<"CHANNEL_CREATE">>, Event, Data) ->
    sessions(1, Event, Data);
event(<<"CHANNEL_HANGUP_COMPLETE">>, Event, Data) ->
    sessions(-1, Event, Data);
event(_Name, Event, Data) ->
    forward(Event, Data),
    keep_state_and_data.

sessions(Delta, Event, #data{load = Load} = Data0) ->
    N = max(0, maps:get(sessions, Load, 0) + Delta),
    Data = Data0#data{load = Load#{sessions => N}},
    publish(up, Data),
    forward(Event, Data),
    {keep_state, Data}.

heartbeat_load(Event) ->
    Fields = [
        {sessions, <<"Session-Count">>, int},
        {max_sessions, <<"Max-Sessions">>, int},
        {sessions_per_sec, <<"Session-Per-Sec-Last">>, int},
        {idle_cpu, <<"Idle-CPU">>, float},
        {uptime_ms, <<"Uptime-msec">>, int}
    ],
    Load = maps:from_list([
        {Key, V}
     || {Key, Header, Type} <- Fields,
        V <- [number(Type, chappe_esl_event:header(Header, Event))],
        V =/= undefined
    ]),
    Load#{heartbeat_at => erlang:system_time(millisecond)}.

load(New, #data{load = Load} = Data) ->
    Data#data{load = maps:merge(Load, New)}.

heartbeat_timer(C) ->
    {{timeout, heartbeat}, 2 * maps:get(heartbeat_interval_ms, C), heartbeat}.

%% probes

%% The probe runs in its own process so a slow node does not block this one;
%% it sends its result back tagged with its monitor reference.
start_probe(#data{conn = Conn, config = C} = Data) ->
    Probes = maps:get(probes, C),
    Timeout = maps:get(probe_timeout_ms, C),
    Self = self(),
    Tag = make_ref(),
    {_, Ref} = spawn_monitor(fun() ->
        Self ! {Tag, {probe, run_probes(Conn, Probes, Timeout, #{})}},
        ok
    end),
    Data#data{probe = {Tag, Ref}}.

run_probes(_Conn, [], _Timeout, Acc) ->
    {ok, Acc};
run_probes(Conn, [Cmd | Rest], Timeout, Acc) ->
    case chappe_esl:api(Conn, Cmd, Timeout) of
        {ok, Body} -> run_probes(Conn, Rest, Timeout, Acc#{Cmd => Body});
        {error, Reason} -> {error, Cmd, Reason}
    end.

probed(up, {probe, {ok, Bodies}}, #data{config = C} = Data0) ->
    Data = load(probe_load(Bodies), Data0),
    publish(up, Data),
    announce({load, Data#data.load}, Data),
    {keep_state, Data, [
        {{timeout, probe}, maps:get(probe_interval_ms, C), probe}
    ]};
probed(_State, {probe, {ok, Bodies}}, Data) ->
    go_up(load(probe_load(Bodies), Data));
probed(State, {probe, {error, Cmd, Reason}}, Data) ->
    fail(State, {probe_failed, Cmd, Reason}, Data);
probed(State, Other, Data) ->
    fail(State, {probe_failed, Other}, Data).

probe_load(Bodies) ->
    Status = maps:fold(
        fun
            (<<"status">>, Body, Acc) -> maps:merge(Acc, parse_status(Body));
            (<<"show calls count">>, Body, Acc) -> calls(Body, Acc);
            (_, _, Acc) -> Acc
        end,
        #{},
        Bodies
    ),
    Status#{probe_at => erlang:system_time(millisecond)}.

%% "0 session(s) - peak 2, last 5min 1" and "1000 session(s) max".
status_line(Line, Acc) ->
    case binary:split(Line, <<" session(s) ">>) of
        [N, <<"- ", _/binary>>] -> put_int(sessions, N, Acc);
        [N, <<"max", _/binary>>] -> put_int(max_sessions, N, Acc);
        _ -> Acc
    end.

%% "\n3 total.\n"
calls(Body, Acc) ->
    case binary:split(string:trim(Body), <<" total">>) of
        [N, _] -> put_int(calls, N, Acc);
        _ -> Acc
    end.

put_int(Key, Bin, Acc) ->
    case number(int, Bin) of
        undefined -> Acc;
        N -> Acc#{Key => N}
    end.

number(_Type, undefined) ->
    undefined;
number(Type, Bin) when is_binary(Bin) ->
    Trimmed = string:trim(Bin),
    try
        case Type of
            int -> binary_to_integer(Trimmed);
            float -> to_float(Trimmed)
        end
    catch
        error:badarg -> undefined
    end;
number(_Type, _) ->
    undefined.

%% registry row and notices

publish(State, #data{name = Name, config = C, conn = Conn, load = Load} = Data) ->
    Row = (maps:with([host, port, tags, weight, max_sessions, sip_uri], C))#{
        state => shown(State, Data),
        pid => self(),
        conn => live_conn(State, Conn),
        load => Load,
        since => Data#data.since
    },
    true = ets:insert(chappe_esl_nodes, {Name, Row}),
    ok.

live_conn(up, Conn) -> Conn;
live_conn(_State, _Conn) -> undefined.

shown(up, #data{drain = true}) -> draining;
shown(State, _Data) -> State.

%% up, down and load go to the state subscribers; `up' while drained is
%% shown as `draining'.
announce(up, #data{name = Name} = Data) ->
    chappe_esl_nodes:notify(state, Name, shown(up, Data));
announce(Msg, #data{name = Name}) ->
    chappe_esl_nodes:notify(state, Name, Msg).

forward(Event, #data{name = Name}) ->
    chappe_esl_nodes:notify(events, Name, {event, Event}).

%% options

defaults() ->
    #{
        port => 8021,
        password => <<"ClueCon">>,
        tags => [],
        weight => 1,
        max_sessions => infinity,
        sip_uri => undefined,
        events => [],
        probes => [<<"status">>, <<"show calls count">>, <<"sofia status">>],
        heartbeat_interval_ms => 20000,
        probe_interval_ms => 5000,
        probe_timeout_ms => 2000,
        connect_timeout_ms => 2000,
        backoff_min_ms => 500,
        backoff_max_ms => 30000
    }.

host(Host) when is_binary(Host) -> binary_to_list(Host);
host(Host) -> Host.

%% Strings for the binary options.
strings(Config) ->
    maps:map(
        fun
            (password, V) when is_list(V) -> unicode:characters_to_binary(V);
            (sip_uri, V) when is_list(V) -> unicode:characters_to_binary(V);
            (_K, V) -> V
        end,
        Config
    ).

valid(host, H) ->
    is_list(H) orelse is_tuple(H) orelse is_atom(H);
valid(port, P) ->
    is_integer(P) andalso P > 0 andalso P < 65536;
valid(password, P) ->
    is_binary(P);
valid(tags, T) ->
    is_list(T);
valid(weight, W) ->
    is_integer(W) andalso W >= 0;
valid(max_sessions, infinity) ->
    true;
valid(max_sessions, M) ->
    is_integer(M) andalso M > 0;
valid(sip_uri, U) ->
    U =:= undefined orelse is_binary(U);
valid(events, E) ->
    is_list(E);
valid(probes, P) ->
    is_list(P);
valid(K, V) when
    K =:= heartbeat_interval_ms;
    K =:= probe_interval_ms;
    K =:= probe_timeout_ms;
    K =:= connect_timeout_ms;
    K =:= backoff_min_ms;
    K =:= backoff_max_ms
->
    is_integer(V) andalso V > 0;
valid(_K, _V) ->
    false.

bins(List) ->
    [iolist_to_binary(to_iodata(E)) || E <- List].

to_iodata(A) when is_atom(A) -> atom_to_binary(A);
to_iodata(B) -> B.

to_float(Bin) ->
    try
        binary_to_float(Bin)
    catch
        error:badarg -> float(binary_to_integer(Bin))
    end.

now_ms() ->
    erlang:system_time(millisecond).
