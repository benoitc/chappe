# What was tried

Approaches tried for chappe_mix and what became of them, kept or reverted,
with the numbers that decided it. Read this before proposing an optimisation,
so you do not rediscover something already measured and thrown away. The
numbers behind each entry are in `PERF.md`.

## Tests that were checked against a broken implementation

Every new test module is run before the code it covers exists, and again
against deliberate mutations. A test that cannot fail is worse than no test.

- `chappe_mix_g711_tests`: 24 cases, all failing with no implementation.
  Three mutations were all caught: mu-law bias `0x84` to `0x80` (2 failures),
  A-law XOR mask `0x55` to `0x54` (7 failures), and a frame clip that wraps
  instead of saturating (1 failure).
- `rebar3 eunit --app chappe_mix` ran 0 tests while the app had no source
  module: `--app` only finds test modules paired with source modules. Run a
  new module with `--module` until then, and check the count.
- `chappe_mix_jbuf_tests`: two mutations survived the first version and
  each got a test. Advancing the playout point on an empty buffer
  (`underrun_waits_test`) and accepting the frame just behind the playout
  point (`late_by_one_test`). Four more mutations (depth bound, extended
  sequence wrap, RTCP detection, padding strip) were caught from the start.
- Restoring a mutated file within the same second as the mutated build left
  a stale beam: rebar3 compares mtimes at one-second resolution, and a
  mutated table was still loaded. Remove `_build/test/lib/chappe_mix`
  between mutations; the scratch `mutate.sh` does.

- `chappe_mix_SUITE:tick_trace`: without the `trace` option the conference
  sends nothing, which is the first mutation below. Three mutations of the
  trace, each caught: the message never sent (`no_tick_trace`), the leg
  count reported as 0 (`expected [2], got [0]`), and trace on by default to
  the owner (`untraced_conf_traced`).
- `chappe_mix_SUITE:probe_calibration`: the probe stamping a burst one tick
  late (`+ 20000` us) reads below the reflector's 60 ms and fails
  (`below_delay`).
- `chappe_mix_live_SUITE` and `chappe_mix_ref_SUITE` against a mixer that
  does not subtract a leg's own frame (`own/3` returning the sum): the live
  suite fails with `{leaked, 440, -14.7}` at the PCMU party, and
  `same_detection_as_reference` sees every chappe_mix receiver leak while the
  reference does not. Against a mixer that sends only silence: the live
  suite fails with `{missing, 1100, 0, 10}`, the ref suite with every tone
  missing and `burst_latency_logged` with all 20 bursts lost.
- `chappe_mix_ref_SUITE:reference_n_minus_one` against a reference made deaf
  (`conference <name> deaf all` through `fs_cli` after the joins, "+OK deaf"
  three times in the log): every receiver misses its tones. The suite can
  tell a reference that does not deliver.
- The suites judge with `chappe_mix_test_tone:hears/3`, moved out of
  `chappe_mix_SUITE` unchanged in its rule so the three suites share it. At
  load 143 `chappe_mix_SUITE` failed three presence checks on this branch
  and three on `359a605` in the next minute (different cases each time,
  never a leak), so those failures are the load and not the move.

