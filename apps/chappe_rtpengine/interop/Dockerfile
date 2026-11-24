# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Test image: rtpengine built from an upstream sipwise/rtpengine release
# tag, the userspace daemon only (no kernel module). The distribution
# packages lag: Ubuntu 24.04 ships 11.5, which has no L16 RTP codec, and
# the 16 kHz rooms need it. The build carries transcoding, so
# publish/subscribe, play media and silence media are available.
#
# The tag is checked against its commit; the base is pinned by digest
# (the multi-arch index, so arm64 laptops and amd64 CI get the same
# release). Built through interop/docker-compose.yml; no entrypoint on
# purpose (the compose command assembles the rtpengine command line).
# Test-only, never shipped with chappe.

ARG BASE=ubuntu:26.04@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db

FROM ${BASE} AS build
ARG RTPENGINE_TAG=mr26.3.1.4
ARG RTPENGINE_SHA=1165c63dec35c64d315ca9c57cc6b6d63365132d
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git ca-certificates devscripts equivs build-essential
RUN git clone --depth 1 --branch "${RTPENGINE_TAG}" \
      https://github.com/sipwise/rtpengine /src \
 && test "$(git -C /src rev-parse HEAD)" = "${RTPENGINE_SHA}"
WORKDIR /src
RUN mk-build-deps -i -r -t 'apt-get -y --no-install-recommends' debian/control
# -B: the architecture packages only (the daemon among them); nocheck
# skips the upstream test suite
RUN DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -B -us -uc

FROM ${BASE}
ENV DEBIAN_FRONTEND=noninteractive
COPY --from=build /ngcp-rtpengine-daemon_*.deb /tmp/
# the package's rtpengine.conf turns on settings the compose commands do
# not expect (listeners, interfaces); an empty section leaves the command
# line alone in charge
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      /tmp/ngcp-rtpengine-daemon_*.deb openssl \
 && rm -rf /var/lib/apt/lists/* /tmp/*.deb \
 && printf '[rtpengine]\n' > /etc/rtpengine/rtpengine.conf
