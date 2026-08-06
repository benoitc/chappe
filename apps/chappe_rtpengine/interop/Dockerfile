# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Test image: rtpengine from the Ubuntu 24.04 archive. Unlike the
# common minimal images, this build carries transcoding support, so
# publish/subscribe, play media and silence media are available.
# Built through interop/docker-compose.yml; no entrypoint on purpose
# (the compose command assembles the rtpengine command line).
FROM ubuntu:24.04
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends rtpengine openssl \
    && rm -rf /var/lib/apt/lists/* \
    && printf '[rtpengine]\n' > /etc/rtpengine/rtpengine.conf
