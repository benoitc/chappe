# chappe_mix listening quality record

What listeners hear in a 16 kHz chappe_mix room, measured against the stock
FreeSWITCH 16 kHz room with speech, through the demo (`make demo`). Read it
before you claim a change to the HD path keeps quality, and measure again
after a change to the mixer's L16 path, to the rtpengine flags of a 16 kHz
room, or to rtpengine itself. Each run records its margins before its first
capture; a margin that is missed is recorded as missed, never moved after
the numbers arrive. `PERF.md` is the performance record, this page the
quality one.

## 2026-11-25: HD rooms, G.722 and Opus

### Margins, declared before any capture

Declared at 2026-11-25T06:36:44Z in the manifest
(`runs/hd-room-2026-11-25/manifest.json` of the taq checkout), before the
first capture of either arm: a pilot candidate run at 06:38 checked the
pipeline and was kept out of the manifest (`c9-...-pcmu`), and the trials
ran from 06:39. The reasons below were written in the manifest's margins
note at that time; this page copies them. taq reports the margins block's
sha256 as `37d441a36e01d688...`.

| Check | Margin | Why |
| --- | --- | --- |
| ViSQOL, paired difference (candidate minus baseline, per clip) | lower bound of the 95% bootstrap interval above -0.3 MOS | below the 0.38 NISQA drop taq measured between a G.722 and a PCMU path, so a narrowband hop fails; above the shift two runs of one path are expected to show |
| NISQA, paired difference | the same, -0.3 MOS | the same |
| Bandwidth, every candidate capture | 4-7 kHz share within 6 dB of the reference's | G.722 and Opus keep it within a few dB; a hop through 8 kHz reads 33 to 53 dB down |
| Level, every candidate capture | within 6 dB of the reference | a mixer gain fault shows as a level step |
| Clipping | at most 1e-4 of the samples | the gain control must not clip speech at -26 dBov |
| Dropouts | no gap in active speech longer than 40 ms | two 20 ms packets |
| Delay | not gated | taq live has no synchronized timestamps |

The pcmu-join conditions have one clip per arm: their scorers are reported,
not gated, and their bandwidth, level, clipping and dropout checks are
gated as above.

### What was measured

Two pjsua participants exchange known speech through one room of the
running demo:

- bob, the listener, calls first and records; 3 s later alice, the
  talker, calls and plays one clip (8 to 10 s at -26 dBov, 48 kHz source)
  and 2 s of silence; both hang up.
- `g722-to-opus`: alice on G.722 (pjsua clock 16 kHz), bob on Opus (clock
  48 kHz; rtpengine answers `opus/48000/2`, `useinbandfec=0; cbr=1`).
  `opus-to-g722` is the reverse.
