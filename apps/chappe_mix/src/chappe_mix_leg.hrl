%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% One leg of a conference, shared by chappe_mix_conf (the conference)
%% and chappe_mix_leg (what one leg does on its own).

-record(leg, {
    id :: pos_integer(),
    sock :: gen_udp:socket(),
    port :: inet:port_number(),
    %% where the mix goes; learnt from the first packet when unset
    remote :: {inet:ip_address(), inet:port_number()} | undefined,
    %% the address RTP is taken from, latched on the first packet
    source :: {inet:ip_address(), inet:port_number()} | undefined,
    law :: chappe_mix_g711:law(),
    %% the packet time the far end sends, in ms (informational: the
    %% jitter buffer takes any size, and the mix always goes out in 20 ms)
    ptime = 20 :: pos_integer(),
    mute = false :: boolean(),
    name :: binary() | undefined,
    jbuf :: chappe_mix_jbuf:jbuf(),
    sess :: chappe_mix_session:session(),
    tx = 0 :: non_neg_integer(),
    bad = 0 :: non_neg_integer(),
    other_pt = 0 :: non_neg_integer(),
    filtered = 0 :: non_neg_integer(),
    %% RTCP on the RTP port (mux) or on the next one up (pair)
    rtcp = mux :: mux | pair,
    rtcp_sock :: gen_udp:socket() | undefined,
    rtcp_port :: inet:port_number(),
    %% pair: the address RTCP is taken from, latched like source
    rtcp_source :: {inet:ip_address(), inet:port_number()} | undefined
}).
