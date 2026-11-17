# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0

# chappe umbrella convenience targets over rebar3.

.PHONY: all compile test test-static check eunit ct lint xref dialyzer \
        fmt fmt-check asan tsan lint-c fuzz interop interop-mix interop-ref bench-ref bench-pass \
        interop-conformance interop-esl demo-esl interop-sbc interop-mrf \
        interop-cluster compliance \
        cover docs clean advisories-test \
        demo demo-compile demo-shell demo-down demo-cluster demo-cluster-smoke \
        demo-cluster-shell demo-cluster-down

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

# The C NIF in a Linux container (apps/chappe_sip/test/asan/run.sh).
# asan: the engine suites under ASan + UBSan; SUITES replaces the list,
# EXTRA_SUITES adds to it.
asan:
	apps/chappe_sip/test/asan/run.sh asan

# The lifecycle stress and smoke suites under ThreadSanitizer.
tsan:
	apps/chappe_sip/test/asan/run.sh tsan

# clang-tidy (apps/chappe_sip/c_src/.clang-tidy) and gcc -fanalyzer on the
# shim; any finding fails.
lint-c:
	apps/chappe_sip/test/asan/run.sh lint-c

# The libFuzzer targets (apps/chappe_sip/c_src/fuzz) for FUZZ_TIME seconds
# each, then the NIF boundary fuzz suite (FUZZ_ITERS, FUZZ_SEED), all under
# ASan + UBSan.
FUZZ_TIME ?= 60
fuzz:
	FUZZ_TIME=$(FUZZ_TIME) apps/chappe_sip/test/asan/run.sh fuzz

# The gated rtpengine suites against a real daemon in docker.
interop:
	apps/chappe_rtpengine/test/e2e.sh

# The ESL client against a real FreeSWITCH in docker.
interop-esl:
	apps/chappe_esl/test/e2e.sh

# chappe_mrf against rtpengine and two FreeSWITCH media servers in docker
# (IVR, bridging, recording, native and FreeSWITCH conferences, a node
# stopped mid-call; apps/chappe_mrf/interop).
interop-mrf:
	apps/chappe_mrf/test/e2e.sh

# chappe_cluster nodes in docker under a seeded schedule of partitions,
# kills, pauses, delays and clock skews, then the lease checker over every
# node's log (apps/chappe_cluster/interop). SEED replays a run, DURATION
# sets its length (5m), NODES the node count (3 to 5). MODE=proofs runs
# each fault against a fake cluster with the matching bug and expects the
# checker to fail (about 20 minutes; by hand, not in CI).
interop-cluster:
	apps/chappe_cluster/test/e2e.sh

# Two FreeSWITCH nodes and a shell with chappe_esl monitoring them
# (apps/chappe_esl/examples/README.md).
demo-esl:
	apps/chappe_esl/examples/nodes.sh

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

# The measuring pass over the mixer's arms (the PERF.md rows), interleaved,
# five launches each. PASS picks the group (cost, timer, prefill, events,
# capacity, ref, all); see apps/chappe_mix/bench/pass.sh.
PASS ?= all
bench-pass:
	apps/chappe_mix/bench/pass.sh $(PASS)

# The unit tests of scripts/advisories.py (versions, ranges, fail-closed
# cases); the Advisories workflow runs them before its checks.
advisories-test:
	python3 -I scripts/advisories_test.py

# Each app's compliance matrix from its requirements, the `%% req:'
# annotations and the latest CT results. GATE=demo fails on any hard
# requirement of the demo tier that is not passing.
COMPLIANCE_APPS = chappe_sip chappe_mix chappe_rtpengine chappe_esl chappe_mrf

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

# The B2BUA as an SBC: SIPp calls through a chappe node to two FreeSWITCH
# peers, with rtpengine and Kamailio, all in docker
# (apps/chappe_sip/interop/sbc). SBC_LAB names the compose project.
interop-sbc:
	INTEROP=1 rebar3 ct --suite apps/chappe_sip/test/chappe_sip_sbc_interop_SUITE

# A small SBC to try by hand (demo/sbc/README.md): rtpengine and Kamailio in
# docker, the chappe node in the foreground on this machine. make demo-shell
# attaches a shell to it; make demo-down stops the containers.
DEMO_NODE ?= demo
DEMO_COMPOSE = docker compose -f demo/sbc/docker-compose.yml

