%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_esl_outbound_SUITE).
-behaviour(chappe_esl_handler).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    channel_data/1,
    execute_on_channel/1,
    linger_disabled/1,
    linger_seconds/1,
    linger_then_disconnect/1,
    listen_ip/1,
    listen_ipv6/1,
    bad_listener_options/1
]).
%% chappe_esl_handler callback.
-export([handle_channel/3]).

all() ->
    [
        channel_data,
        execute_on_channel,
        linger_disabled,
        linger_seconds,
        linger_then_disconnect,
        listen_ip,
        listen_ipv6,
        bad_listener_options
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(chappe_esl),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_esl),
    ok.

%% The handler runs in its own process. In relay mode it forwards every
%% connection message to the test until the socket closes. Otherwise it
%% reports the channel, executes an app on the channel, and reports the result.
handle_channel(Conn, Channel, {relay, TestPid}) ->
    TestPid ! {channel, Conn, Channel},
    relay(Conn, TestPid);
handle_channel(Conn, Channel, TestPid) ->
    TestPid ! {channel, Conn, Channel},
    Result = chappe_esl:execute(Conn, "playback", "tone.wav"),
    TestPid ! {execute_result, Result},
    ok.

relay(Conn, TestPid) ->
    receive
        {chappe_esl_closed, Conn} = Msg ->
            TestPid ! {relayed, Msg};
        Msg ->
            TestPid ! {relayed, Msg},
            relay(Conn, TestPid)
    end.

%% The client opens with `connect' and the reply carries the channel data.
%% req: ESL-18
channel_data(_Config) ->
    Port = pick_port(),
    {ok, _Ref} = chappe_esl:start_listener(Port, ?MODULE, self()),
    try
        S = fs_connect(Port),
        ?assertEqual(<<"connect">>, recv_block(S)),
        ok = gen_tcp:send(S, channel_frame()),
        receive
            {channel, _Conn, Channel} ->
                ?assertEqual(
                    <<"uuid-out-1">>,
                    chappe_esl_event:header(<<"Channel-Unique-ID">>, Channel)
                )
        after 5000 ->
            ct:fail(no_channel)
        end
    after
        chappe_esl:stop_listener(Port)
    end.

%% By default `linger' follows `connect'; its reply is consumed internally so
%% the handler's first command gets its own reply.
%% req: ESL-19 ESL-21
execute_on_channel(_Config) ->
    Port = pick_port(),
    {ok, _Ref} = chappe_esl:start_listener(Port, ?MODULE, self()),
    try
        S = fs_connect(Port),
        ?assertEqual(<<"connect">>, recv_block(S)),
        ok = gen_tcp:send(S, channel_frame()),
        ?assertEqual(<<"linger">>, recv_block(S)),
        ok = gen_tcp:send(S, ok_reply()),
        %% The handler issues a sendmsg execute; answer it +OK.
        Block = recv_block(S),
        ?assertMatch(<<"sendmsg", _/binary>>, Block),
        ?assert(contains(Block, <<"execute-app-name: playback">>)),
        ok = gen_tcp:send(S, ok_reply()),
        receive
            {execute_result, Res} -> ?assertEqual(ok, Res)
        after 5000 ->
            ct:fail(no_execute_result)
        end
    after
        chappe_esl:stop_listener(Port)
    end.

%% req: ESL-19
linger_disabled(_Config) ->
    Port = pick_port(),
    {ok, _Ref} = chappe_esl:start_listener(Port, ?MODULE, self(), #{
        linger => false
    }),
    try
        S = fs_connect(Port),
        ?assertEqual(<<"connect">>, recv_block(S)),
        ok = gen_tcp:send(S, channel_frame()),
        ?assertMatch(<<"sendmsg", _/binary>>, recv_block(S))
    after
        chappe_esl:stop_listener(Port)
    end.

%% req: ESL-19
linger_seconds(_Config) ->
    Port = pick_port(),
    {ok, _Ref} = chappe_esl:start_listener(Port, ?MODULE, self(), #{
        linger => 30
    }),
    try
        S = fs_connect(Port),
        ?assertEqual(<<"connect">>, recv_block(S)),
        ok = gen_tcp:send(S, channel_frame()),
        ?assertEqual(<<"linger 30">>, recv_block(S))
    after
        chappe_esl:stop_listener(Port)
    end.