- `chappe_mix_rfc_SUITE:bye_grace` and `chappe_mix_SUITE:bye_grace` (the
  BYE grace, RFC 3550 6.2.1): both failed before the grace existed, the
  straggler coming back as a new source (`{ok, _, true}`, and
  `source_ssrc` 16#B on the leg). Five mutations, each caught: a grace
  that never ends (both), a grace of 0 s (both), a report block for the
  marked source (rfc), the marked source still named by `src_ssrc/1`
  (both), and the straggler taken into the jitter buffer (wire, by the
  leg's `received` count; the CSRC lists alone did not show it, so the
  case checks it).
- The BYE grace first muted a source that says BYE and goes on under the
  same SSRC (pjsip on hold and unhold) for 5 s. A packet newer than the
  highest sequence number at the BYE now ends the mark.
  `chappe_mix_rfc_SUITE:bye_resume` and `bye_resume_wrap` and the reworked
  `chappe_mix_SUITE:bye_grace`, with `bye_then_new_remote`, all failed on
  the first grace. Five mutations, each caught: no packet ever newer
  (bye_resume, bye_resume_wrap, wire bye_grace), no 16-bit wrap in the
  comparison (bye_resume_wrap), the BYE-time highest counted as newer
  (bye_grace, bye_resume_wrap), `clear_bye/1` doing nothing on a new far
  end (bye_then_new_remote), and a returning source not flagged new for
  the SSRC space (bye_resume). In chappe_audio, a mark that never ends on
  a newer packet, the comparison without the wrap, and the BYE-time highest
  counted as newer were each caught by
  `resume_after_bye_test` and `resume_wrap_test`.

## The first tick-trace run: ticks fire early

`tick_trace` first asserted due =< start. It failed: a tick fired 546 us
before it was due. The timer is armed with `erlang:start_timer/4` at
millisecond resolution, and the due time is truncated to the millisecond,
so a tick can fire up to 1 ms early. The bench then showed it is the common
case (over 94% of ticks, see `PERF.md`). The histogram clamps early ticks to
zero, so it never showed. The mixer is unchanged: rounding the arm time up
would move every tick up to 1 ms later, and whether that is better is a
question for a quiet box. The assertion allows 1 ms early.

## Reference suite: what the first versions got wrong

- A fixed 2 s settle after the joins was not enough: emulated FreeSWITCH
  took over a second to start mixing, and the first five windows of a
  reference receiver were near silence. Replaced by a wait for the steady
  state: two polls in a row where every receiver's last 200 ms shows the
  contract, up to 15 s. A mixer that leaks for good never gets there and is
  judged after 15 s anyway (the leak mutation above took 15.2 s).
- With 440, 1100 and 1700 Hz the reference leaked the 440 Hz party's own
  tone at -50.9 dBFS in the first two windows, twice. The enter tone that
  mod_conference plays on each join is 500, 600 and 700 Hz; delivered late
  by the emulated reference, a 500 Hz burst reads about -50 dBFS in a 440 Hz
  Goertzel bin over 200 ms, and only the 440 Hz receiver showed it. The
  suite now uses 1100, 1700 and 2300 Hz.
- FreeSWITCH's SDP names its container address (192.168.x), which the host
  cannot reach under Docker Desktop. The caller sends media to
  `FREESWITCH_HOST` on the SDP's port instead, and puts the address the
  container reaches the host at (`host.docker.internal`, 0.250.250.254 on
  this box) in Via, Contact and its own SDP. RTP flowed both ways with no
  other change.

## Opus on the live suite: through rtpengine twice

The Ubuntu 24.04 rtpengine transcodes opus (`rtpengine --codecs`: fully
supported), but a test party cannot speak opus without an Erlang codec.
The opus party therefore speaks PCMU into one rtpengine call that encodes
opus, a UDP relay on the host carries the opus to a second call that decodes
it to PCMU for the mixer, and back. Both directions of a negotiated opus
leg go through rtpengine's encoder and decoder. G.722 in Erlang was the
fallback and was not needed. The PCMA party speaks PCMA directly.

## Bench traffic: in a peer node, not in the mixer's node

The capacity and jitter arms put the synthetic senders in a second VM
started with `peer`. In the mixer's node they would share its one scheduler
and be counted in its utilisation and lateness. One sender process per
conference, one socket for all four legs, pre-encoded frames, and the
socket never read. The first capacity run compared what the mixer received
with legs x 50 x seconds and read 0.48 to 1.01: that mixed senders falling
behind with the window being read at slightly different times. The senders
now count the sends their socket accepted, and the arm reports
`sent_per_expected` (1.0 in every step so far) and `rx_per_sent`
separately; the second still wanders by a few percent on 3 s steps.

## The latency probe took a late burst for the next one

`probe_calibration` failed once at load 103: against a 60 ms reflector the
probe read 48.5 ms for one burst. The reflector's timer had fired late
enough that the previous burst, never counted, arrived after the next one
had started and was taken for it. The probe now cycles its bursts through
700, 1100 and 1500 Hz (whole cycles in 20 ms, so orthogonal in a frame) and
counts a loud frame only when the burst's own tone carries four times the
power of each other one; that holds down to 20 samples of tone in a frame.
Three runs passed after it, and a timestamp one tick late still fails the
case. The latency numbers taken before the fix were dropped from
`PERF.md`. Disabling the tone check is not caught deterministically: it
only matters when a burst arrives more than a gap late.

## Single-frame bursts and the jitter buffer

Under load the latency arm missed 9 of 50 bursts. The legs' jitter buffers
had dropped 864 of 4034 frames and every prefill had grown to 2: a sender
that stalls and then bursts overflows the depth of 3, and the one loud frame
is trimmed with the rest. The probe counts that as a missed burst rather
than retrying, since it is what a listener would hear. Nothing was changed;
it is worth a look on a quiet box, together with the prefill, which only
grows.

## Tables built lazily inside a call: reverted

`chappe_mix_g711` first built its frame tables on first use. Each
`persistent_term:put` stalls every process on the node, and the first frame
of the first conference paid for it: one tick 126 ms late, 13 skipped
ticks, and 35 to 40 frames trimmed per leg from the backlog. The tables are
now built by `chappe_mix_g711:init/0` from `chappe_mix_app:start/2`. After:
no overruns in the same diagnostic.

## Holding the playout point after an underrun: not enough

The first jitter buffer held the playout point on an empty tick so a late
packet would still play. That gives no slack: the late frame is consumed by
the very next tick, so a sender whose 20 ms clock is in phase with the
mixer's races the tick forever. Measured: 2 of 4 runs had 31 silent frames
in 100 at the receiver, with 29 frames trimmed per leg. Kept the hold and
added an adaptive prefill (start at 1 frame, grow by 1 per underrun up to
depth - 1), `underrun_adds_slack_test`.

## The load on the test box

Timing results from 2026-09-23 are void. The load average was 34 to 48,
from ten CPU-bound loops left by another session. Bare 20 ms
`erlang:send_after/4` timers with no mixer involved woke up to 164 ms late
(6 to 34 gaps over 30 ms in 250 ticks, 3 runs). A trace of one bad mixer run
showed the ticks on time and the test senders bursting: nothing for 110 ms,
then 5 packets in 50 us. `chappe_mix_SUITE` therefore judges a present tone
per 200 ms window and requires it in 70% of windows, while a leak must be
absent from every window. Rerun the suite and every bench arm on a quiet
box before quoting any number.

## rtpengine as the mixer: not on Ubuntu 24.04

Spike on 2026-09-23, three parties with distinct PCMU tones, Goertzel on
every receiver.

- Ubuntu 24.04 ships rtpengine 11.5.1.18. `subscribe request` with several
  from-tags gives one m-line per source, and one SSRC per source when all
  m-lines are answered on one port. The `mix` flag is ignored,
  `audio-player=always` re-encodes each stream separately, and `connect`
  and `mesh` are unknown commands. No N-1 mix is possible.
- rtpengine 26.0.1.21 (Debian sid) does it. Two calls with
  `audio-player=always` and `connect` with `directional,bidirectional`
  give every party a single SSRC at 50 pps carrying the others at about
  -13 dBFS and its own tone at -58 to -70 dBFS. Without the audio player
  the routing is right but nothing is mixed. The mix is a plain sum with no
  gain control.
- Verdict: a usable fallback only if we ship rtpengine 26.x ourselves.
  Script: a scratch escript, not kept.

## move_leg

`move_keeps_the_port` failed with `undef` before `chappe_mix:move_leg/3`
existed, and catches the mutation that skips
`gen_udp:controlling_process/2` in the hand-off (1100 Hz heard in 0 of 3
windows: the socket died with the first conference). Passed 3 of 3 at a
load average of 89.
- The source conference used to call the destination synchronously.
  `move_crossing` (two rooms swapping a leg at once), `move_to_self` and
  `move_to_dead` failed on that code: the crossing calls timed out, the
  self-call failed, and a dead destination crashed the source on
  `controlling_process`. The move now runs in a process of its own.
- The same stale beam reached across repos: a product repo builds chappe_mix
  through `_checkouts`, and a build made during a mutation run here kept
  the mutant. After mutating anything in this tree, remove
  `_build/*/checkouts/chappe_mix` in any repo that checks it out.

## RFC 3550 mixer rules (RTCP, CSRC, latch, collisions)

- Seen failing first: the new eunit modules (`chappe_mix_rtcp_tests` undef,
  `chappe_mix_rtp_tests` 29 failures: CSRC build and parse, and 27 second
  octets 192..199 and 205..223 not taken for RTCP) and the ten new suite
  cases against the old conference (the timestamp case with
  `{ts, 3270885907, 3270886067, 6}`: 6 ticks skipped, timestamp +160).
- RTCP was first sent to the address the far end's RTCP came from
  (symmetric). Reverted to the RTP remote, or its port + 1 on a pair: RFC
  3550 11 says the source port is not a destination.
- The first packet of a leg had M=1; RFC 3551 4.1 wants 0 without silence
  suppression, so M is always 0 now.
- Lint refused the conference at 36 record fields and 758 lines. Rather
  than add ignores, the per-leg RTP session moved to `chappe_mix_session`
  and the socket side of a leg to `chappe_mix_leg`.
- Jitter reads 0 in `rtcp_sender_reports`: a timestamp unit is 125 us and
  the loopback peer's timers are more precise than that. The formula is
  checked in `chappe_mix_rtcp_tests:jitter_test`.
- Live against rtpengine with the default `rtcp => mux` and an SDP without
  a=rtcp-mux, rtpengine logged "RTP packet with unknown payload type 72"
  four times (our SRs, dropped; N-1 still held). The live suite now opens
  its legs with `rtcp => pair`, and rtpengine then counts our reports on its
  RTCP ports with no error.
- Mutations, each on a fresh build: 33, two rewritten after they failed to
  compile, 28 caught. Not caught: NAME in every report instead of every
  third; the interval without its random factor (the bounds hold either
  way); sender counts kept after an SSRC change (no case waits for an SR
  after a collision); a new SSRC equal to one in use (random, a test would
  have to force the draw); a BYE from a leg that never sent (such a leg has
  no far end to send to in the suite).

## The demo gate rows on the wire (`chappe_mix_rfc_SUITE`)

- The compliance gate reads only CT results, so the rows proved by eunit
  alone (RTCP layout, jitter) were untested there. `chappe_mix_rfc_SUITE`
  walks the mixer's RTCP datagrams with its own parser and drives RTP from
  a plain socket; two codec cases call the session and RTCP modules where
  the row is a state the mixer never reaches on the wire (an empty RR:
  RTP goes out from the first tick with a far end) or a formula (A.8).
- Seen failing first: `rtcp_on_the_wire` (the collision BYE had no
  reason, so no reason padding to check) and `new_ssrc_not_seen` (no way
  to script the draw). The mixer now says "SSRC collision" in that BYE and
  takes `ssrc_draw`. The seven other cases passed on the code as it was
  and each was then shown to catch a mutation.
- Mutations, 18, all caught: extension skipped in half-words, A-law mask
  0x54, mu-law sign flipped, an 80-octet silence frame, any payload type
  mixed, an underrun counted as loss, the remote following the source,
  an RTCP length one word long, the padding bit set, an SDES chunk with no
  terminator or not word padded, an unpadded BYE reason, a BYE from a leg
  that never sent, a taken SSRC accepted, the old SSRC left out of the
  taken set, an SR before any RTP, jitter gain 1/8, jitter without abs.
  The two survivors of the first run (never-sent BYE, SSRC redraw) are
  among them.
- The padding check first asked for the exact set {1, 3, 4} nulls; the
  forwarded chunk of leg A carries its NAME on the first report, so it
  needed 2. The case now asks for a word of nulls and two other paddings;
  every chunk is still checked byte by byte.

## four_party under load: settle, then listen again on a short listen

`four_party` failed once in a full-suite run with `{missing, 1700, 3, 5}`
and passed alone. The endpoints share the mixer's node: a stalled test
sender underruns its leg's jitter buffer (silence, then a larger prefill),
its catch-up burst is trimmed past the depth of 3, and a mixer tick more
than a period late skips the frames it missed, so one second of listening
can come back as two or three 200 ms windows. One stall across a window
edge costs two windows, and 70% of 5 is 4. Twenty runs at load 24 to 211
(CPU burners plus `chappe_sip` CT) reproduced it once, as
`{missing, 440, 1, 2}`.

Not taken: lowering the 70% or the 3 dB, or one longer listen (a stall
still lands in it). Taken: `three_party` and `four_party` wait for two
200 ms polls in a row where every receiver meets the contract (up to 5 s,
as in the reference suite), then judge a 1 s listen with
`chappe_mix_test_tone:hears/3` unchanged, and listen again, up to three
times, only when a listen is short of presence or samples. A leak fails at
once in any listen.

- After: 20 of 20 at load 196 to 288, and 20 of 20 at load 64 to 165
  without the extra load. No run needed a second listen; the settle took
  402 to 1299 ms.
- Mutations, both caught: the mixer sending each party the full sum
  (`{leaked, 440, -14.7}` on the first listen) and sending only silence
  (`{missing, 1100, 0, 5}` after three listens; the settle gave up at 5 s).
## The far end wins the latch (`interop-mix` on Linux)

- `chappe_mix_live_SUITE` failed on ubuntu-24.04 CI and passed on macOS:
  one party's tone was missing at the others (-85 dB). On an OrbStack
  Ubuntu VM with docker.io it failed 2 runs in 12. The leg counters of a
  failing run: `remote => {127.0.0.1, 30050}`, `source => {172.18.0.2,
  30050}`, `filtered => 199`, `received => 1`.
- Why: Docker runs a userland proxy for the published ports, so what the
  mixer sends to 127.0.0.1 reaches rtpengine from 172.18.0.1 on a proxy
  port, while rtpengine sends to the SDP address (host-gateway) straight
  from the container. When rtpengine forwarded a packet before the mixer's
  first one reached it, that packet came from 172.18.0.2 and the leg
  latched it. Once rtpengine confirmed the proxy address it sent through
  the proxy, from 127.0.0.1, the far end set on the leg, and the latch
  dropped every packet. OrbStack on macOS shows both paths as 127.0.0.1.
- Kept: RTP from the leg's far end is always taken and moves the latch to
  it (RFC 4961: a symmetric peer sends from where it receives). A stray
  first sender no longer holds the leg. Thresholds unchanged.
- `far_end_wins_the_latch` failed on the old code (source stayed on the
  first sender). Mutations, 3, all caught: far end accepted but latch not
  moved, latch moved but far end still filtered, no source filter.
- After: Linux 30 runs, 30 passed; macOS 3 runs, 3 passed.

## A native reference (`interop/freeswitch`, `ref_capacity`)

- The product repo's FreeSWITCH image was amd64 only and ran emulated on arm64.
  `drachtio/drachtio-freeswitch-mrf` (FreeSWITCH 1.10.10) is multi-arch;
  its `/entrypoint.sh` edits the stock tree with sed, so the harness skips
  it and starts FreeSWITCH with `-conf` on one mounted `freeswitch.xml`.
- `energy-level` 0 and no comfort noise, so `mod_conference` mixes every
  member all the time as chappe_mix does. With that config both mixers gave
  the same Goertzel levels for every receiver and tone to 0.01 dB in all
  three `ref_tones` runs: the two N-1 mixes are sample for sample alike.
- `ref_capacity` first judged a step by the probe's packet gaps (p99 within
  5 ms of 20 ms, the bound `capacity` puts on tick lateness).
  `mod_conference` missed it with 5 rooms at 16% of its CPU (7.2 ms): it
  paces output with that spread at any load. Dropped as a criterion; the
  spread is reported.
