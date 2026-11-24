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
        "    <skipped type=\"unknown\">cancelled</skipped>\n"
        "  </testcase>\n"
        "  <testcase time=\"0\" name=\"m_tests:31 cut_test_\"/>\n"
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

%% A test cut by its timeout did not pass: it fails its function.
eunit_timeout_is_fail_test() ->
    Xml = <<
        "<testsuite tests=\"2\" name=\"module 'm_tests'\">\n"
        "  <testcase time=\"0\" name=\"m_tests:30 -slow_test_/0-fun-3-\">\n"
        "    <skipped type=\"timeout\"/>\n"
        "  </testcase>\n"
        "  <testcase time=\"0\" name=\"m_tests:31 -slow_test_/0-fun-5-\"/>\n"
        "</testsuite>\n"
    >>,
    ?assertEqual(
        #{<<"m_tests:slow_test_">> => fail},
        chappe_sip_compliance:eunit_results([Xml])
    ).

%% A fixture whose setup or cleanup failed names no test, so its failure
%% is the module's: every claim in that module fails, those with a result
%% of their own and those whose tests never ran.
eunit_fixture_failure_fails_module_test() ->
    Xml = <<
        "<testsuite tests=\"2\" name=\"module 'n_tests'\">\n"
        "  <testcase time=\"0\" name=\"n_tests:0 plain_test\"/>\n"
        "  <testcase time=\"0\" name=\"fixture setup [1,1]\">\n"
        "    <error type=\"error\">setup</error>\n"
        "  </testcase>\n"
        "</testsuite>\n"
    >>,
    Res = chappe_sip_compliance:eunit_results([Xml]),
    ?assertEqual(fail, maps:get(<<"n_tests:*">>, Res)),
    {ok, Reqs} = chappe_sip_compliance:parse_requirements(tsv()),
    Ann = [
        {<<"n_tests:plain_test">>, [<<"X-4.7-14">>]},
        {<<"n_tests:gen_test_">>, [<<"R4579-07">>]},
        {<<"o_tests:other_test">>, [<<"R4028-01">>]}
    ],
    M = maps:from_list([
        {Id, S}
     || #{id := Id, status := S} <- chappe_sip_compliance:matrix(
            Reqs, Ann, Res#{<<"o_tests:other_test">> => pass}
        )
    ]),
    ?assertEqual(fail, maps:get(<<"X-4.7-14">>, M)),
    ?assertEqual(fail, maps:get(<<"R4579-07">>, M)),
    ?assertEqual(pass, maps:get(<<"R4028-01">>, M)).

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
        {error, [<<"R3515-01">>]},
        chappe_sip_compliance:gate(None, [<<"demo">>])
    ).

%% `--gate TIER,...' names the gated tiers; a bare `--gate' keeps `table';
%% `--expected-fail FILE' may come anywhere after the paths.
args_test() ->
    P = ["a", "b", "c", "d"],
    ?assertEqual({P, none, #{}}, chappe_sip_compliance:args(P)),
    ?assertEqual(
        {P, [<<"table">>], #{}},
        chappe_sip_compliance:args(P ++ ["--gate"])
    ),
    ?assertEqual(
        {P, [<<"demo">>, <<"platform">>], #{}},
        chappe_sip_compliance:args(P ++ ["--gate", "demo,platform"])
    ),
    ?assertEqual(
        {P, [<<"demo">>], #{expected_fail => "ef"}},
        chappe_sip_compliance:args(
            P ++ ["--expected-fail", "ef", "--gate", "demo"]
        )
    ),
    ?assertEqual(
        {P, [<<"table">>], #{expected_fail => "ef"}},
        chappe_sip_compliance:args(P ++ ["--gate", "--expected-fail", "ef"])
    ).

%% A deviation is documented: one with empty notes is reported by the gate.
undocumented_deviations_test() ->
    Tsv = <<
        (tsv())/binary,
        "R4579-24\tRFC 4579\t6\t901\tMUST\tfocus\tR7\tdeviation\tbare\t \n"
    >>,
    {ok, Reqs} = chappe_sip_compliance:parse_requirements(Tsv),
    M = chappe_sip_compliance:matrix(Reqs, [], #{}),
    ?assertEqual(
        [<<"R4579-24">>], chappe_sip_compliance:undocumented_deviations(M)
    ).

%% Each expected-fail case must name, in its reason, a requirement row
%% with deviation status.
expected_fail_test() ->
    {ok, Reqs} = chappe_sip_compliance:parse_requirements(tsv()),
    M = chappe_sip_compliance:matrix(Reqs, [], #{}),
    Ef = <<
        "# a comment naming R4579-07\n"
        "\n"
        "tls_case     S/MIME not built (deviation R4579-23, TLS instead)\n"
        "focus_case   isfocus missing (R4579-07)\n"
        "bare_case    no id at all\n"
        "lone_case\n"
    >>,
    ?assertEqual(
        [<<"focus_case">>, <<"bare_case">>, <<"lone_case">>],
        chappe_sip_compliance:expected_fail(Ef, M)
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

%% The committed matrix may claim less than this run, never more: a row
%% pass there and not pass here is a regression; the reverse is a gain.
check_against_test() ->
    {ok, Reqs} = chappe_sip_compliance:parse_requirements(tsv()),
    Ann = [
        {<<"s:a">>, [<<"X-4.7-14">>, <<"R4579-07">>]},
        {<<"s:b">>, [<<"R4028-01">>]}
    ],
    Committed = iolist_to_binary(
        chappe_sip_compliance:render(
            chappe_sip_compliance:matrix(Reqs, Ann, #{<<"s:a">> => pass})
        )
    ),
    Now = chappe_sip_compliance:matrix(Reqs, Ann, #{
        <<"s:a">> => skip, <<"s:b">> => pass
    }),
    ?assertEqual(
        {[<<"X-4.7-14">>, <<"R4579-07">>], [<<"R4028-01">>]},
        chappe_sip_compliance:check_against(Committed, Now)
    ),
    Same = chappe_sip_compliance:matrix(Reqs, Ann, #{<<"s:a">> => pass}),
    ?assertEqual(
        {[], []}, chappe_sip_compliance:check_against(Committed, Same)
    ).

%% `--check-against FILE' names the committed matrix to compare with.
check_args_test() ->
    P = ["a", "b", "c", "d"],
    ?assertEqual(
        {P, none, #{check_against => "m.md"}},
        chappe_sip_compliance:args(P ++ ["--check-against", "m.md"])
    ).

render_test() ->
    {ok, Reqs} = chappe_sip_compliance:parse_requirements(tsv()),
    Md = iolist_to_binary(
        chappe_sip_compliance:render(
            chappe_sip_compliance:matrix(Reqs, [], #{})
        )
    ),
    ?assertNotEqual(nomatch, binary:match(Md, <<"| X-4.7-14 |">>)),
    ?assertNotEqual(nomatch, binary:match(Md, <<"untested">>)),
    %% the deviations come first, with their reason, linked from the top
    ?assertNotEqual(nomatch, binary:match(Md, <<"(#deviations)">>)),
    ?assertNotEqual(
        nomatch,
        binary:match(
            Md, <<"| R4579-23 | RFC 4579 | 6 | S/MIME | TLS instead |">>
        )
    ),
    {Dev, _} = binary:match(Md, <<"## Deviations">>),
    {Rows, _} = binary:match(Md, <<"## Requirements">>),
    ?assert(Dev < Rows).
