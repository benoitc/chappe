%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Guards the documentation snippets against API drift. It scans every fenced
%% ```erlang code block in the umbrella's guides, design docs, READMEs,
%% the umbrella docs/ tree and CONTRIBUTING.md,
%% parses each block, and asserts that every `chappe_*' module:function/arity it
%% calls actually exists and is exported. It does not execute the snippets: most
%% are fragments with free variables (Req, Res, Dialog, ...) or need a live SIP /
%% media stack, so running them is neither possible nor the point. What rots
%% after a rename is the API surface, and that is exactly what this verifies.
%%
%% A syntactically broken snippet also fails here (the block must at least
%% parse). Non-`chappe_*' modules (io, maps, crypto, ...) are not checked, so a
%% snippet may reference a user module like `my_call' without tripping this.
-module(doc_snippets_tests).

-include_lib("eunit/include/eunit.hrl").

%% One eunit case per referenced API call (plus one per un-parseable block), so
%% a failure names the exact file:line and call.
doc_snippets_test_() ->
    Root = umbrella_root(),
    Files = doc_files(Root),
    ?assert(Files =/= []),
    Cases = lists:flatmap(fun(F) -> file_cases(Root, F) end, Files),
    %% Sanity: the corpus is non-trivial, so a broken scanner cannot pass by
    %% silently finding nothing.
    ?assert(length(Cases) >= 50),
    [case_to_test(C) || C <- Cases].

case_to_test({call, Where, M, F, A}) ->
    {Where ++ lists:flatten(io_lib:format(" ~p:~p/~p", [M, F, A])), fun() ->
        _ = code:ensure_loaded(M),
        ?assertEqual(
            {Where, M, F, A, true},
            {Where, M, F, A, erlang:function_exported(M, F, A)}
        )
    end};
case_to_test({parse_error, Where, Reason}) ->
    {Where ++ " (parse)", fun() ->
        erlang:error({snippet_parse_error, Where, Reason})
    end}.

%% ---- doc discovery ----

umbrella_root() ->
    {ok, Cwd} = file:get_cwd(),
    find_root(Cwd).

find_root(Dir) ->
    IsRoot =
        filelib:is_dir(filename:join(Dir, "apps")) andalso
            filelib:is_file(filename:join(Dir, "rebar.config")),
    case IsRoot of
        true ->
            Dir;
        false ->
            Parent = filename:dirname(Dir),
            case Parent of
                Dir -> error(umbrella_root_not_found);
                _ -> find_root(Parent)
            end
    end.

doc_files(Root) ->
    lists:usort(
        filelib:wildcard(filename:join(Root, "apps/*/docs/**/*.md")) ++
            filelib:wildcard(filename:join(Root, "apps/*/README.md")) ++
            filelib:wildcard(filename:join(Root, "docs/**/*.md")) ++
            filelib:wildcard(filename:join(Root, "CONTRIBUTING.md")) ++
            filelib:wildcard(filename:join(Root, "README.md"))
    ).

%% ---- per-file extraction ----

file_cases(Root, File) ->
    {ok, Bin} = file:read_file(File),
    Rel = rel(Root, File),
    Blocks = erlang_blocks(numbered_lines(Bin)),
    lists:flatmap(fun({Line, Src}) -> block_cases(Rel, Line, Src) end, Blocks).

