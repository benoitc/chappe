%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Fakes for chappe_mrf_SUITE, so the app runs end to end without docker:
%%
%% fs_start/2: a FreeSWITCH node. Its SIP side (UDP) answers an INVITE
%% the way the dialplan `socket ... async full' does: it opens an
%% outbound event socket to the listener, with the INVITE's
%% X-Chappe-Call as variable_sip_h_X-Chappe-Call, and sends the 200 once
%% the socket executes `answer'. On the socket it answers like
%% mod_event_socket: sendmsg execute gets +OK, CHANNEL_EXECUTE and
%% CHANNEL_EXECUTE_COMPLETE (play_and_get_digits completes with the
%% digits of the `digits' option), api gets +OK; uuid_kill and a BYE end
%% the channel. A `conference' application joins a room: add-member, and
%% `conference <room> kick <id>' gives del-member. Every command block
%% reaches the test as {fake_fs, Name, Uuid, Block}.
%%
%% esl_start/0: a bare inbound event socket (auth, +OK to everything),
%% enough for chappe_esl's node registry to see a node up; esl_stop/1
%% makes it go down.
%%
%% rtpe_start/1: an rtpengine NG node that passes the SDP through with a
%% marker line (a=rtpe-offer:<from-tag>, a=rtpe-answer:<to-tag>).
%%
%% ua_*: a caller over UDP that INVITEs the engine, ACKs, answers BYE and
%% re-INVITE (and reports them), and sends BYE or RTP.
-module(chappe_mrf_fake).

-export([fs_start/2, fs_stop/1, fs_dtmf/2, fs_hangup/2, fs_port/1]).
-export([fs_event/3, socket_start/3, socket_event/3, socket_stop/1]).
-export([refuser_start/1]).
-export([esl_start/0, esl_stop/1]).
-export([rtpe_start/1, rtpe_stop/1]).
-export([ua_call/2, ua_bye/1, ua_rtp/2, ua_rtp/3, callee_start/1]).
-export([pick/0, sdp/2, hdr/2, body/1]).

-define(RTPE_NODE, chappe_mrf_fake_rtpe).

%% ---- ports ----

pick() ->
    {ok, S} = gen_udp:open(0, [{ip, {127, 0, 0, 1}}]),
    {ok, P} = inet:port(S),
    ok = gen_udp:close(S),
    case gen_tcp:listen(P, [{ip, {127, 0, 0, 1}}]) of
        {ok, L} ->
            ok = gen_tcp:close(L),
            P;
        {error, _} ->
            pick()
    end.

%% ---- FreeSWITCH ----

%% Opts: esl_port (the chappe_mrf listener), digits (what
%% play_and_get_digits collects, default <<"1">>), name.
fs_start(Name, Opts) ->
    Parent = self(),
    Pid = spawn(fun() ->
        {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
        {ok, Port} = inet:port(Sock),
        Parent ! {fs_ready, self(), Port},
        fs_loop(#{
            pid => self(),
            name => Name,
            sock => Sock,
            port => Port,
            parent => Parent,
            opts => Opts,
            calls => #{}
        })
    end),
    receive
        {fs_ready, Pid, Port} -> {Pid, Port}
    after 2000 -> error(fs_start)
    end.

fs_port({_Pid, Port}) -> Port.

fs_stop({Pid, _}) ->
    Pid ! stop,
    ok.

%% DTMF on every channel of the node
fs_dtmf({Pid, _}, Digit) ->
    Pid ! {all, {dtmf, Digit}},
    ok.

fs_hangup({Pid, _}, Cause) ->
    Pid ! {all, {hangup, Cause}},
    ok.

%% an event on every channel of the node
fs_event({Pid, _}, Name, Headers) ->
    Pid ! {all, {event, Name, Headers}},
    ok.

%% A SIP peer that answers every INVITE with Status: {Pid, Port}.
refuser_start(Status) ->
    Parent = self(),
    Pid = spawn_link(fun() ->
        {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
        Parent ! {refuser, self(), element(2, inet:port(Sock))},
        refuse_loop(Sock, Status)
    end),
    receive
        {refuser, Pid, Port} -> {Pid, Port}
    after 2000 -> error(refuser)
    end.

refuse_loop(Sock, Status) ->
    receive
        {udp, Sock, _, Src, <<"INVITE ", _/binary>> = I} ->
            _ = gen_udp:send(Sock, {127, 0, 0, 1}, Src, resp(I, Status, <<"Nope">>, tag(), [], <<>>)),
            refuse_loop(Sock, Status);
        {udp, Sock, _, _, _} ->
            refuse_loop(Sock, Status)
    end.

%% ---- a bare outbound socket ----

%% Connect to the listener on Port as a channel with Headers (Unique-ID is
%% added). Mode ok answers every command +OK and executes complete at
%% once; err answers sendmsg with -ERR.
socket_start(Port, Headers, Mode) ->
    Parent = self(),
    spawn_link(fun() ->
        {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {packet, raw}, {active, true}], 5000),
        Parent ! {socket_up, self()},
        sock_loop(S, Headers, Mode, <<>>)
    end).

socket_event(Sock, Name, Headers) ->
    Sock ! {event, Name, Headers},
    ok.

socket_stop(Sock) ->
    unlink(Sock),
    Sock ! stop,
    ok.

sock_loop(S, Headers, Mode, Buf) ->
    receive
        {tcp, S, Data} ->
            sock_loop(S, Headers, Mode, sock_cmds(S, Headers, Mode, <<Buf/binary, Data/binary>>));
        {tcp_closed, S} ->
            ok;
        {event, Name, H} ->
            Inner = iolist_to_binary([
                [<<"Event-Name: ">>, Name, <<"\n">>],
                <<"Unique-ID: sock-uuid\n">>,
                [[K, <<": ">>, V, <<"\n">>] || {K, V} <- H],
                <<"\n">>
            ]),
            _ = gen_tcp:send(S, frame(<<"text/event-plain">>, Inner)),
            sock_loop(S, Headers, Mode, Buf);
        stop ->
            gen_tcp:close(S)
    end.

sock_cmds(S, Headers, Mode, Buf) ->
    case binary:split(Buf, <<"\n\n">>) of
        [_] ->
            Buf;
        [Block, Rest] ->
            [First | _] = binary:split(Block, <<"\n">>),
            _ =
                case {First, Mode} of
                    {<<"connect", _/binary>>, _} ->
                        Lines = [[K, <<": ">>, V, <<"\n">>] || {K, V} <- Headers],
                        gen_tcp:send(S, iolist_to_binary([
                            <<"Content-Type: command/reply\nReply-Text: +OK\n">>,
                            <<"Unique-ID: sock-uuid\n">>, Lines, <<"\n">>
                        ]));
                    {<<"sendmsg", _/binary>>, err} ->
                        gen_tcp:send(S, reply(<<"-ERR no">>));
                    {<<"api ", _/binary>>, _} ->
                        gen_tcp:send(S, api_resp(<<"+OK">>));
                    _ ->
                        gen_tcp:send(S, reply(<<"+OK">>))
                end,
            sock_cmds(S, Headers, Mode, Rest)
    end.

fs_loop(#{sock := Sock, calls := Calls} = S) ->
    receive
        {udp, Sock, Ip, Src, Bin} ->
            fs_loop(fs_sip(Bin, {Ip, Src}, S));
        {all, Msg} ->
            _ = [C ! Msg || C <- maps:values(Calls)],
            fs_loop(S);
        {call_done, CallId} ->
            fs_loop(S#{calls := maps:remove(CallId, Calls)});
        {set_digits, D} ->
            _ = [C ! {set_digits, D} || C <- maps:values(Calls)],
            fs_loop(S#{opts := (maps:get(opts, S))#{digits => D}});
        stop ->
            _ = [exit(C, kill) || C <- maps:values(Calls)],
            gen_udp:close(Sock)
    end.

fs_sip(<<"SIP/2.0 ", _/binary>>, _Src, S) ->
    S;
fs_sip(Bin, Src, #{calls := Calls} = S) ->
    CallId = hdr(Bin, <<"call-id">>),
    case Calls of
        #{CallId := C} ->
            C ! {sip, Bin, Src},
            S;
        _ ->
            case method(Bin) of
                <<"INVITE">> ->
                    C = spawn(fun() -> channel(Bin, Src, S) end),
                    S#{calls := Calls#{CallId => C}};
                <<"ACK">> ->
                    S;
                _ ->
                    send_sip(S, Src, resp(Bin, 481, <<"No Dialog">>, <<>>, [], <<>>)),
                    S
            end
    end.

%% one channel: its INVITE dialog and its outbound socket
channel(Invite, Src, #{opts := Opts, name := Name} = Node) ->
    Uuid = <<"uuid-", (tag())/binary>>,
    Tag = tag(),
    send_sip(Node, Src, resp(Invite, 100, <<"Trying">>, <<>>, [], <<>>)),
    Id = hdr(Invite, <<"x-chappe-call">>),
    Tcp =
        case maps:get(no_socket, Opts, false) of
            true ->
                undefined;
            false ->
                {ok, T} = gen_tcp:connect(
                    {127, 0, 0, 1}, maps:get(esl_port, Opts), [binary, {packet, raw}, {active, true}], 5000
                ),
                T
        end,
    C0 = #{
        node => Node,
        name => Name,
        uuid => Uuid,
        tag => Tag,
        invite => Invite,
        src => Src,
        tcp => Tcp,
        buf => <<>>,
        id => Id,
        answered => false,
        members => #{}
    },
    case Tcp of
        undefined ->
            %% a node whose dialplan never reaches the socket
            Sdp = sdp(<<"fs-", Name/binary>>, 40100),
            send_sip(Node, Src, resp(Invite, 200, <<"OK">>, Tag, [contact(Node)], Sdp)),
            chan_loop_sip_only(C0#{answered := true});
        _ ->
            chan_loop(C0)
    end.

chan_loop(#{tcp := Tcp} = C) ->
    receive
        {tcp, Tcp, Data} ->
            chan_loop(esl_in(C#{buf := <<(maps:get(buf, C))/binary, Data/binary>>}));
        {tcp_closed, Tcp} ->
            chan_loop_sip_only(C);
        {sip, Bin, Src} ->
            chan_loop(chan_sip(Bin, Src, C));
        {dtmf, Digit} ->
            event(C, <<"DTMF">>, [{<<"DTMF-Digit">>, Digit}]),
            chan_loop(C);
        {hangup, Cause} ->
            end_channel(C, Cause, true);
        {event, Name, Headers} ->
            event(C, Name, Headers),
            chan_loop(C);
        {set_digits, D} ->
            #{node := #{opts := O} = N} = C,
            chan_loop(C#{node := N#{opts := O#{digits => D}}})
    end.

%% the socket is gone (the controller closed it): SIP still answers
chan_loop_sip_only(C) ->
    receive
        {sip, Bin, Src} ->
            chan_loop_sip_only(chan_sip(Bin, Src, C#{tcp := undefined}));
        _ ->
            chan_loop_sip_only(C)
    after 30000 -> ok
    end.

chan_sip(Bin, Src, #{node := Node} = C) ->
    case method(Bin) of
        <<"BYE">> ->
            send_sip(Node, Src, resp(Bin, 200, <<"OK">>, <<>>, [], <<>>)),
            report(C, {bye, Bin}),
            _ = end_channel(C, <<"NORMAL_CLEARING">>, false),
            C;
        <<"INVITE">> ->
            report(C, {reinvite, Bin}),
            #{opts := NOpts} = Node,
            _ =
                maps:get(reject_reinvite, NOpts, false) andalso
                    send_sip(Node, Src, resp(Bin, 488, <<"Not Here">>, <<>>, [], <<>>)),
            Sdp = sdp(<<"fs-", (maps:get(name, C))/binary>>, 40100),
            _ =
                maps:get(reject_reinvite, NOpts, false) orelse
                    send_sip(Node, Src, resp(Bin, 200, <<"OK">>, maps:get(tag, C), [contact(Node)], Sdp)),
            C;
        <<"ACK">> ->
            C;
        _ ->
            send_sip(Node, Src, resp(Bin, 200, <<"OK">>, <<>>, [], <<>>)),
            C
    end.

%% hang the channel up: events, a BYE when we end it, the socket closed
end_channel(#{tcp := Tcp, node := Node} = C, Cause, SendBye) ->
    H = [{<<"Hangup-Cause">>, Cause}],
    event(C, <<"CHANNEL_HANGUP">>, H),
    event(C, <<"CHANNEL_HANGUP_COMPLETE">>, H),
    _ = SendBye andalso maps:get(answered, C) andalso send_bye(C),
    _ = Tcp =/= undefined andalso gen_tcp:close(Tcp),
    maps:get(pid, Node) ! {call_done, hdr(maps:get(invite, C), <<"call-id">>)},
    exit(normal).

send_bye(#{invite := Inv, tag := Tag, src := Src, node := Node}) ->
    {ok, #{uri := Target}} = chappe_sip_hdr:name_addr(hdr(Inv, <<"contact">>)),
    P = integer_to_binary(maps:get(port, Node)),
    To = hdr(Inv, <<"from">>),
    From = <<(hdr(Inv, <<"to">>))/binary, ";tag=", Tag/binary>>,
    Bye = build(<<"BYE">>, Target, [
        {<<"Via">>, <<"SIP/2.0/UDP 127.0.0.1:", P/binary, ";branch=", (branch())/binary>>},
        {<<"Max-Forwards">>, <<"70">>},
        {<<"From">>, From},
        {<<"To">>, To},
        {<<"Call-ID">>, hdr(Inv, <<"call-id">>)},
        {<<"CSeq">>, <<"200 BYE">>}
    ], <<>>),
    send_sip(Node, Src, Bye),
    ok.

%% ---- the outbound socket ----

esl_in(#{buf := Buf} = C) ->
    case binary:split(Buf, <<"\n\n">>) of
        [_] ->
            C;
        [Block, Rest] ->
            case clen(Block) of
                0 ->
                    esl_in(esl_cmd(Block, C#{buf := Rest}));
                N when byte_size(Rest) >= N ->
                    <<Body:N/binary, Rest1/binary>> = Rest,
                    esl_in(esl_cmd(<<Block/binary, "\n\n", Body/binary>>, C#{buf := Rest1}));
                _ ->
                    C
            end
    end.

esl_cmd(Block, #{tcp := Tcp} = C) ->
    report(C, {cmd, Block}),
    [First | _] = binary:split(Block, <<"\n">>),
    case First of
        <<"connect", _/binary>> ->
            tcp(Tcp, channel_data(C)),
            C;
        <<"api ", Cmd/binary>> ->
            api(string:trim(Cmd), C);
        <<"sendmsg", _/binary>> ->
            tcp(Tcp, reply(<<"+OK">>)),
            execute(block_headers(Block), C);
        _ ->
            tcp(Tcp, reply(<<"+OK">>)),
            C
    end.

api(<<"uuid_kill ", _/binary>>, #{tcp := Tcp} = C) ->
    tcp(Tcp, api_resp(<<"+OK">>)),
    end_channel(C, <<"NORMAL_CLEARING">>, true);
api(<<"conference ", Rest/binary>>, #{tcp := Tcp} = C) ->
    tcp(Tcp, api_resp(<<"+OK">>)),
    case binary:split(Rest, <<" ">>, [global]) of
        [Room, <<"kick">>, Id] ->
            member_event(C, Room, <<"del-member">>, Id),
            C;
        _ ->
            C
    end;
api(_Cmd, #{tcp := Tcp} = C) ->
    tcp(Tcp, api_resp(<<"+OK">>)),
    C.

execute(H, C) ->
    case maps:get(<<"call-command">>, H, undefined) of
        <<"execute">> ->
            App = maps:get(<<"execute-app-name">>, H),
            Arg = maps:get(<<"execute-app-arg">>, H, <<>>),
            AppUuid = maps:get(<<"event-uuid">>, H, <<>>),
            Common = [
                {<<"Application">>, App},
                {<<"Application-Data">>, Arg},
                {<<"Application-UUID">>, AppUuid}
            ],
            event(C, <<"CHANNEL_EXECUTE">>, Common),
            app(App, Arg, Common, C);
        _ ->
            C
    end.

app(<<"answer">>, _Arg, Common, #{node := Node} = C) ->
    Sdp = sdp(<<"fs-", (maps:get(name, C))/binary>>, 40100),
    send_sip(
        Node,
        maps:get(src, C),
        resp(maps:get(invite, C), 200, <<"OK">>, maps:get(tag, C), [contact(Node)], Sdp)
    ),
    complete(C, Common, []),
    C#{answered := true};
app(<<"play_and_get_digits">>, Arg, Common, #{node := #{opts := Opts}} = C) ->
    Var = lists:nth(8, binary:split(Arg, <<" ">>, [global])),
    Digits = maps:get(digits, Opts, <<"1">>),
    complete(C, Common, [{<<"variable_", Var/binary>>, Digits}]),
    C;
app(<<"playback">>, Arg, Common, C) ->
    Extra =
        case binary:match(Arg, <<"missing">>) of
            nomatch ->
                [{<<"Application-Response">>, <<"FILE PLAYED">>}, {<<"variable_playback_ms">>, <<"1234">>}];
            _ ->
                [{<<"Application-Response">>, <<"FILE NOT FOUND">>}]
        end,
    event(C, <<"CHANNEL_EXECUTE_COMPLETE">>, Common ++ Extra),
    C;
app(<<"conference">>, Arg, _Common, #{node := #{opts := Opts}} = C) ->
    [Room | _] = binary:split(Arg, <<"@">>),
    Id = integer_to_binary(erlang:unique_integer([positive])),
    _ = maps:get(silent_conference, Opts, false) orelse member_event(C, Room, <<"add-member">>, Id),
    C;
app(_App, _Arg, Common, C) ->
    complete(C, Common, []),
    C.

member_event(C, Room, Action, Id) ->
    event(C, <<"CUSTOM">>, [
        {<<"Event-Subclass">>, <<"conference::maintenance">>},
        {<<"Action">>, Action},
        {<<"Conference-Name">>, Room},
        {<<"Member-ID">>, Id}
    ]).

complete(C, Common, Extra) ->
    event(C, <<"CHANNEL_EXECUTE_COMPLETE">>, Common ++ [{<<"Application-Response">>, <<"_none_">>} | Extra]).

event(#{tcp := undefined}, _Name, _Headers) ->
    ok;
event(#{tcp := Tcp, uuid := Uuid}, Name, Headers) ->
    Inner = iolist_to_binary([
        [<<"Event-Name: ">>, Name, <<"\n">>],
        [<<"Unique-ID: ">>, Uuid, <<"\n">>],
        [[K, <<": ">>, V, <<"\n">>] || {K, V} <- Headers],
        <<"\n">>
    ]),
    tcp(Tcp, frame(<<"text/event-plain">>, Inner)).

channel_data(#{uuid := Uuid, id := Id, node := #{port := Port}}) ->
    IdLine =
        case Id of
            undefined -> <<>>;
            _ -> <<"variable_sip_h_X-Chappe-Call: ", Id/binary, "\n">>
        end,
    <<"Content-Type: command/reply\nReply-Text: +OK\nUnique-ID: ", Uuid/binary,
        "\nChannel-Unique-ID: ", Uuid/binary, "\n", IdLine/binary,
        "variable_sip_req_host: 127.0.0.1\nvariable_sip_req_port: ",
        (integer_to_binary(Port))/binary, "\n\n">>.

report(#{node := #{parent := P}, name := Name, uuid := Uuid}, What) ->
    P ! {fake_fs, Name, Uuid, What},
    ok.

block_headers(Block) ->
    [Head | _] = binary:split(Block, <<"\n\n">>),
    [_ | Lines] = binary:split(Head, <<"\n">>, [global]),
    maps:from_list([
        {string:lowercase(K), V}
     || L <- Lines, [K, V] <- [binary:split(L, <<": ">>)]
    ]).

clen(Block) ->
    case re:run(Block, <<"(?i)content-length: *([0-9]+)">>, [{capture, all_but_first, binary}]) of
        {match, [N]} -> binary_to_integer(N);
        nomatch -> 0
    end.

tcp(undefined, _) -> ok;
tcp(Tcp, Bytes) -> _ = gen_tcp:send(Tcp, Bytes), ok.

reply(Text) ->
    <<"Content-Type: command/reply\nReply-Text: ", Text/binary, "\n\n">>.

api_resp(Body) ->
    frame(<<"api/response">>, Body).

frame(Type, Body) ->
    iolist_to_binary([
        <<"Content-Type: ">>, Type, <<"\nContent-Length: ">>,
        integer_to_binary(byte_size(Body)), <<"\n\n">>, Body
    ]).

%% ---- a bare inbound event socket ----

esl_start() ->
    Parent = self(),
    Pid = spawn(fun() ->
        {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}, {ip, {127, 0, 0, 1}}]),
        {ok, Port} = inet:port(L),
        Parent ! {esl_ready, self(), Port},
        esl_accept(L)
    end),
    receive
        {esl_ready, Pid, Port} -> {Pid, Port}
    after 2000 -> error(esl_start)
    end.

esl_stop({Pid, _}) ->
    Pid ! stop,
    ok.

esl_accept(L) ->
    case gen_tcp:accept(L, 100) of
        {ok, S} ->
            ok = inet:setopts(S, [{active, true}]),
            ok = gen_tcp:send(S, <<"Content-Type: auth/request\n\n">>),
            esl_serve(L, S, <<>>);
        {error, timeout} ->
            receive
                stop -> gen_tcp:close(L)
            after 0 -> esl_accept(L)
            end
    end.

esl_serve(L, S, Buf) ->
    receive
        {tcp, S, Data} ->
            esl_serve(L, S, esl_answer(S, <<Buf/binary, Data/binary>>));
        {tcp_closed, S} ->
            esl_accept(L);
        stop ->
            gen_tcp:close(S),
            gen_tcp:close(L)
    end.

esl_answer(S, Buf) ->
    case binary:split(Buf, <<"\n\n">>) of
        [_] ->
            Buf;
        [Block, Rest] ->
            _ =
                case Block of
                    <<"api ", _/binary>> -> gen_tcp:send(S, api_resp(<<"+OK">>));
                    _ -> gen_tcp:send(S, reply(<<"+OK">>))
                end,
            esl_answer(S, Rest)
    end.

%% ---- rtpengine ----

rtpe_start(Collector) ->
    Self = self(),
    Pid = spawn(fun() ->
        {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
        {ok, Port} = inet:port(Sock),
        Self ! {rtpe_port, self(), Port},
        rtpe_loop(Sock, Collector)
    end),
    Port =
        receive
            {rtpe_port, Pid, P} -> P
        after 2000 -> exit(no_rtpe)
        end,
    ok = chappe_sip_media:configure(#{
        rtpengine => #{nodes => [#{name => ?RTPE_NODE, host => "127.0.0.1", port => Port}]},
        mix => #{ip => {127, 0, 0, 1}}
    }),
    Pid.

rtpe_stop(Pid) ->
    _ = chappe_rtpengine:remove_node(?RTPE_NODE),
    Pid ! stop,
    ok.

rtpe_loop(Sock, Collector) ->
    receive
        {udp, Sock, Ip, Port, Packet} ->
            [Cookie, Body] = binary:split(Packet, <<" ">>),
            {ok, Cmd} = chappe_rtpengine_bencode:decode(Body),
            Collector ! {rtpe_cmd, Cmd},
            Reply = chappe_rtpengine_bencode:encode_to_binary(rtpe_reply(Cmd)),
            ok = gen_udp:send(Sock, Ip, Port, <<Cookie/binary, " ", Reply/binary>>),
            rtpe_loop(Sock, Collector);
        stop ->
            gen_udp:close(Sock)
    end.

rtpe_reply(#{<<"command">> := <<"offer">>, <<"sdp">> := Sdp} = Cmd) ->
    marked(Sdp, <<"offer">>, maps:get(<<"from-tag">>, Cmd, <<>>));
rtpe_reply(#{<<"command">> := <<"answer">>, <<"sdp">> := Sdp} = Cmd) ->
    marked(Sdp, <<"answer">>, maps:get(<<"to-tag">>, Cmd, <<>>));
rtpe_reply(_Cmd) ->
    #{<<"result">> => <<"ok">>}.

marked(Sdp, What, Tag) ->
    #{
        <<"result">> => <<"ok">>,
        <<"sdp">> => <<Sdp/binary, "a=rtpe-", What/binary, ":", Tag/binary, "\r\n">>
    }.

%% ---- a caller ----

%% INVITE the engine at EnginePort from a new UDP peer; reports to the
%% caller of ua_call/2 {ua, Ua, Event}: {final, Status, Bin}, {bye, Bin},
%% {reinvite, Bin}, rtp (the first RTP packet heard).
ua_call(EnginePort, Opts) ->
    Parent = self(),
    spawn_link(fun() ->
        {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
        {ok, Rtp} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
        {ok, RtpPort} = inet:port(Rtp),
        P = integer_to_binary(element(2, inet:port(Sock))),
        CallId = <<"ua-", (tag())/binary>>,
        FromTag = tag(),
        Ruri = maps:get(ruri, Opts, <<"sip:ivr@127.0.0.1">>),
        Inv = build(<<"INVITE">>, Ruri, [
            {<<"Via">>, <<"SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary>>},
            {<<"Max-Forwards">>, <<"70">>},
            {<<"From">>, <<"<sip:caller@127.0.0.1:", P/binary, ">;tag=", FromTag/binary>>},
            {<<"To">>, <<"<", Ruri/binary, ">">>},
            {<<"Contact">>, <<"<sip:caller@127.0.0.1:", P/binary, ">">>},
            {<<"Call-ID">>, CallId},
            {<<"CSeq">>, <<"1 INVITE">>},
            {<<"Content-Type">>, <<"application/sdp">>}
        ], sdp(<<"caller">>, RtpPort)),
        ok = gen_udp:send(Sock, {127, 0, 0, 1}, EnginePort, Inv),
        ua_wait(#{sock => Sock, rtp => Rtp, parent => Parent, engine => EnginePort,
                  invite => Inv, port => P, heard => false})
    end).

ua_bye(Ua) ->
    Ua ! bye,
    ok.

%% send G.711 to the far end of the answer for Ms
ua_rtp(Ua, Ms) ->
    Ua ! {rtp, Ms},
    ok.

%% send G.711 to To ({Ip, Port}) for Ms
ua_rtp(Ua, To, Ms) ->
    Ua ! {rtp, To, Ms},
    ok.

ua_wait(#{sock := Sock, parent := Parent, engine := EP, invite := Inv} = U) ->
    receive
        {udp, Sock, _, _, <<"SIP/2.0 1", _/binary>>} ->
            ua_wait(U);
        {udp, Sock, _, _, <<"SIP/2.0 ", Code:3/binary, _/binary>> = R} ->
            Status = binary_to_integer(Code),
            Parent ! {ua, self(), {final, Status, R}},
            case Status of
                200 ->
                    D = #{
                        to => hdr(R, <<"to">>),
                        target => contact_uri(R),
                        remote => remote_rtp(body(R))
                    },
                    ok = gen_udp:send(Sock, {127, 0, 0, 1}, EP, ua_req(<<"ACK">>, 1, U, D)),
                    ua_up(U#{dialog => D, cseq => 1});
                _ ->
                    ok = gen_udp:send(Sock, {127, 0, 0, 1}, EP, ack_failure(Inv, R)),
                    ok
            end
    after 15000 -> Parent ! {ua, self(), timeout}
    end.

ua_up(#{sock := Sock, rtp := Rtp, parent := Parent, engine := EP, dialog := D, cseq := N} = U) ->
    receive
        {udp, Sock, _, Src, <<"BYE ", _/binary>> = B} ->
            ok = gen_udp:send(Sock, {127, 0, 0, 1}, Src, resp(B, 200, <<"OK">>, <<>>, [], <<>>)),
            Parent ! {ua, self(), {bye, B}},
            ua_done(U);
        {udp, Sock, _, Src, <<"INVITE ", _/binary>> = I} ->
            Parent ! {ua, self(), {reinvite, I}},
            ok = gen_udp:send(Sock, {127, 0, 0, 1}, Src,
                              resp(I, 200, <<"OK">>, <<>>, [], sdp(<<"caller">>, element(2, inet:port(Rtp))))),
            ua_up(U);
        {udp, Sock, _, Src, <<M, _/binary>> = Req} when M >= $A, M =< $Z ->
            _ = gen_udp:send(Sock, {127, 0, 0, 1}, Src, resp(Req, 200, <<"OK">>, <<>>, [], <<>>)),
            ua_up(U);
        {udp, Sock, _, _, _} ->
            ua_up(U);
        {udp, Rtp, _, _, _} when not map_get(heard, U) ->
            Parent ! {ua, self(), rtp},
            ua_up(U#{heard := true});
        {udp, Rtp, _, _, _} ->
            ua_up(U);
        bye ->
            ok = gen_udp:send(Sock, {127, 0, 0, 1}, EP, ua_req(<<"BYE">>, N + 1, U, D)),
            ua_up(U#{cseq := N + 1});
        {rtp, Ms} ->
            send_rtp(Rtp, maps:get(remote, D), Ms),
            ua_up(U);
        {rtp, To, Ms} ->
            send_rtp(Rtp, To, Ms),
            ua_up(U)
    end.

ua_done(_U) ->
    receive
        _ -> ok
    after 2000 -> ok
    end.

ua_req(Method, N, #{port := P, invite := Inv}, #{to := To, target := T}) ->
    build(Method, T, [
        {<<"Via">>, <<"SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary>>},
        {<<"Max-Forwards">>, <<"70">>},
        {<<"From">>, hdr(Inv, <<"from">>)},
        {<<"To">>, To},
        {<<"Call-ID">>, hdr(Inv, <<"call-id">>)},
        {<<"CSeq">>, <<(integer_to_binary(N))/binary, " ", Method/binary>>}
    ], <<>>).

ack_failure(Inv, R) ->
    build(<<"ACK">>, ruri(Inv), [
        {<<"Via">>, hdr(Inv, <<"via">>)},
        {<<"Max-Forwards">>, <<"70">>},
        {<<"From">>, hdr(Inv, <<"from">>)},
        {<<"To">>, hdr(R, <<"to">>)},
        {<<"Call-ID">>, hdr(Inv, <<"call-id">>)},
        {<<"CSeq">>, <<"1 ACK">>}
    ], <<>>).

send_rtp(_Rtp, undefined, _Ms) ->
    ok;
send_rtp(Rtp, To, Ms) ->
    N = Ms div 20,
    Loud = binary:copy(<<16#10>>, 160),
    lists:foreach(
        fun(I) ->
            Pkt = <<2:2, 0:1, 0:1, 0:4, 0:1, 0:7, I:16, (I * 160):32, 4242:32, Loud/binary>>,
            _ = gen_udp:send(Rtp, To, Pkt),
            timer:sleep(20)
        end,
        lists:seq(1, N)
    ).

remote_rtp(Sdp) ->
    case
        {re:run(Sdp, <<"c=IN IP4 ([0-9.]+)">>, [{capture, all_but_first, list}]),
            re:run(Sdp, <<"m=audio ([0-9]+)">>, [{capture, all_but_first, binary}])}
    of
        {{match, [Ip]}, {match, [Port]}} ->
            {ok, A} = inet:parse_address(Ip),
            {A, binary_to_integer(Port)};
        _ ->
            undefined
    end.

%% A callee: answers INVITE 200, BYE 200, reports {callee, Event}.
callee_start(Tag) ->
    Parent = self(),
    Pid = spawn_link(fun() ->
        {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
        Parent ! {callee_ready, self(), element(2, inet:port(Sock))},
        callee_loop(Sock, Parent, Tag)
    end),
    receive
        {callee_ready, Pid, Port} -> {Pid, Port}
    after 2000 -> error(callee)
    end.

callee_loop(Sock, Parent, Tag) ->
    receive
        {udp, Sock, _, Src, <<"INVITE ", _/binary>> = I} ->
            Parent ! {callee, invite, I},
            P = integer_to_binary(element(2, inet:port(Sock))),
            C = {<<"Contact">>, <<"<sip:callee@127.0.0.1:", P/binary, ">">>},
            ok = gen_udp:send(Sock, {127, 0, 0, 1}, Src, resp(I, 200, <<"OK">>, Tag, [C], sdp(<<"callee">>, 40200))),
            callee_loop(Sock, Parent, Tag);
        {udp, Sock, _, Src, <<"BYE ", _/binary>> = B} ->
            Parent ! {callee, bye, B},
            ok = gen_udp:send(Sock, {127, 0, 0, 1}, Src, resp(B, 200, <<"OK">>, <<>>, [], <<>>)),
            callee_loop(Sock, Parent, Tag);
        {udp, Sock, _, _, _} ->
            callee_loop(Sock, Parent, Tag)
    end.

%% ---- SIP text ----

sdp(Marker, Port) ->
    P = integer_to_binary(Port),
    <<"v=0\r\no=", Marker/binary, " 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
      "t=0 0\r\nm=audio ", P/binary, " RTP/AVP 0 101\r\na=rtpmap:0 PCMU/8000\r\n"
      "a=rtpmap:101 telephone-event/8000\r\na=ptime:20\r\na=sendrecv\r\n">>.

send_sip(#{sock := Sock}, {Ip, Port}, Bin) ->
    _ = gen_udp:send(Sock, Ip, Port, Bin),
    ok.

contact(#{port := Port}) ->
    {<<"Contact">>, <<"<sip:fs@127.0.0.1:", (integer_to_binary(Port))/binary, ">">>}.

method(Bin) ->
    [M | _] = binary:split(Bin, <<" ">>),
    M.

ruri(Bin) ->
    [_, U | _] = binary:split(Bin, <<" ">>, [global]),
    U.

build(Method, RUri, Headers, Body) ->
    iolist_to_binary([
        Method, <<" ">>, RUri, <<" SIP/2.0\r\n">>,
        [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Headers],
        <<"Content-Length: ">>, integer_to_binary(byte_size(Body)), <<"\r\n\r\n">>, Body
    ]).

resp(ReqBin, Status, Reason, ToTag, Extra, Body) ->
    {ok, Msg} = chappe_sip_msg:parse(ReqBin),
    Vias = chappe_sip_msg:get_all(<<"via">>, Msg),
    To0 = chappe_sip_msg:get(<<"to">>, Msg),
    To =
        case chappe_sip_msg:to_tag(Msg) of
            undefined when Status > 100, ToTag =/= <<>> -> <<To0/binary, ";tag=", ToTag/binary>>;
            _ -> To0
        end,
    CT =
        case Body of
            <<>> -> [];
            _ -> [<<"Content-Type: application/sdp\r\n">>]
        end,
    iolist_to_binary([
        <<"SIP/2.0 ">>, integer_to_binary(Status), <<" ">>, Reason, <<"\r\n">>,
        [[<<"Via: ">>, V, <<"\r\n">>] || V <- Vias],
        <<"From: ">>, chappe_sip_msg:get(<<"from">>, Msg), <<"\r\n">>,
        <<"To: ">>, To, <<"\r\n">>,
        <<"Call-ID: ">>, chappe_sip_msg:call_id(Msg), <<"\r\n">>,
        <<"CSeq: ">>, chappe_sip_msg:get(<<"cseq">>, Msg), <<"\r\n">>,
        [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Extra],
        CT,
        <<"Content-Length: ">>, integer_to_binary(byte_size(Body)), <<"\r\n\r\n">>, Body
    ]).

hdr(Bin, Name) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    chappe_sip_msg:get(Name, M).

body(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    chappe_sip_msg:body(M).

contact_uri(Msg) ->
    {ok, #{uri := U}} = chappe_sip_hdr:name_addr(hdr(Msg, <<"contact">>)),
    U.

tag() -> binary:encode_hex(crypto:strong_rand_bytes(5), lowercase).

branch() -> <<"z9hG4bK", (tag())/binary>>.
