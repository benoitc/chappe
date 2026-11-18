#!/usr/bin/env escript
%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Check that the docs follow the code. Run it from the repository root:
%% `make docs-check'. It prints one line per finding and exits 1 on any.
%%
%% For each app under apps/:
%%   - every module of src/** is in exactly one ex_doc group, and every
%%     module a group names exists;
%%   - every docs/**/*.md (docs/history aside) is an ex_doc extra, and
%%     every extra exists;
%%   - every supervisor of src/** is named in docs/design/overview.md.
%% For the repository: every relative markdown link resolves, and every
%% #anchor matches a heading of its target (GitHub slug rules).
-mode(compile).

main(_) ->
    Apps = lists:sort(filelib:wildcard("apps/*/rebar.config")),
    AppFindings = lists:flatmap(fun check_app/1, Apps),
    LinkFindings = lists:flatmap(fun check_links/1, md_files()),
    case AppFindings ++ LinkFindings of
        [] ->
            halt(0);
        Findings ->
            [io:format("~ts~n", [F]) || F <- Findings],
            halt(1)
    end.

%% ---- Per app -----------------------------------------------------------

check_app(Config) ->
    Dir = filename:dirname(Config),
    App = filename:basename(Dir),
    case file:consult(Config) of
        {ok, Terms} ->
            ExDoc = proplists:get_value(ex_doc, Terms, []),
            Mods = src_modules(Dir),
            [
                fmt("~ts: ~ts", [App, M])
             || M <-
                    check_groups(ExDoc, Mods) ++
                        check_extras(Dir, ExDoc) ++
                        check_supervisors(Dir)
            ];
        {error, Reason} ->
            [fmt("~ts: cannot read ~ts: ~p", [App, Config, Reason])]
    end.

src_modules(Dir) ->
    [
        {list_to_atom(filename:basename(F, ".erl")), F}
     || F <- filelib:wildcard(filename:join([Dir, "src", "**", "*.erl"]))
    ].

check_groups(ExDoc, Mods) ->
    Groups = proplists:get_value(groups_for_modules, ExDoc, []),
    Named = lists:append([Ms || {_, Ms} <- Groups]),
    Known = [M || {M, _} <- Mods],
    Missing = [
        fmt("~ts is in no ex_doc group", [M])
     || M <- Known, not lists:member(M, Named)
    ],
    Dups = [
        fmt("~ts is in ~b ex_doc groups", [M, N])
     || M <- lists:usort(Named),
        N <- [length([X || X <- Named, X =:= M])],
        N > 1
    ],
    Ghosts = [
        fmt("ex_doc group names ~ts, which is not a module of src", [M])
     || M <- lists:usort(Named), not lists:member(M, Known)
    ],
    Missing ++ Dups ++ Ghosts.

check_extras(Dir, ExDoc) ->
    Extras = [
        to_list(extra_path(E))
     || E <- proplists:get_value(extras, ExDoc, [])
    ],
    Docs = [
        F
     || F <- wildcard(Dir, "docs/**/*.md"),
        not lists:prefix("docs/history/", F)
    ],
    [
        fmt("~ts is not in ex_doc extras", [F])
     || F <- Docs, not lists:member(F, Extras)
    ] ++
        [
            fmt("extra ~ts does not exist", [E])
         || E <- Extras, not filelib:is_regular(filename:join(Dir, E))
        ].

extra_path({Path, _Opts}) -> Path;
extra_path(Path) -> Path.

check_supervisors(Dir) ->
    Overview = filename:join([Dir, "docs", "design", "overview.md"]),
    Sups = [
        atom_to_list(M)
     || {M, F} <- src_modules(Dir), is_supervisor(F)
    ],
    case {Sups, file:read_file(Overview)} of
        {[], _} ->
            [];
        {_, {ok, Text}} ->
            [
                fmt("supervisor ~ts is not named in docs/design/overview.md", [
                    S
                ])
             || S <- Sups, not names(Text, S)
            ];
        {_, {error, _}} ->
            [
                fmt("docs/design/overview.md is missing; supervisors: ~ts", [
                    lists:join(", ", Sups)
                ])
            ]
    end.

is_supervisor(File) ->
    {ok, Bin} = file:read_file(File),
    match =:=
        re:run(
            Bin,
            "^-behaviou?r\\(\\s*supervisor\\s*\\)",
            [multiline, {capture, none}]
        ).

names(Text, Name) ->
    match =:=
        re:run(Text, "(?<![a-z0-9_])" ++ Name ++ "(?![a-z0-9_])", [
            {capture, none}
        ]).

%% ---- Links -------------------------------------------------------------

md_files() ->
    Roots = ["README.md", "CONTRIBUTING.md", "AGENTS.md"],
    Trees =
        wildcard(".", "docs/**/*.md") ++
            wildcard(".", "apps/*/docs/**/*.md") ++
            wildcard(".", "apps/*/README.md"),
    Skip = [
        "_build/", "deps/", "node_modules/", "docs/history/", "docs/plans/"
    ],
    [F || F <- Roots, filelib:is_regular(F)] ++
        [F || F <- Trees, not lists:any(fun(S) -> contains(F, S) end, Skip)].

check_links(File) ->
    Lines = lines(File),
    lists:flatmap(
        fun({N, Line}) ->
            [
                fmt("~ts:~b: ~ts", [File, N, M])
             || T <- links(Line), M <- check_link(File, T)
            ]
        end,
        unfenced(Lines)
    ).

check_link(File, Target) ->
    case is_external(Target) of
        true ->
            [];
        false ->
            {Path, Anchor} = split_anchor(Target),
            Abs =
                case Path of
                    "" -> File;
                    _ -> normalize(filename:join(filename:dirname(File), Path))
                end,
            case filelib:is_file(Abs) of
                false ->
                    [fmt("broken link ~ts", [Target])];
                true when Anchor =:= none ->
                    [];
                true ->
                    check_anchor(Abs, Anchor, Target)
            end
    end.

check_anchor(Abs, Anchor, Target) ->
    case filename:extension(Abs) =:= ".md" andalso filelib:is_regular(Abs) of
        false ->
            [];
        true ->
            Slugs = anchors(Abs),
            case lists:member(string:lowercase(Anchor), Slugs) of
                true -> [];
                false -> [fmt("no heading for the anchor in ~ts", [Target])]
            end
    end.

is_external(T) ->
    match =:= re:run(T, "^[a-zA-Z][a-zA-Z0-9+.-]*:", [{capture, none}]).

split_anchor(T) ->
    case string:split(T, "#") of
        [P, A] -> {decode(P), decode(A)};
        [P] -> {decode(P), none}
    end.

decode(S) ->
    case uri_string:percent_decode(S) of
        {error, _, _} -> S;
        D -> unicode:characters_to_list(D)
    end.

%% Inline links and images `[text](target)` and reference definitions
%% `[label]: target'. Code spans are dropped first.
links(Line) ->
    L = re:replace(Line, "`[^`]*`", "", [global, unicode, {return, list}]),
    Inline =
        case
            re:run(L, "\\]\\(\\s*<?([^)\\s>]+)>?(?:\\s+\"[^\"]*\")?\\s*\\)", [
                global, unicode, {capture, all_but_first, list}
            ])
        of
            {match, Ms} -> [T || [T] <- Ms];
            nomatch -> []
        end,
    Ref =
        case
            re:run(L, "^\\s{0,3}\\[[^\\]]+\\]:\\s*<?([^\\s>]+)>?", [
                unicode, {capture, all_but_first, list}
            ])
        of
            {match, [T]} -> [T];
            nomatch -> []
        end,
    Inline ++ Ref.

