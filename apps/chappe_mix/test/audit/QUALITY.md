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

Declared at 2026-11-25T06:36:44Z by writing the manifest
(`runs/hd-room-2026-11-25/manifest.json` of the taq checkout) with its
margins and no trials, before the first capture of either arm; that file
is [`quality/manifest-margins.json`](quality/manifest-margins.json). A
pilot candidate run at 06:38 checked the pipeline and was kept out of the
manifest (`c9-...-pcmu`), and the trials ran from 06:39. The reasons below
were written in the manifest's margins note at that time; this page copies
them, with what this record adds in brackets. taq reports the sha256 of
the margins block (its JSON with sorted keys) as
`37d441a36e01d6880d6ba595adb78fc2766332ad01c3fbd7dd51d956e7fa6f9c`.

| Check | Margin | Why |
| --- | --- | --- |
| ViSQOL, paired difference (candidate minus baseline, per clip) | lower bound of the 95% bootstrap interval above -0.3 MOS | below the 0.38 NISQA drop taq measured between a G.722 and a PCMU path, so a narrowband hop fails; above the shift two runs of one path are expected to show [the reason is NISQA's: no ViSQOL drop was measured to back this margin, and on that same G.722 against PCMU test ViSQOL scored the PCMU arm 0.38 higher (taq's README), so this margin does not catch a narrowband hop; the bandwidth check does] |
| NISQA, paired difference | the same, -0.3 MOS | the same |
| Bandwidth, every candidate capture | 4-7 kHz share within 6 dB of the reference's | G.722 and Opus keep it within a few dB; a hop through 8 kHz reads 33 to 53 dB down |
| Level, every candidate capture | within 6 dB of the reference | a mixer gain fault shows as a level step |
| Clipping | at most 1e-4 of the samples | the gain control must not clip speech at -26 dBov |
| Dropouts, every candidate capture | no gap in active speech longer than 40 ms | two 20 ms packets [a baseline gap is reported, not gated] |
| Delay | not gated | taq live has no synchronized timestamps |

Bandwidth, level, clipping and dropouts gate the candidate's captures
only: taq counts a baseline capture past a limit and reports it, but does
not fail on it. The pcmu-join conditions have one clip per arm: their
scorers are reported, not gated, and their bandwidth, level, clipping and
dropout checks are gated as above.

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
| chappe | `bee9adf` (`bee9adf8d59465b96c0c551391032f888534c19d`), the first commit of this record's branch (the demo's HD rooms), on top of `7a8325a` (`7a8325a50876245054d8acd868d7c91b102ae24e`), which is main once #87 (16 kHz rooms in L16) merged; the later commits of the branch do not touch the measured path. Erlang/OTP 29.1.2 on the host |
| FreeSWITCH | `drachtio/drachtio-freeswitch-mrf@sha256:2f1583c3...` (image `sha256:534f085e...`), 1.10.10 git `4cb05e7`, G.722 from mod_spandsp, Opus from mod_opus |
| rtpengine | 26.3.1.4+0~mr26.3.1.4, `chappe-rtpengine-interop` (image `sha256:9cf8018b...`) |
| pjsua | 2.15.1, `taq-pjsua:2.15.1` (`sha256:45c94f10...`); the PCMU caller `chappe-hd-pjsua` (`sha256:8c877774...`, `apps/chappe_sip/interop/pjsua`) |
| taq | 0.1.0 at `cf11b89` (`cf11b89ac1b9a8dd86ca0dc3c7e4c1cb21b558d4`), a local repository with no public remote (see Reproduce) |
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
| G.722 to Opus | NISQA | 3.981 | 4.056 | +0.075 [-0.091, +0.274] | +0.374 [-0.024, +0.865] | -0.3 | inconclusive: two runs of the baseline differ by more than the margin (taq says pass; unverified) |
| G.722 to Opus | bandwidth at the Opus listener | -3.0 dB, worst -3.5, edge 7.0 kHz | -2.7 dB, worst -3.0, edge 7.25 kHz | | | -6 dB | pass |
| G.722 to Opus | level | -6.0 to -6.4 dB | -6.0 to -6.4 dB | -0.14 to +0.04 dB per clip | | 6 dB | **missed**: 8 of 8 candidates (and 14 of 16 baselines) |
| G.722 to Opus | longest gap | 0 to 90 ms | 0 ms | | | 40 ms | pass |
| Opus to G.722 | ViSQOL | 4.194 | 4.383 | +0.190 [+0.099, +0.279] | -0.015 [-0.048, +0.020] | -0.3 | pass |
| Opus to G.722 | NISQA | 3.790 | 3.853 | +0.063 [-0.121, +0.238] | +0.009 [-0.363, +0.469] | -0.3 | inconclusive: the interval of its reference variation is wider than the margin (taq says pass; unverified) |
| Opus to G.722 | bandwidth at the G.722 listener | -2.8 dB, worst -3.1, edge 7.25 kHz | -2.8 dB, worst -3.4, edge 8.0 kHz | | | -6 dB | pass |
| Opus to G.722 | level | +5.6 to +6.0 dB | +5.6 to +6.0 dB | -0.10 to +0.03 dB per clip | | 6 dB | pass, just under the edge (worst candidate 5.95 dB): the same 6 dB pjsua G.722 offset as the missed row above, here at the G.722 listener |
| Opus to G.722 | longest gap | 0 to 60 ms | 0 ms | | | 40 ms | pass |

