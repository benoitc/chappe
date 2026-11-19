%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The native stack's TCP/TLS connections that closed lately.
%%
%% chappe_sip_engine records a connection here when the stack reports it
%% closed (flow_closed), and clears the record when a new engine starts.
%% The edge proxy reads it to tell a lost flow from a busy UA (RFC 5626
%% 5.3). The table (chappe_sip_closed_conns) is owned by
%% chappe_sip_registry_keeper; every call is a no-op while it is missing.
-module(chappe_sip_engine_conns).

-export([conn_closed/1, closed/1, clear/0]).

-define(CLOSED_TAB, chappe_sip_closed_conns).
-define(MAX_CLOSED, 10000).

%% True when the native stack's TCP/TLS connection Id closed lately
%% (since this engine started; ids are never reused within the VM). A
%% request sent over a connection as it closes can come back as the
%% stack's own 503 rather than an error: the edge proxy tells a lost flow
%% from a busy UA with this (RFC 5626 5.3).
-spec conn_closed(pos_integer()) -> boolean().
conn_closed(Id) ->
    try
        ets:member(?CLOSED_TAB, Id)
    catch
        error:badarg -> false
    end.

%% Record connection Id as closed. The record is bounded: past
%% ?MAX_CLOSED entries the older half goes.
-spec closed(pos_integer()) -> ok.
closed(Id) ->
    try
        true = ets:insert(
            ?CLOSED_TAB, {Id, erlang:unique_integer([monotonic])}
        ),
        case ets:info(?CLOSED_TAB, size) > ?MAX_CLOSED of
            true ->
                Ts = lists:sort([T || {_, T} <- ets:tab2list(?CLOSED_TAB)]),
                Cut = lists:nth(?MAX_CLOSED div 2, Ts),
                _ = ets:select_delete(
                    ?CLOSED_TAB, [{{'_', '$1'}, [{'<', '$1', Cut}], [true]}]
                ),
                ok;
            false ->
                ok
        end
    catch
        error:badarg -> ok
    end.

%% Forget every closed connection (a new engine started). Connection ids
%% come from one counter for the life of the VM (the NIF's g_next_id), so
%% an id never comes back: the record is cleared only to free it, since
%% the stack already refuses a previous engine's ids as unknown.
-spec clear() -> ok.
clear() ->
    _ =
        ets:info(?CLOSED_TAB) =/= undefined andalso
            ets:delete_all_objects(?CLOSED_TAB),
    ok.
