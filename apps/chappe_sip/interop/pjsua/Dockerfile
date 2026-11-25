# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0

# Test image: stock pjsua from a pinned pjproject release, built here
# because Ubuntu 24.04 does not package the pjsua binary. No sound
# device: run it with --null-audio. The SIP stack is untouched, so it
# stands for an independent implementation of REFER, Replaces and
# session timers. It is also the HD peer of the wideband labs, with Opus
# (libopus) and G.722 (built in), driven by hd.sh.
# The base is pinned by digest, the source tarball by sha256.
ARG BASE=ubuntu:24.04@sha256:562111b88caa79c71391c0c4d3c2114a7d5c35915c20561fd893cb1e07929e6b

FROM ${BASE} AS build
ARG PJPROJECT_TAG=2.15.1
ARG PJPROJECT_SHA256=8f3bd99caf003f96ed8038b8a36031eb9d8cd9eaea1eaff7e01c2eef6bd55706
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends build-essential ca-certificates curl \
        libopus-dev libssl-dev pkg-config python3 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN curl -fsSL -o /tmp/pj.tar.gz \
        "https://github.com/pjsip/pjproject/archive/refs/tags/${PJPROJECT_TAG}.tar.gz" \
    && echo "${PJPROJECT_SHA256}  /tmp/pj.tar.gz" | sha256sum -c - \
    && tar xzf /tmp/pj.tar.gz --strip-components=1 \
    && rm /tmp/pj.tar.gz
RUN ./configure --disable-video --disable-sound --disable-libwebrtc \
        --disable-libyuv --disable-opencore-amr --disable-silk \
        --disable-sdl --disable-ffmpeg --disable-v4l2 --disable-openh264 \
        --disable-bcg729 --disable-speex-aec --with-opus=/usr \
        CFLAGS="-O2 -fPIC" \
    && make dep && make -j"$(nproc)" \
    && cp pjsip-apps/bin/pjsua-* /usr/local/bin/pjsua
# the HD codecs must be in: Opus is autodetected, G.722 is built in
RUN grep -q '^#define PJMEDIA_HAS_OPUS_CODEC 1' \
        pjmedia/include/pjmedia-codec/config_auto.h

FROM ${BASE}
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends libopus0 libssl3t64 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/pjsua /usr/local/bin/pjsua
WORKDIR /work
ENTRYPOINT ["pjsua"]
