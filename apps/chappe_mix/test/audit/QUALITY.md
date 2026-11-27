# chappe_mix listening quality record

What listeners hear in a 16 kHz chappe_mix room, measured against the stock
FreeSWITCH 16 kHz room with speech, through the demo (`make demo`). Read it
before you claim a change to the HD path keeps quality, and measure again
after a change to the mixer's L16 path, to the rtpengine flags of a 16 kHz
room, or to rtpengine itself. Each run records its margins before its first
capture; a margin that is missed is recorded as missed, never moved after
the numbers arrive. `PERF.md` is the performance record, this page the
quality one.

## 2026-11-27, A/B of main against the build before the hardening, on a GitHub runner

The A/B of the next two sections, run again on a GitHub-hosted runner at
the declared gate (a 1 min load of at most 4.0), which the Mac never
allowed. All four blocks ran, 128 trials; the gate refused none and
rtpengine was never lost. On the declared margins the A/B passes:
against the old build (`821870c`), the new one (`840bb74`) keeps ViSQOL
and NISQA within 0.04 MOS in both directions, every interval above the
margin and holding zero, and keeps the band, the level (within 0.02 dB
on every pair) and clipping. No candidate capture of either build has a
gap in speech: the longest is 0 ms in all 64. `taq compare` exits 0.
Each build also passes every check against its FreeSWITCH room. The
1 min load stayed between 0.03 and 2.58 (median 0.25), and the CPU steal
counter never moved. The traces have no miss to explain: no tick of the
mixer fired more than 5 ms late, and chappe_mix's stream reached
rtpengine with no gap over 21.6 ms in speech in any capture. The two
dropout misses of the gate-8 run, both in the new build's first block on
the loaded Mac, have no counterpart here. On this runner the new build gets
the same verdict as the old one on every declared margin.

### Margins

The block declared at 2026-11-25T22:38:12Z, unchanged: sha256
`268e6bca4d9306a2a6939ede8017565bcfdf2331786c3c5d9c3840366039a997`, its
table and file two sections down. The three manifests of the run carry
it, `makeab.py` checked it before it filled the A/B manifest, and each
`results.json` reports it. The comparisons are the three declared, as in
the gate-8 run: the A/B (old's chappe_mix captures as the baseline arm,
new's as the candidate, paired per clip and receiver, the reference
variation being old's block 3 minus its block 1), and each build's
chappe_mix room (1003) against its own FreeSWITCH room (1004).

### The gate, load and waits

The decision is in
[`gate-decision.txt`](quality/2026-11-27-ab-runner/gate-decision.txt),
written at 2026-11-26T23:34:13Z, before any capture on the runner, the
smoke run included: `MAX_LOAD` 4.0, `LOAD_QUIET` 30 s and `MAXWAIT`
1800 s, read from `/proc/loadavg`. The design is the gate-8 run's:
blocks old, new, old, new on one runner, each build from a worktree of
its commit built in the job, per clip and direction one baseline trial
then one candidate trial, SIP and RTP traced per demo session, the mixer
probe on. What differs: `trial.sh` makes taq live's two calls (same
order, durations, ports and pjsua options) through chappe's `hd.sh`, and
`taq live-import` finishes the trials on the Mac, where they are scored.
A refused trial would have been tried again up to four more times, and
no trial could start after 285 min of the job (04:38:58Z). Neither came
into play: no trial was refused, and the four blocks took 1 h 54 min of
a job of 2 h 2 min (23:53:52Z to 01:56:02Z).

| Block | Build | When (UTC, 27th) | Trials | Waiting | 1 min load at each trial start | 1 min load while it ran |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | old | 00:01 to 00:30 | 32 | 960 s, longest 30 s | 0.05 to 1.74, median 0.23 | 0.04 to 1.60, median 0.25 |
| 2 | new | 00:30 to 00:58 | 32 | 963 s, longest 31 s | 0.04 to 0.49, median 0.23 | 0.03 to 0.74, median 0.24 |
| 3 | old | 00:58 to 01:27 | 32 | 961 s, longest 31 s | 0.10 to 0.72, median 0.24 | 0.05 to 0.92, median 0.25 |
| 4 | new | 01:27 to 01:56 | 32 | 963 s, longest 31 s | 0.06 to 0.57, median 0.23 | 0.06 to 0.73, median 0.24 |

The gate waited 3847 s in all, every trial the minimum (30 or 31 s).
Sampled every 10 s from 00:01:18 to 01:55:32 (`hostload.log`, 686
samples), the 1 min load ran from 0.03 to 2.58, median 0.25, and never
reached 4.0. The highest sample, 2.58, is the first one, taken while the
first demo came up. The 5 min load peaked at 1.75. The CPU steal counter
of `/proc/stat` stayed at 0 in all 686 samples: the hypervisor reported
no stolen time. A hypervisor that does not account for steal also reads
0, so that is all it says. Each block ran in one demo session, and no
trial was run again.

### Versions

