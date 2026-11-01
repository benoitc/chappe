#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Runs every target c_src/fuzz/build.sh built, for SECONDS each (default 60).
# Usage: c_src/fuzz/run.sh [SECONDS] [OUTDIR]
#
# Each target starts from its committed seeds (corpus/<target>: crash inputs
# kept as regression seeds), seeds made from the RFC 4475 torture messages
# and the SIPp scenarios, and the corpus earlier runs grew in
# c_src/build/fuzz/corpus. A crash input is written to OUTDIR (default
# c_src/build/fuzz/artifacts) and fails the run; once fixed, commit it under
# corpus/<target>/.
set -e

FUZZ="$(cd "$(dirname "$0")" && pwd)"
CSRC="$(dirname "$FUZZ")"
APP="$(dirname "$CSRC")"
OUT="$CSRC/build/fuzz"
SECS=${1:-60}
ART=${2:-$OUT/artifacts}
mkdir -p "$ART"

# seeds: whole messages for fuzz_sip_msg, their header block for
# fuzz_sip_headers
SEEDS="$OUT/seeds"
rm -rf "$SEEDS"
mkdir -p "$SEEDS/fuzz_sip_msg" "$SEEDS/fuzz_sip_headers"
for f in "$APP"/test/chappe_sip_rfc4475_SUITE_data/rfc4475/*.dat; do
    cp "$f" "$SEEDS/fuzz_sip_msg/rfc4475_$(basename "$f" .dat)"
done
# a SIPp <send> CDATA block is a message template: fill its [keywords] with
# plain values and end its lines with CRLF
for f in "$APP"/interop/sipp/scenarios/*.xml; do
    awk -v dir="$SEEDS/fuzz_sip_msg" -v base="sipp_$(basename "$f" .xml)" '
        /<!\[CDATA\[/ {
            inmsg = 1; started = 0; n++; out = dir "/" base "_" n
            sub(/.*<!\[CDATA\[/, "")
        }
        inmsg && /\]\]>/ { inmsg = 0; printf "\r\n" > out; close(out); next }
        inmsg {
            sub(/^[ \t]+/, "")
            if (!started && $0 == "") next
            started = 1
            gsub(/\[call_id\]/, "fuzz-1@127.0.0.1")
            gsub(/\[(local_ip|remote_ip|media_ip|service)\]/, "127.0.0.1")
            gsub(/\[(local_port|remote_port|media_port)\]/, "5060")
            gsub(/\[len\]/, "0")
            gsub(/\[[a-z_0-9:+-]+\]/, "x")
            printf "%s\r\n", $0 > out
        }' "$f"
done
for f in "$SEEDS"/fuzz_sip_msg/*; do
    awk 'NR > 1 { if ($0 == "" || $0 == "\r") exit; print }' "$f" \
        >"$SEEDS/fuzz_sip_headers/$(basename "$f")"
done

# halt on any UBSan report the suppressions do not cover
export UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1:suppressions=$FUZZ/ubsan.supp"
export ASAN_OPTIONS="abort_on_error=1:detect_leaks=1"

rc=0
for bin in "$OUT"/bin/fuzz_*; do
    t=$(basename "$bin")
    mkdir -p "$OUT/corpus/$t" "$FUZZ/corpus/$t"
    echo "==> $t for ${SECS}s"
    # -max_len: big enough for the multi-part and long-header cases, small
    # enough to keep the exec rate up (the targets take up to 256 KiB)
    "$bin" -max_total_time="$SECS" -max_len=65536 -timeout=25 \
        -print_final_stats=1 -artifact_prefix="$ART/$t-" \
        "$OUT/corpus/$t" "$FUZZ/corpus/$t" "$SEEDS/$t" \
        >"$ART/$t.log" 2>&1 || rc=1
    grep -E '^(stat::|#[0-9]+ +DONE|==[0-9]+==ERROR|SUMMARY)|runtime error' \
        "$ART/$t.log" || true
done
exit $rc
