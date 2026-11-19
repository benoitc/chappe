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
%% by "--gate" and a comma separated list of gated tiers (default table).
%% LogDir is _build/test/logs: its newest ct_run.* directory and its
%% eunit/ surefire reports.
main(Args) ->
    {Paths, Gate} = args(Args),
    [ReqFile, TestDir, LogDir, Out] = Paths,
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
    case Gate =/= none andalso gate(Matrix, Gate) of
        {error, Open} ->
            io:format("gate: ~p hard requirements of ~s not passing~n", [
                length(Open), lists:join(",", Gate)
            ]),
            halt(1);
        _ ->
            halt(0)
    end.

-spec args([string()]) -> {[string()], none | [binary()]}.
args(Args) ->
    case lists:splitwith(fun(A) -> A =/= "--gate" end, Args) of
        {Paths, []} ->
            {Paths, none};
        {Paths, ["--gate"]} ->
            {Paths, [<<"table">>]};
        {Paths, ["--gate", Tiers]} ->
            {Paths, [list_to_binary(T) || T <- string:lexemes(Tiers, ",")]}
    end.

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
%% result is the aggregate of its testcases: fail if one failed or
%% errored, pass if all passed, skip otherwise.
-spec eunit_results([binary()]) -> #{binary() => pass | fail | skip}.
eunit_results(Reports) ->
    Cases = lists:append([testcases(Bin) || Bin <- Reports]),
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
    Tag = "<(failure|error|skipped)\\b",
    case re:run(Body, Tag, [{capture, [1], binary}]) of
        {match, [<<"skipped">>]} -> skip;
        {match, [_]} -> fail;
        nomatch -> pass
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
                status => status(R, [
                    maps:get(T, Results, missing)
                 || T <- Tests
                ])
            }
        end
     || #{id := Id} = R <- Reqs
    ].

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
        "## By row\n\n",
        "| Row | pass | fail | untested | other |\n| --- | ---: | ---: | ---: | ---: |\n",
        [row_line(Row, Matrix) || Row <- rows(Matrix)],
        "\n## Requirements\n\n",
        "| ID | Keyword | Row | Tier | Status | Tests | Text |\n",
        "| --- | --- | --- | --- | --- | --- | --- |\n",
        [req_line(R) || R <- Matrix]
    ].

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