| What | Version |
| --- | --- |
| chappe | old `821870c` (`821870cb93ec4df455bbce8a3f7140ebc3530e8d`), new `840bb74` (`840bb749f9ab39585b604857b733ab5d25af5dbe`), each from a `git worktree` of its commit built in the job; Erlang/OTP 29.1.2 (erts 17.1.1), rebar3 3.28.0 |
| Host | GitHub-hosted runner, `ubuntu-24.04` image 20261122.23.1, AMD EPYC 7763, 4 vCPUs, kernel 7.0.0-1020-azure, clock source tsc; workflow run 45913592269 |
| FreeSWITCH | `drachtio/drachtio-freeswitch-mrf@sha256:2f1583c3...`, as on the Mac |
| rtpengine | 26.3.1.4+0~mr26.3.1.4, `chappe-rtpengine-interop` built from source in the job (image `sha256:f4eb82c3...`; the Mac's is `sha256:9cf8018b...`), as each session's `.versions` file records |
| pjsua | 2.15.1, chappe's lab image `chappe-conf-pjsua` (`sha256:bc752d4e...`), built once before the first trial; the Mac runs used `taq-pjsua:2.15.1` (`sha256:45c94f10...`) |
| taq | 0.1.0 at `31be153` (`31be15354fea0215f864d144dcc59a12315fa167`): gate-8's `78eebde` plus `taq live-import`; it imported and scored on the Mac and never ran on the runner |
| Scorers | ViSQOL 3.3.3 and NISQA as in the rerun, both verified (`--require-verified`) |
| Traces | tcpdump in `nicolaka/netshoot:v0.13` on the runner's host network: SIP and NG in full, RTP to 128 bytes, one pair of files per block (four sessions) |

### Results

The paired difference is candidate minus baseline, averaged per clip,
with its 95% bootstrap interval over the 8 clips. In the A/B each arm has
two captures per clip and receiver (old: blocks 1 and 3; new: blocks 2
and 4), and the reference variation is old's block 3 minus its block 1.
Bandwidth is at the listener, median and worst of the arm's captures,
with the lowest edge. The level rows give each arm's level change against
the reference (not gated) and, as the difference, the gated level against
the baseline.

New against old:

| Direction | Check | Old (`821870c`) | New (`840bb74`) | Paired difference [95%] | Reference variation [95%] | Margin | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| G.722 to Opus | ViSQOL | 4.390 | 4.384 | -0.006 [-0.025, +0.010] | -0.007 [-0.021, +0.003] | -0.3 | pass |
| G.722 to Opus | NISQA | 4.077 | 4.077 | -0.000 [-0.045, +0.043] | -0.014 [-0.024, -0.004] | -0.3 | pass |
| G.722 to Opus | bandwidth at the Opus listener | -2.86 dB, worst -3.04, edge 7.25 kHz | -2.76 dB, worst -3.09, edge 7.25 kHz | | | -6 dB | pass |
| G.722 to Opus | level against the baseline | -6.00 to -6.41 dB | -6.00 to -6.41 dB | +0.000 dB [-0.006, +0.005], worst pair -0.02 (p234) | | 1.5 dB, worst pair | pass |
| G.722 to Opus | longest gap | 0 ms | 0 ms | | | 40 ms | pass |
| G.722 to Opus | clipping | none | none | | | 1e-4 | pass |
| Opus to G.722 | ViSQOL | 4.399 | 4.403 | +0.004 [-0.007, +0.016] | +0.010 [-0.004, +0.032] | -0.3 | pass |
| Opus to G.722 | NISQA | 3.888 | 3.926 | +0.039 [-0.008, +0.113] | +0.044 [-0.048, +0.202] | -0.3 | pass |
| Opus to G.722 | bandwidth at the G.722 listener | -2.67 dB, worst -2.98, edge 8.0 kHz | -2.63 dB, worst -2.98, edge 8.0 kHz | | | -6 dB | pass |
| Opus to G.722 | level against the baseline | +5.61 to +5.96 dB | +5.61 to +5.96 dB | +0.003 dB [+0.000, +0.006], worst pair +0.015 (p226) | | 1.5 dB, worst pair | pass |
| Opus to G.722 | longest gap | 0 ms | 0 ms | | | 40 ms | pass |
| Opus to G.722 | clipping | none | none | | | 1e-4 | pass |

The A/B verdict on the declared margins: **pass**. `taq compare` exits
0, and every check passes in both directions.

Each build against its FreeSWITCH room:

| Direction | Check | Build | FreeSWITCH (1004) | chappe_mix (1003) | Paired difference [95%] | Reference variation [95%] | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| G.722 to Opus | ViSQOL | old | 4.124 | 4.390 | +0.265 [+0.211, +0.335] | -0.032 [-0.084, +0.002] | pass |
| G.722 to Opus | ViSQOL | new | 4.145 | 4.384 | +0.239 [+0.180, +0.317] | +0.017 [-0.000, +0.040] | pass |
| G.722 to Opus | NISQA | old | 4.182 | 4.077 | -0.105 [-0.211, +0.011] | -0.016 [-0.102, +0.064] | pass |
| G.722 to Opus | NISQA | new | 4.194 | 4.077 | -0.118 [-0.243, +0.003] | +0.017 [-0.018, +0.055] | pass |
| G.722 to Opus | bandwidth | old | -2.99 dB, worst -3.47, edge 7.0 kHz | -2.86 dB, worst -3.04, edge 7.25 kHz | | | pass |
| G.722 to Opus | bandwidth | new | -3.03 dB, worst -3.47, edge 7.0 kHz | -2.76 dB, worst -3.09, edge 7.25 kHz | | | pass |
| G.722 to Opus | level against the baseline | old | -6.01 to -6.35 dB | -6.00 to -6.41 dB | -0.034 dB [-0.055, -0.014], worst pair -0.10 (p248) | | pass |
| G.722 to Opus | level against the baseline | new | -6.01 to -6.35 dB | -6.00 to -6.41 dB | -0.040 dB [-0.060, -0.019], worst pair -0.09 (p248) | | pass |
| G.722 to Opus | longest gap | old | 0 to 90 ms (8 of 16 over 40) | 0 ms | | | pass |
| G.722 to Opus | longest gap | new | 0 to 90 ms (7 of 16 over 40) | 0 ms | | | pass |
| G.722 to Opus | clipping | both | none | none | | | pass |
| Opus to G.722 | ViSQOL | old | 4.210 | 4.399 | +0.188 [+0.092, +0.280] | +0.007 [-0.002, +0.019] | pass |
| Opus to G.722 | ViSQOL | new | 4.202 | 4.403 | +0.200 [+0.107, +0.291] | -0.015 [-0.055, +0.009] | pass |
| Opus to G.722 | NISQA | old | 3.974 | 3.888 | -0.087 [-0.213, +0.052] | +0.004 [-0.037, +0.056] | pass |
| Opus to G.722 | NISQA | new | 3.938 | 3.926 | -0.012 [-0.163, +0.164] | -0.018 [-0.062, +0.012] | pass |
| Opus to G.722 | bandwidth | old | -2.76 dB, worst -3.25, edge 7.25 kHz | -2.67 dB, worst -2.98, edge 8.0 kHz | | | pass |
| Opus to G.722 | bandwidth | new | -2.77 dB, worst -3.25, edge 7.25 kHz | -2.63 dB, worst -2.98, edge 8.0 kHz | | | pass |
| Opus to G.722 | level against the baseline | old | +5.61 to +6.00 dB | +5.61 to +5.96 dB | -0.041 dB [-0.086, -0.013], worst pair -0.19 (p245) | | pass |
| Opus to G.722 | level against the baseline | new | +5.61 to +6.00 dB | +5.61 to +5.96 dB | -0.039 dB [-0.088, -0.009], worst pair -0.20 (p245) | | pass |
| Opus to G.722 | longest gap | old | 0 to 60 ms (2 of 16 over 40) | 0 ms | | | pass |
| Opus to G.722 | longest gap | new | 0 to 60 ms (2 of 16 over 40) | 0 ms | | | pass |
| Opus to G.722 | clipping | both | none | none | | | pass |

The margins are those of the A/B table. Both builds' comparisons exit 0
(pass).

What the numbers say:

- New against old, the scorers do not move: every interval holds zero.
  Per clip, the NISQA differences lie between -0.13 and +0.11 from G.722
  to Opus and between -0.03 and +0.29 from Opus to G.722. The +0.29
  (p226) comes from one old capture of block 1 that scores 3.01, against
  3.58 for the other three captures of that clip (see the traces). One
  clip scores the same to two decimals in all four blocks (p245 from
  G.722 to Opus). The A/B's reference variation intervals are at
  most 0.25 wide, under the margin.
- Level and band: the builds agree within 0.02 dB on every pair, and both
  keep the band within 3.1 dB of the reference.
- Both builds beat FreeSWITCH on ViSQOL by 0.19 to 0.27 MOS with
  intervals above zero, as in the earlier runs. On NISQA their means are
  0.01 to 0.12 under FreeSWITCH's, every interval holding zero. All four
  reference variation intervals against FreeSWITCH are at most 0.17 wide;
  on the Mac three of four were wider than the margin. On the quiet
  runner, mod_conference's two runs of a clip repeat closely.
- mod_conference drops quiet speech as before (7 or 8 of 16 captures over
  40 ms from G.722 to Opus, 2 from Opus to G.722). Its stream into
  rtpengine had no gap over 40.8 ms in speech in any capture: the gaps of 50 to
  90 ms are in the audio it sends, not between its packets. A baseline
  gap does not gate.

### What the traces show

No capture missed a margin, so there is no miss to trace. The traces of
the four sessions were read as in the gate-8 run, to set the hops beside
the Mac's: `rtpan-runner.py` on each session's RTP trace (gate-8's
`rtpan.py`, with alice's speech taken from `trial.json`, because the
runner keeps no played file), `mixan.py` on the mixer probe's samples,
then `tracesum.py` and `perblock-runner.py` on the results in
[`traces/`](quality/2026-11-27-ab-runner/traces/). Times are from the
trial's start.

| Block | Build | Candidate captures with a gap over 40 ms in speech into rtpengine | Mixer ticks over 20 ms late (overruns) | Lasting steps at bob of 15 ms or more in speech, candidate | pjsua empties in speech, candidate | FreeSWITCH captures with a gap over 40 ms into rtpengine |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | old | 0 of 16 (longest 21.6 ms) | 0 (0) | none | 1 | 2 of 16 (40.1 and 40.5 ms) |
| 2 | new | 0 of 16 (longest 21.2 ms) | 0 (0) | none | 0 | 0 of 16 |
| 3 | old | 0 of 16 (longest 20.9 ms) | 0 (0) | none | 0 | 0 of 16 |
| 4 | new | 0 of 16 (longest 20.9 ms) | 0 (0) | none | 0 | 1 of 16 (40.8 ms) |

The mixer's counts cover 15 candidate windows per block, as in the
gate-8 run: the probe stops with the demo, so the last candidate trial of
each block has no sample after it.

- chappe_mix's stream reached rtpengine whole in every capture of both
  builds: longest gap in speech 20.1 to 21.6 ms, spread at most 1.7 ms,
  no lost packet, no timestamp jump. rtpengine's stream to bob kept it
  (longest gap 21.7 ms, net shift at most 1.8 ms), with no lasting step
  in speech at bob. On the Mac the same hop had gaps of up to 68.8 ms in
  the new build's first block.
- The mixer's ticks held the period: in the 60 candidate windows (about
  100,000 ticks) none fired more than 5 ms late, and 7 more than 2 ms
  (0, 5, 1 and 1 per block); no overrun. The gate-8 run counted 21 ticks
  over 20 ms late.
- FreeSWITCH's stream had gaps of 40.1 to 40.8 ms into rtpengine in 3
  of 64 captures, and bob saw 17 lasting steps of +20 or +21 ms in its
  speech (11 old, 6 new): the stream moves by one frame and stays there.
  bob's pjsua emptied its jitter buffer 18 times in speech on
  FreeSWITCH's stream, and once on chappe_mix's (old, block 1, p226 from
  G.722 to Opus, at 9.4 s, with no gap over 20.1 ms at any hop in the
  100 ms before it).
- The one candidate capture that stands out, old block 1, Opus to G.722,
  p226 (NISQA 3.01 and ViSQOL 4.50, against 3.58 and 4.58 for the other
  three captures of that clip), is whole at every hop, alice's stream to
  the mixer included (longest gap 21.2 ms), and the mixer ticked on time.
  Its only marks: alice's leg in the mixer ran under once and its prefill
  grew to two frames, as 17 of the run's 120 legs did in both builds; and
  the capture is 20 ms later than the other three (3052.8 against
  3032.8 ms), with a lower correlation (0.79 against 0.89). It is an old
  capture, the A/B's baseline arm, so it raises new's NISQA difference on
  that clip. The traces do not say why it scored lower.

### Against the gate-8 run on the Mac

Absolute scores do not compare: the host, the pjsua image and the
rtpengine build differ, as the gate decision says. Only the verdicts of
old against new do.

| Comparison | Mac, gate 8 (2026-11-26) | Runner, declared gate 4.0 (this run) |
| --- | --- | --- |
| A/B, new against old | **missed**: dropouts, one capture per direction (100 and 110 ms), both in new's first block; every other check passes | pass, every check in both directions |
| old against its FreeSWITCH room | pass | pass |
| new against its FreeSWITCH room | **missed**: dropouts, the same two captures | pass |