- Baseline, room `1004`: rtpengine, then a FreeSWITCH endpoint per caller
  (FreeSWITCH picks G.722 or Opus from the caller's offer), then
  mod_conference `demo-hd-fs@wideband` (rate 16000, interval 20,
  energy-level 100).
- Candidate, room `1003`: rtpengine transcodes each caller to L16/16000,
  then chappe_mix `demo-hd` at 16 kHz.
- The eight pinned VCTK 0.92 clips (four female, four male speakers), each
  direction, in this order per clip: baseline rep 0, candidate, baseline
  rep 1, so a drift of the host hits both arms. 48 trials from 06:39 to
  06:57 UTC, then the four PCMU runs.

### Host and versions

| What | Version |
| --- | --- |
| Host | macOS 27.2, arm64, 14 cores, 48 GB; shared with other jobs, 1 min load 5.9 to 42.2 over the runs (median 8.2; above 14 only for three idle trials and the two last PCMU runs) |
| Docker | OrbStack, docker 29.8.2, linux/arm64; pjsua on the host network |
| chappe | `bee9adf` (the demo of this record on `7a8325a`; the later commits of the branch do not touch the measured path), Erlang/OTP 29.1.2 on the host |
| FreeSWITCH | `drachtio/drachtio-freeswitch-mrf@sha256:2f1583c3...` (image `sha256:534f085e...`), 1.10.10 git `4cb05e7`, G.722 from mod_spandsp, Opus from mod_opus |
| rtpengine | 26.3.1.4+0~mr26.3.1.4, `chappe-rtpengine-interop` (image `sha256:9cf8018b...`) |
| pjsua | 2.15.1, `taq-pjsua:2.15.1` (`sha256:45c94f10...`); the PCMU caller `chappe-hd-pjsua` (`sha256:8c877774...`, `apps/chappe_sip/interop/pjsua`) |
| taq | 0.1.0 at `cf11b89` |
| ViSQOL | 3.3.3, speech mode, `taq-visqol:3.3.3` (`sha256:f5486dda...`), verified |
| NISQA | code and weights at `fe84f0f2`, unverified |

### Results

The paired difference is candidate minus baseline, averaged per clip, with
its 95% bootstrap interval over the 8 clips; the reference variation is
baseline rep 1 minus rep 0. Bandwidth is the 4-7 kHz share of the capture
against the reference's, at the listener (bob), median and worst of the
arm's captures; the edge, the lowest of the arm's, is the highest 250 Hz
band whose capture-to-reference ratio stays within 10 dB of the 300 to
3000 Hz one.

| Direction | Check | Baseline (1004) | Candidate (1003) | Paired difference [95%] | Reference variation [95%] | Margin | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| G.722 to Opus | ViSQOL | 4.125 | 4.382 | +0.257 [+0.203, +0.318] | -0.004 [-0.057, +0.057] | -0.3 | pass |
| G.722 to Opus | NISQA | 3.981 | 4.056 | +0.075 [-0.091, +0.274] | +0.374 [-0.024, +0.865] | -0.3 | pass (unverified; its reference variation is wider than the margin) |
| G.722 to Opus | bandwidth at the Opus listener | -3.0 dB, worst -3.5, edge 7.0 kHz | -2.7 dB, worst -3.0, edge 7.25 kHz | | | -6 dB | pass |
| G.722 to Opus | level | -6.0 to -6.4 dB | -6.0 to -6.4 dB | -0.14 to +0.04 dB per clip | | 6 dB | **missed**: 8 of 8 candidates (and 14 of 16 baselines) |
| G.722 to Opus | longest gap | 0 to 90 ms | 0 ms | | | 40 ms | pass |
| Opus to G.722 | ViSQOL | 4.194 | 4.383 | +0.190 [+0.099, +0.279] | -0.015 [-0.048, +0.020] | -0.3 | pass |
| Opus to G.722 | NISQA | 3.790 | 3.853 | +0.063 [-0.121, +0.238] | +0.009 [-0.363, +0.469] | -0.3 | pass (unverified; its reference variation is wider than the margin) |
| Opus to G.722 | bandwidth at the G.722 listener | -2.8 dB, worst -3.1, edge 7.25 kHz | -2.8 dB, worst -3.4, edge 8.0 kHz | | | -6 dB | pass |
| Opus to G.722 | level | +5.6 to +6.0 dB | +5.6 to +6.0 dB | -0.10 to +0.03 dB per clip | | 6 dB | pass |
| Opus to G.722 | longest gap | 0 to 60 ms | 0 ms | | | 40 ms | pass |

No clipping in any capture. `taq compare` exits 1 (regression), on the
level check alone. With `--require-verified` NISQA counts as missing:
ViSQOL and the checks are the same, the opus-to-g722 condition is
incomplete and the verdict is still regression, on the level check.

What the numbers say:

- Both rooms carry the band: every capture keeps 4-7 kHz within 3.5 dB
  of the reference, and the candidate's edge is at or above the
  baseline's.
- The level check is missed in both arms alike, and the margin was the
  wrong measure. pjsua's G.722 codec is 6 dB off the others (pjmedia
  shifts its PCM by one bit; the HD live suite calibrates the band check
  around it): a G.722 talker arrives 6 dB low and a G.722 listener hears
  6 dB high, in either room. Per clip the two arms differ by 0.14 dB at
  most. The margin compared each capture with the reference where it
  should have compared the arms, or allowed for the codec. It stays
  missed for this run; declare the next run's level margin on the
  difference between the arms.
- mod_conference drops speech: the baseline has gaps of 40 to 90 ms in
  active speech on six of the eight clips from G.722 to Opus and three
  from Opus to G.722, most of the same length in both of its runs (p245
  90 ms, p248 70 ms, p326 60 ms each time), where the candidate has none.
  That fits its energy gate (`energy-level` 100) cutting quiet syllables,
  and is likely part of ViSQOL's lead for the candidate. A baseline gap
  does not gate.
- NISQA moved by +0.37 between two baseline runs of the same path
  (G.722 to Opus): its intervals are wider than the margin, so its pass
  is weak evidence. ViSQOL's reference variation stays within 0.06.

### The PCMU caller joining and leaving

One run per arm and direction (clip p225): a silent PCMU pjsua joins the
room 1.8 to 3.0 s after the talker's INVITE and leaves 5 s later, inside
the clip (from the SIP trace). It heard the talker (median -27 to
-32 dBFS over its 65 to 89 active frames).

| Direction | Arm | Bandwidth at the HD listener | Level | Longest gap | ViSQOL | NISQA |
| --- | --- | --- | --- | --- | --- | --- |
| G.722 to Opus | baseline | -1.7 dB | -6.04 dB | 0 ms | 3.848 | 2.493 |
| G.722 to Opus | candidate | -1.7 dB (pass) | -6.01 dB (missed, as above) | 0 ms | 4.075 | 3.346 |
| Opus to G.722 | baseline | -1.5 dB | +5.97 dB | 0 ms | 3.907 | 3.646 |
| Opus to G.722 | candidate | -1.6 dB (pass) | +5.93 dB (pass) | 0 ms | 4.030 | 3.213 |

The HD pair keeps its band while the PCMU caller is in, in both rooms. The
scorers are not gated on one clip; the NISQA swings (+0.85, -0.43) are of
the size of its reference variation. The last two runs ran at a load of 23
and 42.

