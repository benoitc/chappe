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
%%
%% A REFER inside a call is accepted with chappe_sip:accept_refer/4: the
%% node dials the target (with its Replaces, for an attended transfer) and
%% reports the outcome, as the REFER guide shows.
%%
%% An INVITE with Replaces goes through chappe_sip:find_replaced/1 with the
%% response rules of the answer-calls guide. SUBSCRIBE serves the
%% `conference' package (RFC 6665); any other package gets 489.
%%
%% A MESSAGE to `dial' sends an OPTIONS to the URI in its body and answers
%% with the status that OPTIONS got (480 when it got none): the dns_* cases
%% use it to make the node resolve a domain through the lab's DNS server
%% (RFC 3263). With the lab's certificates in /certs the node also listens
%% for TLS on 5061, so it can reach a sips: URI.
%%
%% Every event is printed on stdout, which the suite collects.
-module(chappe_conf_node).

-export([start/1]).

-define(PACKAGES, [<<"conference">>]).

-spec start(string()) -> ok.
start(Ip) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Contact = iolist_to_binary(["sip:", Ip, ":5060"]),
    ok = chappe_sip:start(maps:merge(#{contact => Contact}, tls(Ip))),
    IpBin = list_to_binary(Ip),
    persistent_term:put({?MODULE, ip}, IpBin),
    ok = chappe_sip:invite(fun(Req, Res) -> invite(IpBin, Req, Res) end),
    %% no OPTIONS handler: the stack's own answer is what the scenario checks
    ok = subscribe_handler(),
    ok = chappe_sip:message(fun message/2),
    log("chappe_conf_node up on ~s", [Contact]),
    ok.

%% ---- INVITE ----

invite(Ip, Req, Res) ->
    log("INVITE ~s ~s", [chappe_sip_req:uri(Req), chappe_sip_req:call_id(Req)]),
    case chappe_sip:find_replaced(Req) of
        {error, no_replaces} ->
            answer(user(Req), Ip, Req, Res);
        Found ->
            replaces(Found, Ip, Req, Res)
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

tls(Ip) ->
    case filelib:is_regular("/certs/agent.pem") of
        true ->
            #{tls => #{contact => iolist_to_binary(["sips:", Ip, ":5061;transport=tls"]),
                       cert_dir => <<"/certs">>}};
        false ->
            #{}
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
