# Design overview

This page explains how chappe_mix is built: the process model, the clock,
the mix, the jitter buffer, RTCP and socket ownership. Read it before you
change anything on the tick path, or when a room sounds wrong and you need
to know which module decides what. Performance claims here cite
[`test/audit/PERF.md`](../../test/audit/PERF.md); what was tried and
reverted is in [`test/audit/ATTEMPTS.md`](../../test/audit/ATTEMPTS.md).

## Scope

chappe_mix takes G.711 RTP on UDP sockets it owns, mixes, and sends it back.
It has no SIP, no SDP and no codec other than G.711: rtpengine in front of
it handles SRTP, DTLS, ICE and transcoding. The SDP for a mixer leg is
written by its caller (`chappe_sip_media_mix_sdp` in chappe_sip).

## Process model

```
chappe_mix_sup (one_for_one)
`-- chappe_mix_conf_sup (simple_one_for_one, temporary children)
    `-- chappe_mix_conf   one gen_server per conference (room)
```

One `chappe_mix_conf` process is one room. It owns every leg's socket, runs
the clock and holds all leg state. Nothing else runs per call: a leg is data
in the conference process, not a process of its own. A conference that
crashes is not restarted; its owner sees it go.

The conference monitors its owner (the caller of `chappe_mix:start/1`, or
the `owner` option) and stops when the owner exits. On stop, every leg gets
an RTCP BYE and its sockets close.

| Module | Role |
|---|---|
| `chappe_mix` | Public API. Every call is a `gen_server:call` to the conference. |
| `chappe_mix_conf` | The process: sockets, clock, RTCP schedule, SSRC space, crossing BYEs and SDES between legs. |
| `chappe_mix_room` | What one tick and one RFC 4733 event do to the legs, as plain functions. |
| `chappe_mix_dsp` | The compute of one tick: the sum, the N-1 outputs, the gain control, talker levels. |
| `chappe_mix_jbuf` | One leg's jitter buffer, as plain data. |
| `chappe_mix_leg` | One leg on its own: open sockets, filter what arrives, send its share. |
| `chappe_mix_session` | One leg's RTP session as RFC 3550 sees it (SSRC, sender and receiver state, RTCP timing). |
| `chappe_mix_rtp`, `chappe_mix_rtcp` | Total parsers and builders: whatever a peer sends comes back as a value, never an exception or an atom. |
| `chappe_mix_g711` | G.711 tables, built once at application start in `persistent_term`. |
| `chappe_mix_move` | Moving a leg from one conference to another, in a short-lived process of its own. |
| `chappe_mix_tap` | Taps: the decoded audio of a party or of the room handed to a process every 20 ms (`chappe_mix:tap/3`, `untap/2`, `taps/1`). |

`chappe_mix_app` calls `chappe_mix_g711:init/0` before any room starts,
because a `persistent_term:put` stalls every process on the node and would
cost a tick inside a running call (ATTEMPTS.md, "Tables built lazily inside
a call: reverted").

## The clock and the tick

The clock is absolute. Tick `k` is due at `T0 + 20k ms` on the monotonic
clock and armed with `erlang:start_timer/4` and `{abs, true}`, so a late
tick does not push the next one back and the output keeps its rate over a
long call.

- `tick_ceiling` (default `true`) arms the timer at the millisecond at or
  after the due time, so a tick never fires early. Truncating made most
  ticks fire up to 1 ms early (PERF.md, "Tick timer" row).
- A tick that fires more than a period late skips the frames it missed (an
  overrun) instead of sending them back to back. The RTP timestamp still
  advances by the skipped frames, so it stays the sampling clock (RFC 3550
  5.1).
- Each tick's lateness goes into a histogram (`chappe_mix:stats/1`,
  `late_histogram_us`). With `trace => Pid`, every tick sends
  `{chappe_mix_tick, Conf, #{due, start, done, legs}}`; the bench arms use
  it.

A tick, in order:

1. pop one 20 ms frame from each leg's jitter buffer;
2. add the frames of the legs the room takes from into one sum;
3. send each leg the room sends to the sum less its own frame and less the
   frames of legs it does not hear;
4. send the RTCP reports that are due.

A leg with nothing to hear is sent silence, so the media path towards
rtpengine never goes quiet.

## N-1 mixing (`chappe_mix_dsp`)

