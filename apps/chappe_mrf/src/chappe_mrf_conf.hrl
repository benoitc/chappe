%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The state of a conference process (chappe_mrf_conf), shared with its
%% backends.

-define(MRF_JOIN_TIMEOUT, 15000).

-record(state, {
    name :: binary(),
    backend :: native | fs,
    room :: binary(),
    node :: term(),
    profile = <<"default">> :: binary(),
    owner_mon :: reference() | undefined,
    listeners = #{} :: #{pid() => reference()},
    members = #{} :: #{binary() => map()},
    pending = #{} :: #{term() => map()},
    locked = false :: boolean(),
    anchor_params = #{} :: map(),
    %% rtpengine flags between the mixer and an endpoint's node:
    %% #{offer => map(), answer => map()}
    endpoint_params = #{} :: map(),
    %% how long an fs member may take to show up in the room
    join_timeout = ?MRF_JOIN_TIMEOUT :: pos_integer(),
    bridge = #{} :: map(),
    focus :: chappe_sip_focus:focus() | undefined,
    entity :: binary() | undefined
}).
