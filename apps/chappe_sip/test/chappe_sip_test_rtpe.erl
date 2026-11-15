%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% A fake rtpengine NG node over UDP for the B2BUA suites. It answers
%% offer and answer with the SDP it got plus a marker line naming the
%% command and the tag rtpengine would key it by:
%%   a=rtpe-offer:<from-tag>    a=rtpe-answer:<to-tag>
%% and, for a command with a via-branch (one offer per fork profile),
%%   a=rtpe-via:<via-branch>
%% so a case sees which SDP went through the anchor, and every command
%% reaches the collector as {rtpe_cmd, Dict}. A command carrying x-fail
%% gets an error.
-module(chappe_sip_test_rtpe).

-export([start/1, stop/1, configure/1, marked/2]).

-define(NODE, chappe_sip_test_rtpe).

%% Start the node and point chappe_sip_media at it.
start(Collector) ->
    Self = self(),
    Pid = spawn(fun() ->
        {ok, Sock} = gen_udp:open(0, [binary, {active, true},
                                      {ip, {127, 0, 0, 1}}]),
        {ok, Port} = inet:port(Sock),
        Self ! {rtpe_port, self(), Port},
        loop(Sock, Collector)
    end),
    Port = receive {rtpe_port, Pid, P} -> P after 2000 -> exit(no_rtpe) end,
    ok = configure(Port),
    Pid.

configure(Port) ->
    chappe_sip_media:configure(
      #{rtpengine => #{nodes => [#{name => ?NODE, host => "127.0.0.1",
                                    port => Port}]}}).

stop(Pid) ->
    _ = chappe_rtpengine:remove_node(?NODE),
    Pid ! stop,
    ok.

%% Whether Sdp went through the fake's Command (offer | answer).
marked(Sdp, Command) ->
    Tag = <<"a=rtpe-", (atom_to_binary(Command))/binary, ":">>,
    binary:match(Sdp, Tag) =/= nomatch.

loop(Sock, Collector) ->
    receive
        {udp, Sock, Ip, Port, Packet} ->
            [Cookie, Body] = binary:split(Packet, <<" ">>),
            {ok, Cmd} = chappe_rtpengine_bencode:decode(Body),
            Collector ! {rtpe_cmd, Cmd},
            Reply = chappe_rtpengine_bencode:encode_to_binary(reply(Cmd)),
            ok = gen_udp:send(Sock, Ip, Port, <<Cookie/binary, " ", Reply/binary>>),
            loop(Sock, Collector);
        stop ->
            gen_udp:close(Sock)
    end.

reply(#{<<"x-fail">> := _}) ->
    #{<<"result">> => <<"error">>, <<"error-reason">> => <<"x-fail">>};
reply(#{<<"command">> := <<"offer">>, <<"sdp">> := Sdp} = Cmd) ->
    ok(via(Sdp, Cmd), <<"offer">>, maps:get(<<"from-tag">>, Cmd, <<>>));
reply(#{<<"command">> := <<"answer">>, <<"sdp">> := Sdp} = Cmd) ->
    ok(via(Sdp, Cmd), <<"answer">>, maps:get(<<"to-tag">>, Cmd, <<>>));
reply(#{<<"command">> := <<"subscribe request">>} = Cmd) ->
    %% one sendonly PCMU m-line per tapped party, at a port of its own,
    %% marked with the party's tag
    Tags = maps:get(<<"from-tags">>, Cmd, [<<"all">>]),
    N = erlang:unique_integer([positive]),
    Media = [
        [<<"m=audio ">>, integer_to_binary(20000 + (N rem 10000) * 2),
         <<" RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\na=sendonly\r\na=rtpe-sub:">>,
         T, <<"\r\n">>]
     || T <- Tags
    ],
    #{<<"result">> => <<"ok">>,
      <<"to-tag">> => <<"sub-", (integer_to_binary(N))/binary>>,
      <<"sdp">> => iolist_to_binary([
          <<"v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n">>,
          Media
      ])};
reply(_Cmd) ->
    #{<<"result">> => <<"ok">>}.

via(Sdp, #{<<"via-branch">> := V}) -> <<Sdp/binary, "a=rtpe-via:", V/binary, "\r\n">>;
via(Sdp, _Cmd) -> Sdp.

ok(Sdp, What, Tag) ->
    #{<<"result">> => <<"ok">>,
      <<"sdp">> => <<Sdp/binary, "a=rtpe-", What/binary, ":", Tag/binary, "\r\n">>}.
