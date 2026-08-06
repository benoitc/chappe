%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Scriptable in-process fake of FreeSWITCH mod_event_socket for inbound tests.
%% It sends auth/request on accept, answers commands (api, bgapi, event,
%% sendmsg, filter, exit), and lets a test push arbitrary frames with inject/2.
%% bgapi answers with a Job-UUID and then pushes the matching BACKGROUND_JOB
%% event. api bodies are configured with the `api' option (a command => body
%% map); everything else defaults to +OK.
-module(chappe_esl_fake_server).

-export([start/0, start/1, stop/1, inject/2]).
-export([plain_event/2]).

%% Start the fake on an ephemeral port. Returns {ok, Server, Port}.
-spec start() -> {ok, pid(), inet:port_number()}.
start() ->
    start(#{}).

-spec start(map()) -> {ok, pid(), inet:port_number()}.
start(Opts) ->
    Parent = self(),
    Pid = spawn(fun() -> init(Parent, Opts) end),
    receive
        {Pid, port, Port} -> {ok, Pid, Port}
    after 5000 ->
        error(fake_server_start_timeout)
    end.

-spec stop(pid()) -> ok.
stop(Server) ->
    Server ! stop,
    ok.

%% Push raw bytes (for example an event frame) to the connected client.
-spec inject(pid(), iodata()) -> ok.
inject(Server, Bytes) ->
    Server ! {inject, iolist_to_binary(Bytes)},
    ok.

%% Build a text/event-plain frame for the given event name and headers.
-spec plain_event(iodata(), [{iodata(), iodata()}]) -> binary().
plain_event(Name, Headers) ->
    Lines = [
        [<<"Event-Name: ">>, Name, <<"\n">>]
        | [[K, <<": ">>, V, <<"\n">>] || {K, V} <- Headers]
    ],
    Inner = iolist_to_binary([Lines, <<"\n">>]),
    frame(<<"text/event-plain">>, [], Inner).

%% internal

init(Parent, Opts) ->
    {ok, Listen} = gen_tcp:listen(0, [
        binary, {packet, raw}, {active, false}, {reuseaddr, true}
    ]),
    {ok, Port} = inet:port(Listen),
    Parent ! {self(), port, Port},
    {ok, Sock} = gen_tcp:accept(Listen),
    ok = inet:setopts(Sock, [{active, true}]),
    ok = gen_tcp:send(Sock, <<"Content-Type: auth/request\n\n">>),
    loop(#{sock => Sock, listen => Listen, buf => <<>>, opts => Opts}).

loop(State) ->
    receive
        {tcp, _Sock, Data} ->
            Buf = <<(maps:get(buf, State))/binary, Data/binary>>,
            loop(process(State#{buf := Buf}));
        {tcp_closed, _Sock} ->
            shutdown(State);
        {inject, Bytes} ->
            ok = gen_tcp:send(maps:get(sock, State), Bytes),
            loop(State);
        stop ->
            shutdown(State)
    end.

shutdown(State) ->
    _ = gen_tcp:close(maps:get(sock, State)),
    _ = gen_tcp:close(maps:get(listen, State)),
    ok.

process(State) ->
    case binary:split(maps:get(buf, State), <<"\n\n">>) of
        [_Incomplete] ->
            State;
        [Block, Rest] ->
            State1 = handle_command(Block, State#{buf := Rest}),
            process(State1)
    end.

handle_command(Block, State) ->
    Sock = maps:get(sock, State),
    Opts = maps:get(opts, State),
    [First | _] = binary:split(Block, <<"\n">>),
    case First of
        <<"auth ", _/binary>> ->
            send(Sock, command_reply(<<"+OK accepted">>));
        <<"api ", Cmd/binary>> ->
            send(Sock, api_response(api_reply(Cmd, Opts)));
        <<"bgapi ", Cmd/binary>> ->
            handle_bgapi(Sock, Cmd, Opts);
        <<"event ", _/binary>> ->
            send(Sock, command_reply(<<"+OK event listener enabled">>));
        <<"filter ", _/binary>> ->
            send(Sock, command_reply(<<"+OK filter added">>));
        <<"sendevent ", _/binary>> ->
            send(Sock, command_reply(<<"+OK">>));
        <<"sendmsg", _/binary>> ->
            send(Sock, command_reply(<<"+OK">>));
        <<"exit", _/binary>> ->
            send(Sock, command_reply(<<"+OK bye">>)),
            send(Sock, disconnect_notice());
        _Other ->
            send(Sock, command_reply(<<"-ERR unknown command">>))
    end,
    State.

handle_bgapi(Sock, Cmd, Opts) ->
    Uuid = new_uuid(),
    send(Sock, command_reply(<<"+OK Job-UUID: ", Uuid/binary>>)),
    Result = api_reply(Cmd, Opts),
    send(Sock, background_job(Uuid, Result)).

api_reply(Cmd, Opts) ->
    Key = string:trim(Cmd),
    maps:get(Key, maps:get(api, Opts, #{}), <<"+OK">>).

send(Sock, Bytes) ->
    ok = gen_tcp:send(Sock, Bytes).

new_uuid() ->
    integer_to_binary(erlang:unique_integer([positive, monotonic])).

command_reply(Text) ->
    <<"Content-Type: command/reply\nReply-Text: ", Text/binary, "\n\n">>.

api_response(Body) ->
    frame(<<"api/response">>, [], Body).

disconnect_notice() ->
    frame(<<"text/disconnect-notice">>, [], <<"Disconnected, goodbye.\n">>).

background_job(Uuid, Result) ->
    Len = integer_to_binary(byte_size(Result)),
    Inner =
        <<"Event-Name: BACKGROUND_JOB\nJob-UUID: ", Uuid/binary,
            "\nContent-Length: ", Len/binary, "\n\n", Result/binary>>,
    frame(<<"text/event-plain">>, [], Inner).

frame(Type, Extra, Body) ->
    ExtraLines = [[K, <<": ">>, V, <<"\n">>] || {K, V} <- Extra],
    CL =
        case byte_size(Body) of
            0 -> [];
            N -> [<<"Content-Length: ">>, integer_to_binary(N), <<"\n">>]
        end,
    iolist_to_binary([
        <<"Content-Type: ">>, Type, <<"\n">>, ExtraLines, CL, <<"\n">>, Body
    ]).
