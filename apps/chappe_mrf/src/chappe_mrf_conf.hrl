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
    %% no join past this many members (pending joins count)
    max_members = infinity :: pos_integer() | infinity,
    %% fs: mod_conference room flags, set on each joining channel
    room_flags = [] :: [binary()],
    focus :: chappe_sip_focus:focus() | undefined,
    entity :: binary() | undefined,
    %% fs recordings started with store => default, adopted into the
    %% recording store when they stop: {Path, CallRef, Meta}
    recordings = [] :: [{binary(), binary(), map()}],
    %% REFER to the room (chappe_mrf_conf_refer): who decides, how a
    %% target is dialed (dial fun, profile, timeout, endpoint options), and
    %% the dial-outs under way
    refer_policy :: fun((map()) -> boolean() | {reject, 300..699}) | undefined,
    dial = #{} :: map(),
    dialing = #{} :: #{term() => map()}
}).
