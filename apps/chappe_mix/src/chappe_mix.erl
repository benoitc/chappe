%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc chappe_mix: an RTP audio conference mixer.
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
    direction/3,
    relate/4,
    events/2,
    ref/1,
    tap/3,
    untap/2,
    taps/1,
    legs/1,
    stats/1
]).

-export_type([
    conf/0, leg/0, endpoint/0, conf_opts/0, leg_opts/0, remote/0, direction/0
]).

-type conf() :: pid().
-type leg() :: pos_integer().
-type endpoint() :: {inet:ip_address(), inet:port_number()}.
%% What the room does with a leg, from the room's side: sendrecv (mixed,
%% hears the room), sendonly (hears the room, mixed into nothing: a
%% recorder over RTP), recvonly (heard by all, sent nothing: a prompt
%% player, or a deaf party), inactive. The mixer's SDP for the leg says
%% the same. A recorder in Erlang takes tap/3 instead: decoded PCM of a
%% party or of the room, with no RTP leg.
-type direction() :: sendrecv | sendonly | recvonly | inactive.

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
%% events: a process that gets `{chappe_mix, Conf, {talking, Leg, true |
%% false}}' when a leg starts or stops talking (off by default, and then
%% the levels are not computed at all); talk_threshold (dBFS RMS over a
%% frame, default -40), talk_start_ms (default 60) and talk_stop_ms
%% (default 300) set the detection. ref: an opaque binary of the app's
%% (a call ref), returned by ref/1; a leg's own ref (leg_opts()) is in
%% legs/1. Events keep their {chappe_mix, Conf, Event} shape either way.
%% tick_ceiling (default true) arms the tick at the millisecond at or
%% after it is due, so it never fires early; false truncates, and most
%% ticks fire up to 1 ms early. prefill_shrink (default false) takes back
%% a jitter-buffer prefill that grew, after 10 s without an underrun; its
%% A/B showed more underruns, so it stays off (test/audit/PERF.md).
-type conf_opts() :: #{
    owner => pid(),
    tick_ceiling => boolean(),
    prefill_shrink => boolean(),
    trace => pid(),
    events => pid(),
    talk_threshold => number(),
    talk_start_ms => pos_integer(),
    talk_stop_ms => pos_integer(),
    ip => inet:ip_address(),
    law => chappe_mix_g711:law(),
    depth => pos_integer(),
    cname => binary(),
    ssrc_draw => fun(() -> 0..16#FFFFFFFF),
    ref => binary()
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
%% (RFC 3551 4.2). dtmf_pt: the RFC 4733 telephone-event payload type the
%% far end negotiated; unset, the leg takes no events and gets none.
%% dtmf_events: the event codes its fmtp lists (default 0 to 15, the
%% digits); it is sent no others. rtcp_remote: where this leg's RTCP goes
%% when the far end's SDP names it with a=rtcp (RFC 3605), instead of the
%% RTP port (mux) or the port after it (pair). direction: see
%% direction(), default sendrecv; mute => true on top of it is what
%% mute/3 does. injected: the leg carries media the room itself plays (a
%% prompt, music), so listeners see the mixer's SSRC for it in their CSRC
%% lists (RFC 3550 7.1). ref: the app's opaque binary for this leg, in its
%% events and in legs/1; it moves with the leg (move_leg/3).
-type leg_opts() :: #{
    remote => endpoint(),
    law => chappe_mix_g711:law(),
    ptime => pos_integer(),
    dtmf_pt => 0..127,
    dtmf_events => [0..255],
    mute => boolean(),
    direction => direction(),
    injected => boolean(),
    rtcp => mux | pair,
    rtcp_remote => endpoint(),
    name => binary(),
    ref => binary()
}.

%% Where a leg sends, as set_remote/3 takes it: the far end alone, or the
%% far end with its RTCP address and the leg's telephone-event as the
%% answer gave them.
-type remote() ::
    endpoint()
    | #{
        remote := endpoint(),
        rtcp_remote => endpoint(),
        dtmf_pt => 0..127,
        dtmf_events => [0..255]
    }.

-spec start(conf_opts()) -> {ok, conf()} | {error, term()}.
start(#{ref := Ref}) when not is_binary(Ref) ->
    {error, {bad_option, ref}};
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
add_leg(_Conf, #{ref := Ref}) when not is_binary(Ref) ->
    {error, {bad_option, ref}};
add_leg(Conf, Opts) ->
    gen_server:call(Conf, {add_leg, Opts}).

-spec remove_leg(conf(), leg()) -> ok | {error, not_found}.
remove_leg(Conf, Leg) ->
    gen_server:call(Conf, {remove_leg, Leg}).

%% Hand a leg to another conference. The socket, its port and the far end
%% move with it, so the peer keeps sending to the same address and needs
%% no re-negotiation: it leaves the first mix and joins the second. Returns
%% the leg's id in the destination conference; a move to the conference the
%% leg is in returns its id and changes nothing.
%%
%% The move runs in a short-lived process, so neither conference waits on
%% the other. When the destination is gone (destination_down) or refuses
%% the leg (refused), the leg stays in the source under its id.
-spec move_leg(conf(), leg(), conf()) ->
    {ok, leg()}
    | {error, not_found | source_down | destination_down | refused}.
move_leg(Conf, Leg, Conf) ->
    gen_server:call(Conf, {has_leg, Leg});
move_leg(From, Leg, To) ->
    chappe_mix_move:run(From, Leg, To).

%% Send the mix to Remote from now on, and take RTP from the next
%% address that sends (the source latch is reset). Given as a map, its
%% rtcp_remote replaces the leg's (none in the map: none any more), and
%% the telephone-event options there replace the leg's.
-spec set_remote(conf(), leg(), remote()) -> ok | {error, not_found}.
set_remote(Conf, Leg, Remote) ->
    gen_server:call(Conf, {set_remote, Leg, Remote}).

%% A muted leg still hears the conference but is not mixed into it: the
%% room stops taking from it (sendrecv becomes sendonly, recvonly
%% inactive); unmuting gives that back.
-spec mute(conf(), leg(), boolean()) -> ok | {error, not_found}.
mute(Conf, Leg, Mute) when is_boolean(Mute) ->
    gen_server:call(Conf, {mute, Leg, Mute}).

%% Set what the room does with a leg (see direction()).
-spec direction(conf(), leg(), direction()) -> ok | {error, not_found}.
direction(Conf, Leg, Dir) when
    Dir =:= sendrecv; Dir =:= sendonly; Dir =:= recvonly; Dir =:= inactive
->
    gen_server:call(Conf, {direction, Leg, Dir}).

%% Send talker events to Pid from now on (see conf_opts()), or to nobody.
-spec events(conf(), pid() | undefined) -> ok.
events(Conf, Pid) when is_pid(Pid); Pid =:= undefined ->
    gen_server:call(Conf, {events, Pid}).

%% Whether Listener hears Speaker. nohear takes Speaker's audio out of
%% what Listener hears, its SSRC out of Listener's CSRC lists and its
%% events out of what Listener is sent; everyone else is unchanged.
-spec relate(conf(), leg(), leg(), hear | nohear) -> ok | {error, not_found}.
relate(Conf, Listener, Speaker, Rel) when Rel =:= hear; Rel =:= nohear ->
    gen_server:call(Conf, {relate, Listener, Speaker, Rel}).

%% The room's ref (conf_opts()), undefined without one.
-spec ref(conf()) -> binary() | undefined.
ref(Conf) ->
    gen_server:call(Conf, ref).

%% Hand the decoded audio of a party (a leg) or of the room to a
%% process, every 20 ms: {chappe_mix, Conf, {tap, Tap, Pcm}}, where Pcm
%% is 320 bytes of 16-bit signed little-endian PCM at 8 kHz. A party's tap carries
%% what the room takes from the leg (silence when it sends nothing or is
%% muted); the room's carries every talker. Opts: to (default the
%% caller), max_queue (default 500: past that many messages waiting at
%% `to', a frame is dropped and counted in taps/1), ref (default the
%% leg's, else the room's; taps/1 shows it). The tap ends when `to' dies, with untap/2, or
%% with {tap_closed, Tap} when its leg leaves or the room stops. For
%% calls that never touch FreeSWITCH: a recorder, a transcriber.
-spec tap(conf(), room | leg(), #{
    to => pid(), max_queue => pos_integer(), ref => binary()
}) -> {ok, reference()} | {error, not_found | badarg}.
tap(Conf, room, Opts) ->
    add_tap(Conf, room, Opts);
tap(Conf, Leg, Opts) when is_integer(Leg) ->
    add_tap(Conf, Leg, Opts);
tap(_Conf, _Source, _Opts) ->
    {error, badarg}.

add_tap(Conf, Source, #{} = Opts) ->
    To = maps:get(to, Opts, self()),
    Max = maps:get(max_queue, Opts, 500),
    Ref = maps:get(ref, Opts, undefined),
    case
        is_pid(To) andalso pos(Max) andalso
            (Ref =:= undefined orelse is_binary(Ref))
    of
        true -> gen_server:call(Conf, {taps, {add, Source, To, Max, Ref}});
        false -> {error, badarg}
    end;
add_tap(_Conf, _Source, _Opts) ->
    {error, badarg}.

pos(N) -> is_integer(N) andalso N > 0.

-spec untap(conf(), reference()) -> ok | {error, not_found}.
untap(Conf, Tap) ->
    gen_server:call(Conf, {taps, {remove, Tap}}).

%% The taps of a conference: tap, source, to, ref, dropped.
-spec taps(conf()) -> [map()].
taps(Conf) ->
    gen_server:call(Conf, {taps, list}).

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
