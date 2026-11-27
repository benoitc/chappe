#!/usr/bin/env python3
"""trial.sh's last step: write OUT/trial.json and check the trial.

Reads what trial.sh recorded per participant in STATE (<name>.start and
<name>.end, epochs; <name>.rc; <name>.cmd; <name>.timeout when it was
killed) and the trial's facts from the environment (T_*, set by
trial.sh). Writes OUT/trial.json (schema chappe-hd-trial/1, which taq
live-import reads and checks against taq's schema/trial.schema.json) and
prints one line per problem: a call that exited non-zero or timed out, a
recording missing or empty, a pjsua log missing or without a 200 OK to
the INVITE carrying SDP, no pjsua image id or no chappe SHA.

Usage: trial.py OUT STATE
Exits 0 for a clean trial, 1 when there is a problem.
"""

import datetime as dt
import json
import os
import platform
import re
import subprocess
import sys
import wave
from pathlib import Path

MSG_START = re.compile(r"\b(TX|RX) \d+ bytes (Request|Response) msg (\S+)")
CLOCKSOURCE = "/sys/devices/system/clocksource/clocksource0/current_clocksource"


def env(name):
    v = os.environ.get(name)
    if v is None:
        raise SystemExit(f"trial.py: {name} not set")
    return v


def iso(epoch):
    t = dt.datetime.fromtimestamp(int(epoch), dt.timezone.utc)
    return t.isoformat().replace("+00:00", "Z")


def read(state, name, kind):
    p = state / f"{name}.{kind}"
    return p.read_text().strip() if p.is_file() else None


def answered_with_sdp(log):
    """True when the log holds a 200 response to an INVITE with SDP."""
    cur = None
    for line in log.splitlines():
        if cur is None:
            m = MSG_START.search(line)
            if m:
                cur = (m.group(2), m.group(3), [])
            continue
        if line.strip() == "--end msg--":
            kind, what, lines = cur
            _, _, body = "\n".join(lines).replace("\r", "").partition("\n\n")
            if (kind == "Response" and what.startswith("200/INVITE")
                    and "v=0" in body):
                return True
            cur = None
            continue
        cur[2].append(line)
    return False


def recorded(path):
    try:
        with wave.open(str(path), "rb") as w:
            return w.getnframes() > 0
    except (OSError, EOFError, wave.Error):
        return False


def cpu_model():
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    try:
        r = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"],
                           capture_output=True, text=True, check=False)
        return r.stdout.strip() or None
    except OSError:
        return None


def nproc():
    try:
        return len(os.sched_getaffinity(0))
    except AttributeError:
        return os.cpu_count()


def host():
    n = nproc()
    image_os = os.environ.get("ImageOS")
    if image_os:
        name = f"GitHub-hosted runner {image_os} {os.environ.get('ImageVersion', '')}"
    else:
        name = platform.node()
    parts = [name.strip()]
    cpu = cpu_model()
    if cpu:
        parts.append(cpu)
    parts.append(f"{n} cpus")
    clock = "pjsua --null-audio, system clock"
    try:
        cs = Path(CLOCKSOURCE).read_text().strip()
        clock += f", kernel clocksource {cs}"
    except OSError:
        pass
    return {"name": ", ".join(parts), "clock_source": clock,
            "kernel": platform.release(), "nproc": n}


def pjsua_version(dockerfile):
    try:
        m = re.search(r"^ARG PJPROJECT_TAG=(\S+)", Path(dockerfile).read_text(), re.M)
        return m.group(1) if m else "unknown"
    except OSError:
        return "unknown"


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    out, state = Path(argv[0]), Path(argv[1])
    clip_id = env("T_CLIP")
    padded = json.loads(Path(env("T_PADDED")).read_text())
    clip = padded["clips"][clip_id]
    problems = []
    parts = []
    for spec in env("T_PARTS").split(","):
        name, role, codec, rate, sip, rtp, dur = spec.split()
        start, end = read(state, name, "start"), read(state, name, "end")
        rc = read(state, name, "rc")
        timed_out = (state / f"{name}.timeout").is_file()
        p = {"name": name, "role": role, "codec": codec, "clock_rate": int(rate),
             "ptime": 20, "sip_port": int(sip), "rtp_port": int(rtp),
             "duration": int(dur),
             "start_epoch": round(float(start), 6) if start else None,
             "end_epoch": round(float(end), 6) if end else None,
             "rc": int(rc) if rc is not None else None, "timed_out": timed_out,
             "cmd": read(state, name, "cmd") or ""}
        parts.append(p)
        if timed_out:
            problems.append(f"{name}: still running 30 s after its expected end; "
                            "container killed")
        if p["rc"] != 0:
            problems.append(f"{name}: hd.sh exited {p['rc']} (see {name}.out "
                            f"and {name}.pjsua.log)")
        lp = out / f"{name}.pjsua.log"
        if not lp.is_file():
            problems.append(f"{name}: no pjsua log")
        elif not answered_with_sdp(lp.read_text(errors="replace")):
            problems.append(f"{name}: no 200 OK with SDP in the log "
                            "(call not answered?)")
        if not recorded(out / f"{name}.rx.wav"):
            problems.append(f"{name}: recording missing or empty")
    # what taq live-import needs to trust the trial (trial.schema.json)
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", env("T_UA_DIGEST")):
        problems.append(f"pjsua image {env('T_UA_IMAGE')}: no image id")
    if not re.fullmatch(r"[0-9a-f]{7,40}", env("T_CHAPPE")):
        problems.append("the chappe SHA of CHAPPE_DIR could not be read")
    if any(p["start_epoch"] is None or p["end_epoch"] is None for p in parts):
        problems.append("a call has no start or end time")
    starts = [p["start_epoch"] for p in parts if p["start_epoch"] is not None]
    ends = [p["end_epoch"] for p in parts if p["end_epoch"] is not None]
    doc = {
        "schema": "chappe-hd-trial/1",
        "id": env("T_ID"),
        "arm": env("T_ARM"),
        "rep": int(env("T_REP")),
        "condition_id": f"hd-room/{env('T_DIR')}/idle/clean",
        "path": env("T_PATH"),
        "load": "idle",
        "impairment": "clean",
        "seed": 0,
        "target": env("T_TARGET"),
        "clip": {"id": clip_id, "sha256": clip["sha256"],
                 "pad_s": padded["pad_s"], "play_s": clip["play_s"]},
        "started": iso(min(starts)) if starts else None,
        "ended": iso(max(ends)) if ends else None,
        "participants": parts,
        "ua": {"name": "pjsua", "version": pjsua_version(env("T_DOCKERFILE")),
               "image": env("T_UA_IMAGE"), "digest": env("T_UA_DIGEST")},
        "host": host(),
        "chappe": env("T_CHAPPE"),
    }
    (out / "trial.json").write_text(json.dumps(doc, indent=2) + "\n")
    for p in problems:
        print(f"problem: {p}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
