%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Scriptable in-process fake of FreeSWITCH mod_event_socket for inbound tests.
%% It sends auth/request on accept, answers commands (api, bgapi, event,
%% myevents, nixevent, noevents, sendmsg, sendevent, filter, exit), and lets a
%% test push arbitrary frames with inject/2. bgapi answers with a Job-UUID and
%% then pushes the matching BACKGROUND_JOB event. api bodies are configured
%% with the `api' option (a command => body map, where a body may be
%% {delay, Ms, Body} to answer late, or `silent' to never answer); everything
%% else defaults to +OK. set_api/3 changes one body at runtime.
%%
%% Options:
%% - `auth => reject' answers the password with -ERR;
%% - `greeting => {rude, Text}' sends a text/rude-rejection and closes instead
%%   of the auth/request;
%% - `port => P' listens on P (to bring a fake back on the same port);
%% - `reaccept => true' accepts a new client after the current one is gone
%%   (closed by the client or dropped with drop/1), instead of stopping;
%% - `heartbeat => Ms' sends a HEARTBEAT event every Ms once the client
%%   subscribed to HEARTBEAT, in the subscribed format, with the headers of
%%   `load' (a map, changed with set_load/2) over FreeSWITCH-like defaults.
%%
%% Every command block received is reported to the process that started the
%% fake as {fake_server, Server, Block} (a body, when the block carries a
%% Content-Length, is appended after a blank line), and every accepted client
%% as {fake_server_accept, Server}.
-module(chappe_esl_fake_server).

-export([start/0, start/1, stop/1, inject/2, drop/1]).
-export([set_api/3, set_load/2]).
-export([plain_event/2, json_event/2]).

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
    Ref = monitor(process, Server),
    Server ! stop,
    receive
        {'DOWN', Ref, process, Server, _} -> ok
    after 5000 ->
        error(fake_server_stop_timeout)
    end.

%% Push raw bytes (for example an event frame) to the connected client.
-spec inject(pid(), iodata()) -> ok.
inject(Server, Bytes) ->
    Server ! {inject, iolist_to_binary(Bytes)},
    ok.

%% Close the client socket from the server side.
-spec drop(pid()) -> ok.
drop(Server) ->
    Server ! drop,
    ok.

