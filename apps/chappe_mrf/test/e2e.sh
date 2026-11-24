#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Runs chappe_mrf_live_SUITE and chappe_mrf_hd_live_SUITE (pjsua callers
# through apps/chappe_sip/interop/pjsua/hd.sh) against the lab of
# apps/chappe_mrf/interop/docker-compose.yml (rtpengine, fs1, fs2),
# brought up and torn down here. `up --wait' blocks on the FreeSWITCH
# healthchecks; MRF=1 makes the suite run instead of skip. The suite stops
# and starts fs1 itself through MRF_COMPOSE.
#
# MRF_PROJECT (compose project, default chappe-mrf) and the MRF_* ports of
# the compose file move the lab out of the way of another one;
# MRF_SIP_PORT (17060) is the chappe node's own SIP port, MRF_MEDIA_DIR
# (_build/mrf-media) the shared /media. The chappe_mrf listener binds
# MRF_ESL_IP (0.0.0.0) and takes the peers of MRF_ESL_ALLOW (loopback and
# docker's pools, comma-separated CIDRs). MRF_KEEP=1 leaves the lab up.
#
# Usage: apps/chappe_mrf/test/e2e.sh   (or: make interop-mrf)
set -u

cd "$(dirname "$0")/../../.."
: "${MRF_NG_PORT:=17222}" "${MRF_RTP_MIN:=31200}" "${MRF_RTP_MAX:=31299}"
: "${MRF_FS1_SIP:=17081}" "${MRF_FS2_SIP:=17082}"
: "${MRF_FS1_ESL:=17031}" "${MRF_FS2_ESL:=17032}"
: "${MRF_SOCKET_PORT:=17084}" "${MRF_SIP_PORT:=17060}"
# created here, before docker would create it owned by root
MRF_MEDIA_DIR=${MRF_MEDIA_DIR:-$(pwd)/_build/mrf-media}
mkdir -p "$MRF_MEDIA_DIR"
chmod 777 "$MRF_MEDIA_DIR"
export MRF_NG_PORT MRF_RTP_MIN MRF_RTP_MAX MRF_FS1_SIP MRF_FS2_SIP \
    MRF_FS1_ESL MRF_FS2_ESL MRF_SOCKET_PORT MRF_SIP_PORT MRF_MEDIA_DIR
# absolute: the suite runs it from the CT log directory
COMPOSE="docker compose -p ${MRF_PROJECT:-chappe-mrf} -f $(pwd)/apps/chappe_mrf/interop/docker-compose.yml"

if ! $COMPOSE up -d --build --wait --wait-timeout 180; then
    echo "the lab did not become healthy:" >&2
    $COMPOSE logs >&2
    $COMPOSE down >/dev/null 2>&1
    exit 1
fi

# the address rtpengine reaches the host at (chappe_mix legs live there)
MEDIA_IP="$($COMPOSE exec -T rtpengine getent hosts host.docker.internal \
    2>/dev/null | awk '{print $1}')"

MRF=1 MRF_MEDIA_IP="$MEDIA_IP" MRF_COMPOSE="$COMPOSE" \
    rebar3 ct --dir apps/chappe_mrf/test \
    --suite chappe_mrf_live_SUITE,chappe_mrf_hd_live_SUITE
RC=$?

if [ "${MRF_KEEP:-0}" != "1" ]; then
    $COMPOSE down >/dev/null 2>&1
fi
exit $RC
