#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Install a pinned rebar3 on a CI runner without the GitHub API. setup-beam
# lists rebar3's releases through api.github.com, which rate-limits (seen
# in CI: "3.28.0 not found in version list"), and its download gives up on
# the first 403 from the release host. Here the release asset is fetched
# straight, retried on any error, and checked against its sha256 (the
# digest GitHub publishes for the asset). Usage: scripts/ci_rebar3.sh VERSION
set -eu

VERSION=${1:?usage: ci_rebar3.sh VERSION}
case $VERSION in
    3.28.0) SHA256=5a28b1cca082d3b023ec0f5df9d9f9d52557036c6f2a21c1ffa11b93a984dd42 ;;
    *)
        echo "ci_rebar3: no sha256 pinned for rebar3 $VERSION; add it here" >&2
        exit 2
        ;;
esac

DIR=${RUNNER_TEMP:?RUNNER_TEMP not set}/rebar3-$VERSION
mkdir -p "$DIR"
curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 \
    --connect-timeout 30 --max-time 300 \
    -o "$DIR/rebar3" \
    "https://github.com/erlang/rebar3/releases/download/$VERSION/rebar3"
echo "$SHA256  $DIR/rebar3" | sha256sum -c -
chmod +x "$DIR/rebar3"
echo "$DIR" >> "${GITHUB_PATH:?GITHUB_PATH not set}"
(cd "$DIR" && ./rebar3 version)
