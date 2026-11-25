# Features

What chappe_mix does today, and what is planned.

## Working

- One process per conference, owning one UDP socket per leg, bound to an
  address you choose (loopback by default).
- N-1 mix on an absolute 20 ms clock: every leg hears the sum of the other
  unmuted legs, never itself. A late tick skips the frames it missed rather
  than bursting them. The tick timer is armed at the millisecond at or
  after the tick is due, so a tick never fires early (`tick_ceiling`,
  default on; `false` truncates, and most ticks then fire up to 1 ms
  early).
- G.711 mu-law and A-law, per leg, with frame tables built at application
  start.
- 16 kHz rooms (`rate => 16000`): every leg L16 at 16000 on a dynamic
  payload type (`pt`, default 96), mixed linearly, 320 samples a frame,
  taps of 640 bytes, telephone-event at 16000. rtpengine turns Opus,
  G.722, PCMU and PCMA callers into L16 and back: tested on 26.3.1.4,
  11.5.1.18 has no L16, upstream has it from 13.4.1.1. The rate is
  fixed for the room's life; an 8 kHz room is the G.711 mix of before,
  byte for byte (a seeded digest pins it). Compared with a FreeSWITCH
  16 kHz room on speech clips in [QUALITY.md](../test/audit/QUALITY.md).
  [Conference guide](guides/conference.md#run-a-16-khz-hd-room)
- Gain control on what each leg hears: a room that does not clip is
  mixed byte for byte as before; when a listener's frame would clip, its
  gain drops at once to fit the frame's peak, then comes back by 0.2 dB a
  frame (10 dB a second) to unity. A hard clip stays as the safety net.
  8 talkers at -6 dBFS measure -29 dB THD+N against -10 dB clipped.
- Per-leg jitter buffer keyed by RTP timestamp: packets of any size from
  0 to 200 ms (10, 20, 30 ms...) play out as 20 ms frames, every sample once
  (RFC 3551 4.2). Reorder repair, loss played as silence for the missing
  packets' time only, a silence-suppression pause skipped rather than played
  out, late packets dropped, bounded depth, adaptive prefill after an
  underrun (a frame is never played half silent while its rest is on the
  way), restart on a new SSRC or a large jump. The mixer always sends 20 ms;
  the `ptime` leg option records what the far end sends.
- Symmetric RTP: the far end is learnt from the first packet unless set.
  Once latched, RTP from any other address is dropped and counted, except
  from the far end itself, which moves the latch to it; `set_remote/3`
  resets the latch.
- Leg directions from the room's side (`direction`: sendrecv, sendonly
  for a recorder, recvonly for a prompt player or a deaf party, inactive),
  `mute/3` as a direction change, and per-pair relations
  (`relate/4`: a listener kept from hearing one speaker, in audio, CSRC
  lists and events). A leg marked `injected` is the room's own media: its
  listeners see the mixer's SSRC for it in their CSRC lists.
- Talker events, opt-in (`events => Pid`, `chappe_mix:events/2`):
  `{chappe_mix, Conf, {talking, Leg, true | false}}` after 60 ms over
  -40 dBFS and 300 ms under it (configurable); the levels are only
  computed when someone listens.
- Join, leave and mute at any time. Comfort noise, unknown payload types
  and malformed packets are counted and dropped.
- RFC 4733 telephone-event forwarding (`dtmf_pt`, `dtmf_events` leg
  options): an event from one leg goes, never mixed, to every other leg
  that negotiated telephone-event and lists its code, payload byte for
  byte, M bit kept, one timestamp per event on the listener's clock, the
  listener's own sequence numbers, the source as CSRC.
- RFC 3550 mixer behaviour on every leg. Mixed packets carry the SSRCs in
  that leg's mix as CSRCs (up to 15). Each leg gets compound SR (RR before
  it sent anything) with a report block for its source, and SDES CNAME,
  plus the CNAME and NAME of each CSRC when known. The interval is the one
  in appendix A.7 with a 5 s minimum. Incoming RTCP is checked (A.2) and
  consumed on its leg; only CNAMEs and BYEs reach the other legs. A leg
  leaving, and every leg at stop, gets a BYE. SSRC collisions and loops are
  handled as in 8.2, over one SSRC space for the whole conference.
- RTCP on the RTP port (`rtcp => mux`, the default, for an SDP with
  a=rtcp-mux) or on an even/odd port pair (`rtcp => pair`). RTCP-mux
  demultiplexing follows RFC 5761 4. An RTCP address from signalling
  (RFC 3605 a=rtcp, the `rtcp_remote` leg option or `set_remote/3` key)
  takes the place of the RTP port or the one after it.
- Cascaded mixers: a talker whose packets carry CSRCs (another mixer)
  contributes those to the CSRC lists, not its own SSRC (RFC 3550 7.4).
- The RTP timestamp stays on the sampling clock across an overrun; the
  marker bit is always 0 (no silence suppression).
- The conference stops when its owner exits.
- Taps: the decoded PCM of one party, or of the whole room, handed to a
  process (`tap/3`), for calls that never touch FreeSWITCH.
  [Conference guide](guides/conference.md#tap-a-party-or-the-room)
- Legs and rooms carry an opaque `ref` (the call's reference) and return it
  in their events.
- Counters per leg (received, lost, late, dropped, underruns, sent,
  prefill, filtered, collisions, loops, RTCP sent, received and invalid)
  and per conference
  (ticks, overruns, tick lateness histogram, and the leg counters summed).
- An optional tick trace (`trace => Pid`): one message per tick with when it
  was due, when it fired and when its last packet went out. Off by default.
- Bench arms in `bench/` (null, latency, loss, jitter, capacity, mix_cost,
  ref_latency, ref_capacity), a reference suite against FreeSWITCH
  `mod_conference` running natively in docker (`make interop-ref`,
  `make bench-ref`), and a live suite behind a real rtpengine with PCMA and
  opus legs (`make interop-mix`).

## Planned

- A room whose rate changes while it runs, and 48 kHz rooms (decision
  [0017](https://github.com/benoitc/chappe/blob/main/docs/decisions/0017-chappe-mix-16khz-l16.md)).
- SIPREC of a 16 kHz room.
- The SDES (CNAME, NAME) of the sources behind a cascaded mixer's CSRCs.
- A prefill that shrinks back after a burst without costing underruns.
  `prefill_shrink` (off by default) takes a grown prefill back after 10 s
  without an underrun; its A/B showed more underruns under loss, so it
  stays off.
