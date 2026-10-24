#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# bob, inside the SIPp container: register, then answer one call on the
# same port (so the NAT binding the REGISTER opened carries the INVITE).
# Usage: bob.sh TARGET
set -eu
COMMON="-m 1 -l 1 -t u1 -p 5090 -nostdin -trace_err"
# shellcheck disable=SC2086
sipp -sf /demo/bob_register.xml $COMMON "$1"
echo "bob registered"
# shellcheck disable=SC2086
sipp -sf /demo/bob_answer.xml $COMMON -timeout 60 "$1"