numbered_lines(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    lists:zip(lists:seq(1, length(Lines)), Lines).

%% Collect {StartLine, Source} for each ```erlang ... ``` block.
erlang_blocks(Numbered) ->
    erlang_blocks(Numbered, outside, []).

erlang_blocks([], _State, Acc) ->
    lists:reverse(Acc);
erlang_blocks([{_N, Line} | T], outside, Acc) ->
    case is_erlang_fence(Line) of
        true -> erlang_blocks(T, {inside, undefined, []}, Acc);
        false -> erlang_blocks(T, outside, Acc)
    end;
erlang_blocks([{N, Line} | T], {inside, Start, Rev}, Acc) ->
    case is_fence(Line) of
        true ->
            Src = join_lines(lists:reverse(Rev)),
            erlang_blocks(T, outside, [{fallback(Start, N), Src} | Acc]);
        false ->
            Start1 =
                case Start of
                    undefined -> N;
                    _ -> Start
                end,
            erlang_blocks(T, {inside, Start1, [Line | Rev]}, Acc)
    end.

fallback(undefined, N) -> N;
fallback(Start, _N) -> Start.

is_erlang_fence(Line) ->
    Trimmed = string:trim(Line, leading),
    binary:part(pad(Trimmed), 0, min(9, byte_size(pad(Trimmed)))) =:=
        <<"```erlang">>.

is_fence(Line) ->
    Trimmed = string:trim(Line, leading),
    byte_size(Trimmed) >= 3 andalso binary:part(Trimmed, 0, 3) =:= <<"```">>.

pad(Bin) when byte_size(Bin) >= 9 -> Bin;
pad(Bin) -> <<Bin/binary, 0:((9 - byte_size(Bin)) * 8)>>.

join_lines(Lines) ->
    iolist_to_binary(lists:join(<<"\n">>, Lines)).

%% ---- per-block parsing + call extraction ----

block_cases(Rel, Line, Src) ->
    Where = lists:flatten(io_lib:format("~ts:~p", [Rel, Line])),
    case erl_scan:string(normalize(Src)) of
        {ok, Tokens, _} ->
            forms_cases(Where, split_forms(Tokens));
        {error, Info, _} ->
            [{parse_error, Where, {scan, Info}}]
    end.

%% Docs use `...' as an elision ("fill in the rest"), which is not valid Erlang.
%% Turn the common shapes into empty/placeholder terms so the block parses and
%% the real calls around the elision are still verified.
normalize(Src) ->
    S0 = unicode:characters_to_list(Src),
    S1 = re:replace(S0, "#\\{\\s*\\.\\.\\.\\s*\\}", "#{}", [
        global, {return, list}
    ]),
    S2 = re:replace(S1, "\\[\\s*\\.\\.\\.\\s*\\]", "[]", [
        global, {return, list}
    ]),
    re:replace(S2, "\\.\\.\\.", "_Elided", [global, {return, list}]).

forms_cases(Where, Chunks) ->
    lists:flatmap(fun(Chunk) -> chunk_cases(Where, Chunk) end, Chunks).

chunk_cases(_Where, {dot, [{dot, _}]}) ->
    %% a lone terminator, nothing to check
    [];
chunk_cases(Where, {dot, Toks}) ->
    case erl_parse:parse_form(Toks) of
        {ok, Form} -> calls_to_cases(Where, remote_calls(Form));
        {error, _} -> wrapped_cases(Where, strip_dot(Toks))
    end;
chunk_cases(Where, {nodot, Toks}) ->
    wrapped_cases(Where, Toks).

%% Wrap a bare expression sequence as a function body so it parses, then walk it.
wrapped_cases(Where, Toks) ->
    Wrapped =
        [{atom, 1, '__snippet__'}, {'(', 1}, {')', 1}, {'->', 1}] ++
            Toks ++ [{dot, 1}],
    case erl_parse:parse_form(Wrapped) of
        {ok, Form} -> calls_to_cases(Where, remote_calls(Form));
        {error, Reason} -> [{parse_error, Where, Reason}]
    end.

calls_to_cases(Where, Calls) ->
    [{call, Where, M, F, A} || {M, F, A} <- lists:usort(Calls)].

strip_dot(Toks) ->
    case lists:reverse(Toks) of
        [{dot, _} | Rev] -> lists:reverse(Rev);
        _ -> Toks
    end.

%% Split a token stream into forms at top-level dot tokens. {dot, Toks} keeps
%% the trailing dot; {nodot, Toks} is a trailing chunk with no terminator.
split_forms(Tokens) ->
    split_forms(Tokens, [], []).

split_forms([], [], Acc) ->
    lists:reverse(Acc);
split_forms([], Cur, Acc) ->
    lists:reverse([{nodot, lists:reverse(Cur)} | Acc]);
split_forms([{dot, _} = D | T], Cur, Acc) ->
    split_forms(T, [], [{dot, lists:reverse([D | Cur])} | Acc]);
split_forms([Tok | T], Cur, Acc) ->
    split_forms(T, [Tok | Cur], Acc).

%% Collect every chappe_* remote call and fun-reference in an abstract form.
remote_calls(Form) ->
    walk(Form, []).

walk({call, _, {remote, _, {atom, _, M}, {atom, _, F}}, Args}, Acc) ->
    Acc1 = add(M, F, length(Args), Acc),
    walk(Args, Acc1);
walk({'fun', _, {function, {atom, _, M}, {atom, _, F}, {integer, _, A}}}, Acc) ->
    add(M, F, A, Acc);
walk(Node, Acc) when is_tuple(Node) ->
    walk(tuple_to_list(Node), Acc);
walk([H | T], Acc) ->
    walk(T, walk(H, Acc));
walk(_, Acc) ->
    Acc.

add(M, F, A, Acc) ->
    case is_chappe(M) of
        true -> [{M, F, A} | Acc];
        false -> Acc
    end.

is_chappe(M) ->
    lists:prefix("chappe_", atom_to_list(M)).

rel(Root, File) ->
    Prefix = Root ++ "/",
    case lists:prefix(Prefix, File) of
        true -> lists:nthtail(length(Prefix), File);
        false -> File
    end.