%% ---- Headings and slugs ------------------------------------------------

anchors(File) ->
    Lines = [L || {_, L} <- unfenced(lines(File))],
    Heads = headings(Lines),
    Html = html_ids(Lines),
    dedup(Heads, #{}) ++ Html.

headings([L, Next | Rest]) ->
    case atx(L) of
        {ok, H} ->
            [slug(H) | headings([Next | Rest])];
        nomatch ->
            case setext(L, Next) of
                true -> [slug(string:trim(L)) | headings(Rest)];
                false -> headings([Next | Rest])
            end
    end;
headings([L]) ->
    case atx(L) of
        {ok, H} -> [slug(H)];
        nomatch -> []
    end;
headings([]) ->
    [].

atx(L) ->
    case
        re:run(L, "^\\s{0,3}#{1,6}\\s+(.*?)(?:\\s+#+)?\\s*$", [
            unicode, {capture, all_but_first, list}
        ])
    of
        {match, [H]} -> {ok, H};
        nomatch -> nomatch
    end.

setext(L, Next) ->
    string:trim(L) =/= "" andalso
        match =:= re:run(Next, "^\\s{0,3}(=+|-+)\\s*$", [{capture, none}]) andalso
        nomatch =:= re:run(L, "^\\s{0,3}([-*_>|]|\\d+\\.)", [{capture, none}]).

html_ids(Lines) ->
    lists:flatmap(
        fun(L) ->
            case
                re:run(L, "<a\\s+(?:name|id)=\"([^\"]+)\"", [
                    global, unicode, {capture, all_but_first, list}
                ])
            of
                {match, Ms} -> [string:lowercase(I) || [I] <- Ms];
                nomatch -> []
            end
        end,
        Lines
    ).

%% GitHub: a second heading with the same slug gets -1, a third -2, ...
dedup([], _) ->
    [];
dedup([S | Rest], Seen) ->
    case maps:get(S, Seen, 0) of
        0 -> [S | dedup(Rest, Seen#{S => 1})];
        N -> [S ++ "-" ++ integer_to_list(N) | dedup(Rest, Seen#{S => N + 1})]
    end.

%% Link text stands for the link, then GitHub lowercases, drops every
%% character but letters, digits, spaces, hyphens and underscores, and
%% turns each space into a hyphen.
slug(Heading) ->
    T0 = re:replace(Heading, "!?\\[([^\\]]*)\\]\\([^)]*\\)", "\\1", [
        global, unicode, {return, list}
    ]),
    T1 = re:replace(T0, "<[^>]+>", "", [global, unicode, {return, list}]),
    Lower = string:lowercase(unicode:characters_to_list(T1)),
    [
        case C of
            $\s -> $-;
            _ -> C
        end
     || C <- Lower, keep(C)
    ].

keep(C) when C >= $a, C =< $z -> true;
keep(C) when C >= $0, C =< $9 -> true;
keep($\s) -> true;
keep($-) -> true;
keep($_) -> true;
keep(C) when C > 127 -> is_letter(C);
keep(_) -> false.

is_letter(C) ->
    match =:= re:run([C], "^[\\p{L}\\p{N}]$", [unicode, ucp, {capture, none}]).

%% ---- Helpers -----------------------------------------------------------

lines(File) ->
    {ok, Bin} = file:read_file(File),
    Text = unicode:characters_to_list(Bin),
    lists:zip(
        lists:seq(1, length(string:split(Text, "\n", all))),
        string:split(Text, "\n", all)
    ).

%% The lines outside fenced code blocks, with their numbers.
unfenced(Lines) ->
    unfenced(Lines, none).

unfenced([], _) ->
    [];
unfenced([{N, L} | Rest], Fence) ->
    case {fence(L), Fence} of
        {none, none} -> [{N, L} | unfenced(Rest, none)];
        {none, _} -> unfenced(Rest, Fence);
        {F, none} -> unfenced(Rest, F);
        {{C, Len}, {C, Open}} when Len >= Open -> unfenced(Rest, none);
        {_, _} -> unfenced(Rest, Fence)
    end.

fence(L) ->
    case
        re:run(L, "^\\s{0,3}(`{3,}|~{3,})", [
            unicode, {capture, all_but_first, list}
        ])
    of
        {match, [[C | _] = F]} -> {C, length(F)};
        nomatch -> none
    end.

wildcard(Dir, Pattern) ->
    lists:sort(filelib:wildcard(Pattern, Dir)).

normalize(Path) ->
    filename:join(norm(filename:split(Path), [])).

norm([], Acc) -> lists:reverse(Acc);
norm(["." | T], Acc) -> norm(T, Acc);
norm([".." | T], [P | Acc]) when P =/= ".." -> norm(T, Acc);
norm([H | T], Acc) -> norm(T, [H | Acc]).

contains(S, Sub) -> string:find(S, Sub) =/= nomatch.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) -> L.

fmt(F, A) -> lists:flatten(io_lib:format(F, A)).
