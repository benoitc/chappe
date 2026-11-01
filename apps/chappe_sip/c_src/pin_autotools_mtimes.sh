#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Pin the autotools mtimes of a vendored sofia-sip tree so make never reruns
# aclocal or automake.
#
# Usage: pin_autotools_mtimes.sh SOFIA_DIR REF_FILE
#
# We vendor the autoreconf output (configure, Makefile.in, etc.). A git
# checkout gives the files arbitrary mtimes in nanosecond order, so the
# autotools rebuild rules may see an input (configure.ac, Makefile.am,
# m4/*.m4) or one generated file as newer than another and try to rerun
# aclocal/automake, which the build hosts do not have. Pin the inputs to an
# old date and give every generated file one identical mtime, that of
# REF_FILE (touched here): make never rebuilds a target that is as new as
# its prerequisites. build.sh calls it before every sofia build; the fuzz
# build reuses it.
set -eu

SOFIA=$1
REF=$2

find "$SOFIA" \( -name configure.ac -o -name Makefile.am \
   -o -path "*/m4/*.m4" -o -name acinclude.m4 \) \
   -exec touch -t 200001010000 {} +
touch "$REF"
find "$SOFIA" \( -name configure -o -name aclocal.m4 -o -name config.h.in \
   -o -name "Makefile.in" \) -exec touch -r "$REF" {} +
