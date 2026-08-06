%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc chappe_sip_media FreeSWITCH backend tests against a fake ESL server.
%%
%% A minimal in-suite TCP server speaks the FreeSWITCH mod_event_socket inbound
%% protocol (auth/request, command/reply, api/response) and captures the
%% command blocks it receives, so the adapter's ESL command shaping is asserted
%% on the wire without a real FreeSWITCH. Live coverage is INTEROP-gated.
-module(chappe_sip_media_fs_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([conference_command/1, play_command/1, dtmf_command/1,
         record_command/1, offer_unsupported/1, needs_channel/1]).

all() ->
    [conference_command, play_command, dtmf_command, record_command,
     offer_unsupported, needs_channel].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_engine_fake,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    _ = application:stop(chappe_esl),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(_Case, Config) ->
    Port = start_fake(self()),
    ok = chappe_sip_media:configure(
        #{freeswitch =>
              #{nodes => [#{name => fs_test, host => "127.0.0.1",
                            port => Port, password => <<"ClueCon">>}]}}),
    [{fake_port, Port} | Config].

end_per_testcase(_Case, _Config) ->
    _ = chappe_sip_media_sup:stop_child(chappe_sip_media_esl_mgr),
    stop_fake(),
    ok.

%% ---- tests ----

conference_command(_Config) ->
    {ok, S} = session(<<"chan-1">>),
    ?assertEqual(ok, chappe_sip_media:conference(S, <<"room-A">>, #{})),
    Block = wait_cmd(<<"sendmsg chan-1">>),
    ?assert(contains(Block, <<"execute-app-name: conference">>)),
    ?assert(contains(Block, <<"execute-app-arg: room-A">>)).

play_command(_Config) ->
    {ok, S} = session(<<"chan-2">>),
    ?assertEqual(ok, chappe_sip_media:play(S, #{file => <<"/tmp/greet.wav">>})),
    Block = wait_cmd(<<"sendmsg chan-2">>),
    ?assert(contains(Block, <<"execute-app-name: playback">>)),
    ?assert(contains(Block, <<"execute-app-arg: /tmp/greet.wav">>)).

dtmf_command(_Config) ->
    {ok, S} = session(<<"chan-3">>),
    ?assertEqual(ok, chappe_sip_media:dtmf(S, #{digits => <<"123">>})),
    Block = wait_cmd(<<"sendmsg chan-3">>),
    ?assert(contains(Block, <<"execute-app-name: send_dtmf">>)),
    ?assert(contains(Block, <<"execute-app-arg: 123">>)).

record_command(_Config) ->
    {ok, S} = session(<<"chan-4">>),
    ?assertEqual(ok, chappe_sip_media:record(S, #{path => <<"/tmp/rec.wav">>})),
    Block = wait_cmd(<<"api uuid_record">>),
    ?assert(contains(Block, <<"uuid_record chan-4 start /tmp/rec.wav">>)).

offer_unsupported(_Config) ->
    {ok, S} = session(<<"chan-5">>),
    ?assertEqual({error, unsupported}, chappe_sip_media:offer(S, <<"v=0">>)).

needs_channel(_Config) ->
    ?assertEqual({error, no_channel},
                 chappe_sip_media:session(#{call_id => <<"c">>},
                                    #{capability => conference,
                                      node => fs_test})).

%% ---- helpers ----

session(Uuid) ->
    chappe_sip_media:session(#{call_id => <<"call-x">>},
                       #{capability => conference, node => fs_test,
                         uuid => Uuid}).

contains(Haystack, Needle) ->
    binary:match(Haystack, Needle) =/= nomatch.

%% Wait for a captured command block whose first line starts with Prefix.
wait_cmd(Prefix) ->
    receive
        {fs_cmd, Block} ->
            case binary:match(Block, Prefix) of
                {0, _} -> Block;
                _ -> wait_cmd(Prefix)
            end
    after 3000 ->
        ct:fail({no_command, Prefix})
    end.

%% ---- fake FreeSWITCH event socket (inbound) ----

start_fake(Collector) ->
    Starter = self(),
    Pid = spawn(fun() -> fake_init(Starter, Collector) end),
    put(fake_pid, Pid),
    receive
        {fake_port, Pid, Port} -> Port
    after 2000 -> exit(fake_start_timeout)
    end.

stop_fake() ->
    case get(fake_pid) of
        undefined -> ok;
        Pid -> Pid ! stop, ok
    end.

fake_init(Starter, Collector) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {packet, raw},
                                      {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Starter ! {fake_port, self(), Port},
    {ok, Sock} = gen_tcp:accept(Listen),
    ok = inet:setopts(Sock, [{active, true}]),
    ok = gen_tcp:send(Sock, <<"Content-Type: auth/request\n\n">>),
    fake_loop(#{sock => Sock, listen => Listen, buf => <<>>,
                collector => Collector}).

fake_loop(State) ->
    receive
        {tcp, _Sock, Data} ->
            Buf = <<(maps:get(buf, State))/binary, Data/binary>>,
            fake_loop(process(State#{buf := Buf}));
        {tcp_closed, _Sock} ->
            close_fake(State);
        stop ->
            close_fake(State)
    end.

close_fake(State) ->
    _ = gen_tcp:close(maps:get(sock, State)),
    _ = gen_tcp:close(maps:get(listen, State)),
    ok.

process(State) ->
    case binary:split(maps:get(buf, State), <<"\n\n">>) of
        [_Incomplete] ->
            State;
        [Block, Rest] ->
            process(handle_block(Block, State#{buf := Rest}))
    end.

handle_block(Block, State) ->
    Sock = maps:get(sock, State),
    [First | _] = binary:split(Block, <<"\n">>),
    case First of
        <<"auth ", _/binary>> ->
            ok = gen_tcp:send(Sock, command_reply(<<"+OK accepted">>));
        <<"api ", _/binary>> ->
            maps:get(collector, State) ! {fs_cmd, Block},
            ok = gen_tcp:send(Sock, api_response(<<"+OK">>));
        <<"sendmsg", _/binary>> ->
            maps:get(collector, State) ! {fs_cmd, Block},
            ok = gen_tcp:send(Sock, command_reply(<<"+OK">>));
        _Other ->
            ok = gen_tcp:send(Sock, command_reply(<<"+OK">>))
    end,
    State.

command_reply(Text) ->
    <<"Content-Type: command/reply\nReply-Text: ", Text/binary, "\n\n">>.

api_response(Body) ->
    Len = integer_to_binary(byte_size(Body)),
    <<"Content-Type: api/response\nContent-Length: ", Len/binary, "\n\n",
      Body/binary>>.
