# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0

# chappe umbrella convenience targets over rebar3.

.PHONY: all compile test test-static check eunit ct lint xref dialyzer \
        fmt fmt-check asan clean

all: compile

compile:
	rebar3 compile

eunit:
	rebar3 eunit

ct:
	rebar3 ct

lint:
	rebar3 lint

xref:
	rebar3 xref

dialyzer:
	rebar3 dialyzer

fmt:
	rebar3 fmt -w

fmt-check:
	rebar3 fmt -c

test: eunit ct

test-static: lint xref dialyzer fmt-check

check: compile test test-static

# The C NIF under AddressSanitizer in a Linux container.
asan:
	apps/chappe_sip/test/asan/run.sh

clean:
	rebar3 clean