No clipping in any capture. `taq compare` exits 1 (regression), on the
level check alone. With `--require-verified` NISQA counts as missing in
every condition, and ViSQOL and the checks are the same. taq gives a
condition the worst of its verdicts, a regression before an incomplete
one: the two g722-to-opus conditions (idle and pcmu-join) stay
regression on their level check, and the two opus-to-g722 conditions,
whose checks all pass, become incomplete for the missing NISQA. The
verdict is still regression, on the level check.

What the numbers say:

- Both rooms carry the band: every capture keeps 4-7 kHz within 3.5 dB
  of the reference, and the candidate's edge is at or above the
  baseline's.
- The level check is missed in both arms alike, and the margin was the
  wrong measure (the Opus to G.722 pass is the same offset, 0.05 dB under
  the edge). pjsua's G.722 codec is 6 dB off the others (pjmedia
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
  (G.722 to Opus), and its reference intervals are wider than the margin
  in both directions: this run cannot tell a NISQA pass from a miss, so
  both rows are inconclusive. ViSQOL's reference variation stays within
  0.06.

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

You need:

- taq 0.1.0 at `cf11b89ac1b9a8dd86ca0dc3c7e4c1cb21b558d4`. It has no
  public remote: the run used the local repository at
  `~/Projects/telephony-audio-quality` of the measuring host. In it, `uv
  sync --extra nisqa`, `uv run taq prepare`, `uv run taq fetch-weights
  nisqa`, and the images `taq-pjsua:2.15.1` and `taq-visqol:3.3.3`.
- The demo, with port 5060 free or moved (here it was taken, and the demo
  ran on 5080): `DEMO_SIP_PORT=5080 make demo`, in its own terminal.

The clips, from taq's pinned set (`clips/vctk-0.92.json`), with the
sha256 of each prepared clip as the manifest recorded it:

| Clip | sha256 |
| --- | --- |
| `vctk092-p225-01` | `19f7a1504a7e029c748c4037c2a3a23f6d91b30cfc2d1f95f16ae4498349510d` |
| `vctk092-p226-01` | `e67c5abf2311eca82656db4735095d2b57ea5080b3e3b6a7a2bbf896183e45e0` |
| `vctk092-p234-01` | `0458e27fbb8f183e4a49ed9c0dccc6f35280f3f061a627384fc89226313100b9` |
| `vctk092-p237-01` | `a19ffbb3dc61e4d8115bdea7d24a061a7ac8d134185f5c3a9feff4337d245aad` |
| `vctk092-p245-01` | `c3f8a7ded17c30c00b77a9c0c92e9aa8384786473a9bb2466981ece09ebf141e` |
| `vctk092-p248-01` | `6bf9631e75869e3f07f24a0c7bcfe838a781cd35a64c578c947edb580d21132f` |
| `vctk092-p294-01` | `8d03cc1d186b8817c007c328e670e3ee9e8a4d4f505b2e10f4019d21531a88f5` |
| `vctk092-p326-01` | `68b50873689a892d17af5f760bed6e4baa2fb80f20ab8a481d74de91cfc5c485` |

