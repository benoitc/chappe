%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc A cluster room (the chappe_mrf `cluster' setting chappe_cluster): the
%% start in the caller, and the lease decisions the room process takes.
%%
%% start/2 runs in the caller of chappe_mrf_conf:start/2. It starts the
%% room process waiting (no name, no backend, its pid given to no one),
%% claims the lease {chappe_mrf_conf, Name} for it, then hands the lease
%% over ({activate, Lease}): only then does the room register its name and
%% set up its backend. The claim never holds the conf supervisor, and a
%% room takes members only under its lease. Without a quorum it opens no
%% second room: it returns the room the local replica names, when this
%% node reaches it, else {error, no_quorum}.
%%
%% The waiting room, owned/2 and the loss of the lease stay in the room
%% process (chappe_mrf_conf); the decisions here are pure.
-module(chappe_mrf_conf_cluster).

-export([start/2, lease_key/1]).
-export([activation/2, same_lease/2, closing/3, start_timeout/0]).

%% start/2's one deadline for every try (start_timeout), and the pause
%% before it starts over when the owner it found is gone
-define(START_MS, 10000).
-define(RETRY_MS, 300).

%% ---- in the caller ----

%% Args: the room's init args (name, opts, caller).
-spec start(binary(), map()) -> {ok, pid()} | {error, term()}.
start(Name, Args) ->
    start_cluster(Name, Args, start_deadline()).

-spec lease_key(binary()) -> {chappe_mrf_conf, binary()}.
lease_key(Name) ->
    {chappe_mrf_conf, Name}.

-spec start_timeout() -> pos_integer().
start_timeout() ->
    application:get_env(chappe_mrf, start_timeout, ?START_MS).

start_deadline() ->
    erlang:monotonic_time(millisecond) + start_timeout().

left(Deadline) ->
    max(1, Deadline - erlang:monotonic_time(millisecond)).

expired(Deadline) ->
    erlang:monotonic_time(millisecond) + ?RETRY_MS >= Deadline.

%% A room the local replica names on another node is used as it is: a
%% call setup there needs no Raft write. Otherwise claim.
start_cluster(Name, #{opts := Opts} = Args, Deadline) ->
    case {cluster_started(), chappe_mrf_conf_move:draining()} of
        {{ok, _}, true} ->
            %% this node is stopping: the room opens on a live node
            case
                chappe_mrf_conf_move:open(
                    Name, Opts, chappe_mrf_conf_move:region(), none, Deadline
                )
            of
                {ok, Conf} -> {ok, Conf};
                {error, _} -> {error, draining}
            end;
        {{ok, _}, false} ->
            case remote_owner(Name) of
                {ok, Conf} -> await_active(Conf, Name, Args, Deadline);
                none -> start_claimed(Name, Args, Deadline)
            end;
        {{error, _} = Err, _} ->
            Err
    end.

cluster_started() ->
    case application:ensure_all_started(chappe_cluster) of
        {ok, _} = Ok -> Ok;
        {error, Why} -> {error, {cluster, Why}}
    end.

remote_owner(Name) ->
    Here = node(),
    case chappe_cluster:owner(lease_key(Name)) of
        {ok, #{node := Node, pid := Conf}} when Node =/= Here ->
            case lists:member(Node, nodes()) of
                true -> {ok, Conf};
                false -> none
            end;
        _ ->
            none
    end.

%% The owner may still be waiting for its lease: its info/1 answers once
%% it runs. One that never runs (its starter died, its claim came back
%% stale) is gone, as is one that gave its name up: try again, until the
%% start's deadline.
await_active(Conf, Name, Args, Deadline) ->
    case chappe_mrf_conf:call(Conf, info, left(Deadline)) of
        #{lost := false} -> {ok, Conf};
        #{lost := true} -> again(Name, Args, Deadline, {error, lost});
        {error, noproc} -> again(Name, Args, Deadline, {error, noproc});
        {error, _} = Err -> Err
    end.

again(Name, Args, Deadline, Err) ->
    case expired(Deadline) of
        true ->
            Err;
        false ->
            %% a dead holder's lease goes with it once the region hears of
            %% its death
            timer:sleep(?RETRY_MS),
            start_cluster(Name, Args, Deadline)
    end.

%% The claim runs here, in the caller, for the waiting room: it waits at
%% most claim_timeout (1000 ms; a node that knows it lost its quorum
%% answers at once), and no other room's start waits behind it.
start_claimed(Name, Args, Deadline) ->
    maybe
        {ok, Room} ?= chappe_mrf_sup:start_conf(Args#{wait => true}),
        Timeout = min(
            application:get_env(chappe_mrf, claim_timeout, 1000), left(Deadline)
        ),
        Claim = chappe_cluster:claim(lease_key(Name), #{
            pid => Room, timeout => Timeout
        }),
        claimed(Claim, Room, Name, Args, Deadline)
    end.

claimed({ok, Lease}, Room, Name, Args, Deadline) ->
    case chappe_mrf_conf:call(Room, {activate, Lease}, left(Deadline)) of
        ok -> {ok, Room};
        {error, {already_started, Other}} -> {ok, Other};
        {error, draining} -> start_cluster(Name, Args, Deadline);
        {error, _} = Err -> Err
    end;
claimed({error, {owned, #{pid := Other}}}, Room, Name, Args, Deadline) ->
    ok = chappe_mrf_conf:stop(Room),
    case reachable(Other) of
        {ok, _} -> await_active(Other, Name, Args, Deadline);
        {error, _} = Err -> Err
    end;
claimed({error, no_quorum}, Room, Name, _Args, _Deadline) ->
    ok = chappe_mrf_conf:stop(Room),
    known_owner(Name);
claimed({error, _} = Err, Room, _Name, _Args, _Deadline) ->
    ok = chappe_mrf_conf:stop(Room),
    Err.

%% The room another node runs, when this node reaches it.
reachable(Conf) ->
    Node = node(Conf),
    case Node =:= node() orelse lists:member(Node, nodes()) of
        true -> {ok, Conf};
        false -> {error, {owner_unreachable, Node}}
    end.

%% No quorum: the owner the local replica knows, never a second room. One
%% on this node is a room that gave its name up (lost) or is gone: start/2
%% found no room registered here.
known_owner(Name) ->
    Here = node(),
    case chappe_cluster:owner(lease_key(Name)) of
        {ok, #{node := Here}} ->
            {error, no_quorum};
        {ok, #{pid := Conf}} ->
            case reachable(Conf) of
                {ok, _} = Ok -> Ok;
                {error, _} -> {error, no_quorum}
            end;
        _ ->
            {error, no_quorum}
    end.

%% ---- the room's decisions ----

%% The lease handed to a waiting room: run under it, or not here (the
%% node began to drain after the claim: give it back), or no longer
%% valid.
-spec activation(Draining :: boolean(), Valid :: boolean()) ->
    run | release | no_quorum.
activation(true, _Valid) -> release;
activation(false, true) -> run;
activation(false, false) -> no_quorum.

%% A lost lease of the room's own (not of an older one).
-spec same_lease(map(), map() | undefined) -> boolean().
same_lease(#{seq := Seq}, #{seq := Seq}) -> true;
same_lease(_Lost, _Lease) -> false.

%% A room that lost its name ends once it has no member and no join
%% under way.
-spec closing(boolean(), map(), map()) -> boolean().
closing(Lost, Members, Pending) ->
    Lost andalso map_size(Members) =:= 0 andalso map_size(Pending) =:= 0.