%% After hangup FreeSWITCH sends a disconnect-notice with Content-Disposition
%% linger and keeps delivering events; the final notice carries disconnect.
%% The handler sees {chappe_esl_linger, Conn}, the late event,
%% {chappe_esl_disconnect, Conn}, then {chappe_esl_closed, Conn}.
%% req: ESL-11 ESL-19
linger_then_disconnect(_Config) ->
    Port = pick_port(),
    {ok, _Ref} = chappe_esl:start_listener(Port, ?MODULE, {relay, self()}),
    try
        S = fs_connect(Port),
        ?assertEqual(<<"connect">>, recv_block(S)),
        ok = gen_tcp:send(S, channel_frame()),
        Conn =
            receive
                {channel, C, _} -> C
            after 5000 -> ct:fail(no_channel)
            end,
        ?assertEqual(<<"linger">>, recv_block(S)),
        ok = gen_tcp:send(S, ok_reply()),
        ok = gen_tcp:send(S, notice(<<"linger">>)),
        ?assertEqual({chappe_esl_linger, Conn}, relayed()),
        ok = gen_tcp:send(
            S,
            chappe_esl_fake_server:plain_event(<<"CHANNEL_HANGUP_COMPLETE">>, [])
        ),
        {chappe_esl_event, Conn, Event} = relayed(),
        ?assertEqual(
            <<"CHANNEL_HANGUP_COMPLETE">>, chappe_esl_event:name(Event)
        ),
        ok = gen_tcp:send(S, notice(<<"disconnect">>)),
        ?assertEqual({chappe_esl_disconnect, Conn}, relayed()),
        ok = gen_tcp:close(S),
        ?assertEqual({chappe_esl_closed, Conn}, relayed())
    after
        chappe_esl:stop_listener(Port)
    end.

%% Bound to 127.0.0.1, the listener takes a connection there and refuses
%% one on another local address.
listen_ip(_Config) ->
    case other_local_address() of
        undefined ->
            {skip, no_other_local_address};
        Other ->
            Port = pick_port(),
            {ok, _Ref} = chappe_esl:start_listener(Port, ?MODULE, self(), #{
                ip => {127, 0, 0, 1}, backlog => 16
            }),
            try
                S = fs_connect(Port),
                ?assertEqual(<<"connect">>, recv_block(S)),
                ?assertEqual(
                    {error, econnrefused},
                    gen_tcp:connect(Other, Port, [binary], 5000)
                )
            after
                chappe_esl:stop_listener(Port)
            end
    end.

%% An IPv6 address listens on IPv6.
listen_ipv6(_Config) ->
    Port = pick_port(),
    Loopback = {0, 0, 0, 0, 0, 0, 0, 1},
    case chappe_esl:start_listener(Port, ?MODULE, self(), #{ip => Loopback}) of
        {ok, _Ref} ->
            try
                {ok, S} = gen_tcp:connect(
                    Loopback, Port, [binary, {active, false}], 5000
                ),
                ?assertEqual(<<"connect">>, recv_block(S))
            after
                chappe_esl:stop_listener(Port)
            end;
        {error, Reason} ->
            {skip, {no_ipv6_loopback, Reason}}
    end.

%% A bad ip, backlog or linger is refused before anything listens.
bad_listener_options(_Config) ->
    Bad = [
        {ip, "127.0.0.1"},
        {ip, {300, 0, 0, 1}},
        {ip, localhost},
        {backlog, 0},
        {backlog, many},
        {linger, -1}
    ],
    lists:foreach(
        fun({Key, Value}) ->
            ?assertEqual(
                {error, {bad_option, Key}},
                chappe_esl:start_listener(pick_port(), ?MODULE, self(), #{
                    Key => Value
                })
            )
        end,
        Bad
    ).

%% helpers

%% An IPv4 address of this host other than loopback, undefined when there
%% is none.
other_local_address() ->
    {ok, Ifs} = inet:getifaddrs(),
    Addrs = [
        A
     || {_Name, Props} <- Ifs,
        {addr, {_, _, _, _} = A} <- Props,
        element(1, A) =/= 127
    ],
    case Addrs of
        [A | _] -> A;
        [] -> undefined
    end.

relayed() ->
    receive
        {relayed, Msg} -> Msg
    after 5000 ->
        ct:fail(nothing_relayed)
    end.

pick_port() ->
    {ok, L} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, P} = inet:port(L),
    gen_tcp:close(L),
    P.

fs_connect(Port) ->
    {ok, S} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {packet, raw}, {active, false}], 5000
    ),
    S.

channel_frame() ->
    <<
        "Content-Type: command/reply\n"
        "Reply-Text: +OK\n"
        "Channel-Unique-ID: uuid-out-1\n"
        "Channel-Name: sofia/internal/1000\n"
        "variable_sip_from_user: 1000\n\n"
    >>.

ok_reply() ->
    <<"Content-Type: command/reply\nReply-Text: +OK\n\n">>.

notice(Disposition) ->
    Body = <<"Disconnected, goodbye.\n">>,
    Len = integer_to_binary(byte_size(Body)),
    <<"Content-Type: text/disconnect-notice\nContent-Disposition: ",
        Disposition/binary, "\nContent-Length: ", Len/binary, "\n\n",
        Body/binary>>.

%% Read the next command block, keeping any bytes past it for the next call
%% (two commands may arrive in one TCP read).
recv_block(S) ->
    Acc = get_buf(S),
    case binary:split(Acc, <<"\n\n">>) of
        [Block, Rest] ->
            put({buf, S}, Rest),
            Block;
        [_Incomplete] ->
            {ok, Data} = gen_tcp:recv(S, 0, 5000),
            put({buf, S}, <<Acc/binary, Data/binary>>),
            recv_block(S)
    end.

get_buf(S) ->
    case get({buf, S}) of
        undefined -> <<>>;
        Buf -> Buf
    end.

contains(Haystack, Needle) ->
    binary:match(Haystack, Needle) =/= nomatch.
