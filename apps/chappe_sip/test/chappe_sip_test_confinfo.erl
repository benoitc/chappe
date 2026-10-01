%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Checks a conference-info+xml body the way a watcher would: well formed
%% and valid against the RFC 4575 schema (test/fixtures/conference-info.xsd,
%% loaded offline). Shared by chappe_sip_confinfo_tests and
%% chappe_sip_focus_SUITE; a failure raises, so it works under both.
-module(chappe_sip_test_confinfo).

-export([validate/1, conference_info/1]).

%% The parsed root element of a valid document.
validate(Body) ->
    {El, []} = xmerl_scan:string(binary_to_list(Body), [{quiet, true}]),
    case xmerl_xsd:validate(El, schema()) of
        {error, E} -> erlang:error({invalid_conference_info, E, Body});
        {_, _} -> El
    end.

%% The root attributes a watcher tracks, plus the body.
conference_info(Body) ->
    El = validate(Body),
    Attrs = maps:from_list([
        {atom_to_list(N), V}
     || {xmlAttribute, N, _, _, _, _, _, _, V, _} <- element(8, El)
    ]),
    #{
        version => list_to_integer(maps:get("version", Attrs)),
        state => maps:get("state", Attrs, "full"),
        body => Body
    }.

schema() ->
    Src = proplists:get_value(source, ?MODULE:module_info(compile)),
    Xsd = filename:join([
        filename:dirname(Src), "fixtures", "conference-info.xsd"
    ]),
    {ok, Schema} = xmerl_xsd:process_schema(Xsd),
    Schema.
