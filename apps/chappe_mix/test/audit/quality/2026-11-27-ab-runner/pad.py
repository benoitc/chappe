#!/usr/bin/env python3
"""The played files of the runner's trials, made once before the first one.

Each clip listed in clips/SHA256SUMS (next to this script) is read from
SRC_DIR, checked against its sha256, and written to OUT_DIR as
<clip>.tx.wav: the same 16-bit mono samples followed by PAD_S (2.0) s of
zeros, as taq live pads its clip so that pjsua's looping player does not
start again before the call ends. OUT_DIR/padded.json holds, per clip,
the prepared clip's sha256, the played file and its sha256, and play_s
(the clip's length plus the pad), which trial.sh reads. One line per clip
is printed: the clip id and its play_s.

Usage: pad.py SRC_DIR OUT_DIR
Exits 1 when a clip is missing, differs from its sha256 or is not 16-bit
mono.
"""

import hashlib
import json
import sys
import wave
from pathlib import Path

PAD_S = 2.0
HERE = Path(__file__).resolve().parent


def sums():
    out = []
    for line in (HERE / "clips" / "SHA256SUMS").read_text().splitlines():
        if line.strip():
            sha, name = line.split(maxsplit=1)
            out.append((name.lstrip("*"), sha))
    return out


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pad(src, dest):
    with wave.open(str(src), "rb") as r:
        if r.getnchannels() != 1 or r.getsampwidth() != 2:
            raise ValueError(f"{src}: not 16-bit mono")
        rate = r.getframerate()
        frames = r.getnframes()
        data = r.readframes(frames)
    zeros = int(PAD_S * rate)
    with wave.open(str(dest), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(data + b"\0\0" * zeros)
    return rate, frames


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    src_dir, out_dir = Path(argv[0]), Path(argv[1])
    out_dir.mkdir(parents=True, exist_ok=True)
    clips = {}
    bad = 0
    for name, want in sums():
        cid = Path(name).stem
        src = src_dir / name
        if not src.is_file():
            print(f"{cid}: {src} missing", file=sys.stderr)
            bad += 1
            continue
        got = sha256(src)
        if got != want:
            print(f"{cid}: {src} sha256 {got}, not {want}", file=sys.stderr)
            bad += 1
            continue
        dest = out_dir / f"{cid}.tx.wav"
        try:
            rate, frames = pad(src, dest)
        except (ValueError, wave.Error) as e:
            print(f"{cid}: {e}", file=sys.stderr)
            bad += 1
            continue
        play_s = round(frames / rate + PAD_S, 6)
        clips[cid] = {"sha256": got, "frames": frames, "sample_rate": rate,
                      "file": dest.name, "tx_sha256": sha256(dest),
                      "play_s": play_s}
        print(f"{cid} {play_s}")
    if bad:
        return 1
    doc = {"schema": "chappe-hd-padded/1", "pad_s": PAD_S, "clips": clips}
    (out_dir / "padded.json").write_text(json.dumps(doc, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
