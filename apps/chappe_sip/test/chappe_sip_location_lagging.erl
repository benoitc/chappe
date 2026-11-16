%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% A location store whose local replica lags behind the region, as a
%% follower's does: a local read returns what the replica holds, which
%% never catches up by itself here; a consistent read returns the region's
%% value. Writes compare against the region's version. The test sets the
%% two views (set/3) and counts the reads (reads/0).
-module(chappe_sip_location_lagging).
-behaviour(chappe_sip_location).

-export([read/2, write/3, aors/0, clear/0]).
-export([new/0, set/3, region/1, reads/0]).

-define(T, ?MODULE).

new() ->
    _ = ets:info(?T) =/= undefined andalso ets:delete(?T),
    ?T = ets:new(?T, [named_table, public, set]),
    ok.

%% View is local or region.
set(View, Aor, {Bs, Version}) ->
    ets:insert(?T, {{View, Aor}, {Bs, Version}}),
    ok.

region(Aor) ->
    view(region, Aor).

reads() ->
    [{M, N} || {{reads, M}, N} <- ets:tab2list(?T)].

read(Aor, Mode) ->
    _ = ets:update_counter(?T, {reads, Mode}, 1, {{reads, Mode}, 0}),
    View =
        case Mode of
            local -> local;
            consistent -> region
        end,
    {Bs, V} = view(View, Aor),
    {ok, Bs, V}.

write(Aor, Version, Bs) ->
    case view(region, Aor) of
        {_, Version} ->
            ets:insert(?T, {{region, Aor}, {Bs, Version + 1}}),
            ok;
        _ ->
            {error, conflict}
    end.

aors() ->
    [].

clear() ->
    ok.

view(View, Aor) ->
    case ets:lookup(?T, {View, Aor}) of
        [{_, V}] -> V;
        [] -> {[], 0}
    end.
