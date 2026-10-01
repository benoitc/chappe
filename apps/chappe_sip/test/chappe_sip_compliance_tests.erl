%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_sip_compliance_tests).

-include_lib("eunit/include/eunit.hrl").

tsv() ->
    <<
        "id\tsource\tsection\tline\tkeyword\tactor\trow\ttier\ttext\tnotes\n"
        "X-4.7-14\tExample spec\t4.7\t10399\tMUST\tua\tinvite\ttable\tCallId copied\tcheck INVITE\n"
        "R4579-07\tRFC 4579\t4.3\t300\tMUST\tfocus\tR1\ttable\tisfocus in OPTIONS\tOPTIONS 200\n"
        "R4579-02\tRFC 4579\t3.1\t120\tMAY\tfocus\tR1\ttable\tSDP info\toptional\n"
        "R4028-01\tRFC 4028\t9\t500\tMUST\tuas\ttimers\tplatform\trefresher\tSession-Expires\n"
        "R3515-01\tRFC 3515\t2\t136\tMUST\trefer-recipient\trefer\tdemo\tone Contact\t2xx Contact\n"
        "R4579-23\tRFC 4579\t6\t900\tSHOULD\tfocus\tR7\tdeviation\tS/MIME\tTLS instead\n"
    >>.

parse_test() ->
    {ok, Reqs} = chappe_sip_compliance:parse_requirements(tsv()),
    ?assertEqual(6, length(Reqs)),
    [R | _] = Reqs,
    ?assertMatch(
        #{id := <<"X-4.7-14">>, keyword := <<"MUST">>, tier := <<"table">>}, R
    ).

%% A line with the wrong number of fields is an error that names the line,
%% not a row silently dropped.
parse_rejects_short_line_test() ->
    Bad =
        <<"id\tsource\tsection\tline\tkeyword\tactor\trow\ttier\ttext\tnotes\nX\tonly\n">>,
    ?assertMatch(
        {error, {bad_line, 2, _}}, chappe_sip_compliance:parse_requirements(Bad)
    ).

parse_rejects_duplicate_ids_test() ->
    Dup = <<
        (tsv())/binary,
        "R4579-07\tRFC 4579\t4.3\t300\tMUST\tfocus\tR1\ttable\tdup\tdup\n"
    >>,
    ?assertMatch(
        {error, {duplicate_id, <<"R4579-07">>}},
        chappe_sip_compliance:parse_requirements(Dup)
    ).

