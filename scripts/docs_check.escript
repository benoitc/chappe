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
%%   - every supervisor of src/** is named in docs/design/overview.md;
%%   - every module of src/** is named in docs/design/overview.md, by its
%%     name in full or by a prefix wildcard `chappe_sip_engine_*' (any
%%     name ending in `*'; the bare `<app>_*' names nothing);
%%   - every module of src/** has a module doc: a `%% @doc' line or a
%%     `-moduledoc' attribute before its first function;
%%   - the app's row of docs/navigation.md ("Public and internal modules
%%     per app") agrees with the ex_doc groups: a module of the group
%%     named "Internal" is internal, a module of any other group public.
%%     In the row, a name is written in full or as `_suffix' for
%%     `<app>_suffix'; `_x*' names every module starting with `<app>_x',
%%     and "every `_x'" every module ending in `_x'. A name written out
%%     wins over a wildcard, so `chappe_sip_b2b_join' in the public column
%%     is public although `_b2b_*' is in the internal one.
%% For the repository: every relative markdown link resolves, and every
%% #anchor matches a heading of its target (GitHub slug rules).
-mode(compile).

main(_) ->
    Apps = lists:sort(filelib:wildcard("apps/*/rebar.config")),
    Nav = nav_rows("docs/navigation.md"),
    AppFindings = lists:flatmap(fun(C) -> check_app(C, Nav) end, Apps),
    LinkFindings = lists:flatmap(fun check_links/1, md_files()),
    case AppFindings ++ LinkFindings of
        [] ->
            halt(0);
        Findings ->
            [io:format("~ts~n", [F]) || F <- Findings],
            halt(1)
    end.

%% ---- Per app -----------------------------------------------------------

check_app(Config, Nav) ->
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
                        check_supervisors(Dir) ++
                        check_overview(Dir, App, Mods) ++
                        check_moduledocs(Mods)
            ] ++ check_visibility(App, Config, ExDoc, Mods, Nav);
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

%% ---- Every module in its overview, with a module doc ------------------

check_overview(Dir, App, Mods) ->
    Overview = filename:join([Dir, "docs", "design", "overview.md"]),
    case file:read_file(Overview) of
        {ok, Text} ->
            Wild = overview_wildcards(Text, App),
            [
                fmt("~ts is not named in docs/design/overview.md", [M])
             || {Atom, _} <- Mods,
                M <- [atom_to_list(Atom)],
                not names(Text, M),
                not lists:any(fun(P) -> lists:prefix(P, M) end, Wild)
            ];
        {error, _} ->
            []
    end.

%% `prefix*' in backquotes; `<app>_*' would name every module, so it names
%% none
overview_wildcards(Text, App) ->
    case
        re:run(Text, "`([a-z][a-z0-9_]*)\\*`", [
            global, {capture, all_but_first, list}
        ])
    of
        {match, Ms} -> [P || [P] <- Ms, P =/= App ++ "_"];
        nomatch -> []
    end.

check_moduledocs(Mods) ->
    [
        fmt(
            "~ts has no module doc (%% @doc or -moduledoc before its first "
            "function)",
            [F]
        )
     || {_, F} <- Mods, not has_moduledoc(F)
    ].

has_moduledoc(File) ->
    {ok, Bin} = file:read_file(File),
    moduledoc(string:split(binary_to_list(Bin), "\n", all)).

moduledoc([]) ->
    false;
moduledoc(["%% @doc" ++ _ | _]) ->
    true;
moduledoc(["-moduledoc" ++ _ | _]) ->
    true;
moduledoc([L | Rest]) ->
    case re:run(L, "^[a-z][a-zA-Z0-9_]*\\(", [{capture, none}]) of
        match -> false;
        nomatch -> moduledoc(Rest)
    end.

%% ---- Public and internal: navigation.md against ex_doc ----------------

-define(NAV, "docs/navigation.md").

%% #{App => {Line, PublicCell, InternalCell}} from the table under the
%% heading "Public and internal modules per app"
nav_rows(File) ->
    case filelib:is_regular(File) of
        false ->
            #{};
        true ->
            Lines = lines(File),
            {_, After} = lists:splitwith(
                fun({_, L}) ->
                    not lists:prefix("## Public and internal modules", L)
                end,
                Lines
            ),
            maps:from_list(nav_table(tl_or_empty(After)))
    end.

tl_or_empty([]) -> [];
tl_or_empty([_ | T]) -> T.

nav_table([]) ->
    [];
nav_table([{_, "## " ++ _} | _]) ->
    [];
nav_table([{N, "| " ++ _ = L} | Rest]) ->
    case [string:trim(C) || C <- string:split(L, "|", all)] of
        ["", App, Pub, Int, ""] when App =/= "App" ->
            case lists:prefix("---", App) of
                true -> nav_table(Rest);
                false -> [{App, {N, Pub, Int}} | nav_table(Rest)]
            end;
        _ ->
            nav_table(Rest)
    end;
