# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# The lab FreeSWITCH, shared by the chappe_esl and chappe_mrf labs:
# drachtio's mrf image (FreeSWITCH 1.10.10 at 4cb05e7) plus the modules the
# live suites need and the image lacks. Test-only, never shipped with
# chappe.
#
# The base image already ships mod_audio_fork, mod_say_en, mod_spandsp
# (tone and fax detection) and mod_avmd. Built here:
#
# - mod_audio_stream (https://github.com/amigniter/mod_audio_stream),
#   AGPL-3.0 with the FreeSWITCH linking exception, pinned to a release tag
#   and its commit, cloned with its libwsc submodule.
# - mod_flite, the text to speech module of FreeSWITCH itself (MPL-1.1),
#   from the FreeSWITCH commit the base image runs, its source checked by
#   sha256, linked against Debian's flite (CMU, BSD-style licence).

ARG FS_IMAGE=drachtio/drachtio-freeswitch-mrf@sha256:2f1583c31259fbf38df3df2e0955e2ffda7f6d2410888718de110b568ea9dac3

FROM ${FS_IMAGE} AS build
ARG AUDIO_STREAM_TAG=v1.1.0
ARG AUDIO_STREAM_SHA=fe3af21d3058753e024a43ef7ca54af2077634a0
ARG FS_SHA=4cb05e7f4a23645ec387f3b5391194128be7d193
ARG FLITE_SRC_SHA256=cac4d9027c910ae6dab856888c81cf4250e6d0cc0ecf597663e2577911038754
# apt as scripts/ci_apt.sh runs it: a stalled mirror or a stale index fails
# one bounded attempt, and the next one fetches the index again
RUN printf 'Acquire::Retries "3";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' \
      > /etc/apt/apt.conf.d/80-retries \
 && for i in 1 2 3; do \
      timeout 300 apt-get update \
      && timeout 900 apt-get install -y --no-install-recommends \
           build-essential cmake git pkg-config ca-certificates curl \
           libevent-dev libspeexdsp-dev libssl-dev zlib1g-dev flite1-dev \
      && break; \
      [ "$i" -lt 3 ] || exit 1; sleep $((i * 15)); \
    done \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "${AUDIO_STREAM_TAG}" --recurse-submodules \
      https://github.com/amigniter/mod_audio_stream.git /src \
 && test "$(git -C /src rev-parse HEAD)" = "${AUDIO_STREAM_SHA}"
RUN PKG_CONFIG_PATH=/usr/local/freeswitch/lib/pkgconfig \
      cmake -S /src -B /src/build -DCMAKE_BUILD_TYPE=Release \
 && cmake --build /src/build -j"$(nproc)"
RUN mkdir /flite \
 && curl -fsSL -o /flite/mod_flite.c \
      "https://raw.githubusercontent.com/signalwire/freeswitch/${FS_SHA}/src/mod/asr_tts/mod_flite/mod_flite.c" \
 && echo "${FLITE_SRC_SHA256}  /flite/mod_flite.c" | sha256sum -c - \
 && gcc -O2 -fPIC -shared -o /flite/mod_flite.so /flite/mod_flite.c \
      $(PKG_CONFIG_PATH=/usr/local/freeswitch/lib/pkgconfig pkg-config --cflags --libs freeswitch) \
      -lflite_cmu_us_awb -lflite_cmu_us_kal -lflite_cmu_us_kal16 \
      -lflite_cmu_us_rms -lflite_cmu_us_slt -lflite_cmulex \
      -lflite_usenglish -lflite -lm

FROM ${FS_IMAGE}
RUN printf 'Acquire::Retries "3";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' \
      > /etc/apt/apt.conf.d/80-retries \
 && for i in 1 2 3; do \
      timeout 300 apt-get update \
      && timeout 900 apt-get install -y --no-install-recommends \
           libevent-2.1-7 libevent-pthreads-2.1-7 libspeexdsp1 libflite1 \
      && break; \
      [ "$i" -lt 3 ] || exit 1; sleep $((i * 15)); \
    done \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/build/mod_audio_stream.so /usr/local/freeswitch/mod/
COPY --from=build /flite/mod_flite.so /usr/local/freeswitch/mod/
