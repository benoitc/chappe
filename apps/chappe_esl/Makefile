# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0

# chappe_esl convenience targets over rebar3.
#
#   make            compile
#   make test       eunit + ct
#   make test-static  lint + xref + dialyzer + fmt-check
#   make check      compile + test + test-static
#   make interop    live suite against a real FreeSWITCH (needs FS_HOST)

.PHONY: all compile test test-static check eunit ct lint xref dialyzer \
        fmt fmt-check docs interop clean

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
	rebar3 fmt -w

fmt-check:
	rebar3 fmt -c

test-static: lint xref dialyzer fmt-check

check: compile test test-static

interop:
	rebar3 ct --suite test/chappe_esl_live_SUITE

clean:
	rebar3 clean