nav_table([_ | Rest]) ->
    nav_table(Rest).

check_visibility(App, Config, ExDoc, Mods, Nav) ->
    case maps:find(App, Nav) of
        error ->
            [fmt("~ts: ~ts has no row for the app", [?NAV, App])];
        {ok, {N, PubCell, IntCell}} ->
            Groups = proplists:get_value(groups_for_modules, ExDoc, []),
            Internal = lists:append([Ms || {<<"Internal">>, Ms} <- Groups]),
            Known = [M || {M, _} <- Mods],
            Pub = nav_names(App, PubCell),
            Int = nav_names(App, IntCell),
            Cfg = config_lines(Config),
            Where = fun(M) -> fmt("~ts:~b", [Config, maps:get(M, Cfg, 0)]) end,
            Ghosts = [
                fmt("~ts:~b: ~ts names ~ts, which is not a module of src", [
                    ?NAV, N, App, M
                ])
             || {exact, M} <- Pub ++ Int,
                not lists:member(list_to_atom(M), Known)
            ],
            Ghosts ++
                lists:flatmap(
                    fun(M) ->
                        Doc =
                            case lists:member(M, Internal) of
                                true -> internal;
                                false -> public
                            end,
                        case visibility(atom_to_list(M), Pub, Int) of
                            Doc ->
                                [];
                            none ->
                                [
                                    fmt(
                                        "~ts:~b: ~ts is ~ts in ex_doc (~ts) "
                                        "but not listed",
                                        [?NAV, N, M, Doc, Where(M)]
                                    )
                                ];
                            Other ->
                                [
                                    fmt(
                                        "~ts:~b: ~ts is ~ts there but ~ts "
                                        "in ex_doc (~ts)",
                                        [?NAV, N, M, Other, Doc, Where(M)]
                                    )
                                ]
                        end
                    end,
                    Known
                )
    end.

%% a name written out wins; then the wildcards; public before internal
visibility(M, Pub, Int) ->
    Exact = fun(Ns) -> lists:member({exact, M}, Ns) end,
    Wild = fun(Ns) -> lists:any(fun(P) -> wild(P, M) end, Ns) end,
    case {Exact(Pub), Exact(Int), Wild(Pub), Wild(Int)} of
        {true, _, _, _} -> public;
        {_, true, _, _} -> internal;
        {_, _, true, _} -> public;
        {_, _, _, true} -> internal;
        _ -> none
    end.

wild({prefix, P}, M) -> lists:prefix(P, M);
wild({suffix, S}, M) -> lists:suffix(S, M);
wild({exact, _}, _) -> false.

%% the backquoted names of a cell: `_x' is `<app>_x', `_x*' a prefix,
%% "every `_x'" a suffix; anything with `:' or `/' is a call, not a module
nav_names(App, Cell) ->
    {match, Ms} =
        case
            re:run(Cell, "(every\\s+)?`([^`]+)`", [
                global, {capture, all_but_first, list}
            ])
        of
            nomatch -> {match, []};
            Found -> Found
        end,
    lists:flatmap(fun(M) -> nav_name(App, M) end, Ms).

nav_name(App, [Every, Name]) ->
    case lists:any(fun(C) -> lists:member(C, ":/ ") end, Name) of
        true ->
            [];
        false ->
            Full =
                case Name of
                    "_" ++ _ -> App ++ Name;
                    _ -> Name
                end,
            case {Every, lists:last(Full)} of
                {"", $*} -> [{prefix, lists:droplast(Full)}];
                {"", _} -> [{exact, Full}];
                {_, _} -> [{suffix, Name}]
            end
    end.

%% each module of the ex_doc groups, with the line it is on
config_lines(Config) ->
    maps:from_list(
        [
            {list_to_atom(W), N}
         || {N, L} <- lines(Config),
            {match, Ws} <- [
                re:run(L, "\\b([a-z][a-z0-9_]*)\\b", [
                    global, {capture, all_but_first, list}
                ])
            ],
            [W] <- Ws
        ]
    ).

%% ---- Links -------------------------------------------------------------

md_files() ->
    Roots = ["README.md", "CONTRIBUTING.md", "AGENTS.md", "SECURITY.md"],
    Trees =
        wildcard(".", ".agents/skills/*/SKILL.md") ++
            wildcard(".", "docs/**/*.md") ++
            wildcard(".", "apps/*/docs/**/*.md") ++
            wildcard(".", "apps/*/README.md"),
    Skip = [
        "_build/", "deps/", "node_modules/", "docs/history/", "docs/plans/"
    ],
    [F || F <- Roots, filelib:is_regular(F)] ++
        [F || F <- Trees, not lists:any(fun(S) -> contains(F, S) end, Skip)].

