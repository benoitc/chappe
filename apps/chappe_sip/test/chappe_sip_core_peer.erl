%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% A raw UDP SIP peer for the RFC 3261 core suites: build requests and
%% responses as bytes, send them, and read what chappe puts on the wire.
%% The socket is active, so the process that opened it receives.
-module(chappe_sip_core_peer).

-export([open/0, open/1, port/1, close/1, send/3, send/4]).
-export([recv/3, recv_none/3, collect/3, drain/1]).
-export([request/3, response/3, ack_for/2]).
-export([parse/1, hdr/2, hdrs/2, status/1, method/1, uri/1, cseq/1,
         to_tag/1, from_tag/1, body/1, top_via/1, via_branch/1]).
-export([branch/0, tag/0, call_id/0, sdp/0, sdp/1, contact/1]).
-export([tcp_listen/1, tcp_recv/2, repeated_uri_params/1]).

-define(LO, {127, 0, 0, 1}).

%% ---- socket ----

open() -> open(0).

open(Port) ->
    {ok, S} = gen_udp:open(Port, [binary, {active, true}, {ip, ?LO},
                                  {recbuf, 262144}, {sndbuf, 262144}]),
    S.

port(Sock) ->
    {ok, P} = inet:port(Sock),
    P.

close(Sock) -> gen_udp:close(Sock).

send(Sock, Port, Bin) -> send(Sock, ?LO, Port, Bin).

send(Sock, Ip, Port, Bin) -> ok = gen_udp:send(Sock, Ip, Port, Bin).

%% The first datagram matching What: {status, Code}, {method, M}, any, or a
%% fun(Bin) -> boolean(). Others are dropped. Returns {Bin, SrcPort}. On a
%% timeout the failure names the start lines of what was dropped, so a
%% wrong answer is told apart from no answer.
recv(Sock, What, Timeout) ->
    Deadline = now_ms() + Timeout,
    recv_until(Sock, matcher(What), Deadline, What, []).

recv_until(Sock, Match, Deadline, What, Dropped) ->
    Left = max(0, Deadline - now_ms()),
    receive
        {udp, Sock, _Ip, Src, Bin} ->
            case Match(Bin) of
                true ->
                    {Bin, Src};
                false ->
                    recv_until(
                        Sock, Match, Deadline, What, [start_line(Bin) | Dropped]
                    )
            end
    after Left -> ct:fail({no_message, What, {dropped, lists:reverse(Dropped)}})
    end.

start_line(Bin) ->
    [Line | _] = binary:split(Bin, <<"\r\n">>),
    Line.

%% Assert that nothing matching What arrives within Timeout ms.
recv_none(Sock, What, Timeout) ->
    Match = matcher(What),
    Deadline = now_ms() + Timeout,
    none_until(Sock, Match, Deadline, What).

none_until(Sock, Match, Deadline, What) ->
    Left = max(0, Deadline - now_ms()),
    receive
        {udp, Sock, _Ip, _Src, Bin} ->
            case Match(Bin) of
                true -> ct:fail({unexpected, What, Bin});
                false -> none_until(Sock, Match, Deadline, What)
            end
    after Left -> ok
    end.

%% Every datagram matching What for Duration ms, as [{MonotonicMs, Bin}].
collect(Sock, What, Duration) ->
    Match = matcher(What),
    Deadline = now_ms() + Duration,
    collect_until(Sock, Match, Deadline, []).

collect_until(Sock, Match, Deadline, Acc) ->
    Left = max(0, Deadline - now_ms()),
    receive
        {udp, Sock, _Ip, _Src, Bin} ->
            Acc1 = case Match(Bin) of
                       true -> [{now_ms(), Bin} | Acc];
                       false -> Acc
                   end,
            collect_until(Sock, Match, Deadline, Acc1)
    after Left -> lists:reverse(Acc)
    end.

drain(Sock) ->
    receive {udp, Sock, _, _, _} -> drain(Sock)
    after 0 -> ok
    end.

matcher(any) -> fun(_) -> true end;
matcher(F) when is_function(F, 1) -> F;
matcher({status, Code}) ->
    C = integer_to_binary(Code),
    fun(<<"SIP/2.0 ", S:3/binary, _/binary>>) -> S =:= C;
       (_) -> false
    end;
matcher({status, Code, Method}) ->
    M1 = matcher({status, Code}),
    fun(B) -> M1(B) andalso cseq_method(B) =:= Method end;
matcher(final) ->
    fun(<<"SIP/2.0 ", S:1/binary, _/binary>>) -> S =/= <<"1">>;
       (_) -> false
    end;
matcher({method, M}) ->
    L = byte_size(M),
    fun(<<X:L/binary, " ", _/binary>>) -> X =:= M;
       (_) -> false
    end.

cseq_method(Bin) ->
    case cseq(Bin) of
        {_, M} -> M;
        _ -> undefined
    end.

now_ms() -> erlang:monotonic_time(millisecond).

%% ---- TCP ----