Every talker's frame is decoded straight into one sum: an `atomics` array of
160 signed slots that lives only for the tick. Once every talker is in, the
sum is read out into a tuple, and each listener's output is encoded from it
less its own frame, decoded again from the code words it came in. No decoded
frame is kept as a list, and every per-sample lookup is `element/2`.
ATTEMPTS.md ("The mix on lists, binaries or atomics", "element/2 for every
per-sample lookup", "A NIF for the mix: not written") records the
alternatives and their numbers.

Each listener has its own gain control. A room that does not clip is mixed
byte for byte as a plain sum. When a listener's frame would clip, its gain
drops at once to fit the frame's peak, then comes back by 0.2 dB a frame to
unity (PERF.md, "Limiter, distortion").

Talker levels (the energy of each frame) are only computed when a process
listens for talker events (`events` option or `chappe_mix:events/2`).

## The jitter buffer (`chappe_mix_jbuf`)

Each leg keeps its packets by RTP timestamp, so a sender may use any packet
size from 10 to 200 ms; the mixer always plays and sends 20 ms frames.

- Reordering inside the buffer is repaired; sequence numbers and timestamps
  are extended past their wrap.
- A gap with missing sequence numbers is loss: only the missing time is
  played as silence. A gap with consecutive sequence numbers is a silence
  suppression pause and is skipped.
- When the buffer runs dry inside a frame, that is an underrun: the leg
  plays silence and waits, so a late packet still plays and a frame is
  never half silent.
- Playout starts after `prefill` frames. The prefill starts at 1 and grows
  by one at each underrun, up to `depth - 1`. `prefill_shrink` would take
  it back after 10 s without an underrun; its A/B raised underruns under
  loss, so it is off (PERF.md, "Prefill").
- Past `depth` frames (default 3), the oldest packets are dropped, so a
  sender running fast cannot grow the latency without bound.
- A new SSRC, or a jump too large to be loss, restarts the buffer.

## RTCP schedule (`chappe_mix_session`, `chappe_mix_rtcp`)

Each leg is its own RTP session with two members, the mixer and the far end.
The mixer follows RFC 3550 7.3 on it:

- mixed packets carry the SSRCs in that listener's mix as CSRCs (up to 15);
- each leg gets compound SR (RR before it sent anything) and SDES CNAME,
  plus the CNAME and NAME of each CSRC when known;
- the interval is the one of appendix A.7 with a 5 s minimum, which decides
  at two members: the first report 1.03 to 3.08 s after the leg opens, then
  every 2.05 to 6.16 s. Timer reconsideration is not done because the member
  count never changes;
- incoming RTCP is validated (A.2) and consumed on its leg; only CNAME,
  NAME and BYE cross to other legs, and `chappe_mix_conf` does the crossing;
- all legs share one SSRC space (7.1, 8.2): collisions and loops are found
  across the whole conference, and a colliding mixer SSRC is renewed after
  a BYE.

RTCP runs on the RTP port by default (`rtcp => mux`) or on the next port
(`rtcp => pair`). RTCP-mux demultiplexing follows RFC 5761 4.

## Sockets and `move_leg`

The conference process is the controlling process of every leg socket
(`{active, 64}`, re-armed on `udp_passive`). Nothing a peer sends becomes an
atom.

The far end is learnt from the first packet (symmetric RTP) unless
`remote` is set. Once latched, RTP from another address is dropped and
counted (`filtered`), except from the far end itself, which moves the
latch. `set_remote/3` resets the latch.

`chappe_mix:move_leg/3` hands a leg to another conference without new
signalling. No conference ever calls another: the move runs in a
short-lived process started by the caller.

1. The source detaches the leg, transfers its sockets to the mover with
   `gen_udp:controlling_process/2` and forwards the packets already in its
   mailbox.
2. The destination adopts the leg under a new id.
3. The mover then transfers the sockets to the destination, with the
   packets that reached it meanwhile, so the destination only receives
   packets for a leg it knows.

Two rooms swapping legs at the same moment therefore cannot wait on each
other. If the destination is gone (`{error, destination_down}`) or refuses
the leg (`{error, refused}`), the leg goes back to the source under its id;
if the source has gone too, the sockets close with the mover. A move to the
conference the leg is already in returns `{ok, Leg}` and changes nothing.

The port and the far end stay the same, so the peer keeps sending to the
same address. The leg's RTP session and RTCP state move with it. Its
relations are dropped, because they named legs of the first room, also when
it returns to the source.

## Relations, directions and mute

- `direction` is seen from the room: `sendrecv` (mixed and hears the room),
  `sendonly` (hears the room, mixed into nothing: a recorder), `recvonly`
  (heard by all, sent nothing: a prompt player or a deaf party),
  `inactive`.
- `mute/3` is a direction change: `sendrecv` becomes `sendonly`, `recvonly`
  becomes `inactive`.
- `relate(Conf, Listener, Speaker, nohear)` takes the speaker out of what
  that one listener hears, out of its CSRC lists and out of the events it is
  sent. Everyone else is unchanged. This is how a whisper or a listen-only
  supervisor is built.
- A leg marked `injected` is the room's own media (a prompt, music): its
  listeners see the mixer's SSRC for it.

## Talker events

With an `events` process set, a leg is talking after `talk_start_ms`
(60 ms) of frames over `talk_threshold` (-40 dBFS RMS), and stops after
`talk_stop_ms` (300 ms) under it. The process gets
`{chappe_mix, Conf, {talking, Leg, true | false}}`. A leg that leaves while
talking sends `false`. PERF.md ("Talker events") has the latency and cost.

## What chappe_sip adds on top

`chappe_sip_media_mix` (in chappe_sip) keeps rooms by name, makes one leg
per call, and writes the leg's SDP. It adds two join options that do not
exist in chappe_mix itself:

- `persist => true`: the room stays up with no leg until its owner exits
  (chappe_mrf's native conferences use it);
- `talk_tag => Tag`: the talker event carries a tag, so one process holding
  several legs can tell them apart.

## Failure handling

| Failure | Behaviour |
|---|---|
| Malformed RTP, unknown payload type, comfort noise | Counted on the leg and dropped |
| Invalid RTCP | Counted (`rtcp_invalid`) and dropped |
| Packet from an address other than the latched one | Counted (`filtered`) and dropped |
| Tick more than one period late | Missed frames skipped, `overruns` counted |
| Owner exits | The conference stops; every leg gets a BYE |
| Conference crash | Not restarted; the owner sees the exit |

## Where it lives

- Code: `apps/chappe_mix/src/`
- Tests: `chappe_mix_SUITE` (rooms on loopback), `chappe_mix_rfc_SUITE`
  (RFC 3550 and 4733 rules on the wire), `chappe_mix_tap_SUITE` (taps),
  eunit for `jbuf`, `dsp`, `rtp`,
  `rtcp`, `g711`
- Labs: `make interop-mix` (behind rtpengine, `chappe_mix_live_SUITE`),
  `make interop-ref` (against mod_conference, `chappe_mix_ref_SUITE`)
- Bench: `apps/chappe_mix/bench/README.md`
