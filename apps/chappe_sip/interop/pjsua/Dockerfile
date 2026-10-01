# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0

# Test image: stock pjsua from a pinned pjproject release, built here
# because Ubuntu 24.04 does not package the pjsua binary. No sound
# device: run it with --null-audio. The SIP stack is untouched, so it
# stands for an independent implementation of REFER, Replaces and
# session timers.
FROM ubuntu:24.04 AS build
ARG PJPROJECT_TAG=2.15.1
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends build-essential ca-certificates curl \
        libssl-dev pkg-config python3 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN curl -fsSL \
        "https://github.com/pjsip/pjproject/archive/refs/tags/${PJPROJECT_TAG}.tar.gz" \
        | tar xz --strip-components=1
RUN ./configure --disable-video --disable-sound --disable-libwebrtc \
        --disable-libyuv --disable-opencore-amr --disable-silk \
        --disable-sdl --disable-ffmpeg --disable-v4l2 --disable-openh264 \
        --disable-bcg729 --disable-speex-aec --disable-opus \
        CFLAGS="-O2 -fPIC" \
    && make dep && make -j"$(nproc)" \
    && cp pjsip-apps/bin/pjsua-* /usr/local/bin/pjsua

FROM ubuntu:24.04
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends libssl3t64 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/pjsua /usr/local/bin/pjsua
WORKDIR /work
ENTRYPOINT ["pjsua"]