%% A passive TCP listener on loopback at Port (0 for any).
tcp_listen(Port) ->
    {ok, L} = gen_tcp:listen(Port, [binary, {active, false}, {ip, ?LO},
                                    {reuseaddr, true}]),
    L.

%% One SIP message off a passive TCP socket, framed by its Content-Length
%% (none means the head alone). Returns the message or {error, Reason}.
tcp_recv(Sock, Timeout) ->
    tcp_recv(Sock, <<>>, now_ms() + Timeout).

tcp_recv(Sock, Buf, Deadline) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [Head, Tail] ->
            Len = case re:run(Head, "\r\n(Content-Length|l)[ \t]*:[ \t]*([0-9]+)",
                              [caseless, {capture, [2], binary}]) of
                      {match, [L]} -> binary_to_integer(L);
                      nomatch -> 0
                  end,
            case Tail of
                <<Body:Len/binary, _/binary>> ->
                    <<Head/binary, "\r\n\r\n", Body/binary>>;
                _ -> tcp_more(Sock, Buf, Deadline)
            end;
        _ ->
            tcp_more(Sock, Buf, Deadline)
    end.

tcp_more(Sock, Buf, Deadline) ->
    case gen_tcp:recv(Sock, 0, max(0, Deadline - now_ms())) of
        {ok, D} -> tcp_recv(Sock, <<Buf/binary, D/binary>>, Deadline);
        {error, _} = E -> E
    end.

%% ---- building ----

%% A request from this peer. Opts: port (our port, for Via/From/Contact),
%% branch, call_id, from_tag, to_tag, cseq, from, to, contact, via
%% (full Via value), headers ([{N, V}] appended), body, content_type,
%% max_forwards (false to omit), omit ([lowercase header names]).
request(Method, RUri, Opts) ->
    P = integer_to_binary(maps:get(port, Opts, 5060)),
    Branch = maps:get(branch, Opts, branch()),
    Via = maps:get(via, Opts,
                   <<"SIP/2.0/UDP 127.0.0.1:", P/binary, ";branch=",
                     Branch/binary>>),
    FromTag = maps:get(from_tag, Opts, tag()),
    From0 = maps:get(from, Opts, <<"<sip:peer@127.0.0.1:", P/binary, ">">>),
    From = case FromTag of
               none -> From0;
               _ -> <<From0/binary, ";tag=", FromTag/binary>>
           end,
    To0 = maps:get(to, Opts, <<"<", RUri/binary, ">">>),
    To = case maps:get(to_tag, Opts, undefined) of
             undefined -> To0;
             T -> <<To0/binary, ";tag=", T/binary>>
         end,
    CSeq = integer_to_binary(maps:get(cseq, Opts, 1)),
    CSeqMethod = maps:get(cseq_method, Opts, Method),
    Contact = maps:get(contact, Opts,
                       <<"<sip:peer@127.0.0.1:", P/binary, ">">>),
    Body = maps:get(body, Opts, <<>>),
    CT = case {Body, maps:get(content_type, Opts, undefined)} of
             {<<>>, undefined} -> [];
             {_, undefined} -> [{<<"Content-Type">>, <<"application/sdp">>}];
             {_, C} -> [{<<"Content-Type">>, C}]
         end,
    MF = case maps:get(max_forwards, Opts, 70) of
             false -> [];
             N -> [{<<"Max-Forwards">>, integer_to_binary(N)}]
         end,
    Base = [{<<"Via">>, Via}] ++ MF ++
        [{<<"From">>, From}, {<<"To">>, To},
         {<<"Call-ID">>, maps:get(call_id, Opts, call_id())},
         {<<"CSeq">>, <<CSeq/binary, " ", CSeqMethod/binary>>}] ++
        [{<<"Contact">>, Contact} || Contact =/= none] ++
        maps:get(headers, Opts, []) ++ CT,
    Omit = maps:get(omit, Opts, []),
    Hdrs = [{N, V} || {N, V} <- Base,
                      not lists:member(string:lowercase(N), Omit)],
    CL = case maps:get(content_length, Opts, undefined) of
             undefined -> integer_to_binary(byte_size(Body));
             L -> integer_to_binary(L)
         end,
    iolist_to_binary(
      [Method, " ", RUri, " SIP/2.0\r\n",
       [[N, ": ", V, "\r\n"] || {N, V} <- Hdrs],
       "Content-Length: ", CL, "\r\n\r\n", Body]).