The files the run used are in [`quality/`](quality/), copied with their
machine paths made variables (`TAQ_DIR` for the taq checkout, the
scripts' own directory, and `hd.sh` of this checkout), except that
`run1.sh` and `campaign.sh` have since been fixed.

The run used the earlier scripts, which could exit 0 after a failed
capture: `run1.sh` printed the capture's status and exited 0 anyway, and
`campaign.sh` never looked at it. Every capture of the run was checked
by hash afterwards, and an outside review verified all 52. The fixed
scripts are the same as taq's (its `runs/hd-room-2026-11-25/`), with this
checkout's paths. `run1.sh` exits non-zero when the capture fails, when
the PCMU caller fails or records nothing, or when the capture log has a
warning (or cannot be read); `campaign.sh` runs every trial, lists the
failed ones and exits non-zero. Both need bash; `RUN_DIR`, `META_DIR`
and `HD_SH` move the run directory, the meta files and `hd.sh`, and
`PCMU_DELAY` the seconds before the PCMU caller joins (5).

| File | What it is |
| --- | --- |
| [`manifest-margins.json`](quality/manifest-margins.json) | the manifest as written at 06:36:44Z, margins and no trials: the declaration of the margins. taq has no command for it; each `taq live --into` then adds its trial |
| [`live2.py`](quality/live2.py) | `taq live` with a codec and clock rate per participant: the talker (alice) and the listener (bob) get their own, the rest is `taq live` as it ships (it enables one codec for every participant) |
| [`run1.sh`](quality/run1.sh) | one trial: arm, rep, direction, clip, and `pcmu` for a PCMU caller that joins `PCMU_DELAY` (5) s in |
| [`campaign.sh`](quality/campaign.sh) | the whole run, in the order above |
| [`meta-baseline.json`](quality/meta-baseline.json), [`meta-candidate.json`](quality/meta-candidate.json) | what each arm runs on, recorded with its trials |

From this checkout, check the declaration, then put it in place before
the first trial:

```sh
Q=$PWD/apps/chappe_mix/test/audit/quality
python3 -c 'import hashlib, json, sys
m = json.load(open(sys.argv[1]))["margins"]
print(hashlib.sha256(json.dumps(m, sort_keys=True).encode()).hexdigest())' \
    $Q/manifest-margins.json
# 37d441a36e01d6880d6ba595adb78fc2766332ad01c3fbd7dd51d956e7fa6f9c
export TAQ_DIR=~/Projects/telephony-audio-quality
R=runs/hd-room-2026-11-25
mkdir -p $TAQ_DIR/$R && cp $Q/manifest-margins.json $TAQ_DIR/$R/manifest.json
```

Start the SIP and NG trace, for the whole session, from the docker host,
then run every trial:

```sh
docker run -d --rm --name hd-tcpdump --net host -v $TAQ_DIR/$R:/out \
    nicolaka/netshoot:v0.13 tcpdump -i any -n -s 0 -w /out/sip.pcap \
    'udp and (port 5080 or port 15081 or port 15082 or port 22223 or portrange 5170-5175 or port 25080)'
DEMO_SIP_PORT=5080 bash $Q/campaign.sh
```

One trial, as `run1.sh` runs it (here baseline, rep 0, G.722 talker to
Opus listener), from the taq checkout (`cd $TAQ_DIR`):

```sh
TAQ_TALKER_CODEC=G722 TAQ_TALKER_RATE=16000 \
TAQ_LISTENER_CODEC=opus TAQ_LISTENER_RATE=48000 \
uv run python $Q/live2.py live sip:1004@127.0.0.1:5080 \
    --out $R/b0-g722-to-opus-vctk092-p225-01 --clip vctk092-p225-01 \
    --codec G722 --clock-rate 16000 --listeners 1 \
    --sip-port 5170 --rtp-port 40000 --arm baseline --rep 0 \
    --condition-id hd-room/g722-to-opus/idle/clean \
    --path "pjsua > rtpengine > FreeSWITCH mod_conference demo-hd-fs@wideband (16 kHz) > rtpengine > pjsua" \
    --meta $Q/meta-baseline.json --load idle --impairment clean --seed 0 \
    --into $R/manifest.json
```

The candidate calls `sip:1003@...` with `--arm candidate` and
`meta-candidate.json`, and `opus-to-g722` swaps the two codecs and rates.
A PCMU run (`--load pcmu-join`, condition `hd-room/<dir>/pcmu-join/clean`)
also starts, 5 s after `taq live`, a silent PCMU caller for 5 s:

```sh
$Q/../../../../chappe_sip/interop/pjsua/hd.sh -c PCMU -r 8000 -d 5 \
    -l 25080 -m 25500 -N hd-pcmu -i chappe-hd-pjsua \
    -o pcmu-caller/pcmu.wav sip:1003@127.0.0.1:5080
```

Then score, from the taq checkout:

```sh
uv run taq compare $R/manifest.json --out out/hd-room-2026-11-25
uv run taq compare $R/manifest.json --out out/hd-room-2026-11-25-verified \
    --require-verified
```
