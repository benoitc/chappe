%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The lease checker of the cluster lab (make interop-cluster).
%%
%% Every lab node runs client workers that claim keys, use the fence and log
%% what they believe, one event per line:
%%
%%     {Time, Holder, Key, Kind, Fence}.
%%
%% Time is the holder's own clock in microseconds, Holder is an opaque term
%% naming one worker of one node boot, Kind is claim_ok | renew | lost |
%% release | fence_used, and Fence is the fence of the lease the event is
%% about.
%%
%% A lease is valid, from its holder's point of view, from its claim_ok to
%% its lost or release. A holder that logs neither (its node was killed, or
%% the run ended) held it until its last logged event on that key: past that
%% point it did nothing with it. The checker asserts:
%%
%% - no overlap: two leases on one key never overlap by more than the margin
%%   (margin_us, for timestamps taken on different clocks);
%% - fence order: on one key, each claim carries a fence strictly greater
%%   than the claim before it;
%% - use in a lease: renew and fence_used come from a holder with an open
%%   lease on the key, with that lease's fence.
%%
%% check/2 returns the first violation in time, with the events of its key
%% around it.
-module(chappe_cluster_lab_checker).

-export([
    check/1,
    check/2,
    leases/1,
    parse/1,
    read_logs/1,
    stats/1,
    format/1
]).

-export_type([event/0, violation/0]).

-type kind() :: claim_ok | renew | lost | release | fence_used.
-type event() :: {integer(), term(), term(), kind(), term()}.
-type lease() :: #{
    key := term(),
    holder := term(),
    fence := term(),
    start := integer(),
    stop := integer(),
    open := boolean(),
    claim := event(),
    last := event()
}.
-type violation() :: #{
    kind :=
        overlap | fence_order | use_without_lease | fence_mismatch | bad_event,
    at := integer(),
    key => term(),
    first => lease() | event(),
    second => lease() | event(),
    context => [event()]
}.
-type opts() :: #{
    margin_us => non_neg_integer(),
    fence_key => fun((term()) -> term()),
    context => non_neg_integer()
}.

-define(KINDS, [claim_ok, renew, lost, release, fence_used]).