%% Change the body answered to `api Cmd'.
-spec set_api(pid(), binary(), binary() | silent | {delay, timeout(), binary()}) ->
    ok.
set_api(Server, Cmd, Body) ->
    Server ! {set_api, Cmd, Body},
    ok.

%% Change the HEARTBEAT headers (merged over the defaults).
-spec set_load(pid(), #{binary() => binary()}) -> ok.
set_load(Server, Load) ->
    Server ! {set_load, Load},
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

%% Build a text/event-json frame for the given event name and headers.
-spec json_event(binary(), [{binary(), binary()}]) -> binary().
json_event(Name, Headers) ->
    Map = maps:from_list([{<<"Event-Name">>, Name} | Headers]),
    frame(<<"text/event-json">>, [], iolist_to_binary(json:encode(Map))).

%% internal

init(Parent, Opts) ->
    {ok, Listen} = gen_tcp:listen(maps:get(port, Opts, 0), [
        binary, {packet, raw}, {active, false}, {reuseaddr, true}
    ]),
    {ok, Port} = inet:port(Listen),
    Parent ! {self(), port, Port},
    accept(#{
        listen => Listen,
        sock => undefined,
        buf => <<>>,
        opts => Opts,
        parent => Parent,
        api => maps:get(api, Opts, #{}),
        load => maps:get(load, Opts, #{}),
        hb_format => undefined
    }).

%% Wait for a client, still answering control messages.
accept(#{listen := Listen} = State) ->
    receive
        stop -> shutdown(State);
        {set_api, _, _} = Msg -> accept(control(Msg, State));
        {set_load, _} = Msg -> accept(control(Msg, State))
    after 0 ->
        case gen_tcp:accept(Listen, 50) of
            {ok, Sock} ->
                maps:get(parent, State) ! {fake_server_accept, self()},
                greet(Sock, State#{sock := Sock, buf := <<>>});
            {error, timeout} ->
                accept(State)
        end
    end.

greet(Sock, State) ->
    case maps:get(greeting, maps:get(opts, State), auth) of
        {rude, Text} ->
            ok = gen_tcp:send(Sock, frame(<<"text/rude-rejection">>, [], Text)),
            gone(State);
        auth ->
            ok = inet:setopts(Sock, [{active, true}]),
            ok = gen_tcp:send(Sock, <<"Content-Type: auth/request\n\n">>),
            loop(State)
    end.

%% The client is gone: wait for the next one, or stop.
gone(#{sock := Sock, opts := Opts} = State) ->
    _ = gen_tcp:close(Sock),
    flush_heartbeats(),
    Next = State#{sock := undefined, buf := <<>>, hb_format := undefined},
    case maps:get(reaccept, Opts, false) of
        true -> accept(Next);
        false -> shutdown(Next)
    end.

flush_heartbeats() ->
    receive
        heartbeat -> flush_heartbeats()
    after 0 -> ok
    end.

loop(#{sock := Sock} = State) ->
    receive
        {tcp, Sock, Data} ->
            Buf = <<(maps:get(buf, State))/binary, Data/binary>>,
            loop(process(State#{buf := Buf}));
        {tcp_closed, Sock} ->
            gone(State);
        {inject, Bytes} ->
            _ = gen_tcp:send(Sock, Bytes),
            loop(State);
        heartbeat ->
            loop(send_heartbeat(State));
        drop ->
            gone(State);
        stop ->
            shutdown(State);
        {set_api, _, _} = Msg ->
            loop(control(Msg, State));
        {set_load, _} = Msg ->
            loop(control(Msg, State));
        _Other ->
            loop(State)
    end.

control({set_api, Cmd, Body}, #{api := Api} = State) ->
    State#{api := Api#{Cmd => Body}};
control({set_load, Load}, #{load := Old} = State) ->
    State#{load := maps:merge(Old, Load)}.

shutdown(#{sock := Sock, listen := Listen}) ->
    _ = Sock =/= undefined andalso gen_tcp:close(Sock),
    _ = gen_tcp:close(Listen),
    ok.

process(State) ->
    case binary:split(maps:get(buf, State), <<"\n\n">>) of
        [_Incomplete] ->
            State;
        [Block, Rest] ->
            case body_length(Block) of
                0 ->
                    process(handle_command(Block, State#{buf := Rest}));
                N when byte_size(Rest) >= N ->
                    <<Body:N/binary, Rest1/binary>> = Rest,
                    Full = <<Block/binary, "\n\n", Body/binary>>,
                    process(handle_command(Full, State#{buf := Rest1}));
                _ ->
                    State
            end
    end.

body_length(Block) ->
    Lines = binary:split(Block, <<"\n">>, [global]),
    lists:foldl(
        fun(Line, Acc) ->
            case binary:split(Line, <<": ">>) of
                [K, V] ->
                    case string:lowercase(K) of
                        <<"content-length">> -> binary_to_integer(V);
                        _ -> Acc
                    end;
                _ ->
                    Acc
            end
        end,
        0,
        tl(Lines)
    ).

handle_command(Block, #{sock := Sock, opts := Opts} = State) ->
    maps:get(parent, State) ! {fake_server, self(), Block},
    [First | _] = binary:split(Block, <<"\n">>),
    case First of
        <<"auth ", _/binary>> ->
            send(Sock, auth_reply(maps:get(auth, Opts, accept))),
            State;
        <<"api ", Cmd/binary>> ->
            send_api(Sock, api_reply(Cmd, State)),
            State;
        <<"bgapi ", Cmd/binary>> ->
            handle_bgapi(Sock, Cmd, State),
            State;
        <<"event ", Spec/binary>> ->
            send(Sock, command_reply(<<"+OK event listener enabled">>)),
            subscribed(Spec, State);
        <<"myevents", _/binary>> ->
            send(Sock, command_reply(<<"+OK Events Enabled">>)),
            State;
        <<"nixevent ", _/binary>> ->
            send(Sock, command_reply(<<"+OK events nixed">>)),
            State;
        <<"noevents", _/binary>> ->
            send(Sock, command_reply(<<"+OK no longer listening for events">>)),
            State#{hb_format := undefined};
        <<"filter ", _/binary>> ->
            send(Sock, command_reply(<<"+OK filter added">>)),
            State;
        <<"sendevent ", _/binary>> ->
            send(Sock, command_reply(<<"+OK">>)),
            State;
        <<"sendmsg", _/binary>> ->
            send(Sock, command_reply(<<"+OK">>)),
            State;
        <<"exit", _/binary>> ->
            send(Sock, command_reply(<<"+OK bye">>)),
            send(Sock, disconnect_notice()),
            State;
        _Other ->
            send(Sock, command_reply(<<"-ERR unknown command">>)),
            State
    end.

%% "event json HEARTBEAT ..." starts the heartbeat when one is configured.
subscribed(Spec, #{opts := Opts} = State) ->
    [Format | Names] = binary:split(Spec, <<" ">>, [global, trim_all]),
    case {maps:get(heartbeat, Opts, undefined), lists:member(<<"HEARTBEAT">>, Names)} of
        {Ms, true} when is_integer(Ms) ->
            Ms > 0 andalso erlang:send_after(Ms, self(), heartbeat),
            State#{hb_format := Format};
        _ ->
            State
    end.

send_heartbeat(#{hb_format := undefined} = State) ->
    State;
send_heartbeat(#{sock := Sock, hb_format := Format, load := Load} = State) ->
    Headers = maps:to_list(maps:merge(default_load(), Load)),
    Frame =
        case Format of
            <<"json">> -> json_event(<<"HEARTBEAT">>, Headers);
            _ -> plain_event(<<"HEARTBEAT">>, Headers)
        end,
    _ = gen_tcp:send(Sock, Frame),
    erlang:send_after(maps:get(heartbeat, maps:get(opts, State)), self(), heartbeat),
    State.

default_load() ->
    #{
        <<"Session-Count">> => <<"0">>,
        <<"Max-Sessions">> => <<"1000">>,
        <<"Session-Per-Sec">> => <<"0">>,
        <<"Idle-CPU">> => <<"99.000000">>,
        <<"Uptime-msec">> => <<"1000">>
    }.

handle_bgapi(Sock, Cmd, State) ->
    Uuid = new_uuid(),
    send(Sock, command_reply(<<"+OK Job-UUID: ", Uuid/binary>>)),
    case api_reply(Cmd, State) of
        silent -> ok;
        {delay, _, Result} -> send(Sock, background_job(Uuid, Result));
        Result -> send(Sock, background_job(Uuid, Result))
    end.

auth_reply(accept) -> command_reply(<<"+OK accepted">>);
auth_reply(reject) -> command_reply(<<"-ERR invalid">>).

send_api(_Sock, silent) ->
    ok;
send_api(Sock, {delay, Ms, Body}) ->
    timer:sleep(Ms),
    send_api(Sock, Body);
send_api(Sock, Body) ->
    send(Sock, api_response(Body)).

api_reply(Cmd, #{api := Api}) ->
    maps:get(string:trim(Cmd), Api, <<"+OK">>).

send(Sock, Bytes) ->
    _ = gen_tcp:send(Sock, Bytes),
    ok.

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
