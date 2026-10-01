# Features

What chappe_mix does today, and what is planned.

## Working

- One process per conference, owning one UDP socket per leg, bound to an
  address you choose (loopback by default).
- N-1 mix on an absolute 20 ms clock: every leg hears the sum of the other
  unmuted legs, never itself. A late tick skips the frames it missed rather
  than bursting them.
- G.711 mu-law and A-law, per leg, with frame tables built at application
  start.
- Per-leg jitter buffer: reorder repair, loss played as silence, late frames
  dropped, bounded depth, adaptive prefill after an underrun, restart on a new
  SSRC or a large sequence jump.
- Symmetric RTP: the far end is learnt from the first packet unless set.
  Once latched, RTP from any other address is dropped and counted, except
  from the far end itself, which moves the latch to it; `set_remote/3`
  resets the latch.
- Join, leave and mute at any time. Telephone-event, comfort noise and
  malformed packets are counted and dropped.
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
  demultiplexing follows RFC 5761 4.
- The RTP timestamp stays on the sampling clock across an overrun; the
  marker bit is always 0 (no silence suppression).
- The conference stops when its owner exits.
- Counters per leg (received, lost, late, dropped, sent, prefill, filtered,
  collisions, loops, RTCP sent, received and invalid) and per conference
  (ticks, overruns, tick lateness histogram, and the leg counters summed).
- An optional tick trace (`trace => Pid`): one message per tick with when it
  was due, when it fired and when its last packet went out. Off by default.
- Bench arms in `bench/` (null, latency, jitter, capacity, mix_cost,
  ref_latency), a reference suite against FreeSWITCH `mod_conference`, and a
  live suite behind a real rtpengine with PCMA and opus legs
  (`make interop-mix`).

## Planned

- Wideband: 16 kHz mixing with G.722 and Opus through a NIF.
- Gain control on the sum (today it saturates).
- RFC 4733 telephone-event forwarding.
- Frames other than 20 ms: 10 ms and 30 ms packets (RFC 3551 4.2) are
  padded or cut to 20 ms today, so a 30 ms sender loses a third of its
  audio.
- An RTCP port from signalling that is not RTP + 1 (RFC 3605 a=rtcp).
- Cascaded mixers: carrying an input packet's CSRCs into the output list
  (RFC 3550 7.4).
- Numbers from a quiet box for every threshold in `test/audit/PERF.md`. The
  arms run; everything measured so far was taken at a load average of 18 or
  more and is void.
- Reference numbers from an amd64 host: the FreeSWITCH image is amd64 only
  and runs emulated on arm64.
- A decision on the tick timer firing up to 1 ms early, and on the
  jitter-buffer prefill that only grows, once latency is measured on a quiet
  box.