demo:
	rebar3 compile
	mkdir -p _build/demo _build/demo-media
	chmod 777 _build/demo-media
	$(DEMO_COMPOSE) up -d --build
	erlc -o _build/demo demo/sbc/src/demo_sbc.erl
	DEMO_MEDIA_IP=$$($(DEMO_COMPOSE) exec -T rtpengine getent hosts \
	    host.docker.internal | awk '{print $$1}') \
	erl -noshell -sname $(DEMO_NODE)@localhost -setcookie chappe-demo \
	    -pa _build/default/lib/*/ebin _build/demo \
	    -eval 'ok = demo_sbc:start("demo/sbc/demo.config").'

# Compile the demos against the built apps, as CI does: erlc with
# warnings as errors, then xref fails on any call the apps do not export.
# Run it after rebar3 compile.
DEMO_SRC = demo/sbc/src/demo_sbc.erl $(wildcard demo/cluster/src/*.erl)
DEMO_XREF = try \
	    {ok, _} = xref:start(demo_xref), \
	    ok = xref:set_default(demo_xref, [{warnings, false}, {verbose, false}]), \
	    ok = xref:set_library_path(demo_xref, code_path), \
	    {ok, [_ | _]} = xref:add_directory(demo_xref, "_build/demo"), \
	    {ok, Undef} = xref:analyze(demo_xref, undefined_function_calls), \
	    [io:format("undefined call: ~p -> ~p~n", [F, T]) || {F, T} <- Undef], \
	    halt(min(length(Undef), 1)) \
	catch C:R -> io:format("demo xref failed: ~p:~p~n", [C, R]), halt(2) end.

demo-compile:
	mkdir -p _build/demo
	erlc +warnings_as_errors +debug_info -o _build/demo $(DEMO_SRC)
	erl -noshell -pa _build/default/lib/*/ebin -eval '$(DEMO_XREF)'

demo-shell:
	erl -sname demo-shell-$$$$@localhost -setcookie chappe-demo \
	    -remsh $(DEMO_NODE)@localhost

demo-down:
	$(DEMO_COMPOSE) down

# Three chappe nodes on chappe_cluster in docker (demo/cluster/README.md):
# one registrar, one conference room and one trunk pinger across them.
# demo-cluster-smoke runs the README's walkthrough with SIPp and checks it;
# demo-cluster-shell N=n1 attaches a shell to a node.
DEMO_CLUSTER_COMPOSE = docker compose -f demo/cluster/docker-compose.yml
N ?= n1

demo-cluster:
	$(DEMO_CLUSTER_COMPOSE) build build
	$(DEMO_CLUSTER_COMPOSE) up -d
	$(DEMO_CLUSTER_COMPOSE) exec -T ctl demo-node ctl-run ready
	@echo "demo-cluster: up; see demo/cluster/README.md"

demo-cluster-smoke:
	demo/cluster/smoke.sh

demo-cluster-shell:
	$(DEMO_CLUSTER_COMPOSE) exec $(N) demo-node shell $(N)

demo-cluster-down:
	$(DEMO_CLUSTER_COMPOSE) --profile tools down -v

# eunit + ct line coverage over every app; fails under MIN_COVERAGE percent.
# Raise MIN_COVERAGE as coverage grows, never lower it.
MIN_COVERAGE ?= 0

cover:
	rm -rf _build/test/cover _build/test/lib/chappe_*/test
	rebar3 eunit --cover
	rebar3 ct --cover
	rebar3 cover --verbose --min_coverage=$(MIN_COVERAGE)

# ex_doc HTML for each app that configures it (an `{ex_doc, ...}' entry in
# its rebar.config), written to apps/<app>/doc; apps without one are
# skipped. Each app is built on its own from its directory, as it is
# published, because its ex_doc paths are relative to it; the C engine is
# not needed for docs.
# Each app builds its docs from its own directory (ex_doc extras are
# relative to the app); the umbrella is compiled first and put on the code
# path so an app that depends on its siblings (chappe_mrf) finds them.
docs:
	@SKIP_ENGINE_BUILD=1 rebar3 compile >/dev/null
	@failed=; for dir in apps/*/; do \
	    app=$$(basename $$dir); \
	    if grep -q '^{ex_doc,' $$dir/rebar.config 2>/dev/null; then \
	        echo "$$app:"; \
	        (cd $$dir && ERL_LIBS=$(CURDIR)/_build/default/lib SKIP_ENGINE_BUILD=1 \
	            REBAR_BASE_DIR=$(CURDIR)/_build/docs/$$app rebar3 ex_doc) \
	            || failed="$$failed $$app"; \
	    else \
	        echo "$$app: no ex_doc config, skipped"; \
	    fi; \
	done; \
	if [ -n "$$failed" ]; then echo "docs failed for:$$failed"; exit 1; fi

clean:
	rebar3 clean
