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
    %% what the room does with this leg, from the room's side: sendrecv
    %% (mixed, hears the room), sendonly (hears the room, mixed into
    %% nothing), recvonly (mixed, sent nothing), inactive
    direction = sendrecv :: sendrecv | sendonly | recvonly | inactive,
    %% the leg carries media the room itself injects (a prompt): in CSRC
    %% lists it is the mixer's own SSRC
    injected = false :: boolean(),
    %% legs this one does not hear, besides itself
    nohear = [] :: [pos_integer()],
    %% talker detection: whether the leg talks, and for how many frames
    %% in a row it has looked otherwise
    talking = false :: boolean(),
    %% the gain control on what this leg hears (chappe_mix_dsp:encode/4)
    gain = 1.0 :: float(),
    talk_run = 0 :: non_neg_integer(),
    %% RFC 4733 telephone-event: the payload type this leg negotiated
    %% (undefined: none) and the event codes it takes
    dtmf_pt :: 0..127 | undefined,
    dtmf_events = [] :: [0..255],
    %% per listening leg, the offset from this leg's event timestamps to
    %% that leg's output clock, set at an event start
    dtmf_off = #{} :: #{pos_integer() => integer()},
    events = 0 :: non_neg_integer(),
    events_sent = 0 :: non_neg_integer(),
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
    rtcp_source :: {inet:ip_address(), inet:port_number()} | undefined,
    %% where RTCP goes when signalling named it (RFC 3605 a=rtcp), instead
    %% of the RTP port or the one after it
    rtcp_remote :: {inet:ip_address(), inet:port_number()} | undefined,
    %% the CSRC list of the last audio packet in: the sources an upstream
    %% mixer put in it (RFC 3550 7.4)
    in_csrcs = [] :: [0..16#FFFFFFFF],
    %% the app's opaque reference for this leg (a call ref), returned in
    %% its events and legs/1
    ref :: binary() | undefined
}).
