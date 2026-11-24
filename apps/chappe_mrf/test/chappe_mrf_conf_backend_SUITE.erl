%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% A third conference backend (chappe_mrf_conf_fake_backend), written
%% against the chappe_mrf_conf_backend behaviour alone, runs a room: a
%% join, the room's events, and the features it leaves out answered
%% {error, {unsupported, Backend}} by the room.
-module(chappe_mrf_conf_backend_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([join_and_events/1, unsupported/1, verbs/1]).

-define(B, chappe_mrf_conf_fake_backend).

all() ->
    [join_and_events, unsupported, verbs].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif, [
        {persistent, true}
    ]),
    {ok, _} = application:ensure_all_started(chappe_mrf),
    Config.

end_per_suite(_Config) ->
    _ = application:stop(chappe_mrf),
    _ = application:stop(chappe_esl),
    _ = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

start(Name) ->
    {ok, Conf} = chappe_mrf_conf:start(Name, #{backend => ?B, test => self()}),
    Conf.

join_and_events(_Config) ->
    Conf = start(<<"fake-join">>),
    ?assertMatch(
        #{backend := ?B, members := 0, joins := 0, lost := false},
        chappe_mrf_conf:info(Conf)
    ),
    {ok, Id} = chappe_mrf_conf:join(Conf, alice, #{name => <<"Alice">>}),
    ok = joined(Conf, Id),
    ?assertMatch(
        [#{id := Id, name := <<"Alice">>, mute := false, talking := false}],
        chappe_mrf_conf:members(Conf)
    ),
    ?assertMatch(#{members := 1, joins := 1}, chappe_mrf_conf:info(Conf)),
    %% a room event of the backend reaches the receivers
    Conf ! {fake_talk, Id, true},
    ok = event(Conf, {talking, Id, true}),
    ?assertMatch([#{talking := true}], chappe_mrf_conf:members(Conf)),
    %% the backend's member gone
    Conf ! {fake_gone, Id},
    ok = event(Conf, {left, Id, departed}),
    ?assertEqual([], chappe_mrf_conf:members(Conf)),
    ok = chappe_mrf_conf:stop(Conf).

unsupported(_Config) ->
    Conf = start(<<"fake-unsupported">>),
    {ok, A} = chappe_mrf_conf:join(Conf, alice, #{}),
    {ok, B} = chappe_mrf_conf:join(Conf, bob, #{}),
    Unsupported = {error, {unsupported, ?B}},
    ?assertEqual(Unsupported, chappe_mrf_conf:deaf(Conf, A)),
    ?assertEqual(Unsupported, chappe_mrf_conf:relate(Conf, A, B, nohear)),
    ?assertEqual(Unsupported, chappe_mrf_conf:record(Conf, <<"/tmp/x.wav">>)),
    ?assertEqual(Unsupported, chappe_mrf_conf:stop_record(Conf)),
    Other = start(<<"fake-unsupported-to">>),
    ?assertEqual(Unsupported, chappe_mrf_conf:transfer(Conf, A, Other)),
    %% nothing changed for the members
    ?assertMatch(
        [#{deaf := false}, #{deaf := false}], chappe_mrf_conf:members(Conf)
    ),
    ok = chappe_mrf_conf:stop(Other),
    ok = chappe_mrf_conf:stop(Conf).

verbs(_Config) ->
    Conf = start(<<"fake-verbs">>),
    {ok, Id} = chappe_mrf_conf:join(Conf, alice, #{}),
    ok = joined(Conf, Id),
    ok = chappe_mrf_conf:mute(Conf, Id),
    ok = event(Conf, {muted, Id, true}),
    ?assertMatch([#{mute := true}], chappe_mrf_conf:members(Conf)),
    ok = chappe_mrf_conf:play(Conf, Id, <<"hello.wav">>),
    receive
        {fake_backend, {play, {Id, _}, <<"hello.wav">>}} -> ok
    after 2000 -> ct:fail(no_play)
    end,
    ok = chappe_mrf_conf:play(Conf, <<"all.wav">>),
    receive
        {fake_backend, {play, all, <<"all.wav">>}} -> ok
    after 2000 -> ct:fail(no_play_all)
    end,
    %% no lock callback: the room keeps the lock itself
    ok = chappe_mrf_conf:lock(Conf),
    ?assertEqual({error, locked}, chappe_mrf_conf:join(Conf, bob, #{})),
    ok = chappe_mrf_conf:unlock(Conf),
    ok = chappe_mrf_conf:kick(Conf, Id),
    receive
        {fake_backend, {hangup, Id}} -> ok
    after 2000 -> ct:fail(no_hangup)
    end,
    ok = event(Conf, {left, Id, kicked}),
    ?assertEqual({error, not_member}, chappe_mrf_conf:mute(Conf, Id)),
    ok = chappe_mrf_conf:stop(Conf).

joined(Conf, Id) ->
    receive
        {chappe_mrf_conf, Conf, {joined, Id, #{}}} -> ok
    after 2000 -> ct:fail({not_joined, Id})
    end.

event(Conf, Event) ->
    receive
        {chappe_mrf_conf, Conf, Event} -> ok
    after 2000 -> ct:fail({no_event, Event})
    end.
