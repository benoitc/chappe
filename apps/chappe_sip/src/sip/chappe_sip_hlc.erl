%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The node's hybrid logical clock, for what chappe_sip orders across
%% nodes (the message-summary updates of chappe_sip_mwi).
%%
%% One clock per node: chappe_cluster's (chappe_cluster:now/0) when it
%% runs, else chappe_sip's own, `chappe_sip_hlc_clock', started by
%% chappe_sip_sup on the `wall_clock' setting and bounded by
%% `hlc_max_offset_ms'. Every stamp a node receives moves its clock
%% forward (seen/1), within that bound.
%%
%% later/2 gives a stamp later than a stamp already seen for the same
%% thing, so an update made after another was seen is
%% ordered after it even when the other came from a node whose wall clock
%% runs far ahead (past the bound the clock itself does not follow). The
%% order is causal, not the wall clocks'.
-module(chappe_sip_hlc).

-compile({no_auto_import, [now/0]}).

-include_lib("hlc/include/hlc.hrl").

-export([child_spec/0, now/0, seen/1, later/2]).

-export_type([stamp/0]).
-type stamp() :: hlc:timestamp().

-define(CLOCK, chappe_sip_hlc_clock).

%% chappe_sip's own clock, for chappe_sip_sup.
-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{
        id => ?CLOCK,
        start =>
            {hlc, start_link, [
                ?CLOCK, wall_clock(), chappe_sip_config:get(hlc_max_offset_ms)
            ]}
    }.

wall_clock() ->
    {M, F, A} = chappe_sip_config:get(wall_clock),
    fun() -> erlang:apply(M, F, A) end.

%% A stamp of this node's clock.
-spec now() -> stamp().
now() ->
    case whereis(chappe_cluster_hlc) of
        undefined -> hlc:now(?CLOCK);
        _ -> chappe_cluster:now()
    end.

%% A stamp received from another node moves this node's clock forward
%% (within hlc_max_offset_ms). Anything else is ignored.
-spec seen(term()) -> ok.
seen(#timestamp{} = T) ->
    try hlc:update(clock(), T) of
        _ -> ok
    catch
        exit:_ -> ok
    end;
seen(_) ->
    ok.

%% Stamp (taken with now/0 when the event happened), unless Last (a
%% stamp already seen for the same thing, or undefined) is not before it:
%% then the stamp right after Last.
-spec later(stamp(), stamp() | undefined) -> stamp().
later(Stamp, #timestamp{logical = L} = Last) when Last >= Stamp ->
    Last#timestamp{logical = L + 1};
later(Stamp, _Last) ->
    Stamp.

clock() ->
    case whereis(chappe_cluster_hlc) of
        undefined -> ?CLOCK;
        _ -> chappe_cluster_hlc
    end.
