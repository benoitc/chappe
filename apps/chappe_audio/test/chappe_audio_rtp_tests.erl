%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% chappe_audio_rtp:remote/2: the receiver learns a moved sender again and
%% drops its old source for a grace window only.
-module(chappe_audio_rtp_tests).

-include_lib("eunit/include/eunit.hrl").

-define(LO, {127, 0, 0, 1}).

remote_test_() ->
    {timeout, 30, [
        fun moves_to_new_source/0,
        fun old_source_back_after_grace/0,
        fun second_move_keeps_old_blocked/0
    ]}.

%% after a move the old source is dropped, the first one at the new
%% address is taken, and it stays latched
moves_to_new_source() ->
    with(fun(R, Port, A, B) ->
        heard(R, A, Port, 1),
        ok = chappe_audio_rtp:remote(R, {?LO, lport(B)}),
        dropped(R, A, Port, 2),
        heard(R, B, Port, 3),
        dropped(R, A, Port, 4)
    end).

%% a sender that keeps sending from where it was, its SDP port alone
%% changed, is taken again once the grace window is over
old_source_back_after_grace() ->
    with(fun(R, Port, A, _B) ->
        heard(R, A, Port, 1),
        ok = chappe_audio_rtp:remote(R, {?LO, 30010}),
        dropped(R, A, Port, 2),
        timer:sleep(1200),
        heard(R, A, Port, 3)
    end).

%% two moves before any source latches keep the first source blocked
second_move_keeps_old_blocked() ->
    with(fun(R, Port, A, _B) ->
        heard(R, A, Port, 1),
        ok = chappe_audio_rtp:remote(R, {?LO, 30010}),
        ok = chappe_audio_rtp:remote(R, {?LO, 30020}),
        dropped(R, A, Port, 2)
    end).

with(Fun) ->
    {ok, R} = chappe_audio_rtp:start_link(#{
        owner => self(),
        ip => ?LO,
        label => <<"1">>,
        sink => {pid, self()},
        remote => {?LO, 30000}
    }),
    {ok, A} = gen_udp:open(0, [binary, {ip, ?LO}]),
    {ok, B} = gen_udp:open(0, [binary, {ip, ?LO}]),
    try
        Fun(R, chappe_audio_rtp:port(R), A, B)
    after
        unlink(R),
        _ = chappe_audio_rtp:stop(R),
        gen_udp:close(A),
        gen_udp:close(B)
    end.

lport(Sock) ->
    {ok, P} = inet:port(Sock),
    P.

heard(R, Sock, Port, Seq) ->
    ok = gen_udp:send(Sock, ?LO, Port, rtp(Seq)),
    receive
        {chappe_audio_rtp, R, {audio, _}} -> ok
    after 2000 -> error({not_heard, Seq})
    end.

dropped(R, Sock, Port, Seq) ->
    ok = gen_udp:send(Sock, ?LO, Port, rtp(Seq)),
    receive
        {chappe_audio_rtp, R, {audio, _}} -> error({heard, Seq})
    after 300 -> ok
    end.

rtp(Seq) ->
    <<2:2, 0:1, 0:1, 0:4, 0:1, 0:7, Seq:16, (Seq * 160):32, 16#1234:32,
        0:1280>>.
