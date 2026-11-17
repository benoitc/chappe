%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% A conference backend written against chappe_mrf_conf_backend alone:
%% no record of the room, only its callbacks and the room API. Its members
%% are names; deaf is refused, relate, record and transfer are left out.
-module(chappe_mrf_conf_fake_backend).
-behaviour(chappe_mrf_conf_backend).

-export([init/2, info/1, join/4, admit/3, handle_info/2]).
-export([set_flag/5, hangup/3, left/2, play/3, portable/0]).

init(Name, Opts) ->
    {ok, #{name => Name, test => maps:get(test, Opts, undefined), n => 0}}.

info(#{n := N}) ->
    #{node => undefined, bridge => #{}, joins => N}.

%% caller side: the room admits the member
join(Conf, _Info, Target, Opts) ->
    chappe_mrf_conf:call(Conf, {join, {fake, Target, Opts}}, 5000).

admit({fake, Target, Opts}, _From, Room) ->
    #{n := N} = B = chappe_mrf_conf_backend:bstate(Room),
    Id = integer_to_binary(N + 1),
    Mb = chappe_mrf_conf_backend:member(Opts, Id, #{fake => Target}),
    Room1 = chappe_mrf_conf_backend:bstate(B#{n := N + 1}, Room),
    {reply, {ok, Id}, chappe_mrf_conf_backend:joined(Id, Mb, Room1)}.

handle_info({fake_talk, Id, Talking}, Room) ->
    {noreply, chappe_mrf_conf_backend:talking(Id, Talking, Room)};
handle_info({fake_gone, Id}, Room) ->
    {noreply, chappe_mrf_conf_backend:gone(Id, Room)};
handle_info(_Msg, _Room) ->
    ignore.

set_flag(_Id, _Mb, deaf, _Value, _Room) ->
    {error, unsupported};
set_flag(Id, _Mb, mute, Value, Room) ->
    {ok, chappe_mrf_conf_backend:emit({muted, Id, Value}, Room)}.

hangup(Id, _Mb, Room) ->
    tell(Room, {hangup, Id}).

left(_Mb, _Reason) ->
    ok.

play(Who, File, Room) ->
    tell(Room, {play, Who, File}).

portable() ->
    false.

tell(Room, Msg) ->
    case chappe_mrf_conf_backend:bstate(Room) of
        #{test := Pid} when is_pid(Pid) -> Pid ! {fake_backend, Msg};
        _ -> ok
    end,
    ok.
