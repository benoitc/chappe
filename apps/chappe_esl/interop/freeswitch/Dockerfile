# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# The lab FreeSWITCH: drachtio's mrf image (FreeSWITCH 1.10.10 with
# mod_audio_fork) plus mod_audio_stream, so the live suite covers both fork
# backends of chappe_esl_call:audio_fork_start/3. Test-only.
#
# mod_audio_stream (https://github.com/amigniter/mod_audio_stream) is
# AGPL-3.0 with the FreeSWITCH linking exception. It is built here for the lab
# and never shipped with chappe.
# Pinned to a release tag and its commit, cloned with its libwsc submodule.

ARG FS_IMAGE=drachtio/drachtio-freeswitch-mrf:latest

FROM ${FS_IMAGE} AS build
ARG AUDIO_STREAM_TAG=v1.1.0
ARG AUDIO_STREAM_SHA=fe3af21d3058753e024a43ef7ca54af2077634a0
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential cmake git pkg-config ca-certificates \
      libevent-dev libspeexdsp-dev libssl-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "${AUDIO_STREAM_TAG}" --recurse-submodules \
      https://github.com/amigniter/mod_audio_stream.git /src \
 && test "$(git -C /src rev-parse HEAD)" = "${AUDIO_STREAM_SHA}"
RUN PKG_CONFIG_PATH=/usr/local/freeswitch/lib/pkgconfig \
      cmake -S /src -B /src/build -DCMAKE_BUILD_TYPE=Release \
 && cmake --build /src/build -j"$(nproc)"

FROM ${FS_IMAGE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends libevent-2.1-7 libevent-pthreads-2.1-7 libspeexdsp1 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/build/mod_audio_stream.so /usr/local/freeswitch/mod/
