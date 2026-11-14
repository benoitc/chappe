%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The chappe side of the conformance lab: a small application on the
%% public chappe_sip API that SIPp and pjsua talk to. It behaves like a
%% plain endpoint and leaves every protocol decision it can to the stack,
%% so a scenario measures chappe_sip, not this module. The Request-URI user
%% picks what the application does with an INVITE:
%%
%%   uas (any other user)  answer with SDP, wait for the end of the call
%%   ringing               send 180 and never answer (an early dialog)
%%   slow                  answer after 1 s
%%   byer                  answer, then hang up after the ACK, with Reason
%%   glare                 answer, then send a re-INVITE after the ACK
%%   b2b, b2b-c, b2b-uas   bridge as a B2BUA (create_b2bua/4) to pjsua
%%                         agent b (10.253.7.21), agent c (10.253.7.22) or
%%                         this node's uas, media anchored and transfer
%%                         => auto: a REFER from either leg is carried out
%%                         by the B2BUA (RFC 5589 flows). The anchor is a
%%                         stand-in NG server in this node that hands each
%%                         SDP back as it came: the lab checks signalling,
%%                         the SBC lab media through a real rtpengine.
%%
%% A REFER inside a call is accepted with chappe_sip:accept_refer/4: the
%% node dials the target (with its Replaces, for an attended transfer) and
%% reports the outcome, as the REFER guide shows.
%%
%% An INVITE with Replaces goes through chappe_sip:find_replaced/1 with the
%% response rules of the answer-calls guide. SUBSCRIBE serves the
%% `conference' package (RFC 6665), and, on a stack that has them,
%% `presence' (RFC 3856, with the PUBLISHes of RFC 3903 as its state) and
%% `message-summary' (RFC 3842); any other package gets 489. A MESSAGE to
%% `mwi' whose body is `Account New Old' sets that account's voice
%% messages.
%%
%% A MESSAGE to `dial' sends an OPTIONS to the URI in its body and answers
%% with the status that OPTIONS got (480 when it got none): the dns_* cases
%% use it to make the node resolve a domain through the lab's DNS server
%% (RFC 3263). With the lab's certificates in /certs the node also listens
%% for TLS on 5061, so it can reach a sips: URI.
%%
%% With CHAPPE_HEP=Ip:Port in its environment the node sends a HEPv3 copy
%% of every message to that capture server (heplify-server in the lab) and
%% also listens for SIP over WebSocket on 5066. hep_calls/1 is the other
%% side of that case: run in a second container, it makes one call to the
%% node over each of UDP, TCP, TLS and WebSocket.
%%
%% Every event is printed on stdout, which the suite collects.
-module(chappe_conf_node).

-export([start/1, hep_calls/1]).
%% the WebSocket client of hep_calls/1
-export([init/2, handle_in/2, handle_info/2, terminate/2]).

-define(PACKAGES, [<<"conference">>]).

-spec start(string()) -> ok.
start(Ip) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Contact = iolist_to_binary(["sip:", Ip, ":5060"]),
    ok = chappe_sip:start(maps:merge(#{contact => Contact},
                                     maps:merge(tls(Ip), hep()))),
    IpBin = list_to_binary(Ip),
    persistent_term:put({?MODULE, ip}, IpBin),
    ok = chappe_sip:invite(fun(Req, Res) -> invite(IpBin, Req, Res) end),
    %% no OPTIONS handler: the stack's own answer is what the scenario checks
    ok = subscribe_handler(),
    ok = events(),
    ok = chappe_sip:message(fun message/2),
    ok = fake_rtpengine(),
    log("chappe_conf_node up on ~s", [Contact]),
    ok.

%% ---- INVITE ----

invite(Ip, Req, Res) ->
    log("INVITE ~s ~s", [chappe_sip_req:uri(Req), chappe_sip_req:call_id(Req)]),
    case {chappe_sip:find_replaced(Req), b2b_target(user(Req), Ip)} of
        {{error, no_replaces}, {ok, Target}} ->
            b2b(Target, Req, Res);
        {{error, no_replaces}, none} ->
            answer(user(Req), Ip, Req, Res);
        {Found, _} ->
            replaces(Found, Ip, Req, Res)
    end.

b2b_target(<<"b2b">>, _Ip) -> {ok, <<"sip:b@10.253.7.21:5060">>};
b2b_target(<<"b2b-c">>, _Ip) -> {ok, <<"sip:c@10.253.7.22:5060">>};
b2b_target(<<"b2b-uas">>, Ip) -> {ok, <<"sip:uas@", Ip/binary, ":5060">>};
b2b_target(_User, _Ip) -> none.

%% ---- B2BUA with transfers ----

b2b(Target, Req, Res) ->
    Opts = #{
        media => anchor,
        notify => spawn(fun b2b_events/0),
        transfer => auto,
        transfer_opts => #{
            domains => [<<"10.253.7.20">>, <<"10.253.7.21">>, <<"10.253.7.22">>]
        }
    },
    case chappe_sip:create_b2bua(Req, Res, Target, Opts) of
        {ok, Legs} ->
            log("b2b ~s up", [Target]),
            log("b2b ~s done: ~p", [Target, chappe_sip_b2b:relay(Legs)]);
        {error, Why} ->
            log("b2b ~s failed: ~p", [Target, Why])
    end.

%% the call's events, for the logs
b2b_events() ->
    receive
        {chappe_sip_b2b, _Ref, Ev} ->
            log("b2b event ~p", [Ev]),
            b2b_events()
    after 600000 ->
        ok
    end.

%% A stand-in rtpengine (NG over UDP on 127.0.0.1:22222): every offer and
%% answer gets its SDP back, everything else ok.
fake_rtpengine() ->
    Self = self(),
    _ = spawn(fun() ->
        {ok, Sock} = gen_udp:open(22222, [binary, {active, true},
                                          {ip, {127, 0, 0, 1}}]),
        Self ! rtpe_up,
        rtpe_loop(Sock)
    end),
    receive rtpe_up -> ok after 5000 -> error(rtpe) end,
    chappe_sip_media:configure(
      #{rtpengine => #{nodes => [#{name => conf_rtpe, host => "127.0.0.1",
                                    port => 22222}]}}).

rtpe_loop(Sock) ->
    receive
        {udp, Sock, Ip, Port, Packet} ->
            [Cookie, Body] = binary:split(Packet, <<" ">>),
            {ok, Cmd} = chappe_rtpengine_bencode:decode(Body),
            Reply = case Cmd of
                #{<<"sdp">> := Sdp} -> #{<<"result">> => <<"ok">>, <<"sdp">> => Sdp};
                _ -> #{<<"result">> => <<"ok">>}
            end,
            Out = chappe_rtpengine_bencode:encode_to_binary(Reply),
            ok = gen_udp:send(Sock, Ip, Port, <<Cookie/binary, " ", Out/binary>>),
            rtpe_loop(Sock)
    end.

%% RFC 3891 section 3 response rules, as the answer-calls guide shows them
replaces({error, bad_request}, _Ip, _Req, Res) ->
    reply(Res, 400);
replaces({error, not_found}, _Ip, _Req, Res) ->
    reply(Res, 481);
replaces({ok, _Old, #{state := terminated}}, _Ip, _Req, Res) ->
    reply(Res, 603);
replaces({ok, _Old, #{state := confirmed, early_only := true}}, _Ip, _, Res) ->
    reply(Res, 486);
replaces({ok, _Old, #{state := early, role := uas}}, _Ip, _Req, Res) ->
    reply(Res, 481);
replaces({ok, Old, Info}, Ip, Req, Res) ->
    log("Replaces matched ~p", [Info]),
    {ok, New} = chappe_sip:create_uas(Req, Res, uas_opts(Ip)),
    ok = chappe_sip_dialog:destroy(Old),
    serve(New, uas).

reply(Res, Status) ->
    log("reply ~b", [Status]),
    chappe_sip_res:send(Res, Status).

answer(<<"ringing">>, Ip, Req, Res) ->
    {ok, D} = chappe_sip:create_uas(Req, Res, (uas_opts(Ip))#{status => 180}),
    serve(D, ringing);
answer(<<"slow">>, Ip, Req, Res) ->
    %% past the 200 ms of RFC 3261 17.2.1, so the stack owes a 100 Trying
    timer:sleep(1000),
    answer(<<"uas">>, Ip, Req, Res);
answer(User, Ip, Req, Res) ->
    {ok, D} = chappe_sip:create_uas(Req, Res, uas_opts(Ip)),
    serve(D, role(User)).

uas_opts(Ip) ->
    #{local_sdp => sdp(Ip), handled_events => [refer]}.

role(<<"byer">>) -> byer;
role(<<"glare">>) -> glare;
role(_) -> uas.

serve(D, Role) ->
    Ref = chappe_sip_dialog:monitor(D),
    %% the owner is not told of the 2xx ACK today (nta absorbs it in the
    %% INVITE server transaction), so act on whichever comes first: the
    %% ACK or half a second after the answer
    erlang:send_after(500, self(), acked),
    loop(D, Ref, Role).

loop(D, Ref, Role) ->
    receive
        {chappe_sip_dialog, _, destroy, Why} ->
            log("dialog ~s destroyed: ~s", [call_id(D), why(Why)]);
        {chappe_sip_dialog, _, ack, _Req, _Res} ->
            log("ACK on ~s", [call_id(D)]),
            on_ack(D, Role),
            loop(D, Ref, done);
        acked ->
            on_ack(D, Role),
            loop(D, Ref, done);
        {chappe_sip_dialog, _, refer, RReq, RRes} ->
            refer(D, RReq, RRes),
            loop(D, Ref, Role);
        {chappe_sip_dialog, _, Event, Req} ->
            log("event ~p ~s", [Event, method(Req)]),
            loop(D, Ref, Role);
        {chappe_sip_dialog, _, Event, Req, _Res} ->
            log("event ~p ~s", [Event, method(Req)]),
            loop(D, Ref, Role);
        {glare_result, R} ->
            log("our re-INVITE returned ~p", [R]),
            loop(D, Ref, Role);
        {'DOWN', Ref, process, _, Reason} ->
            log("dialog process down: ~p", [Reason])
    after 300000 ->
        log("dialog ~s idle, hanging up", [call_id(D)]),
        chappe_sip_dialog:destroy(D)
    end.

on_ack(D, byer) ->
    Reason = {<<"Reason">>, <<"SIP;cause=200;text=\"Call completed\"">>},
    log("hanging up ~s: ~p", [
        call_id(D), chappe_sip_dialog:destroy(D, #{headers => [Reason]})
    ]);
on_ack(D, glare) ->
    Self = self(),
    _ = spawn(fun() ->
        Self ! {glare_result, chappe_sip_dialog:modify(D, hold)}
    end),
    ok;
on_ack(_D, _Role) ->
    ok.

%% ---- REFER ----

refer(D, Req, Res) ->
    case chappe_sip:accept_refer(D, Req, Res, #{}) of
        {ok, Refer} ->
            _ = spawn(fun() -> transfer(Refer) end),
            ok;
        {error, Why} ->
            log("REFER refused: ~p", [Why])
    end.

%% dial the Refer-To target and report its final status; a transferred
%% call stays up until the far end hangs up
transfer(Refer) ->
    #{target := Uri, headers := Headers} = chappe_sip_refer:target(Refer),
    log("REFER to ~s ~p", [Uri, Headers]),
    Ip = local_ip(),
    case chappe_sip:create_uac(Uri, #{local_sdp => sdp(Ip), headers => Headers}) of
        {ok, D} ->
            ok = chappe_sip_refer:final(Refer, 200),
            serve(D, uas);
        {error, Err} when element(1, Err) =:= chappe_sip_error ->
            %% #chappe_sip_error{status}; the lab build has no include path
            ok = chappe_sip_refer:final(Refer, element(2, Err));
        {error, Why} ->
            log("transfer failed: ~p", [Why]),
            ok = chappe_sip_refer:final(Refer, 503)
    end.

%% ---- MESSAGE ----

message(Req, Res) ->
    case user(Req) of
        <<"mwi">> ->
            [Account, New, Old] = binary:split(
                string:trim(chappe_sip_req:body(Req)), <<" ">>, [global, trim_all]
            ),
            log("mwi ~s ~s/~s", [Account, New, Old]),
            ok = chappe_sip_mwi:update(Account, #{
                messages => #{voice => {binary_to_integer(New), binary_to_integer(Old)}}
            }),
            chappe_sip_res:send(Res, 200);
        <<"dial">> ->
            Target = string:trim(chappe_sip_req:body(Req)),
            log("dial ~s", [Target]),
            Status = dial(Target),
            log("dial ~s: ~p", [Target, Status]),
            chappe_sip_res:send(Res, Status);
        _ ->
            chappe_sip_res:send(Res, 200)
    end.

dial(Target) ->
    case chappe_sip:request(Target, #{method => <<"OPTIONS">>}) of
        {ok, Ref} ->
            case chappe_sip_uac:await_response(Ref, 8000) of
                {ok, Resp} ->
                    chappe_sip_msg:status(Resp);
                {error, Why} ->
                    log("dial ~s failed: ~p", [Target, Why]),
                    480
            end;
        {error, Why} ->
            log("dial ~s refused: ~p", [Target, Why]),
            480
    end.

%% CHAPPE_HEP=Ip:Port: capture to it, and serve WebSocket for the WS call
hep() ->
    case os:getenv("CHAPPE_HEP") of
        false ->
            #{};
        HostPort ->
            [Host, Port] = string:split(HostPort, ":", trailing),
            #{hep => #{host => Host, port => list_to_integer(Port),
                       capture_id => 2001},
              ws => #{port => 5066}}
    end.

tls(Ip) ->
    case filelib:is_regular("/certs/agent.pem") of
        true ->
            #{tls => #{contact => iolist_to_binary(["sips:", Ip, ":5061;transport=tls"]),
                       cert_dir => <<"/certs">>}};
        false ->
            #{}
    end.

%% ---- presence and message waiting ----

%% every watcher allowed, and PUBLISH without credentials (a closed lab);
%% one NOTIFY a second at most, so a scenario does not wait the 5 s of
%% RFC 3856 6.10
events() ->
    {module, _} = code:ensure_loaded(chappe_sip_presence),
    case erlang:function_exported(chappe_sip_presence, serve, 1) of
        true ->
            ok = chappe_sip_presence:serve(#{
                authorize => fun(_Watcher, _Presentity, _Req) -> allow end,
                esc => #{allow_unauthenticated => true},
                min_interval => 1000
            }),
            chappe_sip_mwi:serve(#{summary => fun(_Account) -> #{} end});
        false ->
            ok
    end.

%% ---- SUBSCRIBE ----

%% A stack that takes the served packages answers 489 itself; before
%% that the handler does it.
subscribe_handler() ->
    {module, chappe_sip} = code:ensure_loaded(chappe_sip),
    case erlang:function_exported(chappe_sip, subscribe, 2) of
        true -> chappe_sip:subscribe(?PACKAGES, fun subscribe/2);
        false -> chappe_sip:subscribe(fun subscribe/2)
    end.

subscribe(Req, Res) ->
    Event = chappe_sip_req:get(<<"event">>, Req),
    log("SUBSCRIBE ~s Event: ~s", [chappe_sip_req:call_id(Req), Event]),
    case lists:member(package(Event), ?PACKAGES) of
        false ->
            %% RFC 6665 4.2.1.1: 489 with the packages we do serve
            chappe_sip_res:send(Res, 489, #{
                reason => <<"Bad Event">>,
                headers => [{<<"Allow-Events">>, <<"conference">>}]
            });
        true ->
            case chappe_sip:create_uas(Req, Res, #{expires => 3600,
                                                   min_expires => 60}) of
                {ok, D} ->
                    {ok, _} = chappe_sip_dialog:notify(D, conf_notify(active)),
                    sub_loop(D);
                {error, Reason} ->
                    log("SUBSCRIBE refused: ~p", [Reason])
            end
    end.

sub_loop(D) ->
    receive
        {chappe_sip_dialog, D, {refreshed, S}, _} ->
            log("refreshed ~b", [S]),
            %% RFC 6665 4.2.1.2: a NOTIFY right after every accepted refresh
            {ok, _} = chappe_sip_dialog:notify(D, conf_notify(active)),
            sub_loop(D);
        {chappe_sip_dialog, D, unsubscribed, _} ->
            log("unsubscribed", []),
            _ = chappe_sip_dialog:notify(D, conf_notify({terminated, timeout})),
            chappe_sip_dialog:wait(D);
        {chappe_sip_dialog, D, destroy, Why} ->
            log("subscription destroyed: ~s", [why(Why)])
    after 300000 ->
        chappe_sip_dialog:destroy(D)
    end.

conf_notify(State) ->
    #{
        state => State,
        content_type => <<"application/conference-info+xml">>,
        body => <<
            "<?xml version=\"1.0\"?>\r\n"
            "<conference-info xmlns=\"urn:ietf:params:xml:ns:conference-info\""
            " entity=\"sip:conf@chappe\" state=\"full\" version=\"1\"/>\r\n"
        >>
    }.

package(undefined) ->
    undefined;
package(Event) ->
    [P | _] = binary:split(Event, <<";">>),
    string:lowercase(string:trim(P)).

%% ---- HEP calls (the caller side) ----

%% One call (INVITE, 200, ACK, BYE, 200) to the node over each transport;
%% prints `hep call PROTO CALL-ID' for each one that completed.
-spec hep_calls(string()) -> ok.
hep_calls(Node) ->
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(ws),
    {ok, Ip} = inet:parse_address(Node),
    lists:foreach(
        fun(Proto) ->
            try hep_call(Proto, Ip, Node) of
                CallId -> log("hep call ~s ~s", [Proto, CallId])
            catch
                C:R:St -> log("hep call ~s failed: ~p:~p ~p", [Proto, C, R, St])
            end
        end,
        [udp, tcp, tls, ws]
    ).