### Worst pairs

Replay these against the clip (paths under the taq checkout's
`runs/hd-room-2026-11-25/`):

- ViSQOL: p248, Opus to G.722, -0.043 (the one clip where the candidate
  scores below the baseline): `b0-opus-to-g722-vctk092-p248-01/bob.rx.wav`
  and `c0-opus-to-g722-vctk092-p248-01/bob.rx.wav`.
- NISQA: p225 with the PCMU caller, Opus to G.722, -0.433:
  `b0-opus-to-g722-vctk092-p225-01-pcmu/bob.rx.wav` and
  `c0-opus-to-g722-vctk092-p225-01-pcmu/bob.rx.wav`.
- Bandwidth: p226, Opus to G.722, candidate, -3.44 dB:
  `c0-opus-to-g722-vctk092-p226-01/bob.rx.wav`.
- Gaps: p245, G.722 to Opus, baseline, 90 ms in both runs:
  `b0-g722-to-opus-vctk092-p245-01/bob.rx.wav`.

The evidence stays in the taq checkout (git-ignored): each run directory
(`run.json`, the SDP of each leg, the pjsua logs, the WAVs), `sip.pcap`
(the SIP of every call and the rtpengine NG commands, from the docker
host), `load.log`, and the results under `out/hd-room-2026-11-25` and
`out/hd-room-2026-11-25-verified` (`results.json`, `summary.txt`).

### Reproduce

You need the demo, the taq checkout (`uv sync --extra nisqa`, `taq
prepare`, `taq fetch-weights nisqa`, the images `taq-pjsua:2.15.1` and
`taq-visqol:3.3.3`), and port 5060 free (here it was not: the demo ran on
5080).

```sh
DEMO_SIP_PORT=5080 make demo        # in its own terminal
```

`taq live` enables one codec for every participant. This wrapper, kept
next to the runs (`$R/live2.py`, with `run1.sh` and `campaign.sh`, which
drive the whole run below), gives the talker (alice) and the listener
(bob) their own codec and clock rate and leaves the rest of `taq live` as
it ships:

```python
import os, sys
from taq import cli, live

_orig = live.pjsua_args

def pjsua_args(name, target, codec, clock_rate, *rest):
    role = "TALKER" if name == live.NAMES[0] else "LISTENER"
    codec = os.environ.get(f"TAQ_{role}_CODEC", codec)
    clock_rate = int(os.environ.get(f"TAQ_{role}_RATE", clock_rate))
    return _orig(name, target, codec, clock_rate, *rest)

live.pjsua_args = pjsua_args
sys.exit(cli.main(sys.argv[1:]))
```

One trial (here baseline, rep 0, G.722 talker to Opus listener), from the
taq checkout, with `R=runs/hd-room-2026-11-25` holding the manifest and
its margins before the first run:

```sh
TAQ_TALKER_CODEC=G722 TAQ_TALKER_RATE=16000 \
TAQ_LISTENER_CODEC=opus TAQ_LISTENER_RATE=48000 \
uv run python $R/live2.py live sip:1004@127.0.0.1:5080 \
    --out $R/b0-g722-to-opus-vctk092-p225-01 --clip vctk092-p225-01 \
    --codec G722 --clock-rate 16000 --listeners 1 \
    --sip-port 5170 --rtp-port 40000 --arm baseline --rep 0 \
    --condition-id hd-room/g722-to-opus/idle/clean \
    --path "pjsua > rtpengine > FreeSWITCH mod_conference demo-hd-fs@wideband (16 kHz) > rtpengine > pjsua" \
    --meta $R/meta-baseline.json --load idle --impairment clean --seed 0 \
    --into $R/manifest.json
```

- The candidate calls `sip:1003@...` with `--arm candidate` and
  `meta-candidate.json`; `opus-to-g722` swaps the two codecs and rates.
- For each of the eight clips and both directions, run baseline rep 0,
  candidate rep 0, baseline rep 1, in that order.
- The PCMU runs (`--load pcmu-join`, condition
  `hd-room/<dir>/pcmu-join/clean`) start this 5 s after `taq live`:

  ```sh
  apps/chappe_sip/interop/pjsua/hd.sh -c PCMU -r 8000 -d 5 \
      -l 25080 -m 25500 -N hd-pcmu -o pcmu-caller/pcmu.wav \
      sip:1003@127.0.0.1:5080
  ```

- The SIP and NG trace, for the whole session, from the docker host:

  ```sh
  docker run -d --rm --name hd-tcpdump --net host -v $PWD/$R:/out \
      nicolaka/netshoot:v0.13 tcpdump -i any -n -s 0 -w /out/sip.pcap \
      'udp and (port 5080 or port 15081 or port 15082 or port 22223 or portrange 5170-5175 or port 25080)'
  ```

Then score:

```sh
uv run taq compare $R/manifest.json --out out/hd-room-2026-11-25
uv run taq compare $R/manifest.json --out out/hd-room-2026-11-25-verified \
    --require-verified
```
