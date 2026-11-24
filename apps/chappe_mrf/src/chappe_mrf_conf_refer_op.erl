%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The REFERs a room carries out (chappe_mrf_conf_refer), as a value
%% the room keeps in its state. An op is one thing REFERs asked the room
%% for, keyed {Origin, Method, Subject}: who asked
%% (chappe_sip_refer:origin/1: a dialog, or a request's Call-ID and From
%% tag), the Refer-To method, and what it is about: the target's
%% address-of-record (chappe_sip_uri:aor/1), or for a removal the member
%% it names. A REFER that asks again for the same thing from the same
%% origin (a UA that sends a new REFER when the first one's answer was
%% lost, or a user who asks twice) is the same op: it is attached to the
%% op in flight and hears the same progress and final status, or, once
%% the op is done, its final status at once. Nothing is dialed twice.
%%
%% Bounds: an op reserved for a REFER that is never accepted, and a done
%% op, are kept 32 s (64*T1, the lifetime of the REFER's transaction, RFC
%% 3261 17.1.2.2), then forgotten; a room keeps at most 64 ops, and a new
%% one past that is refused (the caller answers 503). The functions that
%% take Now (monotonic milliseconds) are the same with the time given.
-module(chappe_mrf_conf_refer_op).

-export([new/0, key/3, aor/1, lookup/2, reserve/3, start/3, attach/3]).
-export([progress/3, final/3, in_flight/1, count/1]).
-export([data/2, set_data/3, adding/2, wait/4, leave/3, by_mon/2]).
-export([lookup/3, reserve/4, in_flight/2]).

-export_type([ops/0, key/0]).

-define(KEEP_MS, 32000).
-define(MAX_OPS, 64).

-type key() :: {chappe_sip_refer:origin(), binary(), binary()}.
-type status() :: 100..699.
-type op() :: #{
    refers := [chappe_sip_refer:refer()],
    state := {reserved, integer()} | running | {done, 200..699, integer()},
    progress := status() | undefined,
    data := map()
}.
-type ops() :: #{key() => op()}.

-spec new() -> ops().
new() -> #{}.

%% The key of a REFER from Origin asking Method for Subject: a target URI
%% (compared by its address-of-record) or a member id.
-spec key(chappe_sip_refer:origin(), binary(), binary()) -> key().
key(Origin, <<"BYE">> = M, Member) ->
    {Origin, M, Member};
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
    lookup(Key, now_ms(), Ops).

-spec lookup(key(), integer(), ops()) ->
    {reserved | running, map()} | {done, 200..699} | none.
lookup(Key, Now, Ops) ->
    case maps:find(Key, prune(Now, Ops)) of
        {ok, #{state := {done, St, _}}} -> {done, St};
        {ok, #{state := {reserved, _}, data := Data}} -> {reserved, Data};
        {ok, #{state := running, data := Data}} -> {running, Data};
        error -> none
    end.

%% Hold Key for a REFER the room is about to accept (Data: what the room
%% needs to carry it out). {error, full} past the room's bound, {error,
%% exists} for a key the room knows (a repeat, never overwritten).
-spec reserve(key(), map(), ops()) -> {ok, ops()} | {error, full | exists}.
reserve(Key, Data, Ops) ->
    reserve(Key, Data, now_ms(), Ops).

-spec reserve(key(), map(), integer(), ops()) ->
    {ok, ops()} | {error, full | exists}.
reserve(Key, Data, Now, Ops0) ->
    Ops = prune(Now, Ops0),
    case Ops of
        #{Key := _} ->
            {error, exists};
        #{} when map_size(Ops) >= ?MAX_OPS ->
            {error, full};
        #{} ->
            Op = #{
                refers => [],
                state => {reserved, Now},
                progress => undefined,
                data => Data
            },
            {ok, Ops#{Key => Op}}
    end.

%% The REFER of a reserved Key was accepted: the op runs.
-spec start(key(), chappe_sip_refer:refer(), ops()) -> ops().
start(Key, Refer, Ops) ->
    case Ops of
        #{Key := #{state := {reserved, _}} = Op} ->
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
            Done = {done, St, now_ms()},
            Ops#{Key := Op#{state := Done, refers := []}};
        #{Key := #{state := {reserved, _}}} ->
            maps:remove(Key, Ops);
        #{} ->
            Ops
    end.

%% The ops under way (reserved in time, or running), with their data.
-spec in_flight(ops()) -> [{key(), map()}].
in_flight(Ops) ->
    in_flight(now_ms(), Ops).

-spec in_flight(integer(), ops()) -> [{key(), map()}].
in_flight(Now, Ops) ->
    [
        {K, D}
     || K := #{state := S, data := D} <- prune(Now, Ops), not done(S)
    ].

done({done, _, _}) -> true;
done(_State) -> false.

%% The op under way that adds the party with address-of-record Aor, from
%% any origin: a second REFER for it joins that op.
-spec adding(binary(), ops()) -> {ok, key()} | none.
adding(Aor, Ops) ->
    case
        [
            K
         || {{_, <<"INVITE">>, A} = K, #{action := add}} <- in_flight(Ops),
            A =:= Aor
        ]
    of
        [K | _] -> {ok, K};
        [] -> none
    end.

%% A reserved op lives while a worker waits on it: the one of the REFER
%% it was reserved for, and those of REFERs attached to it before it
%% started (its data's waiting, monitor => worker, the room's monitors).
%% Worker, watched with Mon, waits on Key: {ok, Ops}, or none when Key is
%% no reserved op.
-spec wait(key(), reference(), pid(), ops()) -> {ok, ops()} | none.
wait(Key, Mon, Worker, Ops) ->
    case Ops of
        #{Key := #{state := {reserved, _}, data := #{waiting := W} = D} = Op} ->
            {ok, Ops#{Key := Op#{data := D#{waiting := W#{Mon => Worker}}}}};
        #{} ->
            none
    end.

%% The workers waiting on the reserved op Key that Gone(Mon, Worker)
%% picks stop waiting, and an op nobody waits on any more is dropped:
%% their monitors, for the room to take down, and the ops. A running or
%% done op is left as it is.
-spec leave(key(), fun((reference(), pid()) -> boolean()), ops()) ->
    {[reference()], ops()}.
leave(Key, Gone, Ops) ->
    case Ops of
        #{Key := #{state := {reserved, _}, data := #{waiting := W} = D} = Op} ->
            Out = [Mon || Mon := Pid <- W, Gone(Mon, Pid)],
            case maps:without(Out, W) of
                In when map_size(In) =:= 0 ->
                    {Out, maps:remove(Key, Ops)};
                In ->
                    {Out, Ops#{Key := Op#{data := D#{waiting := In}}}}
            end;
        #{} ->
            {[], Ops}
    end.

%% The reserved op one of whose waiting workers the room watches with
%% Mon.
-spec by_mon(reference(), ops()) -> {ok, key()} | none.
by_mon(Mon, Ops) ->
    case
        [
            K
         || K := #{state := {reserved, _}, data := #{waiting := W}} <- Ops,
            is_map_key(Mon, W)
        ]
    of
        [K | _] -> {ok, K};
        [] -> none
    end.

%% The data of an op, or undefined.
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

%% reserved ops never accepted, and done ops, past their time are
%% forgotten
prune(Now, Ops) ->
    maps:filter(
        fun
            (_K, #{state := {done, _, T}}) -> Now - T < ?KEEP_MS;
            (_K, #{state := {reserved, T}}) -> Now - T < ?KEEP_MS;
            (_K, _Op) -> true
        end,
        Ops
    ).

now_ms() ->
    erlang:monotonic_time(millisecond).