hep_call(udp, Ip, _Node) ->
    {ok, S} = gen_udp:open(0, [binary, {active, false}]),
    {ok, LP} = inet:port(S),
    call({udp, S, Ip}, <<"UDP">>, LP);
hep_call(tcp, Ip, _Node) ->
    {ok, S} = gen_tcp:connect(Ip, 5060, [binary, {active, false}], 5000),
    {ok, LP} = inet:port(S),
    call({tcp, S}, <<"TCP">>, LP);
hep_call(tls, Ip, _Node) ->
    %% the lab's own certificates; the call is what is checked, not TLS
    {ok, S} = ssl:connect(Ip, 5061, [binary, {active, false},
                                     {verify, verify_none}], 5000),
    {ok, {_, LP}} = ssl:sockname(S),
    call({tls, S}, <<"TLS">>, LP);
hep_call(ws, _Ip, Node) ->
    Url = iolist_to_binary(["ws://", Node, ":5066/ws"]),
    {ok, C} = ws:connect(Url, #{handler => ?MODULE,
                                handler_opts => #{notify => self()},
                                subprotocols => [<<"sip">>]}),
    call({ws, C}, <<"WS">>, 0).

call(Conn, Via, LP) ->
    CallId = iolist_to_binary(["hep-", Via, "-",
                               integer_to_list(erlang:unique_integer([positive])),
                               "@lab"]),
    FT = integer_to_binary(erlang:unique_integer([positive])),
    Ip = local_ip_of(Conn),
    ok = csend(Conn, req(<<"INVITE">>, Via, Ip, LP, CallId, FT, undefined, 1,
                         sdp(Ip))),
    Ok = await(Conn, <<"200">>, <<"INVITE">>, <<>>),
    {match, [TT]} = re:run(Ok, "\r\nTo:[^\r]*;tag=([^;\r>]+)",
                           [caseless, {capture, all_but_first, binary}]),
    ok = csend(Conn, req(<<"ACK">>, Via, Ip, LP, CallId, FT, TT, 1, <<>>)),
    timer:sleep(200),
    ok = csend(Conn, req(<<"BYE">>, Via, Ip, LP, CallId, FT, TT, 2, <<>>)),
    _ = await(Conn, <<"200">>, <<"BYE">>, <<>>),
    CallId.

