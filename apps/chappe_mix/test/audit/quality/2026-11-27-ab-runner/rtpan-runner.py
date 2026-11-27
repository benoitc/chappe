#!/usr/bin/env python3
"""The gate-8 rtpan.py on the runner's trials. The runner keeps no
alice.tx.wav (the played file), so alice's speech is taken from
trial.json instead: from her call confirmed, for the clip's play_s less
its pad_s of trailing silence, which is what rtpan.py reads from the
played file. Everything else is rtpan.py's own code.

Usage: rtpan-runner.py RTPAN_PY RTP_PCAP RUN_DIR [RUN_DIR ...] > out.json
"""
import importlib.util
import json
import re
import sys

spec = importlib.util.spec_from_file_location("rtpan", sys.argv[1])
rtpan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rtpan)


def talk_window(rd, day):
    clip = json.loads((rd / "trial.json").read_text())["clip"]
    t = None
    for line in (rd / "alice.pjsua.log").read_text(errors="replace").splitlines():
        m = re.match(r"(\d\d):(\d\d):(\d\d)\.(\d{3}) .*state changed to CONFIRMED", line)
        if m:
            h, mi, sec, ms = (int(x) for x in m.groups())
            t = day + h * 3600 + mi * 60 + sec + ms / 1000
            break
    dur = clip["play_s"] - clip["pad_s"]
    return (t, t + dur) if t else (None, None)


rtpan.talk_window = talk_window
rtpan.main(sys.argv[2:])