%% `%% req:' lines bind the ids to the next function clause.
annotations_test() ->
    Src = <<
        "-module(x_SUITE).\n"
        "%% req: X-4.7-14 R4579-07\n"
        "%% A comment in between is fine.\n"
        "adhoc(Config) ->\n"
        "    ok.\n"
        "\n"
        "helper() -> ok.\n"
        "%% req: R4028-01\n"
        "timers(_Config) -> ok.\n"
    >>,
    ?assertEqual(
        [
            {<<"x_SUITE:adhoc">>, [<<"X-4.7-14">>, <<"R4579-07">>]},
            {<<"x_SUITE:timers">>, [<<"R4028-01">>]}
        ],
        chappe_sip_compliance:annotations(<<"x_SUITE">>, Src)
    ).

%% The latest result of a case wins across runs.
results_test() ->
    Old = <<"=case          x_SUITE:adhoc\n=result        failed: boom\n">>,
    New =
        <<"=case          x_SUITE:adhoc\n=result        ok\n=case          x_SUITE:timers\n=result        skipped: no rtpengine\n">>,
    R = chappe_sip_compliance:results([{1, Old}, {2, New}]),
    ?assertEqual(pass, maps:get(<<"x_SUITE:adhoc">>, R)),
    ?assertEqual(skip, maps:get(<<"x_SUITE:timers">>, R)),
    R2 = chappe_sip_compliance:results([{2, Old}, {1, New}]),
    ?assertEqual(fail, maps:get(<<"x_SUITE:adhoc">>, R2)).

%% A requirement passes only when every test that claims it passed; one
%% failure fails it; no test is untested; a skipped test proves nothing.
status_test() ->
    {ok, Reqs} = chappe_sip_compliance:parse_requirements(tsv()),
    Ann = [
        {<<"s:a">>, [<<"X-4.7-14">>]},
        {<<"s:b">>, [<<"X-4.7-14">>, <<"R4579-07">>]},
        {<<"s:c">>, [<<"R4028-01">>]}
    ],
    Res = #{<<"s:a">> => pass, <<"s:b">> => fail, <<"s:c">> => skip},
    M = maps:from_list([
        {Id, S}
     || #{id := Id, status := S} <- chappe_sip_compliance:matrix(Reqs, Ann, Res)
    ]),
    ?assertEqual(fail, maps:get(<<"X-4.7-14">>, M)),
    ?assertEqual(fail, maps:get(<<"R4579-07">>, M)),
    ?assertEqual(untested, maps:get(<<"R4028-01">>, M)),
    ?assertEqual(untested, maps:get(<<"R4579-02">>, M)),
    ?assertEqual(deviation, maps:get(<<"R4579-23">>, M)).

%% The gate: a hard requirement of a gated tier that is not passing fails
%% it; a MAY, another tier or a documented deviation does not.
gate_test() ->
    {ok, Reqs} = chappe_sip_compliance:parse_requirements(tsv()),
    Ann = [{<<"s:a">>, [<<"X-4.7-14">>, <<"R4579-07">>, <<"R3515-01">>]}],
    Pass = chappe_sip_compliance:matrix(Reqs, Ann, #{<<"s:a">> => pass}),
    ?assertEqual(ok, chappe_sip_compliance:gate(Pass, [<<"table">>])),
    Fail = chappe_sip_compliance:matrix(Reqs, Ann, #{<<"s:a">> => fail}),
    ?assertMatch(
        {error, [_, _]}, chappe_sip_compliance:gate(Fail, [<<"table">>])
    ),
    ?assertEqual(
        {error, [<<"R3515-01">>]},
        chappe_sip_compliance:gate(Fail, [<<"demo">>])
    ),
    None = chappe_sip_compliance:matrix(Reqs, [], #{}),
    ?assertEqual(
        {error, [<<"R3515-01">>]}, chappe_sip_compliance:gate(None, [<<"demo">>])
    ).

%% `--gate TIER,...' names the gated tiers; a bare `--gate' keeps `table'.
args_test() ->
    ?assertEqual(
        {["a", "b", "c", "d"], none}, chappe_sip_compliance:args(["a", "b", "c", "d"])
    ),
    ?assertEqual(
        {["a", "b", "c", "d"], [<<"table">>]},
        chappe_sip_compliance:args(["a", "b", "c", "d", "--gate"])
    ),
    ?assertEqual(
        {["a", "b", "c", "d"], [<<"demo">>, <<"platform">>]},
        chappe_sip_compliance:args(["a", "b", "c", "d", "--gate", "demo,platform"])
    ).

%% Unknown ids in annotations are reported, so a typo cannot pretend to
%% cover something.
unknown_ids_test() ->
    {ok, Reqs} = chappe_sip_compliance:parse_requirements(tsv()),
    ?assertEqual(
        [{<<"s:a">>, <<"X-9.9-99">>}],
        chappe_sip_compliance:unknown_ids(Reqs, [
            {<<"s:a">>, [<<"X-9.9-99">>, <<"R4579-07">>]}
        ])
    ).

render_test() ->
    {ok, Reqs} = chappe_sip_compliance:parse_requirements(tsv()),
    Md = iolist_to_binary(
        chappe_sip_compliance:render(chappe_sip_compliance:matrix(Reqs, [], #{}))
    ),
    ?assertNotEqual(nomatch, binary:match(Md, <<"| X-4.7-14 |">>)),
    ?assertNotEqual(nomatch, binary:match(Md, <<"untested">>)).
