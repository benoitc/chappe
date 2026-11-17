%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Owner of the registrar's ETS table, the engine-config snapshot, and
%% the dialog index (chappe_sip_dialog_index).
%%
%% The tables live in this process, not in chappe_sip_registry or chappe_sip_engine, so a
%% crash of either gen_server does not destroy the location bindings or the
%% engine config a restarted engine needs to re-establish itself. This process
%% holds only the tables and has no logic, so it effectively never crashes. It
%% sits under chappe_sip_sup, above the stack, so it survives an engine restart.
-module(chappe_sip_registry_keeper).
-behaviour(gen_server).

-export([start_link/0, tables/0]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(TAB, chappe_sip_registry).
-define(CFG_TAB, chappe_sip_engine_cfg).
-define(DIALOG_TAB, chappe_sip_dialog_index).
%% on a cluster, the AORs this node took a binding of, {Aor, Made}
%% (chappe_sip_registry)
-define(HELD_TAB, chappe_sip_registry_held).
%% the flows of this node's bindings, both ways: {flow, Flow, Aor} and
%% {aor, Aor, Flow} (chappe_sip_registry)
-define(FLOWS_TAB, chappe_sip_registry_flows).
%% the TCP/TLS connections of the native stack that closed lately
%% (chappe_sip_engine:conn_closed/1)
-define(CLOSED_TAB, chappe_sip_closed_conns).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ok = tables(),
    {ok, #{}}.

%% Create the tables this process owns, those that are missing (the
%% calling process owns them when it is not this one: tests).
-spec tables() -> ok.
tables() ->
    _ = ensure_table(?TAB, [named_table, set, public, {read_concurrency, true}]),
    _ = ensure_table(?CFG_TAB, [named_table, set, public]),
    _ = ensure_table(?HELD_TAB, [named_table, set, public]),
    _ = ensure_table(?FLOWS_TAB, [named_table, ordered_set, public]),
    _ = ensure_table(?CLOSED_TAB, [named_table, set, public]),
    _ = ensure_table(?DIALOG_TAB, [
        named_table,
        set,
        public,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    ok.

ensure_table(Name, Opts) ->
    case ets:info(Name) of
        undefined -> ets:new(Name, Opts);
        _ -> Name
    end.

handle_call(_Req, _From, S) ->
    {reply, ok, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.