The Mac's traces put the start of both misses outside chappe_mix's
mixing: a late tick of the node's timer on the loaded host, and a stall
on the way from macOS to the docker host, in the stretch of the run that
also cut the demo off from rtpengine. On the runner neither build shows
such a gap: no candidate capture has a gap in speech, no tick of the
mixer fired more than 5 ms late, and its stream reached rtpengine
whole. ViSQOL's
old-against-new differences hold zero in both runs. NISQA's were 0.06
and 0.08 lower on the Mac, its lowest clips being those of the two missed
captures; here they are 0.00 and +0.04.

### Reproduce

You need taq at `31be15354fea0215f864d144dcc59a12315fa167` and the
gate-8 manifests and meta files in
`runs/hd-room-ab-2026-11-25/gate8/` of the taq checkout (next
section). The runner's scripts and the workflow are described in
[`quality/2026-11-27-ab-runner/`](quality/2026-11-27-ab-runner/README.md);
the analysis reuses gate-8's `makeab.py`, `summarize.py`, `rtpan.py`,
`mixan.py` and `tracesum.py` by path, and adds `rtpan-runner.py` and
`perblock-runner.py`.

```sh
git push origin HEAD:quality/hd-ab-runner     # the A/B: this job took 2 h 2 min
export TAQ_DIR=~/Projects/telephony-audio-quality
F=$TAQ_DIR/runs/hd-room-ab-runner/full
gh run download RUN_ID -n hd-ab-full -D $F
```

Make `$F/manifest.json`, `$F/old/manifest.json` and `$F/new/manifest.json`
from gate-8's (same depth, so the clip list resolves) with no trials and
this run's ids, the margins block untouched. Copy gate-8's
`meta-baseline.json` and `meta-candidate.json` of each build next to its
manifest, with `rtpengine.digest` set to the runner's image (each
session's `.versions` gives it). Then:

```sh
Q=$PWD/apps/chappe_mix/test/audit/quality
cd $TAQ_DIR
for b in old new; do
    uv run taq live-import $F/$b/b?-*[0-9] --meta $F/$b/meta-baseline.json \
        --into $F/$b/manifest.json
    uv run taq live-import $F/$b/c?-*[0-9] --meta $F/$b/meta-candidate.json \
        --into $F/$b/manifest.json
done
python3 -I $Q/2026-11-26-ab-gate8/makeab.py $F \
    268e6bca4d9306a2a6939ede8017565bcfdf2331786c3c5d9c3840366039a997
uv run taq compare $F/manifest.json \
    --out out/hd-room-ab-runner-ab --require-verified
uv run taq compare $F/old/manifest.json \
    --out out/hd-room-ab-runner-old --require-verified
uv run taq compare $F/new/manifest.json \
    --out out/hd-room-ab-runner-new --require-verified
for r in ab old new; do
    python3 -I $Q/2026-11-26-ab-gate8/summarize.py out/hd-room-ab-runner-$r/results.json
done
```

Then the traces, one session per block (block 1 is `old/[bc]0-*`, block
2 `new/[bc]0-*`, block 3 `old/[bc]1-*`, block 4 `new/[bc]1-*`):

```sh
cd $F && mkdir -p an
python3 -I $Q/2026-11-27-ab-runner/rtpan-runner.py $Q/2026-11-26-ab-gate8/rtpan.py \
    pcap/block1-old-s1-rtp.pcap old/[bc]0-*[0-9] > an/block1-old-s1-rtp.json
python3 -I $Q/2026-11-26-ab-gate8/mixan.py block1-old-s1.mix.log old/c0-*[0-9] \
    > an/block1-old-s1-mix.json
python3 -I $Q/2026-11-26-ab-gate8/tracesum.py an
python3 -I $Q/2026-11-27-ab-runner/perblock-runner.py . an
```

The evidence stays in the taq checkout (git-ignored), under
`runs/hd-room-ab-runner/full/`: the artifact of run 45913592269 (the run
directories of both builds with their `trial.json` and `ID.live.log`,
`load.log`, `hostload.log`, `blocks.log`, each session's demo, block and
mixer logs and versions, the traces in `pcap/`), the manifests, the meta
files and the import logs, and the hop-by-hop results in `an/` (the same
as `traces/` here, one trial per line). The results are under
`out/hd-room-ab-runner-ab`, `-old` and `-new`, each with its
`compare.log`.

## 2026-11-26, A/B of main against the build before the hardening, at a load gate of 8

The A/B that the declared gate did not let run (next section), run at the
gate the maintainer chose afterwards: a 1 min load of 8.0. All four blocks
ran, 128 trials, and the gate refused none. Against the old build
(`821870c`), the new one (`840bb74`) keeps ViSQOL and NISQA within 0.09 MOS
in both directions, every interval above the margin, and keeps the band,
the level and clipping. It misses the dropout margin in both directions,
on one capture each (gaps of 100 and 110 ms), so `taq compare` exits 1 and
the A/B is a miss. The old build passes every check against its
FreeSWITCH room. The new one misses only the dropout margin, on the same
two captures. NISQA, missed in the rerun, passes for both builds. The RTP
and mixer traces put the start of both gaps before rtpengine and outside
the mixing. In one, a tick of the mixer fired late on the loaded host and
its frames were skipped. In the other, the mixer ticked on time and the
gap opened on the way from macOS to the docker host. rtpengine stretched
both and kept a lasting delay. Both fell in the new build's first block,
the block in which the host also cut the demo off from rtpengine and
FreeSWITCH's stream stalled more than in any other.

### Margins

The block declared at 2026-11-25T22:38:12Z, unchanged: sha256
`268e6bca4d9306a2a6939ede8017565bcfdf2331786c3c5d9c3840366039a997`, its
table and file in the next section. The three manifests of the run carry
it, `makeab.py` checked it before it filled the A/B manifest, and each
`results.json` reports it. The comparisons are the three declared: the
A/B (old's chappe_mix captures as the baseline arm, new's as the
candidate, paired per clip and receiver, the reference variation being
old's block 3 minus its block 1), and each build's chappe_mix room (1003)
against its own FreeSWITCH room (1004).

### The gate, load and waits

The decision is in
[`gate-decision.txt`](quality/2026-11-26-ab-gate8/gate-decision.txt),
written at 2026-11-26T07:27:26Z, before any capture: `MAX_LOAD` 8.0,
`LOAD_QUIET` 30 s and `MAXWAIT` 1800 s for all four blocks, because the
declared gate (4.0) was refused twice. The absolute numbers are therefore
measured under moderate load; only the comparison of old against new is
the question. The design is the declared one: blocks old, new, old, new,
each built from a fresh worktree of its commit, per clip and direction
one baseline trial then one candidate trial, SIP and RTP traced per demo
session, the mixer probe on. Two changes to the scripts, written before
the first trial: `run-gate8.sh` is `run-all.sh` with this gate, the
campaign's first trial tried again like any other (up to four more
times), and an 8 hour limit after which `block.sh` starts no trial
(`DEADLINE`). Neither came into play: no trial was refused, and the run
took 2 h 51 min.

| Block | Build | When (UTC, 26th) | Trials | Waiting | 1 min load at each trial start | 1 min load while it ran |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | old | 07:30 to 08:10 | 32 | 1696 s, longest 221 s | 3.4 to 7.2, median 5.5 | 3.4 to 18.9, median 6.2 |
| 2 | new | 08:10 to 08:56, two demo sessions | 32, and one run again | 1983 s, longest 246 s | 3.8 to 7.8, median 6.4 | 3.8 to 29.6, median 7.3 |
| 3 | old | 08:56 to 09:43 | 32 | 2082 s, longest 417 s | 4.3 to 7.7, median 6.0 | 4.1 to 23.6, median 7.2 |
| 4 | new | 09:43 to 10:21 | 32 | 1502 s, longest 447 s | 3.7 to 7.6, median 5.5 | 3.5 to 36.4, median 6.3 |

The gate waited 7263 s in all; the median trial waited the minimum, 30 s.
Sampled every 10 s from 07:29:53 to 10:21:16 (`hostload.log`), the 1 min
load ran from 3.4 to 36.4, median 6.8, above 8 in 292 of 1028 samples. It
went under 4.0 at times this morning (27 samples), which it never did in
the two refused waits.

Block 2 lost rtpengine once, as the set-aside block did. From 08:19:17 to
08:19:33 the two trace containers exited, the node lost its ESL
connections to both FreeSWITCH, then got no reply to its NG requests and
marked rtpengine down. The next trial (baseline, G.722 to Opus, p234) got
no answer and was moved to `new/failed-ng/`; `ab.sh` started a fresh demo
session at 08:21:44 and ran that trial again at 08:24:39. The first
session's traces end at 08:19:17, after the speech of its last capture
(candidate, Opus to G.722, p226, 08:18:57 to 08:19:20), so the speech of
every capture of the run is in a trace.

### Versions