local_ip_of(_Conn) ->
    {ok, Addrs} = inet:getifaddrs(),
    hd([list_to_binary(inet:ntoa(A))
        || {_, Opts} <- Addrs, {addr, {10, 253, 7, _} = A} <- Opts] ++
       [<<"127.0.0.1">>]).

req(Method, Via, Ip, LP, CallId, FT, TT, CSeq, Body) ->
    To = case TT of
        undefined -> <<"<sip:uas@chappe>">>;
        _ -> <<"<sip:uas@chappe>;tag=", TT/binary>>
    end,
    iolist_to_binary([
        Method, " sip:uas@chappe SIP/2.0\r\n",
        "Via: SIP/2.0/", Via, " ", Ip, ":", integer_to_binary(LP),
        ";branch=z9hG4bK", integer_to_binary(erlang:unique_integer([positive])),
        ";rport\r\n",
        "Max-Forwards: 70\r\n",
        "From: <sip:caller@lab>;tag=", FT, "\r\n",
        "To: ", To, "\r\n",
        "Call-ID: ", CallId, "\r\n",
        "CSeq: ", integer_to_binary(CSeq), " ", Method, "\r\n",
        "Contact: <sip:caller@", Ip, ":", integer_to_binary(LP),
        ";transport=", string:lowercase(Via), ">\r\n",
        case Body of
            <<>> -> [];
            _ -> "Content-Type: application/sdp\r\n"
        end,
        "Content-Length: ", integer_to_binary(byte_size(Body)), "\r\n\r\n",
        Body
    ]).

