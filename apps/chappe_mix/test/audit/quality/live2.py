"""taq live with a codec and clock rate per participant.

taq live enables one codec for every participant. For a G.722 talker and
an Opus listener (or the reverse) this wraps taq.live.pjsua_args: the
talker (alice) gets TAQ_TALKER_CODEC / TAQ_TALKER_RATE, every listener
TAQ_LISTENER_CODEC / TAQ_LISTENER_RATE; everything else is taq live as it
ships (same pjsua image, same options, same run directory, same import).
The codecs of each leg are read back from the SDP files by taq capture.

Usage: uv run --project <taq repo> python live2.py live <taq live args>
"""

import os
import sys

from taq import cli, live

_orig = live.pjsua_args


def pjsua_args(name, target, codec, clock_rate, *rest):
    role = "TALKER" if name == live.NAMES[0] else "LISTENER"
    codec = os.environ.get(f"TAQ_{role}_CODEC", codec)
    clock_rate = int(os.environ.get(f"TAQ_{role}_RATE", clock_rate))
    return _orig(name, target, codec, clock_rate, *rest)


live.pjsua_args = pjsua_args

if __name__ == "__main__":
    sys.exit(cli.main(sys.argv[1:]))
