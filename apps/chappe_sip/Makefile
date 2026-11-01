# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0

# chappe_sip convenience targets over rebar3.
#
#   make            build (C engine + Erlang)
#   make test       eunit + ct
#   make test-static  lint + xref + dialyzer
#   make check      build + test + test-static
#   make interop    real-stack interop (needs node + docker)
#   make interop-conformance
#                   SIPp and pjsua against a chappe node (needs docker)
#   make asan       run the C NIF under ASan + UBSan (Linux container)
#   make tsan       the same under ThreadSanitizer
#   make lint-c     clang-tidy and gcc -fanalyzer on the shim
#   make fuzz       libFuzzer and the NIF fuzz suite (FUZZ_TIME seconds)

.PHONY: all compile test test-static check eunit ct lint xref dialyzer \
        fmt fmt-check docs interop interop-conformance asan tsan lint-c fuzz \
        clean

all: compile

docs:
	rebar3 ex_doc    # HTML into doc/ (open doc/index.html)

compile:
	rebar3 compile

eunit:
	rebar3 eunit

ct:
	rebar3 ct

test: eunit ct

lint:
	rebar3 lint

xref:
	rebar3 xref

dialyzer:
	rebar3 dialyzer

fmt:
	rebar3 fmt

fmt-check:
	rebar3 fmt --check

test-static: lint xref dialyzer

check: compile test test-static

# chappe_sip is an umbrella app: its suites run from the umbrella root
interop:
	cd ../.. && INTEROP=1 rebar3 ct \
	    --suite apps/chappe_sip/test/chappe_sip_interop_SUITE

interop-conformance:
	$(MAKE) -C ../.. interop-conformance

asan:
	test/asan/run.sh asan

tsan:
	test/asan/run.sh tsan

lint-c:
	test/asan/run.sh lint-c

FUZZ_TIME ?= 60
fuzz:
	FUZZ_TIME=$(FUZZ_TIME) test/asan/run.sh fuzz

clean:
	rebar3 clean