| What | Version |
| --- | --- |
| chappe | old `821870c` (`821870cb93ec4df455bbce8a3f7140ebc3530e8d`), new `840bb74` (`840bb749f9ab39585b604857b733ab5d25af5dbe`), each from a fresh `git worktree` built for this run; Erlang/OTP 29.1.2 (erts 17.1.1) |
| FreeSWITCH, rtpengine, pjsua | as in the next section; rtpengine 26.3.1.4+0~mr26.3.1.4, image `sha256:9cf8018b...`, as each session's `.versions` file records |
| taq | 0.1.0 at `78eebde` (`78eebde26f5f1d1a984c09315e29323696d4c710`) |
| Scorers | ViSQOL 3.3.3 and NISQA as in the rerun, both verified (`--require-verified`) |
| Traces | tcpdump in `nicolaka/netshoot:v0.13` on the docker host's network: SIP and NG in full, RTP to 128 bytes, one pair of files per demo session (five sessions) |

### Results

The paired difference is candidate minus baseline, averaged per clip,
with its 95% bootstrap interval over the 8 clips. In the A/B each arm has
two captures per clip and receiver (old: blocks 1 and 3; new: blocks 2
and 4), and the reference variation is old's block 3 minus its block 1.
Bandwidth is at the listener, median and worst of the arm's captures,
with the lowest edge. The level rows give each arm's level change against
the reference (not gated) and, as the difference, the gated level against
the baseline.

New against old:

| Direction | Check | Old (`821870c`) | New (`840bb74`) | Paired difference [95%] | Reference variation [95%] | Margin | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| G.722 to Opus | ViSQOL | 4.371 | 4.379 | +0.008 [-0.037, +0.050] | +0.025 [-0.004, +0.071] | -0.3 | pass |
| G.722 to Opus | NISQA | 4.060 | 4.001 | -0.058 [-0.159, +0.013] | -0.013 [-0.088, +0.054] | -0.3 | pass |
| G.722 to Opus | bandwidth at the Opus listener | -2.67 dB, worst -2.95, edge 7.25 kHz | -2.65 dB, worst -2.95, edge 7.25 kHz | | | -6 dB | pass |
| G.722 to Opus | level against the baseline | -6.01 to -6.42 dB | -6.02 to -6.42 dB | -0.004 dB [-0.011, +0.002], worst pair -0.04 (p294) | | 1.5 dB, worst pair | pass |
| G.722 to Opus | longest gap | 0 ms | 0 ms, but 100 ms on p225 (block 2) | | | 40 ms | **missed**: 1 of 16 |
| G.722 to Opus | clipping | none | none | | | 1e-4 | pass |
| Opus to G.722 | ViSQOL | 4.373 | 4.373 | -0.001 [-0.034, +0.039] | -0.019 [-0.060, +0.013] | -0.3 | pass |
| Opus to G.722 | NISQA | 3.834 | 3.751 | -0.083 [-0.202, +0.006] | +0.054 [-0.048, +0.197] | -0.3 | pass |
| Opus to G.722 | bandwidth at the G.722 listener | -2.83 dB, worst -3.44, edge 8.0 kHz | -2.90 dB, worst -4.31, edge 8.0 kHz | | | -6 dB | pass |
| Opus to G.722 | level against the baseline | +5.62 to +5.95 dB | +5.61 to +5.95 dB | -0.017 dB [-0.035, -0.001], worst pair -0.10 (p234) | | 1.5 dB, worst pair | pass |
| Opus to G.722 | longest gap | 0 to 40 ms, none over | 0 to 40 ms, but 110 ms on p234 (block 2) | | | 40 ms | **missed**: 1 of 16 |
| Opus to G.722 | clipping | none | none | | | 1e-4 | pass |

The A/B verdict on the declared margins: **missed**. `taq compare` exits
1 (regression) on the dropout check, in both directions; every other
check passes.

Each build against its FreeSWITCH room:

| Direction | Check | Build | FreeSWITCH (1004) | chappe_mix (1003) | Paired difference [95%] | Reference variation [95%] | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| G.722 to Opus | ViSQOL | old | 4.134 | 4.371 | +0.237 [+0.193, +0.280] | -0.001 [-0.023, +0.027] | pass |
| G.722 to Opus | ViSQOL | new | 4.121 | 4.379 | +0.258 [+0.200, +0.319] | -0.015 [-0.069, +0.018] | pass |
| G.722 to Opus | NISQA | old | 4.068 | 4.060 | -0.008 [-0.174, +0.160] | -0.008 [-0.307, +0.273] | pass |
| G.722 to Opus | NISQA | new | 4.162 | 4.001 | -0.161 [-0.257, -0.061] | +0.036 [-0.074, +0.162] | pass |
| G.722 to Opus | bandwidth | old | -3.03 dB, worst -3.45, edge 7.0 kHz | -2.67 dB, worst -2.95, edge 7.25 kHz | | | pass |
| G.722 to Opus | bandwidth | new | -2.98 dB, worst -3.57, edge 7.0 kHz | -2.65 dB, worst -2.95, edge 7.25 kHz | | | pass |
| G.722 to Opus | level against the baseline | old | -5.98 to -6.37 dB | -6.01 to -6.42 dB | -0.054 dB [-0.111, -0.013], worst pair -0.24 (p245) | | pass |
| G.722 to Opus | level against the baseline | new | -5.98 to -6.39 dB | -6.02 to -6.42 dB | -0.057 dB [-0.099, -0.029], worst pair -0.20 (p245) | | pass |
| G.722 to Opus | longest gap | old | 0 to 90 ms (7 of 16 over 40) | 0 ms | | | pass |
| G.722 to Opus | longest gap | new | 0 to 90 ms (6 of 16 over 40) | 0 ms, but 100 ms on p225 | | | **missed**: 1 of 16 |
| G.722 to Opus | clipping | both | none | none | | | pass |
| Opus to G.722 | ViSQOL | old | 4.175 | 4.373 | +0.198 [+0.106, +0.286] | +0.073 [-0.007, +0.188] | pass |
| Opus to G.722 | ViSQOL | new | 4.194 | 4.373 | +0.179 [+0.071, +0.278] | -0.053 [-0.125, +0.006] | pass |
| Opus to G.722 | NISQA | old | 3.503 | 3.834 | +0.330 [+0.104, +0.538] | +0.059 [-0.654, +0.772] | pass |
| Opus to G.722 | NISQA | new | 3.634 | 3.751 | +0.117 [-0.058, +0.313] | -0.112 [-0.479, +0.350] | pass |
| Opus to G.722 | bandwidth | old | -2.88 dB, worst -3.08, edge 7.25 kHz | -2.83 dB, worst -3.44, edge 8.0 kHz | | | pass |
| Opus to G.722 | bandwidth | new | -2.81 dB, worst -3.11, edge 7.25 kHz | -2.90 dB, worst -4.31, edge 8.0 kHz | | | pass |
| Opus to G.722 | level against the baseline | old | +5.53 to +5.97 dB | +5.62 to +5.95 dB | -0.011 dB [-0.033, +0.010], worst pair -0.09 (p248) | | pass |
| Opus to G.722 | level against the baseline | new | +5.50 to +5.96 dB | +5.61 to +5.95 dB | -0.022 dB [-0.055, +0.013], worst pair -0.11 (p234) | | pass |
| Opus to G.722 | longest gap | old | 0 to 60 ms (4 of 16 over 40) | 0 to 40 ms, none over | | | pass |
| Opus to G.722 | longest gap | new | 0 to 80 ms (4 of 16 over 40) | 0 to 40 ms, but 110 ms on p234 | | | **missed**: 1 of 16 |
| Opus to G.722 | clipping | both | none | none | | | pass |

The margins are those of the A/B table. The old build's comparison exits
0 (pass), the new build's exits 1 (regression, the dropout check in both
directions).

What the numbers say:

- New against old, the scorers do not move: ViSQOL's intervals hold zero,
  and NISQA's means are 0.06 and 0.08 lower with upper bounds just above
  zero. The two lowest NISQA differences per clip are the clips of the
  two dropout misses (p225 from G.722 to Opus, -0.38; p234 from Opus to
  G.722, -0.46), whose new captures in block 2 score 2.52 and 2.39; the
  other 14 lie between -0.20 and +0.05. The A/B's reference variation
  intervals (0.14 and 0.24 wide for NISQA) are narrower than the margin:
  old's chappe_mix captures repeat closely across its two blocks.
- Level and band: the builds agree within 0.1 dB on every pair, and both
  keep the band within 4.4 dB of the reference.
- Both builds beat FreeSWITCH on ViSQOL by 0.18 to 0.26 MOS with
  intervals above zero, as in the earlier runs. NISQA passes for both
  builds; in the rerun, at a median load of 13.2, it missed in both
  directions. Three of its four reference variation intervals against
  FreeSWITCH are again wider than the margin (0.58, 0.83 and 1.43):
  mod_conference's two runs of a clip often differ by more than the
  margin.
- mod_conference drops quiet speech as before (6 or 7 of 16 captures over
  40 ms from G.722 to Opus). A baseline gap does not gate.

### What the traces show

Each candidate capture that missed a margin, read hop by hop as in the
set-aside block: `rtpan.py` on the session's RTP trace, `mixan.py` and
`mixsec.py` on the mixer probe's samples. Times are from the trial's
start; alice speaks from about 3.5 to 12.6 s.