csend({udp, S, Ip}, Bin) -> gen_udp:send(S, Ip, 5060, Bin);
csend({tcp, S}, Bin) -> gen_tcp:send(S, Bin);
csend({tls, S}, Bin) -> ssl:send(S, Bin);
csend({ws, C}, Bin) -> ws:send(C, {text, Bin}), ok.

%% the next response with this status and CSeq method
await(Conn, Status, Method, Buf) ->
    case next_msg(Buf) of
        {ok, Msg, Rest} ->
            case is_resp(Msg, Status, Method) of
                true -> Msg;
                false -> await(Conn, Status, Method, Rest)
            end;
        more ->
            {ok, Data} = crecv(Conn),
            await(Conn, Status, Method, <<Buf/binary, Data/binary>>)
    end.

crecv({udp, S, _}) ->
    {ok, {_, _, D}} = gen_udp:recv(S, 0, 10000),
    {ok, D};
crecv({tcp, S}) -> gen_tcp:recv(S, 0, 10000);
crecv({tls, S}) -> ssl:recv(S, 0, 10000);
crecv({ws, _}) ->
    receive
        {ws_in, D} -> {ok, D}
    after 10000 -> {error, timeout}
    end.

is_resp(Msg, Status, Method) ->
    case Msg of
        <<"SIP/2.0 ", Status:3/binary, _/binary>> ->
            re:run(Msg, ["\\r\\nCSeq:[ \\t]*[0-9]+ ", Method],
                   [caseless]) =/= nomatch;
        _ ->
            false
    end.

