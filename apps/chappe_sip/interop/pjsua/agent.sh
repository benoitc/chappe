#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# One pjsua agent of the conformance lab, driven through a fifo so a
# script outside the container can type console commands at any time:
#
#   lab.sh cmd NAME 'm\nsip:x@y\n'
#
# Usage: agent.sh NAME [pjsua options...]
# It answers every call with 200 and logs SIP messages (level 5) on
# stdout, which scenario.sh reads with `lab.sh logs NAME`.
set -eu
NAME="$1"
shift
mkfifo /tmp/cmd
# Hold a writer open so pjsua never reads EOF between commands.
sleep infinity > /tmp/cmd &
# the lab network may carry IPv6 as well; the lab speaks IPv4
IP=$(hostname -i | tr ' ' '\n' | grep -v : | head -1)
exec pjsua \
    --id="sip:$NAME@$IP" \
    --null-audio --local-port=5060 --no-tcp --no-vad \
    --auto-answer=200 --log-level=5 --app-log-level=4 \
    "$@" < /tmp/cmd
