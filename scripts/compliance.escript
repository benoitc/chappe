#!/usr/bin/env escript
%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Generate an app's compliance matrix (see
%% apps/chappe_sip/test/chappe_sip_compliance.erl).
%% Usage: scripts/compliance.escript REQS.tsv TESTDIR CTLOGDIR OUT.md
%%            [--gate TIER,...]
%% `make compliance' runs it after `rebar3 as test compile'.
main(Args) ->
    true = code:add_patha("_build/test/lib/chappe_sip/test"),
    chappe_sip_compliance:main(Args).