%% one message off a byte stream, by its Content-Length
next_msg(Buf) ->
    case binary:match(Buf, <<"\r\n\r\n">>) of
        nomatch ->
            more;
        {Pos, 4} ->
            Len = case re:run(binary:part(Buf, 0, Pos),
                              "\\r\\n(?:content-length|l)[ \\t]*:[ \\t]*([0-9]+)",
                              [caseless, {capture, all_but_first, binary}]) of
                {match, [L]} -> binary_to_integer(L);
                nomatch -> 0
            end,
            Total = Pos + 4 + Len,
            case byte_size(Buf) >= Total of
                true ->
                    <<Msg:Total/binary, Rest/binary>> = Buf,
                    {ok, Msg, Rest};
                false ->
                    more
            end
    end.

%% ws_handler: every message to the caller
init(_Req, #{notify := Pid}) -> {ok, Pid}.
handle_in({text, D}, Pid) -> Pid ! {ws_in, D}, {ok, Pid};
handle_in({binary, D}, Pid) -> Pid ! {ws_in, D}, {ok, Pid};
handle_in(_Frame, Pid) -> {ok, Pid}.
handle_info(_Msg, Pid) -> {ok, Pid}.
terminate(_Reason, _Pid) -> ok.

%% ---- helpers ----

user(Req) ->
    case re:run(chappe_sip_req:uri(Req), "^sips?:([^@;>]+)@",
                [{capture, all_but_first, binary}]) of
        {match, [U]} -> U;
        nomatch -> <<>>
    end.

sdp(Ip) ->
    Id = integer_to_binary(erlang:unique_integer([positive])),
    <<"v=0\r\n",
      "o=chappe ", Id/binary, " 1 IN IP4 ", Ip/binary, "\r\n",
      "s=chappe\r\n",
      "c=IN IP4 ", Ip/binary, "\r\n",
      "t=0 0\r\n",
      "m=audio 40000 RTP/AVP 0\r\n",
      "a=rtpmap:0 PCMU/8000\r\n",
      "a=sendrecv\r\n">>.

local_ip() -> persistent_term:get({?MODULE, ip}).

call_id(D) ->
    try chappe_sip_dialog:call_id(D) catch _:_ -> <<"?">> end.

method(Req) ->
    try chappe_sip_req:method(Req) of
        M when is_binary(M) -> M;
        _ -> <<"-">>
    catch
        _:_ -> <<"-">>
    end.

why(Why) when is_atom(Why) -> atom_to_binary(Why);
why(Why) ->
    try chappe_sip_req:method(Why) of
        M when is_binary(M) -> <<"peer ", M/binary>>;
        _ -> iolist_to_binary(io_lib:format("~p", [Why]))
    catch
        _:_ -> iolist_to_binary(io_lib:format("~p", [Why]))
    end.

log(Fmt, Args) ->
    io:format("[conf ~s] " ++ Fmt ++ "~n",
              [calendar:system_time_to_rfc3339(
                   erlang:system_time(millisecond), [{unit, millisecond}])
               | Args]).
