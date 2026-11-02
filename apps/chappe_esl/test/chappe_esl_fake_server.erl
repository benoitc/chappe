%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Scriptable in-process fake of FreeSWITCH mod_event_socket for inbound tests.
%% It sends auth/request on accept, answers commands (api, bgapi, event,
%% myevents, nixevent, noevents, sendmsg, sendevent, filter, exit), and lets a
%% test push arbitrary frames with inject/2. bgapi answers with a Job-UUID and
%% then pushes the matching BACKGROUND_JOB event. api bodies are configured
%% with the `api' option (a command => body map, where a body may be
%% {delay, Ms, Body} to answer late, `silent' to never answer, or {hold, Body}
%% to withhold the reply until release_api/1, answering the commands received
%% meanwhile after it, in order, as FreeSWITCH does; events still go out);
%% everything else defaults to +OK. set_api/3 changes one body at runtime.
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
%% A fake that has a channel (`channel => Uuid', or the outbound-client mode)
%% plays it too: a sendmsg execute is answered +OK and followed by
%% CHANNEL_EXECUTE and CHANNEL_EXECUTE_COMPLETE carrying the request's
%% Event-UUID as Application-UUID, and the channel's Unique-ID. `apps' maps
%% an application name to how it completes: `silent' (never), or a map with
%% `execute_delay' (ms before CHANNEL_EXECUTE, as if queued), `delay' (ms
%% before the completion, or `silent'), `response' (Application-Response) and `vars' (extra headers
%% of the completion, such as variable_chappe_digits). dtmf/2 and hangup/2
%% push DTMF and CHANNEL_HANGUP / CHANNEL_HANGUP_COMPLETE events.
%%
%% start_outbound/2 runs the fake as FreeSWITCH running the dialplan socket
%% application: it connects to a listener, answers `connect' with the
%% channel data and `linger' with +OK, then behaves as above. It stops when
%% the client closes the socket.
%%
%% Every command block received is reported to the process that started the
%% fake as {fake_server, Server, Block} (a body, when the block carries a
%% Content-Length, is appended after a blank line), and every accepted client
%% as {fake_server_accept, Server}.
-module(chappe_esl_fake_server).

-export([start/0, start/1, stop/1, inject/2, drop/1]).
-export([start_outbound/2, dtmf/2, hangup/2]).
-export([set_api/3, release_api/1, set_load/2]).
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

%% Connect to an outbound listener on Port as the channel `channel' (default
%% <<"fake-uuid-1">>). Returns {ok, Server}.
-spec start_outbound(inet:port_number(), map()) -> {ok, pid()}.
start_outbound(Port, Opts) ->
    Parent = self(),
    Pid = spawn(fun() -> init_outbound(Parent, Port, Opts) end),
    receive
        {Pid, connected} -> {ok, Pid}
    after 5000 ->
        error(fake_server_connect_timeout)
    end.

%% Push a DTMF event for the channel.
-spec dtmf(pid(), binary()) -> ok.
dtmf(Server, Digit) ->
    Server ! {channel_event, <<"DTMF">>, [{<<"DTMF-Digit">>, Digit}]},
    ok.

%% Push CHANNEL_HANGUP then CHANNEL_HANGUP_COMPLETE for the channel.
-spec hangup(pid(), binary()) -> ok.
hangup(Server, Cause) ->
    H = [{<<"Hangup-Cause">>, Cause}],
    Server ! {channel_event, <<"CHANNEL_HANGUP">>, H},
    Server ! {channel_event, <<"CHANNEL_HANGUP_COMPLETE">>, H},
    ok.

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
-spec set_api(
    pid(),
    binary(),
    binary() | silent | {delay, timeout(), binary()} | {hold, binary()}
) ->
    ok.
set_api(Server, Cmd, Body) ->
    Server ! {set_api, Cmd, Body},
    ok.

%% Answer the withheld api, then the commands received behind it.
-spec release_api(pid()) -> ok.
release_api(Server) ->
    Server ! release_api,
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

init_outbound(Parent, Port, Opts0) ->
    Opts = Opts0#{channel => maps:get(channel, Opts0, <<"fake-uuid-1">>)},
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {packet, raw}, {active, true}], 5000
    ),
    Parent ! {self(), connected},
    loop(#{
        listen => undefined,
        sock => Sock,
        buf => <<>>,
        opts => Opts#{reaccept => false},
        parent => Parent,
        api => maps:get(api, Opts, #{}),
        load => #{},
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
        {channel_event, Name, Headers} ->
            _ = gen_tcp:send(Sock, channel_event(Name, Headers, State)),
            loop(State);
        drop ->
            gone(State);
        stop ->
            shutdown(State);
        {set_api, _, _} = Msg ->
            loop(control(Msg, State));
        {set_load, _} = Msg ->
            loop(control(Msg, State));
        release_api ->
            loop(release_api_reply(State));
        _Other ->
            loop(State)
    end.

control({set_api, Cmd, Body}, #{api := Api} = State) ->
    State#{api := Api#{Cmd => Body}};
control({set_load, Load}, #{load := Old} = State) ->
    State#{load := maps:merge(Old, Load)}.

shutdown(#{sock := Sock, listen := Listen}) ->
    _ = Sock =/= undefined andalso gen_tcp:close(Sock),
    _ = Listen =/= undefined andalso gen_tcp:close(Listen),
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

handle_command(Block, State) ->
    maps:get(parent, State) ! {fake_server, self(), Block},
    run_command(Block, State).

%% Behind a withheld api reply, commands wait their turn.
run_command(Block, #{held := {Body, Blocks}} = State) ->
    State#{held := {Body, Blocks ++ [Block]}};
run_command(Block, #{sock := Sock, opts := Opts} = State) ->
    [First | _] = binary:split(Block, <<"\n">>),
    case First of
        <<"auth ", _/binary>> ->
            send(Sock, auth_reply(maps:get(auth, Opts, accept))),
            State;
        <<"api ", Cmd/binary>> ->
            case api_reply(Cmd, State) of
                {hold, Body} ->
                    State#{held => {Body, []}};
                Reply ->
                    send_api(Sock, Reply),
                    State
            end;
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
            maybe_execute(Block, State),
            State;
        <<"connect", _/binary>> ->
            send(Sock, channel_data(State)),
            State;
        <<"linger", _/binary>> ->
            send(Sock, command_reply(<<"+OK will linger">>)),
            State;
        <<"exit", _/binary>> ->
            send(Sock, command_reply(<<"+OK bye">>)),
            send(Sock, disconnect_notice()),
            State;
        _Other ->
            send(Sock, command_reply(<<"-ERR unknown command">>)),
            State
    end.

release_api_reply(#{held := {Body, Blocks}, sock := Sock} = State) ->
    send_api(Sock, Body),
    lists:foldl(fun run_command/2, maps:remove(held, State), Blocks);
release_api_reply(State) ->
    State.

%% A sendmsg execute on a fake with a channel: report the execution, then
%% complete it as `apps' says.
maybe_execute(Block, #{opts := #{channel := _} = Opts}) ->
    H = block_headers(Block),
    case maps:get(<<"call-command">>, H, undefined) of
        <<"execute">> ->
            App = maps:get(<<"execute-app-name">>, H),
            Arg = maps:get(<<"execute-app-arg">>, H, block_body(Block)),
            Common = [
                {<<"Application">>, App},
                {<<"Application-Data">>, Arg},
                {<<"Application-UUID">>, maps:get(<<"event-uuid">>, H)}
            ],
            Spec = maps:get(App, maps:get(apps, Opts, #{}), #{}),
            Started = {channel_event, <<"CHANNEL_EXECUTE">>, Common},
            _ =
                case execute_delay(Spec) of
                    0 -> self() ! Started;
                    Ms -> erlang:send_after(Ms, self(), Started)
                end,
            complete(Spec, Common);
        _ ->
            ok
    end;
maybe_execute(_Block, _State) ->
    ok.

execute_delay(#{execute_delay := Ms}) -> Ms;
execute_delay(_Spec) -> 0.

complete(silent, _Common) ->
    ok;
complete(#{delay := silent}, _Common) ->
    ok;
complete(Spec, Common) ->
    Response = maps:get(response, Spec, <<"_none_">>),
    Headers =
        Common ++
            [{<<"Application-Response">>, Response}] ++
            maps:get(vars, Spec, []),
    Msg = {channel_event, <<"CHANNEL_EXECUTE_COMPLETE">>, Headers},
    erlang:send_after(maps:get(delay, Spec, 0), self(), Msg),
    ok.

%% Header names of a command block, lowercased.
block_headers(Block) ->
    [Head | _] = binary:split(Block, <<"\n\n">>),
    [_First | Lines] = binary:split(Head, <<"\n">>, [global]),
    maps:from_list([
        {string:lowercase(K), V}
     || Line <- Lines, [K, V] <- [binary:split(Line, <<": ">>)]
    ]).

block_body(Block) ->
    case binary:split(Block, <<"\n\n">>) of
        [_, Body] -> Body;
        [_] -> <<>>
    end.

channel_event(Name, Headers, #{opts := Opts}) ->
    Uuid = maps:get(channel, Opts, <<"fake-uuid-1">>),
    plain_event(Name, [{<<"Unique-ID">>, Uuid} | Headers]).

channel_data(#{opts := Opts}) ->
    Uuid = maps:get(channel, Opts, <<"fake-uuid-1">>),
    <<"Content-Type: command/reply\nReply-Text: +OK\n"
        "Unique-ID: ", Uuid/binary, "\nChannel-Unique-ID: ", Uuid/binary,
        "\nChannel-Name: sofia/internal/1000\n"
        "Caller-Caller-ID-Number: 1000\n\n">>.

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
        <<"Session-Per-Sec-Last">> => <<"0">>,
        <<"Idle-CPU">> => <<"99.000000">>,
        <<"Uptime-msec">> => <<"1000">>
    }.

handle_bgapi(Sock, Cmd, State) ->
    Uuid = new_uuid(),
    send(Sock, command_reply(<<"+OK Job-UUID: ", Uuid/binary>>)),
    case api_reply(Cmd, State) of
        silent -> ok;
        {delay, _, Result} -> send(Sock, background_job(Uuid, Result));
        {hold, Result} -> send(Sock, background_job(Uuid, Result));
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
