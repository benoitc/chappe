%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The port picker is what keeps the SIP suites from failing on a bind,
%% so the properties it promises are worth asserting rather than assuming.
-module(chappe_sip_test_port_tests).

-include_lib("eunit/include/eunit.hrl").

-define(N, 500).

%% No caller ever gets a port another caller already holds. This is the
%% property the old `40000 + rand:uniform(20000)' did not have, and the
%% one a suite taking two ports in a row depends on.
distinct_test() ->
    Ports = [chappe_sip_test_port:pick() || _ <- lists:seq(1, ?N)],
    ?assertEqual(?N, length(lists:usort(Ports))).

%% Below the ephemeral range on Linux (32768) and macOS (49152), so the
%% kernel does not hand the same port out from under the caller.
range_test() ->
    lists:foreach(
        fun(Port) ->
            ?assert(Port >= 20000),
            ?assert(Port < 30000)
        end,
        [chappe_sip_test_port:pick() || _ <- lists:seq(1, ?N)]
    ).

%% A picked port binds on both transports, which is what a SIP engine
%% listening on UDP and TCP at one number needs.
bindable_test() ->
    Port = chappe_sip_test_port:pick(),
    {ok, Udp} = gen_udp:open(Port, []),
    ok = gen_udp:close(Udp),
    {ok, Tcp} = gen_tcp:listen(Port, []),
    ok = gen_tcp:close(Tcp).
