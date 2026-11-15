%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Root supervisor.
%%
%% Child order is deliberate:
%% 0. the `chappe_sip' pg scope, owned by this app, and chappe_sip_call,
%%    which owns the table of what serves each call_ref: first, since
%%    every call process may join it.
%% 1.chappe_sip_registry_keeper: owns the location-store ETS, so the bindings
%%    survive a crash of the chappe_sip_registry gen_server (which holds the logic).
%% 2. chappe_sip_registry: the location store. It sits above the stack supervisor
%%    so its ETS survives SIP engine restarts.
%% 3. chappe_sip_dialog_index: sweeps index entries of dialog fsms that die
%%    without cleaning up (the table itself lives in the keeper). Above the
%%    stack so it sees the dialogs of an engine restart go down.
%% 3a. chappe_sip_digest_nc: the nonce counts the digest server accepted,
%%    so a replayed Authorization is refused across engine restarts.
%% 3c. chappe_sip_cdr: the open call records; it monitors their drivers,
%%    so a record outlives a crashed fsm long enough to be stopped.
%% 3b. chappe_sip_refer_sup: REFER subscriptions and their registry; each
%%    subscription watches its dialog, so it too sits above the stack.
%% 3d. chappe_sip_subscriber_sup: the subscriptions we hold and the table
%%    their NOTIFYs are routed by; a subscriber outlives an engine restart.
%% 3e. chappe_sip_events_sup: the ESC, the presence and message-summary
%%    notifiers and the publication agents (event packages we serve).
%% 3f. chappe_sip_peers_sup: the OPTIONS-monitored peers and the
%%    registrar's keepalive; their state outlives an engine restart.
%% 4. chappe_sip_ws_sup / chappe_sip_media_sup: optional subsystems (WS transport, media
%%    control plane). They sit above the stack so their state (and the media
%%    backend connections) survive SIP engine restarts; both are populated
%%    lazily and stay empty unless configured.
%% 4a. chappe_sip_b2b_sup: the transfers B2BUA calls carry out; each one
%%    watches its call's relay, so it needs nothing of the stack's.
%% 5. chappe_sip_stack_sup: the SIP engine and per-call state (rest_for_one);
%%    everything there dies with the engine.
%% 6. chappe_sip_siprec_sup: the SIPREC recordings this node sends; after
%%    the stack, so they stop first and still send their BYE.
%%    chappe_sip_siprec_rtp_sup: the streams this node records as a SIPREC
%%    recording server.
-module(chappe_sip_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    %% the rate buckets of chappe_sip_guard live as long as the application
    ok = chappe_sip_guard:init_table(),
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 10},
    Children = [
        %% this app's pg scope and the call_ref table: calls are found
        %% by call_ref from any node (chappe_sip_call)
        #{
            id => chappe_sip_pg,
            start => {pg, start_link, [chappe_sip_call:scope()]},
            type => worker
        },
        worker(chappe_sip_call),
        worker(chappe_sip_registry_keeper),
        worker(chappe_sip_registry),
        worker(chappe_sip_dialog_index),
        worker(chappe_sip_digest_nc),
        worker(chappe_sip_cdr),
        worker(chappe_sip_hep),
        sup(chappe_sip_refer_sup),
        sup(chappe_sip_subscriber_sup),
        sup(chappe_sip_events_sup),
        sup(chappe_sip_peers_sup),
        %% the optional GET /metrics listener (idle unless configured)
        worker(chappe_sip_metrics_http),
        sup(chappe_sip_ws_sup),
        sup(chappe_sip_media_sup),
        sup(chappe_sip_b2b_sup),
        sup(chappe_sip_stack_sup),
        %% after the stack: a recording stopped at shutdown still sends its
        %% BYE (chappe_sip_siprec)
        sup(chappe_sip_siprec_sup),
        sup(chappe_sip_siprec_rtp_sup),
        %% after the stack: stopped first, while a REGISTER can still go out
        sup(chappe_sip_regc_sup)
    ],
    {ok, {SupFlags, Children}}.

worker(Mod) ->
    #{
        id => Mod,
        start => {Mod, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [Mod]
    }.

sup(Mod) ->
    #{
        id => Mod,
        start => {Mod, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [Mod]
    }.
