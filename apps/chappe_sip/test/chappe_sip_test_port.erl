%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% A port a suite can bind.
%%
%% The suites used to take a random port in 40000-60000 and hope. That
%% range sits almost entirely inside Linux's ephemeral range
%% (32768-60999), so the kernel hands the same port to something else and
%% the bind fails: eaddrinuse out of gen_udp, or "nta_agent_create failed
%% (bad or busy contact?)" when sofia is the one binding. Rare on macOS,
%% whose ephemeral range starts at 49152, and regular on CI.
%%
%% So pick below the ephemeral range, where nothing is allocated behind
%% our back, and confirm the port binds before handing it out. A SIP
%% engine listens on UDP and TCP at the same number, so both have to be
%% free, and the check binds every interface rather than loopback alone
%% because that is the stricter question.
-module(chappe_sip_test_port).

-export([pick/0]).

-define(MIN, 20000).
-define(SPAN, 12000).
-define(TRIES, 50).

-spec pick() -> inet:port_number().
pick() ->
    pick(?TRIES).

pick(0) ->
    error(no_free_port);
pick(Tries) ->
    Port = ?MIN + rand:uniform(?SPAN),
    case free(Port) of
        true -> Port;
        false -> pick(Tries - 1)
    end.

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
