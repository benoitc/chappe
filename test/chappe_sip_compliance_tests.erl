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
        "%% req: R3515-01\n"
        "gen_test_() -> [].\n"
    >>,
    ?assertEqual(
        [
            {<<"x_SUITE:adhoc">>, [<<"X-4.7-14">>, <<"R4579-07">>]},
            {<<"x_SUITE:timers">>, [<<"R4028-01">>]},
            {<<"x_SUITE:gen_test_">>, [<<"R3515-01">>]}
        ],
        chappe_sip_compliance:annotations(<<"x_SUITE">>, Src)
    ).

%% Results of one run, merged across its suite.log files.
results_test() ->
    A = <<"=case          x_SUITE:adhoc\n=result        failed: boom\n">>,
    B =
        <<"=case          y_SUITE:adhoc\n=result        ok\n=case          y_SUITE:timers\n=result        skipped: no rtpengine\n">>,
    R = chappe_sip_compliance:results([A, B]),
    ?assertEqual(fail, maps:get(<<"x_SUITE:adhoc">>, R)),
    ?assertEqual(pass, maps:get(<<"y_SUITE:adhoc">>, R)),
    ?assertEqual(skip, maps:get(<<"y_SUITE:timers">>, R)).

%% EUnit surefire testcases are keyed Module:Function; a generator's
%% tests carry its name and its result is their aggregate.
eunit_results_test() ->
    Xml = <<
        "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n"
        "<testsuite tests=\"6\" name=\"module 'm_tests'\">\n"
        "  <testcase time=\"0.001\" name=\"m_tests:0 plain_test\"/>\n"
        "  <testcase time=\"0.001\" name=\"m_tests:12 -gen_test_/0-fun-0-\"/>\n"
        "  <testcase time=\"0.001\" name=\"m_tests:13 -gen_test_/0-fun-2- (a case)\">\n"
        "    <failure type=\"assertEqual\">boom</failure>\n"
        "  </testcase>\n"
        "  <testcase time=\"0.001\" name=\"m_tests:20 ok_gen_test_\"/>\n"
        "  <testcase time=\"0.001\" name=\"m_tests:21 -ok_gen_test_/0-fun-1-\">\n"
        "    <system-out>noise</system-out>\n"
        "  </testcase>\n"
        "  <testcase time=\"0\" name=\"m_tests:30 -cut_test_/0-fun-3-\">\n"
        "    <skipped type=\"timeout\"/>\n"
        "  </testcase>\n"
        "  <testcase time=\"0\" name=\"m_tests:31 cut_test_\"/>\n"
        "  <testcase time=\"0\" name=\"fixture setup [1]\">\n"
        "    <error type=\"error\">setup</error>\n"
        "  </testcase>\n"
        "</testsuite>\n"
    >>,
    ?assertEqual(
        #{
            <<"m_tests:plain_test">> => pass,
            <<"m_tests:gen_test_">> => fail,
            <<"m_tests:ok_gen_test_">> => pass,
            <<"m_tests:cut_test_">> => skip
        },
        chappe_sip_compliance:eunit_results([Xml, <<"<testsuite/>">>])
    ).

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

%% Every claim must pass: one claim passed and another skipped, or one
%% passed and another has no result at all, leaves the row untested.
status_needs_every_claim_test() ->
    {ok, Reqs} = chappe_sip_compliance:parse_requirements(tsv()),
    Ann = [
        {<<"s:a">>, [<<"X-4.7-14">>, <<"R4579-07">>, <<"R4028-01">>]},
        {<<"s:b">>, [<<"X-4.7-14">>]},
        {<<"s:c">>, [<<"R4579-07">>]},
        {<<"s:d">>, [<<"R4028-01">>]}
    ],
    Res = #{<<"s:a">> => pass, <<"s:b">> => skip, <<"s:d">> => pass},
    M = maps:from_list([
        {Id, S}
     || #{id := Id, status := S} <- chappe_sip_compliance:matrix(Reqs, Ann, Res)
    ]),
    ?assertEqual(untested, maps:get(<<"X-4.7-14">>, M)),
    ?assertEqual(untested, maps:get(<<"R4579-07">>, M)),
    ?assertEqual(pass, maps:get(<<"R4028-01">>, M)),
    Fail = chappe_sip_compliance:matrix(Reqs, Ann, Res#{<<"s:c">> => fail}),
    ?assertMatch(
        [fail],
        [S || #{id := <<"R4579-07">>, status := S} <- Fail]
    ).

%% Only the newest ct_run directory counts, picked by the timestamp in its
%% name whatever the node name.
newest_run_test() ->
    ?assertEqual(none, chappe_sip_compliance:newest_run([])),
    ?assertEqual(
        "logs/ct_run.b@h.example.2026-11-19_10.00.00",
        chappe_sip_compliance:newest_run([
            "logs/ct_run.z@h.2026-11-18_23.59.59",
            "logs/ct_run.b@h.example.2026-11-19_10.00.00",
            "logs/ct_run.a@h.2026-11-19_09.59.59"
        ])
    ).

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