%% A response to ReqBin echoing Via (all, in order), From, To, Call-ID and
%% CSeq. Opts: reason, to_tag (added when the request To has none and the
%% status is above 100), headers, body, content_type.
response(ReqBin, Status, Opts) ->
    M = parse(ReqBin),
    To0 = hdr(<<"to">>, M),
    To = case {chappe_sip_msg:to_tag(M), maps:get(to_tag, Opts, undefined)} of
             {undefined, T} when T =/= undefined, Status > 100 ->
                 <<To0/binary, ";tag=", T/binary>>;
             _ -> To0
         end,
    Body = maps:get(body, Opts, <<>>),
    CT = case {Body, maps:get(content_type, Opts, undefined)} of
             {<<>>, _} -> [];
             {_, undefined} -> [{<<"Content-Type">>, <<"application/sdp">>}];
             {_, C} -> [{<<"Content-Type">>, C}]
         end,
    Vias = maps:get(vias, Opts, hdrs(<<"via">>, M)),
    iolist_to_binary(
      [<<"SIP/2.0 ">>, integer_to_binary(Status), " ",
       maps:get(reason, Opts, reason(Status)), "\r\n",
       [[<<"Via: ">>, V, "\r\n"] || V <- Vias],
       "From: ", hdr(<<"from">>, M), "\r\n",
       "To: ", To, "\r\n",
       "Call-ID: ", hdr(<<"call-id">>, M), "\r\n",
       "CSeq: ", hdr(<<"cseq">>, M), "\r\n",
       [[N, ": ", V, "\r\n"] || {N, V} <- maps:get(headers, Opts, []) ++ CT],
       "Content-Length: ", integer_to_binary(byte_size(Body)), "\r\n\r\n",
       Body]).

%% An ACK for a 2xx we received as the UAC peer (a new transaction).
ack_for(Resp, Opts) ->
    M = parse(Resp),
    {N, _} = cseq(Resp),
    RUri = case hdr(<<"contact">>, M) of
               undefined -> <<"sip:app@127.0.0.1">>;
               C -> contact_uri(C)
           end,
    P = integer_to_binary(maps:get(port, Opts, 5060)),
    iolist_to_binary(
      [<<"ACK ">>, RUri, " SIP/2.0\r\n",
       "Via: SIP/2.0/UDP 127.0.0.1:", P, ";branch=", branch(), "\r\n",
       "Max-Forwards: 70\r\n",
       "From: ", hdr(<<"from">>, M), "\r\n",
       "To: ", hdr(<<"to">>, M), "\r\n",
       "Call-ID: ", hdr(<<"call-id">>, M), "\r\n",
       "CSeq: ", integer_to_binary(N), " ACK\r\n",
       [[H, ": ", V, "\r\n"] || {H, V} <- maps:get(headers, Opts, [])],
       "Content-Length: ", integer_to_binary(byte_size(maps:get(body, Opts, <<>>))),
       "\r\n\r\n", maps:get(body, Opts, <<>>)]).

contact_uri(C) ->
    case chappe_sip_hdr:name_addr(C) of
        {ok, #{uri := U}} -> U;
        _ -> C
    end.

reason(100) -> <<"Trying">>;
reason(180) -> <<"Ringing">>;
reason(183) -> <<"Session Progress">>;
reason(200) -> <<"OK">>;
reason(481) -> <<"Call/Transaction Does Not Exist">>;
reason(486) -> <<"Busy Here">>;
reason(487) -> <<"Request Terminated">>;
reason(_) -> <<"Whatever">>.

%% ---- reading ----

parse(Bin) when is_binary(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    M;
parse(M) -> M.

hdr(Name, X) -> chappe_sip_msg:get(Name, parse(X)).
hdrs(Name, X) -> chappe_sip_msg:get_all(Name, parse(X)).
status(X) -> chappe_sip_msg:status(parse(X)).
method(X) -> chappe_sip_msg:method(parse(X)).
uri(X) -> chappe_sip_msg:uri(parse(X)).
body(X) -> chappe_sip_msg:body(parse(X)).
to_tag(X) -> chappe_sip_msg:to_tag(parse(X)).
from_tag(X) -> chappe_sip_msg:from_tag(parse(X)).

cseq(X) ->
    case chappe_sip_msg:cseq(parse(X)) of
        {ok, #{seq := N, method := M}} -> {N, M};
        _ -> undefined
    end.

%% The top Via value (a Via header may carry several comma separated).
top_via(X) ->
    case hdrs(<<"via">>, X) of
        [] -> undefined;
        [V | _] -> hd(binary:split(V, <<",">>))
    end.

via_branch(Via) ->
    case re:run(Via, "branch=([^;,\\s]+)", [{capture, all_but_first, binary}]) of
        {match, [B]} -> B;
        nomatch -> undefined
    end.

%% the uri-parameter names that appear more than once in Uri
repeated_uri_params(Uri) ->
    [NoHeaders | _] = binary:split(Uri, <<"?">>),
    [_ | Params] = binary:split(NoHeaders, <<";">>, [global]),
    Names = [string:lowercase(hd(binary:split(P, <<"=">>))) || P <- Params],
    lists:usort(Names -- lists:usort(Names)).

%% ---- values ----

branch() ->
    <<"z9hG4bK", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>.

tag() -> binary:encode_hex(crypto:strong_rand_bytes(5), lowercase).

call_id() ->
    <<(binary:encode_hex(crypto:strong_rand_bytes(6)))/binary, "@core">>.

sdp() -> sdp(40000).

sdp(Port) ->
    <<"v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
      "t=0 0\r\nm=audio ", (integer_to_binary(Port))/binary,
      " RTP/AVP 0\r\n">>.

contact(Port) -> <<"sip:127.0.0.1:", (integer_to_binary(Port))/binary>>.
