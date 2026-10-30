%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc SIP metrics in the `instrument' registry, the one livery renders
%% for Prometheus.
%%
%% Counters, updated as traffic flows:
%%   chappe_sip_requests_total{direction, method}   in: received,
%%                                                  out: sent
%%   chappe_sip_responses_total{direction, status}  in: received on our
%%                                                  requests, out: sent
%%   chappe_sip_guard_blocked_total{reason}         user_agent, source, rate
%% Gauges, read when the metrics are scraped (refresh/0):
%%   chappe_sip_dialogs                   dialogs alive
%%   chappe_sip_registrar_bindings        live bindings in the location store
%%   chappe_sip_registrations{status}     outbound registrations by status
%%   chappe_sip_peers{state}              monitored peers by state
%%
%% Serve them on an HTTP route with handler/0, which refreshes the gauges
%% and renders the registry (livery_metrics):
%% ```
%%   R1 = livery_router:add('GET', <<"/metrics">>,
%%                          chappe_sip_metrics:handler(), #{}, R0).
%% '''
%% Set the `metrics' application setting to false to record nothing.
-module(chappe_sip_metrics).

-export([setup/0, enabled/0, refresh/0, handler/0]).
-export([request/2, response/2, guard_blocked/1]).

-define(ON, {?MODULE, on}).

%% Register the metrics (once; again is a no-op). Called at application
%% start.
-spec setup() -> ok.
setup() ->
    case application:get_env(chappe_sip, metrics, true) of
        false ->
            persistent_term:put(?ON, false);
        _ ->
            ok = new(fun() ->
                instrument_metric:new_counter_vec(
                    chappe_sip_requests,
                    <<"SIP requests by direction and method">>,
                    [direction, method]
                )
            end),
            ok = new(fun() ->
                instrument_metric:new_counter_vec(
                    chappe_sip_responses,
                    <<"SIP responses by direction and status">>,
                    [direction, status]
                )
            end),
            ok = new(fun() ->
                instrument_metric:new_counter_vec(
                    chappe_sip_guard_blocked,
                    <<"Requests chappe_sip_guard turned away, by reason">>,
                    [reason]
                )
            end),
            ok = new(fun() ->
                _ = instrument_metric:new_gauge(
                    chappe_sip_dialogs, <<"SIP dialogs alive">>
                ),
                ok
            end),
            ok = new(fun() ->
                _ = instrument_metric:new_gauge(
                    chappe_sip_registrar_bindings,
                    <<"Live bindings in the location store">>
                ),
                ok
            end),
            ok = new(fun() ->
                instrument_metric:new_gauge_vec(
                    chappe_sip_registrations,
                    <<"Outbound registrations by status">>,
                    [status]
                )
            end),
            ok = new(fun() ->
                instrument_metric:new_gauge_vec(
                    chappe_sip_peers,
                    <<"Monitored SIP peers by state">>,
                    [state]
                )
            end),
            persistent_term:put(?ON, true)
    end,
    ok.

%% a metric registered before (the application restarted) is kept
new(Fun) ->
    try
        Fun()
    catch
        error:{badmatch, {error, already_exists}} -> ok
    end.

-spec enabled() -> boolean().
enabled() ->
    persistent_term:get(?ON, false).

%% A request received (in) or sent (out).
-spec request(in | out, binary()) -> ok.
request(Dir, Method) when is_binary(Method) ->
    inc(chappe_sip_requests, [dir(Dir), method(Method)]);
request(_Dir, _Method) ->
    ok.

%% A response received (in) or sent (out).
-spec response(in | out, integer()) -> ok.
response(Dir, Status) when is_integer(Status) ->
    inc(chappe_sip_responses, [dir(Dir), integer_to_binary(Status)]);
response(_Dir, _Status) ->
    ok.

-spec guard_blocked(atom()) -> ok.
guard_blocked(Why) ->
    inc(chappe_sip_guard_blocked, [atom_to_binary(Why)]).

%% the methods we know by name; any other is `other', so a peer cannot
%% grow the label set
method(M) ->
    case
        lists:member(M, [
            <<"INVITE">>,
            <<"ACK">>,
            <<"BYE">>,
            <<"CANCEL">>,
            <<"OPTIONS">>,
            <<"REGISTER">>,
            <<"PRACK">>,
            <<"UPDATE">>,
            <<"INFO">>,
            <<"MESSAGE">>,
            <<"REFER">>,
            <<"SUBSCRIBE">>,
            <<"NOTIFY">>,
            <<"PUBLISH">>
        ])
    of
        true -> M;
        false -> <<"other">>
    end.

dir(in) -> <<"in">>;
dir(out) -> <<"out">>.

inc(Name, Labels) ->
    case enabled() of
        true ->
            %% a metric never takes the SIP path down
            try
                _ = instrument_metric:inc_counter_vec(Name, Labels),
                ok
            catch
                _:_ -> ok
            end;
        false ->
            ok
    end.

%% Read the gauges: dialogs, registrar bindings, registrations and peers.
-spec refresh() -> ok.
refresh() ->
    case enabled() of
        true ->
            try
                set(chappe_sip_dialogs, dialogs()),
                set(chappe_sip_registrar_bindings, bindings()),
                by(
                    chappe_sip_registrations,
                    [registering, registered, failed, expired],
                    [S || {_, S} <- chappe_sip_regc:list()]
                ),
                by(
                    chappe_sip_peers,
                    [unknown, up, down],
                    [maps:get(state, I) || {_, I} <- chappe_sip_peers:peers()]
                )
            catch
                _:_ -> ok
            end;
        false ->
            ok
    end.

set(Name, Value) ->
    case instrument_registry:lookup(Name) of
        undefined -> ok;
        M -> _ = instrument_metric:set_gauge(M, Value)
    end,
    ok.

by(Name, Keys, Values) ->
    lists:foreach(
        fun(K) ->
            N = length([V || V <- Values, V =:= K]),
            _ = instrument_metric:set_gauge_vec(Name, [atom_to_binary(K)], N)
        end,
        Keys
    ).

dialogs() ->
    proplists:get_value(
        active, supervisor:count_children(chappe_sip_dialog_sup), 0
    ).

bindings() ->
    lists:sum([
        length(chappe_sip_registry:bindings(A))
     || A <- chappe_sip_registry:aors()
    ]).

%% A livery handler for GET /metrics: the gauges read, then the registry
%% in the Prometheus text format.
-spec handler() -> livery_middleware:handler().
handler() ->
    Render = livery_metrics:handler(),
    fun(Req) ->
        ok = refresh(),
        Render(Req)
    end.
