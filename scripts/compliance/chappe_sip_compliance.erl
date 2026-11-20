%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The compliance matrix: every normative statement an app must meet
%% (its docs/compliance/requirements.tsv), joined with the tests that
%% claim to prove it (`%% req: ID ...' lines above a CT case in a
%% *_SUITE.erl or an EUnit test function in a *_tests.erl) and the result
%% of each test in the newest run: the newest ct_run.* directory only, and
%% the EUnit surefire reports.
%%
%% A requirement passes only when every test claiming it passed. It fails
%% if any of them failed. It is untested when no test claims it, or when
%% any claiming test was skipped or has no result: a skipped or missing
%% test proves nothing. The matrix is generated, so it cannot claim a test
%% that does not exist, and an annotation naming an unknown id is
%% reported rather than counted.
%%
%% Run through scripts/compliance.escript (`make compliance`).
-module(chappe_sip_compliance).

-export([main/1]).
-export([
    parse_requirements/1,
    annotations/2,
    results/1,
    newest_run/1,
    eunit_results/1,
    matrix/3,
    gate/2,
    undocumented_deviations/1,
    expected_fail/2,
    check_against/2,
    args/1,
    unknown_ids/2,
    render/1
]).

-define(FIELDS, [
    id, source, section, line, keyword, actor, row, tier, text, notes
]).
-define(HARD, [
    <<"MUST">>, <<"MUST NOT">>, <<"SHALL">>, <<"SHALL NOT">>, <<"REQUIRED">>
]).

%% main([RequirementsTsv, TestDir, LogDir, OutMd]), optionally followed
%% by "--expected-fail" and the conformance lab's expected-fail file,
%% "--check-against" and the committed matrix (read before OutMd is
%% written, so both may be the same file), and "--gate" and a comma
%% separated list of gated tiers (default table). LogDir is
%% _build/test/logs: its newest ct_run.* directory and its eunit/ surefire
%% reports.
main(Args) ->
    {Paths, Gate, Opts} = args(Args),
    [ReqFile, TestDir, LogDir, Out] = Paths,
    Committed =
        case Opts of
            #{check_against := CheckFile} ->
                {ok, CommittedBin} = file:read_file(CheckFile),
                CommittedBin;
            #{} ->
                none
        end,
    {ok, Bin} = file:read_file(ReqFile),
    {ok, Reqs} = parse_requirements(Bin),
    Ann = lists:append([
        begin
            {ok, Src} = file:read_file(F),
            annotations(list_to_binary(filename:basename(F, ".erl")), Src)
        end
     || Pattern <- ["*_SUITE.erl", "*_tests.erl"],
        F <- filelib:wildcard(filename:join(TestDir, Pattern))
    ]),
    Ct =
        case newest_run(filelib:wildcard(filename:join(LogDir, "ct_run.*"))) of
            none ->
                #{};
            Run ->
                results([
                    element(2, file:read_file(F))
                 || F <- filelib:wildcard(
                        filename:join([Run, "*", "run.*", "suite.log"])
                    )
                ])
        end,
    Eunit = eunit_results([
        element(2, file:read_file(F))
     || F <- filelib:wildcard(filename:join([LogDir, "eunit", "TEST-*.xml"]))
    ]),
    Matrix = matrix(Reqs, Ann, maps:merge(Eunit, Ct)),
    ok = file:write_file(Out, render(Matrix)),
    [
        io:format("unknown requirement id ~s in ~s~n", [Id, Case])
     || {Case, Id} <- unknown_ids(Reqs, Ann)
    ],
    io:format("~s~n", [summary_line(Matrix)]),
    Checked = check_report(Committed, Matrix),
    Gated =
        case Gate of
            none -> 0;
            _ -> gate_report(Matrix, Gate, maps:get(expected_fail, Opts, none))
        end,
    halt(max(Checked, Gated)).

%% One line per row the committed matrix claims as pass and this run does
%% not (an error), and per row this run passes that it does not claim (a
%% notice). Returns the exit status.
check_report(none, _Matrix) ->
    0;
check_report(Committed, Matrix) ->
    {Lost, Gained} = check_against(Committed, Matrix),
    [
        io:format(
            "check: ~s is pass in the committed matrix, not in this run~n",
            [Id]
        )
     || Id <- Lost
    ],
    [
        io:format(
            "notice: ~s passes in this run; the committed matrix does not "
            "claim it~n",
            [Id]
        )
     || Id <- Gained
    ],
    case Lost of
        [] -> 0;
        _ -> 1
    end.

%% Print one line per gate problem and return the exit status.
gate_report(Matrix, Gate, ExpectedFail) ->
    Open =
        case gate(Matrix, Gate) of
            ok -> [];
            {error, Ids} -> Ids
        end,
    [
        io:format("gate: ~p hard requirements of ~s not passing: ~s~n", [
            length(Open), lists:join(",", Gate), lists:join(" ", Open)
        ])
     || Open =/= []
    ],
    Undocumented = undocumented_deviations(Matrix),
    [
        io:format("gate: deviation ~s has no reason in its notes~n", [Id])
     || Id <- Undocumented
    ],
    Unbacked =
        case ExpectedFail of
            none ->
                [];
            File ->
                {ok, EfBin} = file:read_file(File),
                expected_fail(EfBin, Matrix)
        end,
    [
        io:format(
            "gate: expected-fail ~s names no requirement row with deviation "
            "status~n",
            [Case]
        )
     || Case <- Unbacked
    ],
    case {Open, Undocumented, Unbacked} of
        {[], [], []} -> 0;
        _ -> 1
    end.

-spec args([string()]) ->
    {[string()], none | [binary()], #{atom() => string()}}.
args(Args0) ->
    {Args, Opts} = file_opts(Args0, [], #{}),
    case lists:splitwith(fun(A) -> A =/= "--gate" end, Args) of
        {Paths, []} ->
            {Paths, none, Opts};
        {Paths, ["--gate"]} ->
            {Paths, [<<"table">>], Opts};
        {Paths, ["--gate", Tiers]} ->
            {Paths, [list_to_binary(T) || T <- string:lexemes(Tiers, ",")],
                Opts}
    end.

%% The options that take a file, wherever they sit after the paths.
file_opts([], Acc, Opts) ->
    {lists:reverse(Acc), Opts};
file_opts(["--expected-fail", File | T], Acc, Opts) ->
    file_opts(T, Acc, Opts#{expected_fail => File});
file_opts(["--check-against", File | T], Acc, Opts) ->
    file_opts(T, Acc, Opts#{check_against => File});
file_opts([A | T], Acc, Opts) ->
    file_opts(T, [A | Acc], Opts).

%% ---- requirements ----

-spec parse_requirements(binary()) -> {ok, [map()]} | {error, term()}.
parse_requirements(Bin) ->
    [_Header | Lines] = binary:split(Bin, [<<"\r\n">>, <<"\n">>], [global]),
    parse_lines(Lines, 2, [], #{}).

parse_lines([], _N, Acc, _Seen) ->
    {ok, lists:reverse(Acc)};
parse_lines([<<>> | T], N, Acc, Seen) ->
    parse_lines(T, N + 1, Acc, Seen);
parse_lines([L | T], N, Acc, Seen) ->
    Fields = binary:split(L, <<"\t">>, [global]),
    case length(Fields) =:= length(?FIELDS) of
        false ->
            {error, {bad_line, N, length(Fields)}};
        true ->
            R = maps:from_list(lists:zip(?FIELDS, Fields)),
            Id = maps:get(id, R),
            case maps:is_key(Id, Seen) of
                true -> {error, {duplicate_id, Id}};
                false -> parse_lines(T, N + 1, [R | Acc], Seen#{Id => true})
            end
    end.

%% ---- annotations ----

%% [{<<"Module:Function">>, [Id]}] for every `%% req:' block followed by
%% a function clause: a CT case, or an EUnit test or generator.
-spec annotations(binary(), binary()) -> [{binary(), [binary()]}].
annotations(Suite, Src) ->
    Lines = binary:split(Src, <<"\n">>, [global]),
    annotate(Lines, Suite, [], []).

annotate([], _Suite, _Pending, Acc) ->
    lists:reverse(Acc);
annotate([L | T], Suite, Pending, Acc) ->
    case
        re:run(L, "^%%\\s*req:\\s*(.*)$", [{capture, all_but_first, binary}])
    of
        {match, [Ids]} ->
            annotate(
                T,
                Suite,
                Pending ++
                    [
                        I
                     || I <- binary:split(Ids, [<<" ">>, <<",">>], [global]),
                        I =/= <<>>
                    ],
                Acc
            );
        nomatch when Pending =/= [] ->
            case
                re:run(L, "^([a-z][a-zA-Z0-9_]*)\\(", [
                    {capture, all_but_first, binary}
                ])
            of
                {match, [Fun]} ->
                    annotate(T, Suite, [], [
                        {<<Suite/binary, ":", Fun/binary>>, Pending} | Acc
                    ]);
                nomatch ->
                    annotate(T, Suite, Pending, Acc)
            end;
        nomatch ->
            annotate(T, Suite, [], Acc)
    end.

-spec unknown_ids([map()], [{binary(), [binary()]}]) -> [{binary(), binary()}].
unknown_ids(Reqs, Ann) ->
    Known = maps:from_list([{Id, true} || #{id := Id} <- Reqs]),
    [{Case, Id} || {Case, Ids} <- Ann, Id <- Ids, not maps:is_key(Id, Known)].

%% ---- results ----

%% The newest ct_run.* directory, by the timestamp that ends its name
%% (ct_run.NODE.YYYY-MM-DD_HH.MM.SS). Older runs are ignored: a result
%% does not outlive the run that produced it.
-spec newest_run([string()]) -> none | string().
newest_run(Dirs) ->
    Stamped = [
        {Stamp, D}
     || D <- Dirs,
        {match, [Stamp]} <- [
            re:run(
                D,
                "(\\d{4}-\\d\\d-\\d\\d_\\d\\d\\.\\d\\d\\.\\d\\d)$",
                [{capture, all_but_first, list}]
            )
        ]
    ],
    case lists:sort(Stamped) of
        [] -> none;
        Sorted -> element(2, lists:last(Sorted))
    end.

%% Result per "Suite:case" from the suite.log files of one run.
-spec results([binary()]) -> #{binary() => pass | fail | skip}.
results(Logs) ->
    lists:foldl(
        fun(Bin, Acc) -> maps:merge(Acc, parse_log(Bin)) end, #{}, Logs
    ).

parse_log(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    parse_log(Lines, undefined, #{}).

parse_log([], _Case, Acc) ->
    Acc;
parse_log([L | T], Case, Acc) ->
    case re:run(L, "^=case\\s+(\\S+)", [{capture, all_but_first, binary}]) of
        {match, [C]} ->
            parse_log(T, C, Acc);
        nomatch ->
            case
                {Case,
                    re:run(L, "^=result\\s+(\\S+)", [
                        {capture, all_but_first, binary}
                    ])}
            of
                {undefined, _} ->
                    parse_log(T, Case, Acc);
                {_, {match, [R]}} ->
                    parse_log(T, undefined, Acc#{Case => result(R)});
                {_, nomatch} ->
                    parse_log(T, Case, Acc)
            end
    end.

result(<<"ok">>) -> pass;
result(<<"skipped", _/binary>>) -> skip;
result(<<"auto_skipped", _/binary>>) -> skip;
result(_) -> fail.

%% Result per "Module:Function" from EUnit surefire reports. eunit_surefire
%% names a testcase "Module:Line Function" for a plain test and
%% "Module:Line -Function/0-fun-N-" for a fun a generator returns, so both
%% key on the function the test was written in. A function's
%% result is the aggregate of its testcases: fail if one failed, errored
%% or hit its timeout, pass if all passed, skip otherwise.
%%
%% A fixture whose setup or cleanup failed is reported as "fixture setup
%% [Id]" with no function, and the tests it guards never run. The report
%% cannot tie it to a generator, so it fails the whole module: the key
%% "Module:*" is fail, and every claim in that module fails (see matrix/3).
-spec eunit_results([binary()]) -> #{binary() => pass | fail | skip}.
eunit_results(Reports) ->
    Cases = lists:append([
        testcases(Bin) ++ fixture_failures(Bin)
     || Bin <- Reports
    ]),
    lists:foldl(
        fun({Key, R}, Acc) ->
            maps:update_with(Key, fun(Old) -> worst(Old, R) end, R, Acc)
        end,
        #{},
        Cases
    ).

testcases(Bin) ->
    Found =
        case
            re:run(
                Bin,
                "<testcase\\b[^>]*?\\bname=\"([a-z][a-zA-Z0-9_]*):[0-9]+ -?"
                "([a-z][a-zA-Z0-9_]*)[^\"]*\"[^>]*?(/>|>(.*?)</testcase>)",
                [global, dotall, {capture, [1, 2, 4], binary}]
            )
        of
            {match, M} -> M;
            nomatch -> []
        end,
    [
        {<<Mod/binary, ":", Fun/binary>>, case_result(Body)}
     || [Mod, Fun, Body] <- Found
    ].

case_result(Body) ->
    Tag = "<(failure|error|skipped)\\b([^>]*)",
    case re:run(Body, Tag, [{capture, [1, 2], binary}]) of
        {match, [<<"skipped">>, Attrs]} ->
            case binary:match(Attrs, <<"type=\"timeout\"">>) of
                nomatch -> skip;
                _ -> fail
            end;
        {match, [_, _]} ->
            fail;
        nomatch ->
            pass
    end.

fixture_failures(Bin) ->
    Fixture =
        "<testcase\\b[^>]*?\\bname=\"fixture (?:setup|cleanup) [^\"]*\"",
    Suite = "<testsuite\\b[^>]*?\\bname=\"module '([^']+)'",
    case
        {re:run(Bin, Fixture),
            re:run(Bin, Suite, [{capture, all_but_first, binary}])}
    of
        {{match, _}, {match, [Mod]}} -> [{<<Mod/binary, ":*">>, fail}];
        _ -> []
    end.

worst(fail, _) -> fail;
worst(_, fail) -> fail;
worst(skip, _) -> skip;
worst(_, skip) -> skip;
worst(pass, pass) -> pass.

%% ---- matrix ----

-spec matrix([map()], [{binary(), [binary()]}], map()) -> [map()].
matrix(Reqs, Ann, Results) ->
    Claims = lists:foldl(
        fun({Case, Ids}, Acc) ->
            lists:foldl(
                fun(Id, A) ->
                    maps:update_with(Id, fun(L) -> [Case | L] end, [Case], A)
                end,
                Acc,
                Ids
            )
        end,
        #{},
        Ann
    ),
    [
        begin
            Tests = lists:sort(maps:get(Id, Claims, [])),
            R#{
                tests => Tests,
                status => status(R, [result(T, Results) || T <- Tests])
            }
        end
     || #{id := Id} = R <- Reqs
    ].

%% A test's result, or fail when its EUnit module had a fixture failure.
result(Test, Results) ->
    [Mod | _] = binary:split(Test, <<":">>),
    case maps:find(<<Mod/binary, ":*">>, Results) of
        {ok, fail} -> fail;
        _ -> maps:get(Test, Results, missing)
    end.

status(#{tier := <<"deviation">>}, _) ->
    deviation;
status(#{tier := <<"spec-defect">>}, _) ->
    spec_defect;
status(#{tier := <<"n/a">>}, _) ->
    na;
status(_, []) ->
    untested;
status(_, Rs) ->
    case {lists:member(fail, Rs), lists:all(fun(R) -> R =:= pass end, Rs)} of
        {true, _} -> fail;
        {false, true} -> pass;
        {false, false} -> untested
    end.

-spec gate([map()], [binary()]) -> ok | {error, [binary()]}.
gate(Matrix, Tiers) ->
    Open = [
        Id
     || #{id := Id, tier := T, keyword := K, status := S} <- Matrix,
        lists:member(T, Tiers),
        lists:member(K, ?HARD),
        S =/= pass
    ],
    case Open of
        [] -> ok;
        _ -> {error, Open}
    end.

%% Deviation rows whose notes are empty: a deviation without a reason is
%% not documented.
-spec undocumented_deviations([map()]) -> [binary()].
undocumented_deviations(Matrix) ->
    [
        Id
     || #{id := Id, status := deviation, notes := Notes} <- Matrix,
        string:trim(Notes) =:= <<>>
    ].

%% The cases of an expected-fail file (`case  reason' per line, `#'
%% comments) whose reason names no requirement row with deviation status:
%% a case that fails on purpose must point at the documented deviation.
-spec expected_fail(binary(), [map()]) -> [binary()].
expected_fail(Bin, Matrix) ->
    Deviations = #{Id => true || #{id := Id, status := deviation} <- Matrix},
    [
        Case
     || Line <- binary:split(Bin, [<<"\r\n">>, <<"\n">>], [global]),
        [Case | Reason] <- [string:split(string:trim(Line), " ")],
        Case =/= <<>>,
        binary:first(Case) =/= $#,
        not lists:any(
            fun(Id) -> maps:is_key(Id, Deviations) end,
            row_ids(iolist_to_binary(Reason))
        )
    ].

row_ids(Text) ->
    case
        re:run(Text, "[A-Z][A-Za-z0-9]*(?:-[A-Za-z0-9.]+)+", [
            global, {capture, first, binary}
        ])
    of
        {match, Ids} -> [Id || [Id] <- Ids];
        nomatch -> []
    end.

%% Compare a committed matrix with this run. Returns the ids the committed
%% file shows as pass and this run does not (it claims more than the run
%% proves), and the ids this run passes that the committed file does not.
-spec check_against(binary(), [map()]) -> {[binary()], [binary()]}.
check_against(Committed, Matrix) ->
    Old = committed_status(Committed),
    Lost = [
        Id
     || #{id := Id, status := S} <- Matrix,
        maps:get(Id, Old, none) =:= <<"pass">>,
        S =/= pass
    ],
    Gained = [
        Id
     || #{id := Id, status := pass} <- Matrix,
        maps:get(Id, Old, none) =/= <<"pass">>
    ],
    {Lost, Gained}.

%% Status per id from the "## Requirements" table of a rendered matrix.
committed_status(Md) ->
    Rows =
        case binary:split(Md, <<"\n## Requirements\n">>) of
            [_, After] -> binary:split(After, <<"\n">>, [global]);
            [_] -> []
        end,
    maps:from_list([
        {Id, Status}
     || <<"| ", _/binary>> = Line <- Rows,
        [Id, _Kw, _Row, _Tier, Status | _] <- [
            [
                string:trim(F)
             || F <- binary:split(
                    binary:part(Line, 2, byte_size(Line) - 2),
                    <<" | ">>,
                    [global]
                )
            ]
        ]
    ]).

%% ---- rendering ----

-spec render([map()]) -> iodata().
render(Matrix) ->
    [
        "# Compliance matrix\n\n",
        "Generated by `make compliance` from `docs/compliance/requirements.tsv`,\n"
        "the `%% req:` annotations in `test/*_SUITE.erl` and `test/*_tests.erl`, and\n"
        "the results of the newest Common Test run and EUnit reports. Do not edit\n"
        "by hand.\n\n",
        summary_line(Matrix),
        "\n\n",
        "What chappe does not meet on purpose, and why, is listed under\n"
        "[Deviations](#deviations).\n\n",
        deviations(Matrix),
        "## By row\n\n",
        "| Row | pass | fail | untested | other |\n| --- | ---: | ---: | ---: | ---: |\n",
        [row_line(Row, Matrix) || Row <- rows(Matrix)],
        "\n## Requirements\n\n",
        "| ID | Keyword | Row | Tier | Status | Tests | Text |\n",
        "| --- | --- | --- | --- | --- | --- | --- |\n",
        [req_line(R) || R <- Matrix]
    ].

deviations(Matrix) ->
    [
        "## Deviations\n\n",
        case [R || #{status := deviation} = R <- Matrix] of
            [] ->
                "None.\n\n";
            Devs ->
                [
                    "| ID | Source | Section | Requirement | Reason |\n",
                    "| --- | --- | --- | --- | --- |\n",
                    [deviation_line(R) || R <- Devs],
                    "\n"
                ]
        end
    ].

deviation_line(#{
    id := Id, source := Src, section := Sec, text := Text, notes := Notes
}) ->
    io_lib:format("| ~s | ~s | ~s | ~s | ~s |~n", [
        Id, Src, Sec, escape(short(Text)), escape(Notes)
    ]).

%% The first 100 characters of a requirement, cut at a word.
short(Text) ->
    case string:length(Text) =< 100 of
        true ->
            Text;
        false ->
            Cut = string:slice(Text, 0, 100),
            Words = string:split(Cut, " ", trailing),
            iolist_to_binary([hd(Words), "..."])
    end.

summary_line(Matrix) ->
    Count = fun(S) -> length([ok || #{status := X} <- Matrix, X =:= S]) end,
    io_lib:format(
        "~p requirements: ~p pass, ~p fail, ~p untested, ~p n/a, ~p deviation, ~p spec defect",
        [
            length(Matrix),
            Count(pass),
            Count(fail),
            Count(untested),
            Count(na),
            Count(deviation),
            Count(spec_defect)
        ]
    ).

rows(Matrix) ->
    lists:usort([Row || #{row := Row} <- Matrix]).

row_line(Row, Matrix) ->
    In = [S || #{row := R, status := S} <- Matrix, R =:= Row],
    C = fun(S) -> length([ok || X <- In, X =:= S]) end,
    io_lib:format("| ~s | ~p | ~p | ~p | ~p |~n", [
        Row,
        C(pass),
        C(fail),
        C(untested),
        length(In) - C(pass) - C(fail) - C(untested)
    ]).

req_line(#{
    id := Id,
    keyword := K,
    row := Row,
    tier := T,
    status := S,
    tests := Tests,
    text := Text
}) ->
    io_lib:format("| ~s | ~s | ~s | ~s | ~s | ~s | ~s |~n", [
        Id, K, Row, T, status_text(S), lists:join(", ", Tests), escape(Text)
    ]).

status_text(spec_defect) -> "spec defect";
status_text(na) -> "n/a";
status_text(S) -> atom_to_list(S).

escape(Text) ->
    binary:replace(Text, <<"|">>, <<"\\|">>, [global]).
