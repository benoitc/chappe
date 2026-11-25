#!/usr/bin/env bash
# The joint HD test: for each clip and direction, baseline rep 0,
# candidate, baseline rep 1 (interleaved, so a drift of the host hits both
# arms), then one PCMU join/leave run per arm and direction.
# Every trial runs; the campaign exits non-zero if any of them failed.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CLIPS="vctk092-p225-01 vctk092-p226-01 vctk092-p234-01 vctk092-p237-01 vctk092-p245-01 vctk092-p248-01 vctk092-p294-01 vctk092-p326-01"
FAILED=()
trial() {
    if ! "$HERE/run1.sh" "$@"; then FAILED+=("$*"); fi
}
for c in $CLIPS; do
    for d in g722-to-opus opus-to-g722; do
        trial baseline 0 "$d" "$c"
        trial candidate 0 "$d" "$c"
        trial baseline 1 "$d" "$c"
    done
done
for d in g722-to-opus opus-to-g722; do
    trial baseline 0 "$d" vctk092-p225-01 pcmu
    trial candidate 0 "$d" vctk092-p225-01 pcmu
done
if [ "${#FAILED[@]}" -ne 0 ]; then
    echo "campaign failed: ${#FAILED[@]} trial(s)" >&2
    printf '  %s\n' "${FAILED[@]}" >&2
    exit 1
fi
echo "campaign done"
