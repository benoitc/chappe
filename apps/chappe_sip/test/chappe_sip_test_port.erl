%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% A port a suite can bind.
%%
%% The suites used to take a random port in 40000-60000 and hope, which
%% lost two different races.
%%
%% The kernel one: that range sits almost entirely inside Linux's
%% ephemeral range (32768-60999), so the kernel hands the same port to
%% something else and the bind fails, as eaddrinuse out of gen_udp or as
%% "nta_agent_create failed (bad or busy contact?)" when sofia is the one
%% binding. Rare on macOS, whose ephemeral range starts at 49152, and
%% regular on CI. Picking below the ephemeral range answers that one,
%% because nothing is allocated there behind our back.
%%
%% The one between callers: two picks rolling dice can land on the same
%% number, and a suite that takes an engine port and a peer port in the
%% same breath was rolling against itself. So the number comes from
%% erlang:unique_integer/1 rather than rand: it is VM-global and strictly
%% increasing, so callers walk consecutive ports instead of colliding.
%% The OS pid offsets the walk, so two test runs on one machine start in
%% different places.
%%
%% What is left is another process on the machine holding the port, which
%% no amount of picking can prevent; the bindability check catches it and
%% the next candidate is a different port. A SIP engine listens on UDP and
%% TCP at the same number, so the check covers both, on every interface
%% rather than loopback alone because that is the stricter question.
-module(chappe_sip_test_port).

-export([pick/0]).

%% Below the ephemeral range on both platforms, and clear of the
%% 30000-30100 media range the rtpengine interop container publishes.
-define(MIN, 20000).
-define(SPAN, 10000).
-define(TRIES, 50).

-spec pick() -> inet:port_number().
pick() ->
    pick(?TRIES).

pick(0) ->
    error(no_free_port);
pick(Tries) ->
    Port = candidate(),
    case free(Port) of
        true -> Port;
        false -> pick(Tries - 1)
    end.

%% Never the same port twice in one VM, so callers cannot collide with
%% each other however close together they run.
candidate() ->
    N = erlang:unique_integer([positive, monotonic]),
    ?MIN + (offset() + N) rem ?SPAN.

%% Hashed, not the pid itself: two VMs started together get adjacent
%% pids, and adjacent offsets walk the same ports in lockstep. The hash
%% scatters them instead.
offset() ->
    erlang:phash2(os:getpid(), ?SPAN).

%% Closed again before we return, so the caller binds it for real a
%% moment later. A listening socket that never accepted does not linger
%% in TIME_WAIT, so the reopen is immediate.
free(Port) ->
    case gen_udp:open(Port, []) of
        {ok, Udp} ->
            ok = gen_udp:close(Udp),
            free_tcp(Port);
        {error, _} ->
            false
    end.

free_tcp(Port) ->
    case gen_tcp:listen(Port, []) of
        {ok, Tcp} ->
            ok = gen_tcp:close(Tcp),
            true;
        {error, _} ->
            false
    end.
