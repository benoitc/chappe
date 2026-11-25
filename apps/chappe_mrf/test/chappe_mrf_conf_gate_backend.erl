%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The native backend with a gate in front of its caller-side join: a join
%% given the gate option tells that pid {gate, Joiner} and waits for
%% {gate, go} (it joins), {gate, raise} (it raises) or nothing (the test
%% kills it). The test holds a join where it wants, to make a race happen.
-module(chappe_mrf_conf_gate_backend).
-behaviour(chappe_mrf_conf_backend).

-export([init/2, info/1, join/4, admit/3, handle_call/3, handle_cast/2]).
-export([handle_info/2]).
-export([set_flag/5, hangup/3, left/2, play/3, portable/0]).
-export([relate/4, record/3, stop_record/1, handover/1, dial/4]).

-define(N, chappe_mrf_conf_native).

join(Conf, Info, Target, #{gate := Gate} = Opts) ->
    Gate ! {gate, self()},
    receive
        {gate, go} -> ?N:join(Conf, Info, Target, maps:remove(gate, Opts));
        {gate, raise} -> error(gate_raised)
    end;
join(Conf, Info, Target, Opts) ->
    ?N:join(Conf, Info, Target, Opts).

init(Name, Opts) -> ?N:init(Name, Opts).
info(B) -> ?N:info(B).
admit(Req, From, S) -> ?N:admit(Req, From, S).
handle_call(Req, From, S) -> ?N:handle_call(Req, From, S).
handle_cast(Msg, S) -> ?N:handle_cast(Msg, S).
handle_info(Msg, S) -> ?N:handle_info(Msg, S).
set_flag(Id, Mb, Flag, Value, S) -> ?N:set_flag(Id, Mb, Flag, Value, S).
hangup(Id, Mb, S) -> ?N:hangup(Id, Mb, S).
left(Mb, Why) -> ?N:left(Mb, Why).
play(Who, File, S) -> ?N:play(Who, File, S).
portable() -> ?N:portable().
relate(A, B, How, S) -> ?N:relate(A, B, How, S).
record(Path, Opts, S) -> ?N:record(Path, Opts, S).
stop_record(S) -> ?N:stop_record(S).
handover(Mb) -> ?N:handover(Mb).
dial(Target, Key, Cfg, S) -> ?N:dial(Target, Key, Cfg, S).