%% @doc Check a log with no margin.
-spec check([event()]) -> ok | {violation, violation()}.
check(Events) ->
    check(Events, #{}).

%% @doc Check a log. The events may come in any order (one file per node).
-spec check([event()], opts()) -> ok | {violation, violation()}.
check(Events0, Opts) ->
    Margin = maps:get(margin_us, Opts, 0),
    FenceKey = maps:get(fence_key, Opts, fun fence_key/1),
    Ctx = maps:get(context, Opts, 8),
    case [E || E <- Events0, not valid_event(E)] of
        [Bad | _] ->
            {violation, #{kind => bad_event, at => 0, first => Bad}};
        [] ->
            Events = lists:keysort(1, Events0),
            Found =
                case leases(Events) of
                    {error, V} -> [V];
                    {ok, Leases} -> violations(Leases, Margin, FenceKey)
                end,
            first_violation(Found, Events, Ctx)
    end.

first_violation([], _Events, _Ctx) ->
    ok;
first_violation(Found, Events, Ctx) ->
    [V | _] = lists:sort(fun(A, B) -> at(A) =< at(B) end, Found),
    {violation, V#{context => context(V, Events, Ctx)}}.

at(#{at := At}) -> At.

%% The leases of a log sorted by time, or the first event that uses a key
%% its holder does not hold.
-spec leases([event()]) -> {ok, [lease()]} | {error, violation()}.
leases(Events) ->
    leases(Events, #{}, []).

leases([], Open, Done) ->
    Closed = [L#{open => true} || L <- maps:values(Open)],
    {ok, lists:sort(fun by_start/2, Closed ++ Done)};
leases([{T, H, K, claim_ok, F} = E | Rest], Open, Done) ->
    Done1 =
        case Open of
            %% claimed again without an end: the first lease ends here
            #{{K, H} := L} -> [L#{stop => T, last => E} | Done];
            #{} -> Done
        end,
    L1 = #{
        key => K,
        holder => H,
        fence => F,
        start => T,
        stop => T,
        open => false,
        claim => E,
        last => E
    },
    leases(Rest, Open#{{K, H} => L1}, Done1);
leases([{T, H, K, Kind, F} = E | Rest], Open, Done) when
    Kind =:= renew; Kind =:= fence_used
->
    case Open of
        #{{K, H} := #{fence := F} = L} ->
            leases(Rest, Open#{{K, H} => L#{stop => T, last => E}}, Done);
        #{{K, H} := L} ->
            {error, #{
                kind => fence_mismatch,
                at => T,
                key => K,
                first => L,
                second => E
            }};
        #{} ->
            {error, #{
                kind => use_without_lease, at => T, key => K, second => E
            }}
    end;
leases([{T, H, K, _LostOrRelease, _F} = E | Rest], Open, Done) ->
    case maps:take({K, H}, Open) of
        {L, Open1} -> leases(Rest, Open1, [L#{stop => T, last => E} | Done]);
        %% a lost after a release, or for a lease never seen: nothing held
        error -> leases(Rest, Open, Done)
    end.

by_start(#{start := A}, #{start := B}) -> A =< B.

violations(Leases, Margin, FenceKey) ->
    ByKey = maps:groups_from_list(fun(#{key := K}) -> K end, Leases),
    lists:append([
        overlaps(Ls, Margin) ++ fence_order(Ls, FenceKey)
     || Ls <- maps:values(ByKey)
    ]).

%% Leases sorted by start; the one ending last so far is the one a new
%% lease must start after.
overlaps([], _Margin) ->
    [];
overlaps([First | Rest], Margin) ->
    overlaps(Rest, First, Margin).

overlaps([], _Prev, _Margin) ->
    [];
overlaps([#{start := S} = L | _], #{stop := E} = Prev, Margin) when
    S < E - Margin
->
    [
        #{
            kind => overlap,
            at => S,
            key => maps:get(key, L),
            first => Prev,
            second => L
        }
    ];
overlaps([#{stop := E} = L | Rest], #{stop := PE} = Prev, Margin) ->
    Next =
        case E > PE of
            true -> L;
            false -> Prev
        end,
    overlaps(Rest, Next, Margin).

fence_order([], _FenceKey) ->
    [];
fence_order([First | Rest], FenceKey) ->
    fence_order(Rest, First, FenceKey).

fence_order([], _Prev, _FenceKey) ->
    [];
fence_order([#{fence := F, start := S, key := K} = L | Rest], Prev, FenceKey) ->
    #{fence := PF} = Prev,
    case FenceKey(F) > FenceKey(PF) of
        true ->
            fence_order(Rest, L, FenceKey);
        false ->
            [
                #{
                    kind => fence_order,
                    at => S,
                    key => K,
                    first => Prev,
                    second => L
                }
            ]
    end.

%% A fence {Region, NodeEpoch, Seq} orders by Seq: the epochs of two nodes
%% are not comparable.
fence_key({_Region, _Epoch, Seq}) -> Seq;
fence_key(Fence) -> Fence.

valid_event({T, _H, _K, Kind, _F}) when is_integer(T) ->
    lists:member(Kind, ?KINDS);
valid_event(_) ->
    false.

%% The events of the violation's key around the time it happened.
context(#{key := K, at := At}, Events, Ctx) ->
    Mine = [E || {_, _, EK, _, _} = E <- Events, EK =:= K],
    {Before, After} = lists:splitwith(fun({T, _, _, _, _}) -> T < At end, Mine),
    lists:nthtail(max(0, length(Before) - Ctx), Before) ++
        lists:sublist(After, Ctx + 1);
context(_V, _Events, _Ctx) ->
    [].

%% @doc Parse one node log. A line that does not parse (the last one, cut by
%% a kill) is counted and skipped.
-spec parse(binary()) -> {[event()], non_neg_integer()}.
parse(Bin) ->
    Lines = [L || L <- binary:split(Bin, <<"\n">>, [global]), L =/= <<>>],
    lists:foldr(
        fun(Line, {Evs, Bad}) ->
            case parse_line(Line) of
                {ok, Ev} -> {[Ev | Evs], Bad};
                error -> {Evs, Bad + 1}
            end
        end,
        {[], 0},
        Lines
    ).

parse_line(Line) ->
    case erl_scan:string(binary_to_list(Line)) of
        {ok, Toks, _} ->
            case erl_parse:parse_term(Toks) of
                {ok, Ev} -> {ok, Ev};
                {error, _} -> error
            end;
        _ ->
            error
    end.

%% @doc Every `*.log' file under Dir, merged.
-spec read_logs(file:filename()) -> {[event()], non_neg_integer()}.
read_logs(Dir) ->
    Files = filelib:wildcard(filename:join([Dir, "**", "*.log"])),
    lists:foldl(
        fun(File, {Evs, Bad}) ->
            {ok, Bin} = file:read_file(File),
            {E, B} = parse(Bin),
            {E ++ Evs, B + Bad}
        end,
        {[], 0},
        Files
    ).

%% @doc Counts for the report: events, claims, losts, releases, fence uses,
%% holders, keys, and takeovers (a claim on a key last held by another node).
-spec stats([event()]) -> #{atom() => non_neg_integer()}.
stats(Events) ->
    Count = fun(Kind) ->
        length([E || {_, _, _, K, _} = E <- Events, K =:= Kind])
    end,
    #{
        events => length(Events),
        claims => Count(claim_ok),
        losts => Count(lost),
        releases => Count(release),
        uses => Count(fence_used),
        holders => length(lists:usort([H || {_, H, _, _, _} <- Events])),
        keys => length(lists:usort([K || {_, _, K, _, _} <- Events])),
        takeovers => takeovers(Events)
    }.

takeovers(Events) ->
    Claims = lists:keysort(1, [E || {_, _, _, claim_ok, _} = E <- Events]),
    {N, _} = lists:foldl(
        fun({_, H, K, _, _}, {N0, Last}) ->
            Node = holder_node(H),
            case Last of
                #{K := Prev} when Prev =/= Node -> {N0 + 1, Last#{K => Node}};
                #{} -> {N0, Last#{K => Node}}
            end
        end,
        {0, #{}},
        Claims
    ),
    N.

holder_node({Node, _Boot, _Worker}) -> Node;
holder_node(H) -> H.

%% @doc A violation as text.
-spec format(violation()) -> iolist().
format(#{kind := Kind, at := At} = V) ->
    [
        io_lib:format("violation: ~p at ~p~n", [Kind, At]),
        [
            io_lib:format("  key: ~p~n", [K])
         || K <- [maps:get(key, V, undefined)]
        ],
        [io_lib:format("  first: ~p~n", [brief(F)]) || F <- opt(first, V)],
        [io_lib:format("  second: ~p~n", [brief(S)]) || S <- opt(second, V)],
        "  events around it:\n",
        [io_lib:format("    ~p~n", [E]) || E <- maps:get(context, V, [])]
    ].

opt(Key, V) ->
    case V of
        #{Key := X} -> [X];
        #{} -> []
    end.

brief(#{holder := H, fence := F, start := S, stop := E, open := O}) ->
    #{holder => H, fence => F, start => S, stop => E, open => O};
brief(Ev) ->
    Ev.
