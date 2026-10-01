%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Application configuration access with defaults.
%%
%% All tunables live here so limits are discoverable in one place.
-module(chappe_sip_config).

-include("chappe_sip.hrl").

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
%% The same for a non-INVITE request, never more than handler_deadline_ms:
%% its client times out at 64*T1 (32 s).
default(non_invite_deadline_ms) -> 30000;
%% SIP-over-WebSocket. A connection with no inbound traffic for this long is
%% closed (a half-open one left by a crashed browser). WS transactions have no
%% sofia timers, so their RFC 3261 timeouts are here.
default(ws_idle_timeout_ms) -> 600000;
%% The server pings every WS connection this often (infinity: never), well
%% below ws_idle_timeout_ms: a live client answers with a pong, which counts
%% as traffic, so a quiet but active flow is never reaped as idle.
default(ws_ping_interval_ms) -> 30000;
%% Timer B/F (64*T1) of a WS client transaction.
default(ws_client_txn_timeout_ms) -> 64000;
%% Timer C (RFC 3261 16.6): how long a WS client INVITE transaction waits
%% for a final after a provisional; each provisional restarts it.
default(ws_timer_c_ms) -> 180000;
%% Timer H (64*T1): how long a WS INVITE server transaction waits for the
%% ACK of its final (a 2xx is then BYEd, RFC 3261 13.3.1.4).
default(ws_ack_timeout_ms) -> 32000;
%% A WS server transaction the app never answers is answered 408 (INVITE)
%% or 500 after this.
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
%% Option tags a request may list in Require without a 420 (RFC 3261
%% 8.2.2.3). A route adds its own with chappe_sip:handle/3 `option_tags'
%% (siprec for a recording server, RFC 7866 6.1.1).
default(supported_option_tags) -> ?SUPPORTED_TAGS;
%% Registrar location store.
default(registrar_default_expires) -> 3600;
default(registrar_max_expires) -> 86400;
%% Lower bound on a REGISTER expiry (RFC 3261 10.3 step 7). A shorter non-zero
%% expiry under an hour is refused with 423 Interval Too Brief + Min-Expires.
%% 0 disables it.
default(registrar_min_expires) -> 60;
%% The domains the registrar keeps bindings for (RFC 3261 10.3 steps 1 and
%% 5): a REGISTER whose Request-URI or To names another gets 404. `any'
%% accepts every domain.
default(registrar_domains) -> any;
%% Flow-Timer (s) in the 2xx to a REGISTER that sets up an RFC 5626 outbound
%% flow over a direct connection: how often the UA sends its keep-alive.
default(registrar_flow_timer) -> 120;
%% Bounds on the location store (a flood of REGISTERs is otherwise unbounded
%% memory): distinct AORs, and contacts bound to one AOR.
default(registrar_max_aors) -> 100000;
default(registrar_max_bindings_per_aor) -> 10;
%% Record-Route / flow-token authentication secret. When unset a per-node
%% random secret is generated at boot; set a stable shared value only if
%% record-routed dialogs must survive a restart or span a cluster.
default(flow_token_secret) -> undefined;
%% How long a Record-Route marker stays valid (seconds). The expiry is
%% signed into the marker, so a dialog record-routed through us must end
%% within it.
default(record_route_ttl_s) -> 86400;
%% Timer C (RFC 3261 16.6 step 11): how long a proxy or b2bua INVITE branch
%% may ring, reset by every provisional. On expiry the branch is cancelled
%% and counts as a 408. The RFC wants more than 3 minutes; 185 s is nta's.
default(timer_c_ms) -> 185000;
%% RFC 6026: after the first 2xx a proxy keeps forwarding new 2xx (other
%% forks) for 64*T1.
default(proxy_accepted_ms) -> 32000;
%% Media control-plane backends (chappe_sip_media), read when
%% chappe_sip:start/1 gets no `media' option. Empty disables media entirely;
%% nothing in chappe_rtpengine/chappe_mix is started. Shape:
%%   #{rtpengine => #{nodes => [#{name := atom(), host := _, port := _}]},
%%     mix => #{ip => inet:ip_address(), advertise => inet:ip_address(),
%%              law => ulaw | alaw, depth => pos_integer()}}
default(media) -> #{};
%% Session timers (RFC 4028). session_expires: the interval (s) a UAC asks
%% for and a UAS asks for when the caller supports timers; undefined never
%% asks (a peer's request is still honored). session_min_se: the smallest
%% interval accepted, below it a request with Supported: timer gets 422
%% (RFC 4028 5 puts the floor at 90). session_refresher: who refreshes when
%% the UAS picks (uac | uas).
default(session_expires) -> undefined;
default(session_min_se) -> 90;
default(session_refresher) -> uac;
default(_) -> undefined.