check_links(File) ->
    case lines(File) of
        {error, not_utf8} -> [fmt("~ts: not valid UTF-8", [File])];
        Lines -> check_lines(File, Lines)
    end.

check_lines(File, Lines) ->
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
            case exists_exact(Abs) of
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
            re:run(
                L,
                "\\]\\(\\s*(?:<([^>]+)>|([^)\\s<>]+))"
                "(?:\\s+(?:\"[^\"]*\"|'[^']*'|\\([^)]*\\)))?\\s*\\)",
                [global, unicode, {capture, all_but_first, list}]
            )
        of
            {match, Ms} -> [A ++ B || [A, B | _] <- [M ++ [""] || M <- Ms]];
            nomatch -> []
        end,
    Href =
        case
            re:run(L, "<a\\s[^>]*href=\"([^\"]+)\"", [
                global, unicode, {capture, all_but_first, list}
            ])
        of
            {match, Hs} -> [H || [H] <- Hs];
            nomatch -> []
        end,
    Ref =
        case
            re:run(L, "^\\s{0,3}\\[(?!\\^)[^\\]]+\\]:\\s*<?([^\\s>]+)>?", [
                unicode, {capture, all_but_first, list}
            ])
        of
            {match, [T]} -> [T];
            nomatch -> []
        end,
    Inline ++ Href ++ Ref.

%% ---- Headings and slugs ------------------------------------------------

anchors(File) ->
    Lines =
        case lines(File) of
            {error, not_utf8} -> [];
            All -> [L || {_, L} <- unfenced(All)]
        end,
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
    T1 = untag(string:split(T0, "`", all), text),
    Lower = string:lowercase(unicode:characters_to_list(T1)),
    [
        case C of
            $\s -> $-;
            _ -> C
        end
     || C <- Lower, keep(C)
    ].

%% outside code spans an HTML tag goes; inside one its text stays
untag([], _) ->
    [];
untag([Seg | Rest], text) ->
    re:replace(Seg, "<[^>]+>", "", [global, unicode, {return, list}]) ++
        untag(Rest, code);
untag([Seg | Rest], code) ->
    Seg ++ untag(Rest, text).

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
    case unicode:characters_to_list(Bin) of
        Text when is_list(Text) ->
            Split = string:split(Text, "\n", all),
            lists:zip(lists:seq(1, length(Split)), Split);
        _ ->
            {error, not_utf8}
    end.

%% The lines outside fenced code blocks, with their numbers.
%% HTML comments are dropped too, and a fence closes only on a line with
%% the fence characters alone (CommonMark: no info string).
unfenced(Lines) ->
    unfenced(Lines, none).

unfenced([], _) ->
    [];
unfenced([{N, L} | Rest], comment) ->
    case string:split(L, "-->") of
        [_, After] -> unfenced([{N, After} | Rest], none);
        [_] -> unfenced(Rest, comment)
    end;
unfenced([{N, L} | Rest], none) ->
    case fence(L) of
        none ->
            case uncomment(L) of
                {open, Before} -> [{N, Before} | unfenced(Rest, comment)];
                Clean -> [{N, Clean} | unfenced(Rest, none)]
            end;
        F ->
            unfenced(Rest, F)
    end;
unfenced([{_, L} | Rest], {C, Open} = Fence) ->
    case closing_fence(L) of
        {C, Len} when Len >= Open -> unfenced(Rest, none);
        _ -> unfenced(Rest, Fence)
    end.

%% drop the comments a line opens and closes; an open one ends the line
uncomment(L) ->
    Closed = re:replace(L, "<!--.*?-->", "", [global, unicode, {return, list}]),
    case string:split(Closed, "<!--") of
        [Before, _] -> {open, Before};
        [_] -> Closed
    end.

closing_fence(L) ->
    case
        re:run(L, "^\\s{0,3}(`{3,}|~{3,})\\s*$", [
            unicode, {capture, all_but_first, list}
        ])
    of
        {match, [[C | _] = F]} -> {C, length(F)};
        nomatch -> none
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

%% filelib:is_file/1 with the name's case checked on every part, so a
%% case-insensitive disk (macOS) fails like CI's Linux does
exists_exact(Path) ->
    filelib:is_file(Path) andalso exact(filename:split(Path), "").

exact([], _) ->
    true;
exact([P | Rest], Dir) when P =:= "/"; P =:= "." ->
    exact(Rest, filename:join(Dir, P));
exact([P | Rest], Dir) ->
    Here =
        case Dir of
            "" -> ".";
            _ -> Dir
        end,
    case file:list_dir(Here) of
        {ok, Names} ->
            lists:member(P, Names) andalso exact(Rest, filename:join(Dir, P));
        _ ->
            true
    end.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) -> L.

fmt(F, A) -> lists:flatten(io_lib:format(F, A)).
