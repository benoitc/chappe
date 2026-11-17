#!/usr/bin/env escript
%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Generate an app's compliance matrix (see
%% scripts/compliance/chappe_sip_compliance.erl, compiled here).
%% Usage: scripts/compliance.escript REQS.tsv TESTDIR CTLOGDIR OUT.md
%%            [--gate TIER,...]
%% `make compliance' runs it after `rebar3 as test compile'.
main(Args) ->
    Src = filename:join([
        filename:dirname(escript:script_name()),
        "compliance",
        "chappe_sip_compliance.erl"
    ]),
    {ok, Mod, Bin} = compile:file(Src, [binary, report]),
    {module, Mod} = code:load_binary(Mod, Src, Bin),
    Mod:main(Args).
