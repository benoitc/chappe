%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% A throwaway SIP user agent over raw UDP, just enough to put a test
%% endpoint into a FreeSWITCH conference: INVITE with a PCMU SDP, wait out
%% the provisionals, ACK the 200, answer whatever FreeSWITCH sends inside
%% the dialog with a 200, and BYE on hangup. Test-only: no auth, no TCP,
%% no forking, no timers beyond INVITE and BYE retransmission.
%%
%% Every request goes to the configured host and port, whatever the
%% Contact says: FreeSWITCH in docker advertises its container address,
%% which the host cannot reach, while the published port is on loopback.
%% For the same reason Via, Contact and the SDP carry `advertise', the
%% address the container reaches this machine at, and Via asks for rport
%% so responses follow the source address instead.
-module(chappe_mix_sip_ua).

-export([call/1, hangup/1]).

-define(T1, 500).

%% Opts: host (inet:ip_address()), port, user (binary, the request-URI
%% user, e.g. <<"conf-x">>), advertise (binary, an IPv4 address),
%% rtp_port, timeout (ms for the whole INVITE transaction, default
%% 30000). Returns the call process and the far end's media address as
%% written in its SDP.
call(Opts) ->
    Parent = self(),
    Pid = spawn_link(fun() -> init(Parent, Opts) end),
    Timeout = maps:get(timeout, Opts, 30000),
    receive
        {Pid, answered, Media} -> {ok, Pid, Media};
        {Pid, failed, Reason} -> {error, Reason}
    after Timeout + 2000 ->
        unlink(Pid),
        exit(Pid, kill),
        {error, timeout}
    end.

hangup(Pid) ->
    Ref = monitor(process, Pid),
    Pid ! {hangup, self()},
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 10000 ->
        exit(Pid, kill),
        ok
    end.

%% ---- call process ----

init(Parent, Opts) ->
    {ok, Sock} = gen_udp:open(0, [binary, {ip, {0, 0, 0, 0}}, {active, true}]),
    {ok, SipPort} = inet:port(Sock),
    Tag = hex(4),
    D = #{
        parent => Parent,
        sock => Sock,
        host => maps:get(host, Opts),
        port => maps:get(port, Opts),
        user => maps:get(user, Opts),
        adv => maps:get(advertise, Opts),
        sip_port => SipPort,
        rtp_port => maps:get(rtp_port, Opts),
        call_id => <<(hex(8))/binary, "@chappe-mix-test">>,
        from_tag => Tag,
        to_tag => undefined,
        cseq => 1
    },
    Branch = branch(),
    Invite = invite(D, Branch),
    send(D, Invite),
    Deadline =
        erlang:monotonic_time(millisecond) + maps:get(timeout, Opts, 30000),
    inviting(D#{invite => Invite, branch => Branch}, ?T1, Deadline).

inviting(D, Rto, Deadline) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    receive
        {udp, _, _, _, Pkt} ->
            case parse(Pkt) of
                {response, Code, _, _} when Code < 200 ->
                    %% provisional: stop retransmitting, keep waiting
                    inviting(D, infinity, Deadline);
                {response, Code, H, Body} when Code < 300 ->
                    D1 = D#{to_tag => tag(hdr(<<"to">>, H))},
                    D2 = D1#{contact => contact_uri(hdr(<<"contact">>, H))},
                    send(D2, ack(D2)),
                    maps:get(parent, D) ! {self(), answered, sdp_media(Body)},
                    dialog(D2);
                {response, Code, H, _} ->
                    D1 = D#{to_tag => tag(hdr(<<"to">>, H))},
                    send(D1, ack_failure(D1)),
                    maps:get(parent, D) ! {self(), failed, {status, Code}};
                _ ->
                    inviting(D, Rto, Deadline)
            end
    after min(Rto, max(0, Left)) ->
        case Left =< 0 of
            true ->
                maps:get(parent, D) ! {self(), failed, timeout};
            false ->
                send(D, maps:get(invite, D)),
                inviting(D, min(Rto * 2, 4000), Deadline)
        end
    end.

dialog(D) ->
    receive
        {udp, _, _, _, Pkt} ->
            case parse(Pkt) of
                {response, Code, _, _} when Code >= 200, Code < 300 ->
                    %% a retransmitted 200 to the INVITE: our ACK was lost
                    send(D, ack(D)),
                    dialog(D);
                {request, <<"BYE">>, H, _} ->
                    send(D, reply(H, 200, <<>>)),
                    ok;
                {request, <<"ACK">>, _, _} ->
                    dialog(D);
                {request, <<"INVITE">>, H, _} ->
                    send(D, reply(H, 200, sdp(D))),
                    dialog(D);
                {request, _, H, _} ->
                    send(D, reply(H, 200, <<>>)),
                    dialog(D);
                _ ->
                    dialog(D)
            end;
        {hangup, _From} ->
            D1 = D#{cseq => 2},
            Bye = bye(D1, branch()),
            send(D1, Bye),
            bye_wait(D1, Bye, ?T1, 7)
    end.

bye_wait(_D, _Bye, _Rto, 0) ->
    ok;
bye_wait(D, Bye, Rto, N) ->
    receive
        {udp, _, _, _, Pkt} ->
            case parse(Pkt) of
                {response, Code, H, _} when Code >= 200 ->
                    case cseq_method(H) of
                        <<"BYE">> -> ok;
                        _ -> bye_wait(D, Bye, Rto, N)
                    end;
                {request, <<"BYE">>, H, _} ->
                    send(D, reply(H, 200, <<>>)),
                    ok;
                _ ->
                    bye_wait(D, Bye, Rto, N)
            end
    after Rto ->
        send(D, Bye),
        bye_wait(D, Bye, min(Rto * 2, 4000), N - 1)
    end.

send(#{sock := S, host := H, port := P}, Msg) ->
    ok = gen_udp:send(S, H, P, Msg).

%% ---- messages ----

invite(D, Branch) ->
    Body = sdp(D),
    request(
        <<"INVITE">>,
        ruri(D),
        D,
        Branch,
        1,
        [
            {<<"Contact">>, contact(D)},
            {<<"Content-Type">>, <<"application/sdp">>}
        ],
        Body
    ).

ack(D) ->
    request(<<"ACK">>, maps:get(contact, D, ruri(D)), D, branch(), 1, [], <<>>).

%% ACK for a failure response reuses the INVITE branch (same transaction).
ack_failure(D) ->
    request(<<"ACK">>, ruri(D), D, maps:get(branch, D), 1, [], <<>>).

bye(D, Branch) ->
    request(
        <<"BYE">>,
        maps:get(contact, D, ruri(D)),
        D,
        Branch,
        maps:get(cseq, D),
        [],
        <<>>
    ).

request(Method, Ruri, D, Branch, CSeq, Extra, Body) ->
    #{adv := Adv, sip_port := SP, call_id := CallId, from_tag := FT} = D,
    To =
        case maps:get(to_tag, D) of
            undefined -> [<<"<">>, ruri(D), <<">">>];
            TT -> [<<"<">>, ruri(D), <<">;tag=">>, TT]
        end,
    Headers =
        [
            {<<"Via">>, [
                <<"SIP/2.0/UDP ">>,
                Adv,
                <<":">>,
                integer_to_binary(SP),
                <<";rport;branch=">>,
                Branch
            ]},
            {<<"Max-Forwards">>, <<"70">>},
            {<<"From">>, [<<"<sip:mixtest@">>, Adv, <<">;tag=">>, FT]},
            {<<"To">>, To},
            {<<"Call-ID">>, CallId},
            {<<"CSeq">>, [integer_to_binary(CSeq), <<" ">>, Method]},
            {<<"User-Agent">>, <<"chappe-mix-test">>}
        ] ++ Extra ++
            [{<<"Content-Length">>, integer_to_binary(byte_size(Body))}],
    iolist_to_binary([
        Method,
        <<" ">>,
        Ruri,
        <<" SIP/2.0\r\n">>,
        [[K, <<": ">>, V, <<"\r\n">>] || {K, V} <- Headers],
        <<"\r\n">>,
        Body
    ]).

reply(H, Code, Body) ->
    Copy = [
        {K, V}
     || {K, V} <- H,
        lists:member(K, [
            <<"via">>, <<"from">>, <<"to">>, <<"call-id">>, <<"cseq">>
        ])
    ],
    Ct =
        case Body of
            <<>> -> [];
            _ -> [<<"Content-Type: application/sdp\r\n">>]
        end,
    iolist_to_binary([
        <<"SIP/2.0 ">>,
        integer_to_binary(Code),
        <<" OK\r\n">>,
        [[K, <<": ">>, V, <<"\r\n">>] || {K, V} <- Copy],
        Ct,
        <<"Content-Length: ">>,
        integer_to_binary(byte_size(Body)),
        <<"\r\n\r\n">>,
        Body
    ]).

ruri(#{user := U, host := H, port := P}) ->
    iolist_to_binary([
        <<"sip:">>, U, <<"@">>, inet:ntoa(H), <<":">>, integer_to_binary(P)
    ]).

contact(#{adv := Adv, sip_port := SP}) ->
    [<<"<sip:mixtest@">>, Adv, <<":">>, integer_to_binary(SP), <<">">>].

sdp(#{adv := Adv, rtp_port := RP}) ->
    iolist_to_binary([
        <<"v=0\r\no=- 1 1 IN IP4 ">>,
        Adv,
        <<"\r\ns=mix\r\nc=IN IP4 ">>,
        Adv,
        <<"\r\nt=0 0\r\nm=audio ">>,
        integer_to_binary(RP),
        <<" RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\na=ptime:20\r\na=sendrecv\r\n">>
    ]).

%% ---- parsing ----

parse(Pkt) ->
    case binary:split(Pkt, <<"\r\n\r\n">>) of
        [Head, Body] ->
            [First | Lines] = binary:split(Head, <<"\r\n">>, [global]),
            H = [header(L) || L <- Lines, binary:match(L, <<":">>) =/= nomatch],
            first_line(binary:split(First, <<" ">>, [global]), H, Body);
        _ ->
            garbage
    end.

first_line([<<"SIP/2.0">>, Code | _], H, Body) ->
    {response, binary_to_integer(Code), H, Body};
first_line([Method, _Uri, <<"SIP/2.0">>], H, Body) ->
    {request, Method, H, Body};
first_line(_, _, _) ->
    garbage.

header(Line) ->
    [K, V] = binary:split(Line, <<":">>),
    {long_name(string:lowercase(string:trim(K))), string:trim(V)}.

long_name(<<"v">>) -> <<"via">>;
long_name(<<"f">>) -> <<"from">>;
long_name(<<"t">>) -> <<"to">>;
long_name(<<"i">>) -> <<"call-id">>;
long_name(<<"m">>) -> <<"contact">>;
long_name(<<"l">>) -> <<"content-length">>;
long_name(<<"c">>) -> <<"content-type">>;
long_name(K) -> K.

hdr(K, H) ->
    proplists:get_value(K, H, <<>>).

cseq_method(H) ->
    case binary:split(hdr(<<"cseq">>, H), <<" ">>) of
        [_, M] -> string:trim(M);
        _ -> <<>>
    end.

tag(V) ->
    case binary:split(V, <<";tag=">>) of
        [_, Rest] -> hd(binary:split(Rest, <<";">>));
        _ -> undefined
    end.

contact_uri(V) ->
    case binary:split(V, <<"<">>) of
        [_, Rest] -> hd(binary:split(Rest, <<">">>));
        _ -> undefined
    end.

%% The media address in an SDP body, as {IpText, Port}.
sdp_media(Body) ->
    Lines = binary:split(Body, [<<"\r\n">>, <<"\n">>], [global]),
    Ip = hd([I || <<"c=IN IP4 ", I/binary>> <- Lines] ++ [undefined]),
    Port = hd(
        [
            binary_to_integer(hd(binary:split(R, <<" ">>)))
         || <<"m=audio ", R/binary>> <- Lines
        ] ++ [undefined]
    ),
    #{ip => Ip, port => Port, sdp => Body}.

branch() ->
    <<"z9hG4bK", (hex(6))/binary>>.

hex(N) ->
    binary:encode_hex(crypto:strong_rand_bytes(N), lowercase).