- New, G.722 to Opus, p225 (block 2, first session, 08:12:12Z, 1 min load
  4.5 at the start). The mixer ticked on time through the gap: in the
  second from 10.2 to 11.2 s it fired its 50 ticks, none more than 5 ms
  late. chappe_mix's stream reached the docker host with a 63.9 ms gap at
  10.8 s, with no loss and no timestamp jump. rtpengine's stream to bob
  had a 59.3 ms gap there and stayed 27.4 ms later from then on; the
  docker proxy added nothing. bob's pjsua ran its jitter buffer empty
  twice at that moment, and taq reads a 100 ms gap. The gap opened after
  the mixer sent, between macOS and the docker host, and rtpengine kept
  part of it as a lasting delay.
- New, Opus to G.722, p234 (block 2, second session, 08:29:01Z, load 5.6
  at the start). In the second from 10.75 to 11.75 s one tick fired more
  than 20 ms late, and the mixer skipped two frames (two overruns, 48
  ticks instead of 50), as it is built to. chappe_mix's stream into
  rtpengine had a 68.8 ms gap at 11.0 s with one RTP timestamp jump.
  rtpengine's stream to bob had a 109.9 ms gap and stayed 91.4 ms later.
  bob's jitter buffer ran empty four times in the speech, and taq reads
  110 ms. The gap started at the node's timer on the loaded host, and
  rtpengine stretched it and kept it as delay. An earlier gap of the
  same capture, 47.9 ms into rtpengine at 9.1 s with the mixer on time,
  had left a 17 ms step.
- In both of those seconds the SIP and NG traces hold only the demo's
  OPTIONS keepalives to the two FreeSWITCH and its rtpengine pings, as in
  every second of both builds: no call was set up or joined while the
  gaps opened.

Across the run (`tracesum.py` and `perblock.py` on the traces of
[`traces/`](quality/2026-11-26-ab-gate8/traces/)):

| Block | Build | Candidate captures with a gap over 40 ms in speech into rtpengine | Mixer ticks over 20 ms late (overruns) | Lasting steps at bob of 15 ms or more in speech, candidate | pjsua empties in speech, candidate | FreeSWITCH captures with a gap over 40 ms into rtpengine |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | old | 0 of 16 | 6 (14) | none | 2 | 1 of 16 |
| 2 | new | 4 of 16 | 12 (17) | 5, of 17 to 91 ms | 13 | 2 of 16 |
| 3 | old | 0 of 16 | 0 (0) | none | 1 | 0 of 16 |
| 4 | new | 1 of 16 (41.3 ms) | 3 (4) | none | 5 | 0 of 16 |

The mixer's counts cover 15 candidate windows per block: the probe stops
with the demo, so the last candidate trial of each block has no sample
after it.

So:

