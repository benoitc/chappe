%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The REFERs a room carries out (chappe_mrf_conf_refer), as a value
%% the room keeps in its state. An op is one thing REFERs asked the room
%% for, keyed {Origin, Method, AOR}: who asked (chappe_sip_refer:origin/1:
%% a dialog, or a request's Call-ID and From tag), the Refer-To method,
%% and the target's address-of-record (chappe_sip_uri:aor/1). A REFER
%% that asks again for the same thing from the same origin (a UA that
%% sends a new REFER when the first one's answer was lost, or a user who
%% asks twice) is the same op: it is attached to the op in flight and
%% hears the same progress and final status, or, once the op is done,
%% its final status at once. Nothing is dialed twice.
%%
%% Bounds: a done op is kept 32 s (64*T1, the lifetime of the REFER's
%% transaction, RFC 3261 17.1.2.2), then forgotten; a room keeps at most
%% 64 ops, and a new one past that is refused (the caller answers 503).
-module(chappe_mrf_conf_refer_op).

-export([new/0, key/3, aor/1, lookup/2, reserve/3, start/3, attach/3]).
-export([progress/3, final/3, abort/2, in_flight/1, count/1]).
-export([data/2, set_data/3]).

-export_type([ops/0, key/0]).

-define(KEEP_MS, 32000).
-define(MAX_OPS, 64).

-type key() :: {chappe_sip_refer:origin(), binary(), binary()}.
-type status() :: 100..699.
-type op() :: #{
    refers := [chappe_sip_refer:refer()],
    state := reserved | running | {done, 200..699, integer()},
    progress := status() | undefined,
    data := map()
}.
-type ops() :: #{key() => op()}.

-spec new() -> ops().
new() -> #{}.

%% The key of a REFER from Origin asking Method for Target.
-spec key(chappe_sip_refer:origin(), binary(), binary()) -> key().
key(Origin, Method, Target) ->
    {Origin, Method, aor(Target)}.

%% The address-of-record of a URI, to compare targets and members; a URI
%% chappe_sip_uri:aor/1 does not read stays as it is.
-spec aor(binary()) -> binary().
aor(Uri) when is_binary(Uri) ->
    case chappe_sip_uri:aor(Uri) of
        {ok, A} -> A;
        error -> Uri
    end.

%% What the room knows of Key: an op reserved (its REFER not accepted
%% yet) or running, with its data, one done with its final status, or
%% none.
-spec lookup(key(), ops()) ->
    {reserved | running, map()} | {done, 200..699} | none.
lookup(Key, Ops) ->
    case maps:find(Key, prune(Ops)) of
        {ok, #{state := {done, St, _}}} -> {done, St};
        {ok, #{state := State, data := Data}} -> {State, Data};
        error -> none
    end.

%% Hold Key for a REFER the room is about to accept (Data: what the room
%% needs to carry it out). {error, full} past the room's bound.
-spec reserve(key(), map(), ops()) -> {ok, ops()} | {error, full}.
reserve(Key, Data, Ops0) ->
    Ops = prune(Ops0),
    case map_size(Ops) >= ?MAX_OPS of
        true ->
            {error, full};
        false ->
            Op = #{refers => [], state => reserved, progress => undefined},
            {ok, Ops#{Key => Op#{data => Data}}}
    end.

%% The REFER of a reserved Key was accepted: the op runs.
-spec start(key(), chappe_sip_refer:refer(), ops()) -> ops().
start(Key, Refer, Ops) ->
    case Ops of
        #{Key := #{state := reserved} = Op} ->
            Ops#{Key := Op#{state := running, refers := [Refer]}};
        #{} ->
            Ops
    end.

%% Another accepted REFER for Key: it hears what the op heard so far and
%% what comes; for a done op, its final status now.
-spec attach(key(), chappe_sip_refer:refer(), ops()) -> ops().
attach(Key, Refer, Ops) ->
    case Ops of
        #{Key := #{state := {done, St, _}}} ->
            ok = chappe_sip_refer:final(Refer, St),
            Ops;
        #{Key := #{refers := Rs, progress := P} = Op} ->
            _ =
                is_integer(P) andalso P > 100 andalso
                    chappe_sip_refer:progress(Refer, P),
            Ops#{Key := Op#{refers := [Refer | Rs]}};
        #{} ->
            %% forgotten meanwhile: nothing will report it
            ok = chappe_sip_refer:final(Refer, 503),
            Ops
    end.

%% A provisional status of the referenced request, to every REFER of Key.
-spec progress(key(), 101..199, ops()) -> ops().
progress(Key, St, Ops) ->
    case Ops of
        #{Key := #{state := running, refers := Rs} = Op} ->
            [ok = chappe_sip_refer:progress(R, St) || R <- Rs],
            Ops#{Key := Op#{progress := St}};
        #{} ->
            Ops
    end.

%% The final status of the referenced request, to every REFER of Key;
%% the op is done, and kept a while for a repeated REFER.
-spec final(key(), 200..699, ops()) -> ops().
final(Key, St, Ops) ->
    case Ops of
        #{Key := #{state := running, refers := Rs} = Op} ->
            [ok = chappe_sip_refer:final(R, St) || R <- lists:reverse(Rs)],
            Done = {done, St, erlang:monotonic_time(millisecond)},
            Ops#{Key := Op#{state := Done, refers := []}};
        #{Key := #{state := reserved}} ->
            maps:remove(Key, Ops);
        #{} ->
            Ops
    end.

%% A reserved Key whose REFER was not accepted after all.
-spec abort(key(), ops()) -> ops().
abort(Key, Ops) ->
    case Ops of
        #{Key := #{state := reserved}} -> maps:remove(Key, Ops);
        #{} -> Ops
    end.

%% The ops under way, with their data.
-spec in_flight(ops()) -> [{key(), map()}].
in_flight(Ops) ->
    [{K, D} || K := #{state := S, data := D} <- Ops, not is_tuple(S)].

%% The data of an op under way, or undefined.
-spec data(key(), ops()) -> map() | undefined.
data(Key, Ops) ->
    case Ops of
        #{Key := #{data := D}} -> D;
        #{} -> undefined
    end.

%% Merge Data into what an op keeps.
-spec set_data(key(), map(), ops()) -> ops().
set_data(Key, Data, Ops) ->
    case Ops of
        #{Key := #{data := D} = Op} ->
            Ops#{Key := Op#{data := maps:merge(D, Data)}};
        #{} ->
            Ops
    end.

%% How many ops the room keeps.
-spec count(ops()) -> non_neg_integer().
count(Ops) ->
    map_size(Ops).

%% done ops past their time are forgotten
prune(Ops) ->
    Now = erlang:monotonic_time(millisecond),
    maps:filter(
        fun
            (_K, #{state := {done, _, T}}) -> Now - T < ?KEEP_MS;
            (_K, _Op) -> true
        end,
        Ops
    ).
