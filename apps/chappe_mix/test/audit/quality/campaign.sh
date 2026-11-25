#!/bin/sh
# The joint HD test: for each clip and direction, baseline rep 0,
# candidate, baseline rep 1 (interleaved, so a drift of the host hits both
# arms), then one PCMU join/leave run per arm and direction.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CLIPS="vctk092-p225-01 vctk092-p226-01 vctk092-p234-01 vctk092-p237-01 vctk092-p245-01 vctk092-p248-01 vctk092-p294-01 vctk092-p326-01"
for c in $CLIPS; do
    for d in g722-to-opus opus-to-g722; do
        sh "$HERE/run1.sh" baseline 0 "$d" "$c"
        sh "$HERE/run1.sh" candidate 0 "$d" "$c"
        sh "$HERE/run1.sh" baseline 1 "$d" "$c"
    done
done
for d in g722-to-opus opus-to-g722; do
    sh "$HERE/run1.sh" baseline 0 "$d" vctk092-p225-01 pcmu
    sh "$HERE/run1.sh" candidate 0 "$d" vctk092-p225-01 pcmu
done
echo campaign done
