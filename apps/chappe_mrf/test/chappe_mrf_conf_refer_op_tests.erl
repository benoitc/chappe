%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The REFER ops of a room (chappe_mrf_conf_refer_op) with the time given:
%% a reservation never accepted is forgotten after 32 s, a key is never
%% overwritten, a room keeps at most 64 ops, and what one op holds is
%% counted.
-module(chappe_mrf_conf_refer_op_tests).

-include_lib("eunit/include/eunit.hrl").

-define(OP, chappe_mrf_conf_refer_op).

key(N) ->
    ?OP:key(
        {request, <<"c", (integer_to_binary(N))/binary>>, <<"t">>},
        <<"INVITE">>,
        <<"sip:a@h">>
    ).

%% req: MRF-15
reserved_expires_test() ->
    {ok, Ops} = ?OP:reserve(key(1), #{action => add}, 0, ?OP:new()),
    ?assertMatch({reserved, _}, ?OP:lookup(key(1), 31999, Ops)),
    ?assertMatch([_], ?OP:in_flight(31999, Ops)),
    %% the REFER was never accepted: the reservation goes, and stops
    %% counting as a dial under way
    ?assertEqual(none, ?OP:lookup(key(1), 32000, Ops)),
    ?assertEqual([], ?OP:in_flight(32000, Ops)),
    ?assertMatch({ok, _}, ?OP:reserve(key(1), #{}, 32000, Ops)).

%% req: MRF-15
reserve_never_overwrites_test() ->
    {ok, Ops} = ?OP:reserve(key(1), #{action => add}, 0, ?OP:new()),
    ?assertEqual(
        {error, exists}, ?OP:reserve(key(1), #{action => remove}, 10, Ops)
    ),
    ?assertMatch({reserved, #{action := add}}, ?OP:lookup(key(1), 10, Ops)).

%% req: MRF-15
cap_of_64_test() ->
    Ops = lists:foldl(
        fun(N, Acc) ->
            {ok, Acc1} = ?OP:reserve(key(N), #{}, N, Acc),
            Acc1
        end,
        ?OP:new(),
        lists:seq(1, 64)
    ),
    ?assertEqual({error, full}, ?OP:reserve(key(65), #{}, 100, Ops)),
    %% once the old reservations expired there is room again
    ?assertMatch({ok, _}, ?OP:reserve(key(65), #{}, 32064, Ops)).

%% a removal is keyed by the member it names, not the URI (two members of
%% one room share the room's address-of-record)
remove_key_by_member_test() ->
    O = {request, <<"c">>, <<"t">>},
    ?assertNotEqual(
        ?OP:key(O, <<"BYE">>, <<"m1">>), ?OP:key(O, <<"BYE">>, <<"m2">>)
    ),
    ?assertEqual(
        ?OP:key(O, <<"INVITE">>, <<"sip:a@h">>),
        ?OP:key(O, <<"INVITE">>, <<"sip:a@h;user=phone">>)
    ).

%% the REFERs an op holds while it is reserved: the workers waiting on it
%% (the room caps them with refer_attach_max); none for an unknown key
%% req: MRF-29
attached_counts_waiting_test() ->
    {ok, Ops} = ?OP:reserve(key(1), #{waiting => #{}}, 0, ?OP:new()),
    ?assertEqual(0, ?OP:attached(key(1), Ops)),
    {ok, Ops1} = ?OP:wait(key(1), make_ref(), self(), Ops),
    {ok, Ops2} = ?OP:wait(key(1), make_ref(), self(), Ops1),
    ?assertEqual(2, ?OP:attached(key(1), Ops2)),
    ?assertEqual(0, ?OP:attached(key(2), Ops2)).
