%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% chappe_mix: an RTP audio conference mixer.
%%
%% A conference is a process that owns one UDP socket per leg. Every 20 ms
%% it takes one frame from each leg's jitter buffer (legs may send
%% packets of 10, 30 or any other number of ms), sums the unmuted ones,
%% and sends each leg the sum minus its own contribution (N-1), so nobody
%% hears themselves. G.711 only: put rtpengine in front for SRTP,
%% DTLS and every other codec.
%%
%% Each leg is an RTP session of its own and the mixer behaves on it as
%% an RFC 3550 mixer: mixed packets name their sources in the CSRC list,
%% each leg gets SR and SDES CNAME reports (on the RTP port, or on the
%% next one with `rtcp => pair'), and a BYE when it leaves or the
%% conference stops.
%%
%% ```
%% {ok, Conf} = chappe_mix:start(#{ip => {10, 0, 0, 5}}),
%% {ok, Leg, #{ip := Ip, port := Port}} = chappe_mix:add_leg(Conf, #{}),
%% %% put Ip/Port in the SDP towards rtpengine; the far end is learnt from
%% %% the first packet, or set it with set_remote/3
%% ok = chappe_mix:remove_leg(Conf, Leg),
%% ok = chappe_mix:stop(Conf).
%% '''
%%
%% The conference is bound to its owner (the caller of start/1 unless
%% `owner' says otherwise) and stops when the owner exits.
-module(chappe_mix).

-export([
    start/1,
    stop/1,
    add_leg/2,
    remove_leg/2,
    move_leg/3,
    set_remote/3,
    mute/3,
    legs/1,
    stats/1
]).

-export_type([conf/0, leg/0, endpoint/0, conf_opts/0, leg_opts/0]).

-type conf() :: pid().
-type leg() :: pos_integer().
-type endpoint() :: {inet:ip_address(), inet:port_number()}.

%% ip: the address legs bind to and advertise (default 127.0.0.1, so
%% nothing is exposed unless you say so). law: the conference default
%% codec. depth: jitter buffer depth in frames. trace: a process that
%% gets `{chappe_mix_tick, Conf, #{due, start, done, legs}}' after every
%% tick (native monotonic times: when the tick was due, when it fired, when
%% the last packet was sent); for measurement, off by default. cname: the
%% RTCP CNAME the mixer uses on every leg, default 96 random bits in
%% base64 (RFC 7022). ssrc_draw: a fun that draws a candidate SSRC,
%% default a cryptographic random; a candidate already in use in the
%% conference is drawn again. Set it in tests to script the draws.
-type conf_opts() :: #{
    owner => pid(),
    trace => pid(),
    ip => inet:ip_address(),
    law => chappe_mix_g711:law(),
    depth => pos_integer(),
    cname => binary(),
    ssrc_draw => fun(() -> 0..16#FFFFFFFF)
}.

%% remote: where to send the mix; unset, it is learnt from the first
%% packet received. Once a packet has come in, RTP from any other address
%% is dropped until set_remote/3. law: this leg's codec, default the
%% conference's. rtcp: `mux' (default) sends and takes RTCP on the RTP
%% port, so the SDP for this leg must carry a=rtcp-mux (RFC 5761);
%% `pair' opens an even RTP port and RTCP on the next one, which is what
%% an SDP without a=rtcp-mux means. name: the SDES NAME the other legs
%% see for this leg's source. ptime: the packet time the far end sends
%% in ms (its a=ptime), reported by legs/1; packets of any size up to
%% 200 ms are taken whatever it says, and the mixer always sends 20 ms
%% (RFC 3551 4.2).
-type leg_opts() :: #{
    remote => endpoint(),
    law => chappe_mix_g711:law(),
    ptime => pos_integer(),
    mute => boolean(),
    rtcp => mux | pair,
    name => binary()
}.

-spec start(conf_opts()) -> {ok, conf()} | {error, term()}.
start(Opts) ->
    Owner = maps:get(owner, Opts, self()),
    supervisor:start_child(chappe_mix_conf_sup, [Opts#{owner => Owner}]).

-spec stop(conf()) -> ok.
stop(Conf) ->
    chappe_mix_conf:stop(Conf).

%% Open a leg. Returns the address the far end must send to, and the
%% port its RTCP goes to (the same port with rtcp => mux).
-spec add_leg(conf(), leg_opts()) ->
    {ok, leg(), #{
        ip := inet:ip_address(),
        port := inet:port_number(),
        rtcp_port := inet:port_number()
    }}
    | {error, term()}.
add_leg(Conf, Opts) ->
    gen_server:call(Conf, {add_leg, Opts}).

-spec remove_leg(conf(), leg()) -> ok | {error, not_found}.
remove_leg(Conf, Leg) ->
    gen_server:call(Conf, {remove_leg, Leg}).

%% Hand a leg to another conference. The socket, its port and the far end
%% move with it, so the peer keeps sending to the same address and needs
%% no re-negotiation: it leaves the first mix and joins the second. Returns
%% the leg's id in the destination conference.
-spec move_leg(conf(), leg(), conf()) -> {ok, leg()} | {error, not_found}.
move_leg(From, Leg, To) ->
    gen_server:call(From, {move_leg, Leg, To}).

%% Send the mix to Remote from now on, and take RTP from the next
%% address that sends (the source latch is reset).
-spec set_remote(conf(), leg(), endpoint()) -> ok | {error, not_found}.
set_remote(Conf, Leg, Remote) ->
    gen_server:call(Conf, {set_remote, Leg, Remote}).

%% A muted leg still hears the conference but is not mixed into it.
-spec mute(conf(), leg(), boolean()) -> ok | {error, not_found}.
mute(Conf, Leg, Mute) when is_boolean(Mute) ->
    gen_server:call(Conf, {mute, Leg, Mute}).

%% Per-leg state and counters, among them: ssrc (ours on that leg),
%% source_ssrc, csrcs (of the last packet), filtered (RTP or RTCP from
%% an address other than the latched one), collisions, loops,
%% rtcp_sent, rtcp_received, rtcp_invalid.
-spec legs(conf()) -> [map()].
legs(Conf) ->
    gen_server:call(Conf, legs).

%% Conference counters: ticks, overruns, the tick lateness histogram,
%% and the leg counters filtered, collisions, loops, rtcp_sent,
%% rtcp_received and rtcp_invalid summed over its legs, removed ones
%% included.
-spec stats(conf()) -> map().
stats(Conf) ->
    gen_server:call(Conf, stats).
