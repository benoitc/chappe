%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Application configuration access with defaults.
%%
%% All tunables live here so limits are discoverable in one place.
-module(chappe_sip_config).

-export([get/1]).

-spec get(atom()) -> term().
get(Key) ->
    application:get_env(chappe_sip, Key, default(Key)).

%% Engine backend: chappe_sip_nif in production, chappe_sip_engine_fake in tests.
default(engine_mod) -> chappe_sip_nif;
%% Health checking of the engine stack thread.
default(health_interval_ms) -> 5000;
default(health_miss_limit) -> 3;
%% What to do when the engine is declared hung or cannot be restarted:
%% halt (default: heart/systemd restarts the node) | degrade (SIP dead, node up).
default(engine_failure_action) -> halt;
%% Engine start retry backoff while a previous instance tears down.
default(engine_start_retries) -> 10;
%% Limits (enforced from M2 on).
default(max_message_size) -> 262144;
default(max_request_workers) -> 10000;
default(max_dialogs) -> 100000;
default(max_uac_transactions) -> 100000;
default(handler_deadline_ms) -> 30000;
%% SIP-over-WebSocket. Idle connections are closed after this (clients
%% keepalive per RFC 7118); WS transactions have no sofia timers, so cap them
%% here to bound leaked client/server transaction state.
default(ws_idle_timeout_ms) -> 600000;
default(ws_client_txn_timeout_ms) -> 64000;
default(ws_server_txn_timeout_ms) -> 180000;
%% Max concurrent WS connections; a further connect is refused and closed.
default(max_ws_connections) -> 10000;
%% Allowed browser Origins for the WS upgrade (CSRF protection). Empty allows
%% any origin (and native clients that send none); a non-empty list of binary
%% origins rejects everything else with 403.
default(ws_allowed_origins) -> [];
%% Backpressure: drop inbound WS frames while the transport mailbox is this
%% deep (a slow/flooded transport sheds load instead of growing unbounded).
default(ws_transport_max_mailbox) -> 10000;
%% Registrar location store.
default(registrar_default_expires) -> 3600;
default(registrar_max_expires) -> 86400;
%% Lower bound on a REGISTER expiry (RFC 3261 10.3 step 7). A shorter non-zero
%% expiry is refused with 423 Interval Too Brief + Min-Expires. 0 disables it.
default(registrar_min_expires) -> 0;
%% Bounds on the location store (a flood of REGISTERs is otherwise unbounded
%% memory): distinct AORs, and contacts bound to one AOR.
default(registrar_max_aors) -> 100000;
default(registrar_max_bindings_per_aor) -> 10;
%% Record-Route / flow-token authentication secret. When unset a per-node
%% random secret is generated at boot; set a stable shared value only if
%% record-routed dialogs must survive a restart or span a cluster.
default(flow_token_secret) -> undefined;
%% Media control-plane backends (chappe_sip_media). Empty disables media entirely;
%% nothing in chappe_rtpengine/chappe_esl is started. Shape:
%%   #{rtpengine => #{nodes => [#{name := atom(), host := _, port := _}]},
%%     freeswitch => #{nodes => [#{name := atom(), host := _, port := _,
%%                                 password => binary()}]}}
default(media) -> #{};
default(_) -> undefined.
