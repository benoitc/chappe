# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0

# chappe umbrella convenience targets over rebar3.

.PHONY: all compile test test-static check eunit ct lint xref dialyzer \
        fmt fmt-check asan interop interop-mix interop-ref bench-ref \
        interop-conformance compliance cover clean

all: compile

compile:
	rebar3 compile

eunit:
	rebar3 eunit

# rebar3 copies each app's test dir into _build and never prunes it, so a
# deleted suite would still run; drop the copies first.
ct:
	rm -rf _build/test/lib/chappe_*/test
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

# The gated rtpengine suites against a real daemon in docker.
interop:
	apps/chappe_rtpengine/test/e2e.sh

# The mixer behind a real rtpengine (transcoded legs, N-1 by Goertzel).
interop-mix:
	apps/chappe_mix/test/interop.sh

# The mixer against FreeSWITCH mod_conference (same tones, same judge).
interop-ref:
	apps/chappe_mix/test/ref.sh suite

# A bench arm against mod_conference. REF picks where and what, e.g.
# REF="vm ref_capacity fs" (see apps/chappe_mix/bench/README.md).
REF ?= host ref_latency
bench-ref:
	apps/chappe_mix/test/ref.sh $(REF)

# Each app's compliance matrix from its requirements, the `%% req:'
# annotations and the latest CT results. GATE=demo fails on any hard
# requirement of the demo tier that is not passing.
COMPLIANCE_APPS = chappe_sip chappe_mix chappe_rtpengine

compliance:
	rebar3 as test compile
	@set -e; for app in $(COMPLIANCE_APPS); do \
	    echo "$$app:"; \
	    scripts/compliance.escript apps/$$app/docs/compliance/requirements.tsv \
	        apps/$$app/test _build/test/logs apps/$$app/docs/compliance.md \
	        $(if $(GATE),--gate $(GATE)); \
	done

# chappe_sip against SIPp and pjsua in docker, one flow per RFC clause,
# with a dnsmasq server for the RFC 3263 cases
# (apps/chappe_sip/interop/conformance). Known gaps are listed in
# apps/chappe_sip/interop/conformance/expected-fail.
interop-conformance:
	CONFORMANCE=1 rebar3 ct \
	    --suite apps/chappe_sip/test/chappe_sip_conformance_SUITE

# eunit + ct line coverage over every app; fails under MIN_COVERAGE percent.
# Raise MIN_COVERAGE as coverage grows, never lower it.
MIN_COVERAGE ?= 0

cover:
	rm -rf _build/test/cover _build/test/lib/chappe_*/test
	rebar3 eunit --cover
	rebar3 ct --cover
	rebar3 cover --verbose --min_coverage=$(MIN_COVERAGE)

clean:
	rebar3 clean