- The gaps do not start in chappe_mix's mixing. In both misses the
  stream left the mixer whole, or with the frames of one late tick
  skipped. Between the two builds the mixer differs only in how it draws
  an SSRC when a leg joins (#90), and both gaps fell in the middle of the
  speech, with no join in progress.
- The stalls cluster in block 2, the new build's first block: the block
  that lost rtpengine through the OrbStack forward, and the one in which
  FreeSWITCH's stream also had the most gaps over 40 ms. Block 4, the new
  build's second block, is of the order of the old build's two blocks.
  The traces point at that stretch of the host. But one block is all
  that separates the builds here, and this run cannot rule out that the
  new build had a part in it.
- rtpengine turns a gap upstream into a longer gap and a lasting delay
  (27 and 91 ms here), as in the set-aside block.

### Reproduce

You need taq at `78eebde26f5f1d1a984c09315e29323696d4c710`, with
`runs/hd-room-ab-2026-11-25/` set up as in the next section (the scripts,
`strict/` with its manifests and meta files, `mixprobe.erl` compiled),
and two fresh worktrees, `ab-821870c` and `ab-840bb74`, under one
directory (`WT`). The scripts of this run are in
[`quality/2026-11-26-ab-gate8/`](quality/2026-11-26-ab-gate8/):
`run-gate8.sh` and the `block.sh` with `DEADLINE`, the unchanged `ab.sh`,
`mixprobe.erl.txt`, `rtpan.py`, `mixan.py`, `makeab.py` and
`summarize.py`, and the analysis scripts `tracesum.py`, `perblock.py` and
`mixsec.py`.

```sh
Q=$PWD/apps/chappe_mix/test/audit/quality/2026-11-26-ab-gate8
export TAQ_DIR=~/Projects/telephony-audio-quality
R=$TAQ_DIR/runs/hd-room-ab-2026-11-25
git worktree add --detach $WT/ab-821870c 821870c
git worktree add --detach $WT/ab-840bb74 840bb74
(cd $WT/ab-821870c && rebar3 compile); (cd $WT/ab-840bb74 && rebar3 compile)
cp $Q/run-gate8.sh $Q/block.sh $R/
mkdir -p $R/gate8/old $R/gate8/new
cp $R/strict/manifest.json $R/gate8/
for b in old new; do
    cp $R/strict/$b/manifest.json $R/strict/$b/meta-*.json $R/gate8/$b/
    : > $R/gate8/$b/load.log
done
WT=$WT bash $R/run-gate8.sh
cd $TAQ_DIR
python3 $R/makeab.py $R/gate8 \
    268e6bca4d9306a2a6939ede8017565bcfdf2331786c3c5d9c3840366039a997
uv run taq compare $R/gate8/manifest.json \
    --out out/hd-room-ab-gate8-ab --require-verified
uv run taq compare $R/gate8/old/manifest.json \
    --out out/hd-room-ab-gate8-old --require-verified
uv run taq compare $R/gate8/new/manifest.json \
    --out out/hd-room-ab-gate8-new --require-verified
for r in ab old new; do
    python3 $R/summarize.py out/hd-room-ab-gate8-$r/results.json
done
```

Then the traces, per demo session (block 2 has two, both over
`new/[bc]0-*`; block 3 is `old/[bc]1-*`, block 4 `new/[bc]1-*`):

```sh
cd $R && mkdir -p gate8/an
python3 -I rtpan.py gate8/pcap/block1-old-s1-rtp.pcap gate8/old/[bc]0-*/ \
    > gate8/an/block1-old-s1-rtp.json
python3 -I mixan.py gate8/block1-old-s1.mix.log gate8/old/c0-*/ \
    > gate8/an/block1-old-s1-mix.json
python3 -I $Q/tracesum.py gate8/an
python3 -I $Q/perblock.py gate8 gate8/an
python3 -I $Q/mixsec.py mixan.py gate8/block2-new-s2.mix.log \
    gate8/new/c0-opus-to-g722-vctk092-p234-01
```

The evidence stays in the taq checkout (git-ignored), under
`runs/hd-room-ab-2026-11-25/gate8/`: the run directories of both builds
and their `load.log`, `hostload.log`, `blocks.log`, `run-gate8.log`, each
session's demo, block and mixer logs and versions, the traces in `pcap/`,
the trial lost with rtpengine in `new/failed-ng/`, and the hop-by-hop
results in `an/` (the same as `traces/` here, one trial per line). The
results are under `out/hd-room-ab-gate8-ab`, `-old` and `-new`, each with
its `compare.log`.

## 2026-11-25 and 26, A/B of main against the build before the hardening: not run

The follow-up to the rerun below, meant to tell a change of chappe from the
busier host: main `840bb74` ("new") against `821870c` ("old", main after
#88, before the hardening fixes), each with its own FreeSWITCH baseline, in
four alternating blocks on a host the campaign waits on until it is quiet.
It did not run: twice, the campaign's first trial waited the full 30
minutes for a 1 min load of 4.0 or less and never got it. No capture was
made at that gate, so there is no comparison and no A/B verdict; no margin
was passed or missed. One block of the old build captured at a looser gate
(15) is kept apart, unscored; its packet traces say where the jitter came
from on that build.

### Margins, declared before any capture

Declared at 2026-11-25T22:38:12Z by writing the manifest
(`runs/hd-room-ab-2026-11-25/manifest.json` of the taq checkout) with its
margins and no trials, before any capture of either build; that file is
[`quality/2026-11-25-ab/manifest-margins.json`](quality/2026-11-25-ab/manifest-margins.json).
The sha256 of the margins block (its JSON with sorted keys) is
`268e6bca4d9306a2a6939ede8017565bcfdf2331786c3c5d9c3840366039a997`; the
per-build manifests and the strict attempt's manifests carry the same
block. A pilot (one candidate and one baseline trial of the old build at
22:40, the gate off) checked the traces and the scripts and was kept out
(`runs/hd-room-ab-2026-11-25-pilot/`).

The margins are the rerun's, so the runs compare:

| Check | Margin |
| --- | --- |
| ViSQOL and NISQA, paired difference per clip and receiver | lower bound of the 95% bootstrap interval above -0.3 MOS |
| Longest gap in active speech, every candidate capture | 40 ms |
| Level against the baseline, worst pair | 1.5 dB |
| Bandwidth, every candidate capture | 4-7 kHz share within 6 dB of the reference's |
| Clipping | at most 1e-4 of the samples |
| Level against the reference, delay | not gated |

taq compares two arms, baseline and candidate, and cannot compare two
candidate arms, so the note declared three comparisons, each with this
block: the A/B (old's chappe_mix captures as the baseline arm, new's as the
candidate, paired per clip and receiver; its reference variation old's
block 3 minus block 1), and each build's chappe_mix room against its own
FreeSWITCH room (both of its blocks), as in the rerun. Bandwidth and
clipping are per-capture checks of the candidate arm: in the A/B they read
the same new captures as new's own comparison. The design: four blocks,
old, new, old, new, the demo stopped between blocks, each build's demo
(`DEMO_SIP_PORT=5080 make demo`) from a clean worktree of its commit; in
each block, per clip and direction, one baseline trial (room 1004) then
one candidate trial (room 1003); no PCMU caller.

### Host, load and the gate

macOS 27.2, arm64, 14 cores, OrbStack docker 29.8.2, shared with other
jobs. Before every trial, taq's `run1.sh` (taq `78eebde`) waits until the
1 min load average has stayed at most `MAX_LOAD` for 30 s in a row, for up
to 1800 s; a trial that never gets quiet fails and runs nothing. The
declared gate is 4.0. Every decision below is in
[`gate-decision.txt`](quality/2026-11-25-ab/gate-decision.txt), each
written when it was made, before any score was computed.

| When (UTC) | Gate | What happened | 1 min load |
| --- | --- | --- | --- |
| 25th, 22:45 to 23:15 | 4.0 | block 1 (old): its first trial refused after 1800 s | 9.4 to 32.1, median 20.5 |
| 25th 23:16 to 26th 01:36 | 15 | block 1 (old) at the fallback written at 22:51Z, before any capture (the 25th percentile of the refused wait, rounded up): 31 of its 32 trials, then stopped at a trial boundary; set aside | 6.0 to 14.1 when a trial started (median 12.4), 5440 s of waiting, the longest 1292 s |
| 26th, 01:37 to 02:08 | 4.0 | the coordinator's decision at 01:36Z, with the maintainer, before any score: restart all four blocks at the declared gate in `strict/`; block 1's first trial refused after 1800 s, and the run stopped there rather than lower the bar again | 5.9 to 29.4, median 9.2 |

The gate waited 9040 s in all (two refused windows of 1800 s and the
set-aside block's 5440 s). The load never fell under 5.9: long-running
desktop processes (a browser tab at 100% of a core for two days, NVIDIA
Sync, WindowServer, OrbStack, cloudd) hold it there, and other projects'
test runs pushed it to 30 and more. The new build was built but never ran
a trial.

The set-aside block also lost rtpengine once: at 23:26:00Z the in-VM end of
OrbStack's forward of the node's NG socket moved from `127.0.0.1` to
`[::1]`, the docker proxy passed the requests to rtpengine but no reply came
back, and the node marked rtpengine down; the next trial got a 500. From
then on the scripts stop a block when the demo log shows the loss, start a
fresh demo session (its own logs and traces) and resume, running that
trial again. A refused trial is tried again up to four more times, except
the campaign's first.

### Versions

| What | Version |
| --- | --- |
| chappe | old `821870c` (`821870cb93ec4df455bbce8a3f7140ebc3530e8d`), new `840bb74` (`840bb749f9ab39585b604857b733ab5d25af5dbe`), each from a clean `git worktree`; Erlang/OTP 29.1.2 (erts 17.1.1) |
| FreeSWITCH | `drachtio/drachtio-freeswitch-mrf@sha256:2f1583c3...`, as in the rerun |
| rtpengine | 26.3.1.4+0~mr26.3.1.4, `chappe-rtpengine-interop` (image `sha256:9cf8018b...`, the rerun's) |
| pjsua | 2.15.1, `taq-pjsua:2.15.1` (`sha256:45c94f10...`) |
| taq | 0.1.0 at `78eebde` (`78eebde26f5f1d1a984c09315e29323696d4c710`): the rerun's `48f46ad` plus the load gate |
| Traces | tcpdump 4.99.4 in `nicolaka/netshoot:v0.13` (`sha256:e286c635...`) on the docker host's network: SIP and NG in full, RTP to 128 bytes, one pair of files per block and demo session |
| Scorers | ViSQOL 3.3.3 and NISQA as in the rerun; not run (nothing to compare) |

### Results

None. No trial ran at the declared gate, so `taq compare` had nothing to
score in `strict/`, the A/B verdict was not reached, and the question
(is `840bb74` worse than `821870c`?) stays open. The set-aside block holds
the old build only and was not scored.

### What the traces of the set-aside block show

Not a comparison and not a quality result: the old build only, its 15
candidate and 16 baseline captures at a 1 min load of 6 to 14 when each
trial started, read hop by hop in the RTP trace (`rtpan.py`) and in the
mixer's own counters, sampled once a second from the demo node
(`mixprobe.erl.txt`, `mixan.py`). Per capture: the stream into rtpengine of
bob's leg (from chappe_mix, or from FreeSWITCH), rtpengine's stream to bob,
and the same stream at bob's socket when the docker proxy relays it. The
spread is the range of arrival time minus RTP time, inside alice's speech.

- chappe_mix's stream, as it reaches the docker host, was steady while
  alice spoke: longest inter-arrival gap 21 to 33 ms, spread 1.5 to 13 ms,
  no lost packet, no timestamp jump. rtpengine's stream to bob kept it:
  gaps of 23 to 29 ms, spread 3.5 to 13.5 ms, a net drift of at most
  9.4 ms; the docker proxy added under 1 ms. bob's pjsua ran its jitter
  buffer empty 0 to 3 times per capture, 5 times in speech in all, and 4
  of those 5 had no arrival gap over 30 ms at any hop: pjsua's playout,
  not the network.
- The mixer's ticks do slip when the host is loaded. In the 15 candidate
  windows, 4 of about 25,000 ticks fired more than 10 ms late and 2 more
  than a period late (frames skipped, as designed). With the room empty
  (between trials, or during a baseline trial), in load bursts of 18 to
  80, it skipped 307 ticks in all, the latest 296 ms late. That is the
  Erlang node's timer on a loaded macOS, the same for both builds (the
  two differ in the mixer only by the SSRC draw of #90).
- The macOS to docker forward also stalls on its own: in the pilot, at a
  load of 15, a 53 ms gap arrived on chappe_mix's stream while the mixer's
  ticks were never more than 8.3 ms late.
- rtpengine turns some stalls into lasting delay: in the pilot its stream
  to bob stayed 28 ms later after that 53 ms gap upstream, and in the first
  candidate capture of the block it stepped by 23 and 30 ms (both before
  the talker joined) while chappe_mix's stream was steady. A lasting step
  inside the speech moves the delay inside the capture, which is what the
  three NISQA misses of the rerun showed (40 to 60 ms).
- FreeSWITCH's stream stalls the same way, and worse: one baseline
  capture (p237, Opus to G.722) has gaps of up to 148 ms from FreeSWITCH,
  lasting steps of 20 to 158 ms at bob and 30 jitter buffer empties;
  another (p226, G.722 to Opus) one 40 ms step after a 64 ms gap. The
  p237 steps fall from 00:38:18 to 00:38:22, the seconds in which the
  empty chappe_mix room skipped 38 ticks and the 1 min load went from 10
  to 29: one stall of the host, seen by both senders.

So, on the old build at that load, the jitter that reaches bob starts at
the media senders' scheduling on the loaded host (chappe_mix's ticks on
macOS, FreeSWITCH in its container) and in the macOS to docker forward,
and rtpengine can keep part of it as a lasting delay; it does not start in
chappe_mix's mixing. The rerun's three misses (p226 G.722 to Opus, p225
and p245 Opus to G.722) cannot be traced: the rerun has no RTP, and the
same captures of this block (old build) show no lasting step in speech
(net drift -0.6 to +5.8 ms).

### Reproduce

You need taq at `78eebde26f5f1d1a984c09315e29323696d4c710` (the local
repository at `~/Projects/telephony-audio-quality`, set up as for the
rerun) and two clean worktrees, `ab-821870c` and `ab-840bb74`, under one
directory (`WT`). The scripts of the run are in
[`quality/2026-11-25-ab/`](quality/2026-11-25-ab/): `ab.sh` (one block:
demo, traces, mixer probe, trials, teardown, a fresh demo session when
rtpengine is lost), `block.sh` (the trials of a block), `run-all.sh` (the
four blocks at the declared gate), `mixprobe.erl.txt`, `rtpan.py`, `mixan.py`,
`makeab.py` (fills the A/B manifest from the two builds' manifests) and
`summarize.py` (the rows of a results table).

```sh
Q=$PWD/apps/chappe_mix/test/audit/quality/2026-11-25-ab
python3 -c 'import hashlib, json, sys
m = json.load(open(sys.argv[1]))["margins"]
print(hashlib.sha256(json.dumps(m, sort_keys=True).encode()).hexdigest())' \
    $Q/manifest-margins.json
# 268e6bca4d9306a2a6939ede8017565bcfdf2331786c3c5d9c3840366039a997
git worktree add --detach $WT/ab-821870c 821870c
git worktree add --detach $WT/ab-840bb74 840bb74
(cd $WT/ab-821870c && rebar3 compile); (cd $WT/ab-840bb74 && rebar3 compile)
```

In the taq checkout, make `runs/hd-room-ab-2026-11-25/` with the scripts
and the declared `manifest.json`, then `strict/manifest.json`,
`strict/old/` and `strict/new/` (each manifest a copy of the declaration
with its `clips` path adjusted, no trials, and the meta files of the
rerun with the build's revision), copy `mixprobe.erl.txt` there as `mixprobe.erl` and compile it (it is kept as `.txt` so the test build does not compile it), and run:

```sh
WT=$WT bash runs/hd-room-ab-2026-11-25/run-all.sh
python3 runs/hd-room-ab-2026-11-25/makeab.py runs/hd-room-ab-2026-11-25/strict \
    268e6bca4d9306a2a6939ede8017565bcfdf2331786c3c5d9c3840366039a997
S=runs/hd-room-ab-2026-11-25/strict
for m in $S/manifest.json $S/old/manifest.json $S/new/manifest.json; do
    uv run taq compare $m --out out/hd-room-ab-$(basename $(dirname $m)) --require-verified
done
python3 -I runs/hd-room-ab-2026-11-25/rtpan.py $S/pcap/block1-old-s1-rtp.pcap $S/old/[bc]0-*-01
python3 -I runs/hd-room-ab-2026-11-25/mixan.py $S/block1-old-s1.mix.log $S/old/c0-*-01
```

The evidence stays in the taq checkout (git-ignored), under
`runs/hd-room-ab-2026-11-25/`: `refused/` (the first refused wait),
`set-aside-load15/` (the block at MAX_LOAD 15: run directories, `load.log`,
traces, demo and mixer logs), `strict/` (the second refused wait), and
`gate-decision.txt`. The hop-by-hop numbers of the set-aside block are in
[`set-aside-rtp.json`](quality/2026-11-25-ab/set-aside-rtp.json) and
[`set-aside-mix.json`](quality/2026-11-25-ab/set-aside-mix.json).

## 2026-11-25, rerun: HD rooms after the hardening fixes

The joint test of the run below, run again on main after the hardening
fixes (#90 to #92), with the level margin moved from the reference to the
baseline and NISQA verified. ViSQOL, bandwidth, the level against the
baseline and clipping pass in both directions. NISQA misses its margin in
both directions, and the candidate misses the dropout margin on one
capture (Opus to G.722). `taq compare` exits 1 (regression), with and
without `--require-verified`.

### Margins, declared before any capture

Declared at 2026-11-25T15:40:25Z by writing the manifest
(`runs/hd-room-2026-11-25-rerun/manifest.json` of the taq checkout) with
its margins and no trials, before the first capture of either arm; that
file is
[`quality/2026-11-25-rerun/manifest-margins.json`](quality/2026-11-25-rerun/manifest-margins.json).
taq reports the sha256 of the margins block (its JSON with sorted keys) as
`0491cb816382d53688eaa7f02f8974cbbe027c6db6eb77ce63f87c714b3334fc`, the
same before the first trial and in both results. A pilot candidate run
with the PCMU caller at 15:43:03 checked the pipeline and was kept out of
the manifest (`c9-...-pcmu`, in `runs/hd-room-2026-11-25-rerun-pilot/`);
the trials ran from 15:43:47. The reasons below are the manifest's margins
note, shortened.

| Check | Margin | Why |
| --- | --- | --- |
| ViSQOL, paired difference (candidate minus baseline, per clip) | lower bound of the 95% bootstrap interval above -0.3 MOS | kept from the earlier run so the two compare; no measured ViSQOL drop backs it, and ViSQOL does not catch a narrowband hop (the bandwidth check does) |
| NISQA, paired difference | the same, -0.3 MOS | below the 0.38 NISQA drop taq measured between a G.722 and a PCMU path, so a narrowband hop fails it; NISQA is verified for this run |
| Bandwidth, every candidate capture | 4-7 kHz share within 6 dB of the reference's | as before: G.722 and Opus kept it within 3.5 dB, a hop through 8 kHz reads 33 to 53 dB down |
| Level against the reference | not gated | pjsua's G.722 codec is 6 dB off the others in both rooms: this check measures the phone, not the room |
| Level against the baseline, every candidate capture | its level change minus the mean of the two baseline captures of the same clip and receiver within 1.5 dB (worst pair) | the earlier run's arms differed by 0.14 dB at most per clip; a mixer gain fault of 2 dB or more fails it |
| Clipping | at most 1e-4 of the samples | as before |
| Dropouts, every candidate capture | no gap in active speech longer than 40 ms | as before (two 20 ms packets); a baseline gap is reported, not gated |
| Delay | not gated | taq live has no synchronized timestamps |

The pcmu-join conditions have one clip per arm: their scorers are reported,
not gated, and every other check is gated as above.

### What was measured

The design of the earlier run, unchanged: bob (the listener) calls a room
and records, alice (the talker) calls 3 s later and plays one pinned VCTK
0.92 clip; `g722-to-opus` is alice on G.722 (16 kHz) and bob on Opus
(48 kHz), `opus-to-g722` the reverse; the baseline is room `1004`
(mod_conference `demo-hd-fs@wideband`), the candidate room `1003`
(chappe_mix `demo-hd`, L16 at 16 kHz behind rtpengine). Per clip and
direction: baseline rep 0, candidate, baseline rep 1. 48 trials from 15:43:47
to 16:01:51 UTC, then the four PCMU runs from 16:01:53 to 16:03:23. All 52
trials exited 0 with no warning (`campaign.sh` exited 0), and none was
rerun.

### Host and versions

| What | Version |
| --- | --- |
| Host | macOS 27.2, arm64, 14 cores, 48 GB; shared with other jobs. 1 min load 6.4 to 50.6 over the trials (median 13.2, against 8.2 in the earlier run); above 20 for ten trials (seven baseline, three candidate), all between 15:44 and 15:49 (clips p225, p226 and the first p234) |
| Docker | OrbStack, docker 29.8.2, linux/arm64; pjsua on the host network |
| chappe | `840bb74` (`840bb749f9ab39585b604857b733ab5d25af5dbe`), main after #92; the demo built from it (`make demo`, Erlang/OTP 29.1.2) |
| FreeSWITCH | `drachtio/drachtio-freeswitch-mrf@sha256:2f1583c3...` (image `sha256:534f085e...`), 1.10.10 git `4cb05e7` |
| rtpengine | 26.3.1.4+0~mr26.3.1.4, `chappe-rtpengine-interop` (image `sha256:9cf8018b...`, the earlier run's image) |
| pjsua | 2.15.1, `taq-pjsua:2.15.1` (`sha256:45c94f10...`); the PCMU caller `chappe-hd-pjsua` (`sha256:8c877774...`) |
| taq | 0.1.0 at `48f46ad` (`48f46ad1b29174a52faba2f566ca78e15ebd1189`): the earlier run's `cf11b89` plus the campaign scripts that fail on a failed trial, the refusal of incomplete evidence, the NISQA validation and the level against the baseline |
| ViSQOL | 3.3.3, speech mode, `taq-visqol:3.3.3` (`sha256:f5486dda...`), verified (upstream conformance pair) |
| NISQA | code `fe84f0f2`, weights `nisqa.tar` sha256 `7ec4cf93...`, verified: same scores as the upstream NISQA environment, and its record `validation/nisqa.json` (taq `0f793cb`, made 2026-11-25T10:36:32Z, sha256 `bfc7a531...`) gives r 0.903 and RMSE 0.475 on NISQA_VAL_SIM, r 0.820 and RMSE 0.403 on NISQA_VAL_LIVE, against the published 0.90 / 0.48 and 0.82 / 0.40 |

### Results

As in the earlier run: the paired difference is candidate minus baseline,
averaged per clip, with its 95% bootstrap interval over the 8 clips, and
the reference variation is baseline rep 1 minus rep 0. Bandwidth is at the
listener, median and worst of the arm's captures, with the lowest edge.
The level rows give each arm's level change against the reference (not
gated) and, as the difference, the gated level against the baseline.

| Direction | Check | Baseline (1004) | Candidate (1003) | Paired difference [95%] | Reference variation [95%] | Margin | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| G.722 to Opus | ViSQOL | 4.137 | 4.366 | +0.229 [+0.167, +0.293] | +0.022 [+0.004, +0.046] | -0.3 | pass |
| G.722 to Opus | NISQA | 4.084 | 3.927 | -0.157 [-0.464, +0.120] | +0.163 [-0.134, +0.610] | -0.3 | **missed**: lower bound -0.464 |
| G.722 to Opus | bandwidth at the Opus listener | -2.97 dB, worst -3.56, edge 7.0 kHz | -2.62 dB, worst -3.20, edge 7.25 kHz | | | -6 dB | pass |
| G.722 to Opus | level against the baseline | -5.99 to -6.37 dB | -6.02 to -6.39 dB | -0.06 dB [-0.11, -0.02], worst pair -0.20 (p245) | | 1.5 dB, worst pair | pass |
| G.722 to Opus | longest gap | 0 to 90 ms (8 of 16 over 40) | 0 ms | | | 40 ms | pass |
| G.722 to Opus | clipping | none | none | | | 1e-4 | pass |
| Opus to G.722 | ViSQOL | 4.214 | 4.319 | +0.105 [+0.023, +0.180] | +0.009 [-0.022, +0.046] | -0.3 | pass |
| Opus to G.722 | NISQA | 3.960 | 3.559 | -0.401 [-0.814, -0.040] | +0.088 [-0.063, +0.323] | -0.3 | **missed**: mean and lower bound past the margin |
| Opus to G.722 | bandwidth at the G.722 listener | -2.88 dB, worst -3.13, edge 7.25 kHz | -2.89 dB, worst -3.19, edge 8.0 kHz | | | -6 dB | pass |
| Opus to G.722 | level against the baseline | +5.62 to +5.97 dB | +5.65 to +5.96 dB | -0.04 dB [-0.08, -0.01], worst pair -0.13 (p245) | | 1.5 dB, worst pair | pass |
| Opus to G.722 | longest gap | 0 to 60 ms (3 of 16 over 40) | 0 ms, but 80 ms (three gaps) on p225 | | | 40 ms | **missed**: 1 of 8 candidates |
| Opus to G.722 | clipping | none | none | | | 1e-4 | pass |

`taq compare` exits 1 (regression) with and without `--require-verified`:
both scorers are verified, so the two results are the same. The two idle
conditions are regressions (NISQA in both, the dropout check from Opus to
G.722), the two pcmu-join conditions pass.

What the numbers say:

- Both rooms carry the band, as before: every capture keeps 4-7 kHz
  within 3.6 dB of the reference, and the candidate's edge is at or above
  the baseline's.
- The level against the baseline is the right measure: the arms agree
  within 0.20 dB on every capture, while both keep pjsua's 6 dB G.722
  offset against the reference.
- ViSQOL puts the candidate ahead in both directions, with intervals above
  zero, and its reference variation stays within 0.05.
- NISQA is missed in both directions, on three candidate captures. The
  other 13 per-clip differences lie between -0.37 and +0.55; these three
  score 1.1 to 1.3 below their baselines: p226 from G.722 to Opus (2.83
  against 3.90) and, from Opus to G.722, p225 (2.36 against 3.67) and p245
  (2.78 against 4.08). In each, the delay moves by about 40 to 60 ms inside
  the capture (taq's local delay windows), as in only three other captures
  of the run (two baseline, one candidate, which score 3.10 to 4.14); every
  other capture moves by 30 ms at most. p225 also holds the three gaps of
  the dropout miss. bob's pjsua got every packet of those calls (no loss,
  one packet discarded, jitter at most 10.6 ms) and its jitter buffer still
  ran empty 2 to 8 times (1 to 3 in most captures of both arms), so the
  steps are in the audio that reached it or in pjsua's playout. The baseline has
  the same kind of capture (rep 0 of p226 from Opus to G.722, at a load of
  44, scores 2.79), but its two runs per clip halve the weight of one bad
  capture, where the candidate has one run per clip. Against the earlier
  run, bob's jitter buffer ran empty more often in the candidate from Opus
  to G.722 (19 times over 9 captures, against 7), and about as often in
  the baseline (34 against 36). This run cannot tell a change of chappe
  from the busier host: the trace holds no RTP, and two of the three
  captures ran at a load of 20.
- NISQA's reference variation intervals are again wider than the margin
  (0.74 and 0.39): even a NISQA pass could not be told from run-to-run
  noise in this design.
- mod_conference drops quiet speech as before (p245 90 ms from G.722 to
  Opus in both runs, p248 70 ms, p326 60 ms, p226 50 ms). A baseline gap
  does not gate.

To tell the two apart, run again on a quiet host with the RTP in the
trace, and with a second candidate on main before the hardening fixes
(`821870c`, after #88) in the same campaign, its margins declared first as
here.

### The PCMU caller joining and leaving

One run per arm and direction (clip p225): a silent PCMU pjsua joins the
room 1.6 to 3.3 s after the talker's INVITE and leaves 5 s later, inside
the clip (from the SIP trace). It heard the talker (median -27 to -33 dBFS
over its 69 to 94 active frames).

| Direction | Arm | Bandwidth at the HD listener | Level against the baseline | Longest gap | ViSQOL | NISQA |
| --- | --- | --- | --- | --- | --- | --- |
| G.722 to Opus | baseline | -1.75 dB | (-6.00 dB against the reference) | 0 ms | 3.854 | 3.298 |
| G.722 to Opus | candidate | -1.63 dB (pass) | -0.03 dB (pass) | 0 ms (pass) | 4.051 | 3.163 |
| Opus to G.722 | baseline | -1.53 dB | (+5.94 dB against the reference) | 0 ms | 3.890 | 3.591 |
| Opus to G.722 | candidate | -1.52 dB (pass) | 0.00 dB (pass) | 0 ms (pass) | 4.071 | 3.629 |

The HD pair keeps its band and its level while the PCMU caller is in, in
both rooms. The scorers are not gated on one clip. The four runs ran at a
load of 11 to 15.

### Worst pairs

Paths under the taq checkout's `runs/hd-room-2026-11-25-rerun/`:

- ViSQOL: p248, Opus to G.722, -0.085:
  `b0-opus-to-g722-vctk092-p248-01/bob.rx.wav` and
  `c0-opus-to-g722-vctk092-p248-01/bob.rx.wav`.
- NISQA: p225, Opus to G.722, -1.315:
  `b0-opus-to-g722-vctk092-p225-01/bob.rx.wav` and
  `c0-opus-to-g722-vctk092-p225-01/bob.rx.wav`.
- Gaps: the same candidate capture, 80 ms:
  `c0-opus-to-g722-vctk092-p225-01/bob.rx.wav`.
- Bandwidth: p326, G.722 to Opus, candidate, -3.20 dB:
  `c0-g722-to-opus-vctk092-p326-01/bob.rx.wav`.
- Level against the baseline: p245, G.722 to Opus, -0.20 dB:
  `c0-g722-to-opus-vctk092-p245-01/bob.rx.wav` against
  `b0-...` and `b1-g722-to-opus-vctk092-p245-01/bob.rx.wav`.

The evidence stays in the taq checkout (git-ignored): each run directory,
`sip.pcap` (the SIP of every call and the rtpengine NG commands, sha256
`8b48d478...`), `load.log`, `campaign.log`, the demo and rtpengine logs,
the pilot under `runs/hd-room-2026-11-25-rerun-pilot/`, and the results
under `out/hd-room-2026-11-25-rerun` and
`out/hd-room-2026-11-25-rerun-verified`.

### Reproduce

You need taq at `48f46ad1b29174a52faba2f566ca78e15ebd1189` (the local
repository at `~/Projects/telephony-audio-quality` of the measuring host;
`uv sync --extra nisqa`, `uv run taq prepare`, `uv run taq fetch-weights
nisqa`, the images `taq-pjsua:2.15.1` and `taq-visqol:3.3.3`), and this
checkout at `840bb74`. The campaign scripts are taq's own
(`scripts/campaign/`), the same as the fixed copies in
[`quality/`](quality/) but for their default paths. The files of this run
are in [`quality/2026-11-25-rerun/`](quality/2026-11-25-rerun/): the
declaration and the meta of each arm.

```sh
Q=$PWD/apps/chappe_mix/test/audit/quality/2026-11-25-rerun
python3 -c 'import hashlib, json, sys
m = json.load(open(sys.argv[1]))["margins"]
print(hashlib.sha256(json.dumps(m, sort_keys=True).encode()).hexdigest())' \
    $Q/manifest-margins.json
# 0491cb816382d53688eaa7f02f8974cbbe027c6db6eb77ce63f87c714b3334fc
export TAQ_DIR=~/Projects/telephony-audio-quality
R=$TAQ_DIR/runs/hd-room-2026-11-25-rerun
mkdir -p $R && cp $Q/manifest-margins.json $R/manifest.json
cp $Q/meta-baseline.json $Q/meta-candidate.json $R/
```

Start the demo in its own terminal (`DEMO_SIP_PORT=5080 make demo`; 5060
was taken), then the trace, the pilot, the campaign and the scoring:

```sh
docker run -d --rm --name hd-tcpdump --net host -v $R:/out \
    nicolaka/netshoot:v0.13 tcpdump -i any -n -s 0 -w /out/sip.pcap \
    'udp and (port 5080 or port 15081 or port 15082 or port 22223 or portrange 5170-5175 or port 25080)'
mkdir -p $R-pilot
RUN_DIR=$R-pilot META_DIR=$R CHAPPE_DIR=$PWD DEMO_SIP_PORT=5080 \
    bash $TAQ_DIR/scripts/campaign/run1.sh candidate 9 g722-to-opus \
    vctk092-p225-01 pcmu no-into
RUN_DIR=$R CHAPPE_DIR=$PWD DEMO_SIP_PORT=5080 \
    bash $TAQ_DIR/scripts/campaign/campaign.sh
docker stop hd-tcpdump
cd $TAQ_DIR
uv run taq compare runs/hd-room-2026-11-25-rerun/manifest.json \
    --out out/hd-room-2026-11-25-rerun-verified --require-verified
uv run taq compare runs/hd-room-2026-11-25-rerun/manifest.json \
    --out out/hd-room-2026-11-25-rerun
```

Stop the demo with Ctrl-C, then `make demo-down`. (Here the pilot had its
own trace, `sip-pilot.pcap`, in the pilot directory.)

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