- It then judged latency against the first step's p99 + 20 ms. Each step's
  probe room is new, and `mod_conference`'s latency moves by whole frames
  with the phase of its timers (p50 25.9 ms at 25 rooms, 60.3 ms at 100,
  with p99 within 2 ms of p50 in both): the ramp stopped on a phase, not
  on load. Replaced by p99 within one frame of the same room's p50. The
  first two `ref_capacity` runs of each mixer used the earlier judge; their
  step lines are re-judged in `PERF.md`.
- The docker API answers an HTTP/1.0 stats request with a chunked body, and
  a one-shot stats call can take long enough to skew a window timed around
  it: the CPU share is taken from the stats' own `read` time, and the
  senders' rate from timestamps around the `sent` reads.
- The arm's load check reads the VM's load when it runs in the bench
  container, which on macOS leaves out the host; `ref.sh vm` checks the
  host's load first. After a `ref_capacity chappe` ramp the VM's own load
  sat above 3.5 for a minute (the peer's senders), so an `fs` run straight
  after it was refused three times.
- Mutation of the `ref_capacity` judge: chappe_mix sending each leg
  silence instead of the N-1 mix (`own/3` returning zeros). The probe heard
  0 of 10 bursts, B still got a packet per frame, and the ramp reported
  `none_in_budget` at the first step. On the other side, the unmutated
  `mod_conference` broke the judge by itself at 100 rooms (p99 73 to 80 ms
  above p50 at 92 to 95% of its CPU).

## Where the capacity ceiling comes from

- Read first as timing: the `capacity` ramps stopped at a reported
  scheduler utilisation of 0.46 to 0.50, so the scheduler looked half idle
  while ticks ran tens of ms late. It was the arm: `total` in
  `scheduler:utilization/1` averages the normal scheduler with the idle
  dirty CPU scheduler that `+S 1` also starts. The arm now reports the
  normal schedulers; the ceiling is CPU.
- Scheduler busy wait (`+sbwt none`, `+sbwt very_long`) against the
  default: 200 to 250 conferences each way. Not a lever.

## The mix on lists, binaries or atomics: atomics kept

The whole compute of a tick (decode, sum, take out each leg's own frame,
encode) in six representations, same input, all checked to give the same
bytes. Scratch harness, best of 5, `+S 1`, load 4.4 (void as numbers, the
order held at load 4.8 too):

| representation | 4 legs | 16 legs | 64 legs |
| --- | ---: | ---: | ---: |
| lists, as the mixer had it | 30.7 us | 144.5 us | 629.7 us |
| lists, subtract and encode in one pass | 23.3 us | 114.2 us | 473.5 us |
| binaries of decoded samples | 28.8 us | 108.5 us | 418.6 us |
| binaries, code words kept, decode on the fly | 27.3 us | 104.0 us | 423.2 us |
| atomics sum, decoded lists kept | 23.4 us | 111.7 us | 477.5 us |
| atomics sum, code words kept, decode on the fly | 19.9 us | 82.3 us | 335.2 us |

- Kept: the last, as `chappe_mix_dsp`. A binary comprehension builds a new
  sum binary per leg; `atomics:add/3` adds in place, and keeping each
  leg's code words instead of a decoded copy saves the allocation twice.
- Interleaved in the mixer (`PERF.md`): `mix_cost` -31% at 4 legs and -45%
  at 64; capacity in budget 275 in 4 of 5 launches against 1 of 5 before,
  275 in the best launch of both. Both new thresholds missed.
- `chappe_mix_dsp_tests` failed 13 of 13 with no `chappe_mix_dsp`. Three
  mutations, all caught: the high clip at 30000 (11 failures), the own
  frame added instead of taken out (11), one sample skipped past the end
  of a short frame (10). A first clip mutation (32767 to 32766) survived
  and is equivalent: both samples encode to the same code word in both
  laws.

## A NIF for the mix: not written

- The best a NIF could do is a mix that costs nothing. A scratch build with
  `chappe_mix_dsp` returning a fixed frame ran out of scheduler at about
  410 conferences, short of the 500 threshold it was meant to reach
  (`PERF.md`). Not written: the C, its crash radius and its build would
  buy at most 310 to 410.
- Where the time goes then is the UDP send: `port_command` is a third of
  the conferences' time under `tprof`, and `gen_udp:send/4` resolves the
  address on every packet. Next to try, each against `capacity`
  interleaved: a connected socket per leg (`gen_udp:connect/3`, then
  `send/2`), and the `socket` module's `sendto` instead of the inet driver.

## The send path: connected sockets, the socket backend

- E1, connect each leg's socket to its far end on the first send and send
  with `gen_udp:send/2`: the scheduler 15% less busy at 200 conferences.
  Not kept: a connected UDP socket makes the kernel drop packets from any
  other address, so the leg could no longer move its latch to a far end
  that changes address (`far_end_wins_the_latch`, RFC 4961). Keeping it
  would need a reconnect when the source moves, and a way to see a packet
  from the new address in the first place.
- E2, `{inet_backend, socket}` on the leg sockets: no change (0.68 to 0.73
  against 0.68 to 0.71). E3, the same plus `socket:sendto/3` on the socket
  under it, skipping the `gen_udp` wrapper: no better (0.69, 0.77). The
  `socket` NIF costs what the inet driver costs here.
- Capacity ramps were dropped for this comparison: on a box whose load
  spikes, one late tick ends a ramp at any step. Holding a fixed number of
  conferences and reading the scheduler gave launches within 0.03 of each
  other.
- Where that leaves the 500 threshold: no mix and the best send path
  together project to about 450 on one scheduler. Reaching 500 needs a
  change in shape (fewer packets or system calls per tick), or the
  threshold read per core over several schedulers.

## element/2 for every per-sample lookup: kept

- `binary:at/2` on the 64 KiB encode table and `atomics:get/2` per sample
  per leg were the two biggest calls left in the mix. A 65536-tuple encode
  table and the sum read out once into a 160-tuple make both `element/2`.
  The clip is inlined and each output is built by binary append. Compute
  -30% at 4 legs and -45% at 64 against the atomics-only version (scratch
  harness, load 4, void; see `PERF.md`).
- Cost: 512 KiB per law of `persistent_term`, built once at start.
- `chappe_mix_dsp_tests` against three mutations of the new code: high
  clip at 30000 (11 failures), own frame added (11), one sample skipped
  past a short frame (10).

## Packets of any size: a jitter buffer keyed by timestamp

- The buffer counted packets, so a 30 ms sender underran every third tick
  (a whole silent frame, and the leg cut each packet to 20 ms on top) and
  a 10 ms sender played half-silent frames and overflowed the depth. It now
  keeps packets by extended RTP timestamp and pops 160 samples, whatever
  the packet size. A 20 ms packet right at the playout point is returned
  as it came, so 20 ms input takes the same path and the eleven existing
  `chappe_mix_jbuf_tests` pass unchanged (push/4 stays, placing a one
  frame packet by its sequence number).
- First version played what it had when the buffer ran out inside a frame,
  padded with silence. Against a 30 ms sender that is a 10 ms gap in every
  other frame, and the 30 ms packet that comes next then starts behind the
  playout point. Kept instead: a frame the buffer cannot fill is an
  underrun (silence, the prefill grows), and the part already there waits
  for the rest (`half_frame_waits_test`).
- A timestamp gap is loss or a silence-suppression pause, and only the
  sequence numbers tell which: playing a pause out as silence would add its
  whole length to the latency once the talker is back. The playout point
  jumps to the next packet less the time of the packets missing before it
  (`suppression_test`, `loss_after_pause_test`).
- The depth bound in samples first trimmed a 200 ms sender: the next
  packet arrives while a frame of the last is still to play, the two hold
  1760 samples against a bound of 480, and the older one went with its
  last 20 ms. Found by the mutation run (the suite case passed by phase).
  The bound is now the depth plus what the newest packet holds over a
  frame, which is the depth for 20 ms packets
  (`two_hundred_ms_back_to_back_test`).
- An `underruns` counter is new: empty ticks once the stream has played.
- Seen failing first: 9 new `chappe_mix_jbuf_tests` (undef), the three
  `chappe_mix_rfc_SUITE` sender cases (30 ms: 33 frames of 100 with a
  10 ms run of silence; 10 and 200 ms: the tone missing in every window),
  `chappe_sip_media_SUITE:conference_ptime` (a maxptime of 10 answered),
  `chappe_mix_live_SUITE:thirty_ms_n_minus_one` (1100 Hz missing in 4 of
  10 windows behind rtpengine) and `chappe_mix_ref_SUITE:
  thirty_ms_same_detection` (1100 Hz missing at both receivers, 34 of 100
  frames short of it, against 0 through `mod_conference`).
- Mutations, 12, all caught in the end: resume ignoring the missing
  packets (3 failures), never jumping a pause (2), a half frame played
  (1), the trim bound without the packet size (1), a single packet trimmed
  (7, and `sender_200ms`), the leg keying by sequence number (three suite
  cases), the backward timestamp wrap not extended (1), loss filled with
  code 0 (1), maxptime not checked and ptime not passed to the leg
  (`conference_ptime`). An underrun counted before the first frame
  survived the first run and got `no_underrun_before_start_test`; a first
  mutation of the timestamp extension did not compile and was rewritten.

## A soft limiter: a static curve cannot meet the distortion row (replaced)

- Kept, as planned: a static soft knee on what each listener hears,
  identity up to -6 dBFS and tanh toward full scale above, folded into the
  65536-entry encode table. A sum past 16 bits (a clipping room) takes a
  slower path: the curve computed, then the plain encoder, with the law
  read from a 65537th element of the table. The common path is the same
  `element/2` as before.
- Measured before the code, in a Python model of the dsp on 8 tones at
  -6 dBFS (300 to 2300 Hz, whole cycles in 1 s, mu-law): the sum is at
  full scale RMS and peaks near 2.7 times full scale. THD+N with the hard
  clip -10.4 dB; tanh knee at -12, -6, -3 dBFS -11.6, -11.0, -10.5 dB; a
  rational knee -10.6 to -10.9 dB. No static curve gets near -26 dB: with
  the signal at full scale RMS, any memoryless compression into 16 bits
  distorts most samples. The -6 dBFS knee was taken as the middle way
  between leaving normal rooms alone and bending a loud one.
- In the same model, a per-listener gain set from each frame's peak
  (instant attack, release over 25 frames) gives -37.8 dB: the tones are
  scaled, not bent. That is not a static curve (it needs a peak per
  listener per tick and a gain per sample), so it is not in this change;
  it is the measured way to the threshold if the row is to be met.
- In the mixer (`chappe_mix_dsp_tests:limiter_distortion_test`, 50 frames
  of the same room through the real dsp): hard clip -10.19 dB, limiter
  -10.67 dB. The distortion row is missed.
- A lone talker louder than -6 dBFS now comes back through the curve, so
  `chappe_mix_rfc_SUITE:g711_octets_through_the_mix` and
  `silence_suppression_resume` (their test frame spans every code word)
  expect the limited frame: decode, `limit/1`, encode.
- The equivalence test keeps the byte match against the old list mix for
  every sample under the knee, the hard clip included, and checks the
  rest against the reference put through `limit/1`, plus sign, no louder
  than the hard clip and no quieter than the knee. Seen failing first:
  `limit/1` undefined, and the distortion case equal to the hard clip
  (-10.19 dB both).
- Mutations, 6, all caught: knee at -12 dBFS (11 failures) and at -3 dBFS
  (2), samples past 16 bits hard clipped (10), the table without the curve
  (11), the negative side clipped (2), the curve overshooting full scale
  (12).

## RFC 4733 events: forwarded on arrival, one timestamp per event

- Event packets are forwarded when they arrive, not on the tick: the
  conference sends each one on every other leg that negotiated
  telephone-event and lists its codes, under that leg's SSRC and next
  sequence number, with the source's SSRC as the CSRC. The payload is
  passed byte for byte; nothing in it is rewritten.
- The timestamp: at an event start (M set, or the first packet seen) the
  offset from the source's timestamps to each listener's output clock
  (the timestamp of its next mixed packet) is taken and kept, so every
  packet of the event, long-event segments and end retransmissions
  included, has one timestamp on each leg. Taking the offset on every
  packet would move the timestamp within an event; keeping one offset for
  the whole call would carry a sender's timestamp jump (a pause) onto the
  listener's clock. The suite case makes A's timestamps jump by a second
  between the two digits, which tells the two apart.
- A muted leg's events are not forwarded, as its audio is not heard. No
  case covers it.
- Seen failing first: `dtmf_forwarded` (no event counter, and no event
  forwarded), `conference_dtmf` (no telephone-event in the answer),
  `dtmf_through_rtpengine` (B got none of the 6 event packets).
- Forwarding delay on loopback, 12 packets at a load of 30 (void as a
  number): at most 521 us.
- Mutations, 11, all caught: events not forwarded, the M bit dropped, the
  offset taken on every packet, the offset not reset at a new event, the
  events list ignored, no CSRC, an event taking no sequence number, events
  mixed as audio, an answer without fmtp, the offer's events list not
  read, the mixer's offer without telephone-event. Three first versions
  did not compile (an unused function or variable) and were rewritten.

## a=rtcp and cascaded CSRCs

- `rtcp_remote` (a leg option, and a key of the map `set_remote/3` now
  takes) sends a leg's RTCP where a media-level a=rtcp says, on the RTCP
  socket of a pair or the RTP socket of a muxed leg. A new far end without
  one drops the old one: an a=rtcp belongs to the SDP it came in.
- An input packet's CSRC list is kept per leg (from the last audio packet)
  and a talking leg contributes it in place of its own source's SSRC; the
  listener's own contributions are left out and the list stays capped at
  15. The SDES chunks of cascaded CSRCs are not forwarded: only a leg's
  own source has one.
- Seen failing first: `cascaded_csrcs` (C's list stayed [A, B]),
  `rtcp_to_the_given_port` (no RTCP at the given port), and
  `chappe_sip_media_SUITE:conference_rtcp_port` (no `rtcp_remote`).
- Mutations, 8, all caught: input CSRCs ignored, input CSRCs not kept,
  the listener not excluded, the a=rtcp port not used, `set_remote/3` not
  taking it, a=rtcp read on a muxed m-line, its address ignored, an
  answer's a=rtcp not passed to the leg.

## Leg directions and per-pair relations

- A leg's `direction`, from the room's side, replaces the mute flag:
  sendrecv, sendonly (hears, is not mixed: a recorder), recvonly (is
  mixed, is sent nothing: a prompt player, or a deaf party), inactive.
  `mute/3` is kept and moves the direction (sendrecv to sendonly, recvonly
  to inactive, and back). A leg the room sends nothing gets no RTP at all,
  as an SDP recvonly asks; its RTCP still flows.
- `relate/4` keeps one leg from hearing another: `chappe_mix_dsp:encode/3`
  takes a list of frames to take out of the sum (their own sum, taken out
  sample by sample); one frame keeps the path it had. The CSRC list and
  event forwarding follow the same relations, and a sendonly or inactive
  leg's events are not forwarded.
- `injected => true` marks a leg whose media the room itself plays: the
  listeners' CSRC lists name the mixer's own SSRC for it (R3550-21).
- First version opened a leg given `direction => sendonly` as sendrecv:
  the mute flag was applied as "unmute" when it was false. `directions`
  failed with the recorder's tone leaking; `mute_is_a_direction` had not
  opened a sendonly leg. Mute is now applied at open only when set.
- `chappe_mix_conf` passed 500 lines; the mix and the event forwarding
  moved to `chappe_mix_room`, plain functions over the legs map.
- Seen failing first: the four `chappe_mix_SUITE` cases (`directions`
  leaked the sendonly leg's tone, the others undef or no `direction`),
  `several_left_out_test`, and the two facade cases
  (`conference_directions`, `conference_deaf_relate`).
- Mutations, 13, all caught in the end: a leg the room sends nothing
  still sent, a sendonly leg mixed, nohear frames not taken out, nohear
  sources left in the CSRC list, injected media named by its own SSRC,
  muting a recvonly leg doing nothing, several frames added back instead
  of taken out, events past a relation, a muted leg's events forwarded,
  the peer's direction not turned round, the session-level direction
  ignored, deaf not applied, a relation across rooms. The first survived:
  `chappe_mix_leg:send/3` refused a recvonly leg as well, a second guard
  that hid the first; it was removed.

## Talker events

- Opt-in: a conference started with `events => Pid` (or given one with
  `chappe_mix:events/2`) takes each frame's energy while it sums it,
  `chappe_mix_dsp:add_level/3`, and runs a hysteresis per leg: talking
  after 60 ms over -40 dBFS RMS, not talking after 300 ms under it, both
  configurable. Without a subscriber the sum goes through `add/3` as
  before and no level is computed. A leg removed while talking is
  reported as stopped. The facade subscribes a room when a join asks for
  `talk_events` and sends that call `{chappe_sip_media, {talking, Room,
  true | false}}`.
- Seen failing first: `chappe_mix_SUITE:talker_events` (no event) and
  `chappe_sip_media_SUITE:conference_talking` (none relayed). The suite
  case first asked only for an upper bound on detection; a mutation that
  started talk on the first frame passed it, so it also asks for at least
  40 ms (three frames, less the one the jitter buffer holds) and at least
  260 ms to stop.
- Mutations, 7, all caught: talk starting on the first frame, stopping
  after 100 ms, the threshold inverted, the energy not summed, no stop
  when a talking leg goes, events sent to calls that did not ask, the
  room not subscribed.
- `cascaded_csrcs` failed once in a full run: it read the last datagram
  at C right after the leg's counters showed it sent. It now waits for
  the datagram.

## The tick timer and the prefill: built, not decided

- Timer: arming at the millisecond ceiling (`-convert_time_unit(-At)`)
  instead of truncating. `tick_never_early` saw every traced tick early
  with truncation (45 to 454 us) and none of 50 with the ceiling. Whether
  the ceiling keeps p99 lateness inside the tick jitter row needs the
  `jitter idle` and `jitter capacity` A/B, which never ran (box over the
  load limit, see `PERF.md`).
- Prefill: after 500 frames (10 s) without an underrun, a prefill that
  grew is taken back by one and the frame of slack it held is skipped,
  so the latency comes back down a frame. Tests: `prefill_shrinks_test`,
  `prefill_floor_test`, `prefill_stays_by_default_test`. Whether `latency`
  p99 improves without more underruns in `loss` needs the A/B, which
  never ran.
- The plan keeps each only on its A/B, so both are in the mixer behind
  conference options, off by default (`tick_ceiling`, `prefill_shrink`).
  The A/B builds (the mixer at the commit before, with only the ceiling,
  with only the shrink) and the interleaving script are in the session
  scratchpad; `bench/README.md` has the procedure.
- Seen failing first: `tick_never_early` (every tick early) and
  `prefill_shrinks_test` (the prefill stayed at 2). A first lint run
  refused a duplicated frame assembly between the skip and the playout;
  both now go through `next_frame/1`.
- Mutations, 8, all caught: the timer truncated again, the prefill never
  shrinking, the shrink without the skip (a first version did not
  compile and was rewritten), the prefill shrinking to 0, an underrun
  not resetting the count, the shrink on by default, `tick_ceiling`
  ignored.

## A gain per listener in place of the static curve: kept

- The static knee (`981adc4`) missed the -26 dB row at -10.67 dB and is
  removed, `chappe_mix_g711:limit/1` and its tests with it: the encode
  table is the plain one again. In its place a gain per listener, kept in
  the leg across ticks: unity until a frame would clip, then at once the
  gain that puts the frame's peak at full scale, then back by a release
  step per frame, never above unity. `chappe_mix_dsp:encode/4` takes the
  gain and returns the next one; at unity the encode is the old path,
  which fails with `clip` at the first sample past 16 bits, and only then
  is the frame scaled. The hard clip stays behind it.
- Tried in the dsp, on the loud room (see `PERF.md` for the table):
  release 0.4 dB a frame stepped at the frame start -27.60 dB; spread
  across the frame -28.42 dB; 0.2 dB a frame spread -29.22 dB (kept: a
  9 dB cut still undone in under a second); the attack spread too, with
  each sample capped at full scale so the frame start cannot clip,
  -18.85 dB (the cap is a per-sample clip again; reverted).
- `elvis` refuses `throw/1`; the clip escape is `error(clip)`, caught in
  `encode/4`. Only frames that clip pay for it.
- The equivalence test: every leg whose signal fits in 16 bits gets the
  old mix's bytes; a leg that would clip gets, byte for byte, its signal
  scaled by full scale over its peak (a fresh leg). The lone-talker
  frames of `chappe_mix_rfc_SUITE` never clip and expect the plain
  frame again.
- The first loud room used 300 to 2300 Hz, which repeat every 20 ms:
  every frame had the same peak and the gain never moved, so the
  stability case could not fail. The room now uses tones that make
  whole cycles in 1 s and not in 20 ms.
- Seen failing first: `encode/4` undefined (every dsp case), and
  `loud_room_gain` (no `gain` in the leg).
- Mutations, 9: gain above unity allowed, no release, attack disabled,
  release twice as fast, the gain not kept across ticks, the release not
  spread across the frame (survived the first run; the recovery case now
  checks each released frame byte for byte), the attack spread from the
  old gain: all caught. Removing the hard clip survived: with the gain,
  no scaled sample reaches past full scale, so the net is unreachable
  by construction and kept as a guard.


## The tick timer and the prefill: decided on GitHub runners

- The macOS box never went quiet (load 50 to 180), so the A/B ran on
  GitHub's 2 vCPU `ubuntu-24.04` runners (`.github/workflows/bench.yml`,
  `make bench-pass`), each option set per conference through
  `CHAPPE_MIX_BENCH_CONF` on one build instead of two trees, the sides
  swapped every round, 5 launches each. Numbers in `PERF.md`.
- `tick_ceiling`: 0 early ticks in 10 of 10 launches against 345 to
  1500 of 1500 truncated, p99 lateness at most 1.0 ms idle and 1.2 ms at
  100 conferences. Kept, and on by default.
- `prefill_shrink`: nothing to win in the `latency` arm on that box (the
  prefill never grew without it); in the `loss` arm, where it grows, the
  shrink gave the frame back and the underruns rose from 26 to 58 over
  5 launches. Reverted to what it was: built, off by default, not used.
- `tick_never_early` now checks the default instead of passing the
  option. Seen failing first with the old default (an early tick, at a
  load of 180). Mutation: the state's `tick_ceiling` defaulting to false
  while the first arm used true (every tick after the first armed
  truncated) failed with 50 early ticks.
- The limiter cost row is missed at 64 legs (+157%), not because a room
  that fits pays anything (`mix_cost fit`, a new variant: within 1.3% of
  the base at 4 and 64 legs), but because the arm's 64-leg room clips and
  the arm puts each listener's gain back to unity every tick, so every
  tick takes the attack and the scaled encode. The row is recorded as
  missed; the arm is unchanged.

## rtpengine 26.3 in the labs, the L16 gate and the band check

The 16 kHz room needs rtpengine to hand the mixer L16/16000 whatever the
caller speaks. Ubuntu 24.04's package, 11.5.1.18-1ubuntu1.2, has no L16 RTP
codec; upstream 13.x is the first with one.

- The lab image now builds upstream `sipwise/rtpengine` tag `mr26.3.1.4`
  (commit `1165c63`) on `ubuntu:26.04` (pinned by digest), the userspace
  daemon only: `mk-build-deps`, `dpkg-buildpackage -B`, install
  `ngcp-rtpengine-daemon`. `rtpengine --codecs`: L16, X-L16, opus, G722,
  PCMU and telephone-event fully supported. 26.x defaults `table` to -1,
  so no kernel table is tried. The compose command lines needed no change.
- What the upgrade broke, both in `make interop`'s siprec suite: the
  `siprec` flag of a subscription now relabels the streams `["0"]`,
  `["1"]`, `["2"]` (11.5 added the zero-based label beside the source
  one); and a `delete` reply with statistics is 10276 bytes for a
  three-stream publish with three forks. Inside the docker network it
  arrives; through the Mac's published UDP port (OrbStack) it never did,
  and the session's stop timed out. The session never reads those
  statistics, so its deletes now carry the `fast` flag (no statistics).
- Build: 101 s from nothing on the 14-CPU Mac (load 4 to 13), 101 s again
  on a builder held to 4 CPUs; apt (about 50 s) and the compile (22 to
  28 s) dominate. CI's interop jobs take 3 to 7 minutes against 45 to 75
  minute timeouts, so they build it without a layer cache.

The L16 gate, one NG offer and answer against the new daemon (a scratch
escript, not kept). The caller offers opus/48000/2 (96), G722/8000 (9),
PCMU (0) and telephone-event/8000 (101); the offer carries
`codec => #{mask => [<<"all">>], transcode => [<<"L16/16000/1">>,
<<"telephone-event/16000">>]}`. The mixer side answers with exactly what
it was offered.

- Toward the mixer: `m=audio ... RTP/AVP 97 98`, `L16/16000` and
  `telephone-event/16000` (fmtp 0-15), nothing else.
- Toward the caller: `opus/48000/2` alone. Its telephone-event/8000 is
  dropped: RFC 4733 events run on the audio codec's clock, and the caller
  offered none at 48000. The same offer without opus comes back
  `G722/8000` with `telephone-event/8000` (101). The caller keeps its
  wideband codec either way, and rtpengine transcodes to L16.

The band check (`chappe_mix_test_tone:band_check/2,3`): a 16 kHz probe of
1000 and 2500 Hz (the narrow band) and 5000 and 6000 Hz (above it),
Goertzel over 3200-sample windows, the median window per tone. A path
passes when each tone is within 3 dB of its calibration (6 dB through a
codec) and the bins at 2000 and 3000 Hz, where 6000 and 5000 Hz fold when a
path drops to 8 kHz, are 40 dB below the quietest tone.

- Written before the helper: the 7 eunit cases failed on `undef`.
- The identity path passes. A correct narrowband round trip (127-tap
  Blackman low-pass at 3.4 kHz, decimate to 8 kHz, zero-stuff, the same
  low-pass) fails on the high tones only. Naive decimation with
  sample-and-hold fails on both alias bins, at 3 and 6 dB: the folded tones
  land within 2 dB of full level.
- Mutations: the alias test turned off (limit raised by 1000 dB) failed the
  naive control; the Goertzel at 8 kHz instead of 16 kHz failed 5 of 7.
- On real codecs, two lab pjsua calling each other at a 16 kHz clock
  (`hd.sh`), the callee's recording judged over 4 s: G.722 and Opus pass
  at 3 dB (5000 and 6000 Hz within 0.6 dB, alias bins at -60 to -80
  dBFS), PCMU fails (5000 and 6000 Hz at -97 and -105 dBFS).
- The FreeSWITCH reference (`interop/freeswitch`, mod_opus and mod_spandsp
  loaded, codecs `OPUS,G722,PCMU,PCMA`): two G.722 pjsua in one room, one
  playing the probe, the other recording. In `wconf-<name>` (the
  `wideband` profile, 16 kHz) every tone arrives at -16.3 to -17.1 dBFS
  against -16.3 sent; in `conf-<name>` (`default`, 8 kHz, the control)
  1000 and 2500 Hz arrive at -16.3 and 5000 and 6000 Hz at -89 to
  -113 dBFS.
