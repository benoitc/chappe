%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The demo's trunk: a UDP socket on 5060 that answers every OPTIONS 200
%% and logs which node sent it, so `docker compose logs -f trunk' shows
%% the pings leave from one node and move when it stops. sources/1 gives
%% the addresses seen in the last Ms milliseconds (the smoke test asks).
-module(demo_cluster_trunk).

-export([start/0, sources/1]).

-spec start() -> ok.
start() ->
    Pid = spawn(fun() ->
        {ok, Sock} = gen_udp:open(5060, [binary, {active, true}]),
        loop(Sock, [])
    end),
    true = register(?MODULE, Pid),
    io:format("trunk: answering OPTIONS on 5060~n"),
    ok.

-spec sources(non_neg_integer()) -> [string()].
sources(Ms) ->
    Ref = make_ref(),
    ?MODULE ! {sources, self(), Ref, Ms},
    receive
        {Ref, L} -> L
    after 5000 -> error(timeout)
    end.

loop(Sock, Seen) ->
    receive
        {udp, Sock, Ip, Port, <<"OPTIONS ", _/binary>> = Req} ->
            Addr = inet:ntoa(Ip),
            io:format("trunk: OPTIONS from ~s~n", [Addr]),
            ok = gen_udp:send(Sock, Ip, Port, ok(Req)),
            Now = erlang:monotonic_time(millisecond),
            loop(Sock, [{Now, Addr} | lists:sublist(Seen, 500)]);
        {sources, From, Ref, Ms} ->
            Since = erlang:monotonic_time(millisecond) - Ms,
            From ! {Ref, lists:usort([A || {T, A} <- Seen, T >= Since])},
            loop(Sock, Seen);
        _ ->
            loop(Sock, Seen)
    end.

%% 200 to a request: its Via, From, To (tagged), Call-ID and CSeq back
ok(Req) ->
    [Head | _] = binary:split(Req, <<"\r\n\r\n">>),
    [_ | Lines] = binary:split(Head, <<"\r\n">>, [global]),
    Keep = [
        tag_to(L)
     || L <- Lines,
        lists:member(name(L), [<<"via">>, <<"from">>, <<"to">>, <<"call-id">>, <<"cseq">>])
    ],
    iolist_to_binary([
        <<"SIP/2.0 200 OK\r\n">>,
        [[L, <<"\r\n">>] || L <- Keep],
        <<"Content-Length: 0\r\n\r\n">>
    ]).

name(Line) ->
    string:lowercase(string:trim(hd(binary:split(Line, <<":">>)))).

tag_to(Line) ->
    case name(Line) of
        <<"to">> ->
            case binary:match(Line, <<"tag=">>) of
                nomatch -> <<Line/binary, ";tag=trunk">>;
                _ -> Line
            end;
        _ ->
            Line
    end.
