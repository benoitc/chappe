%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Header and dialog duties of the demo gate, on the wire: where Event may
%% appear (RFC 6665 8.2.1), one Reason per protocol (RFC 3326 2), the
%% Contact of an UPDATE during an INVITE (RFC 3311 5.1), a refused UPDATE
%% (RFC 3311 5.3) and a response sent to the Via sent-by port (RFC 3581 3).
%% A raw gen_udp peer (chappe_sip_core_peer) plays the far end.
-module(chappe_sip_gate1_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-import(chappe_sip_core_peer, [
    open/0,
    port/1,
    send/3,
    recv/3,
    request/3,
    response/3,
    hdr/2,
    hdrs/2,
    status/1,
    method/1,
    cseq/1,
    to_tag/1,
    from_tag/1,
    tag/0,
    sdp/0, sdp/1
]).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    event_only_in_subscribe_notify/1,
    reason_one_per_protocol/1,
    update_contact_matches_2xx/1,
    refused_update_keeps_session/1,
    response_on_sent_by_port/1
]).

all() ->
    [
        event_only_in_subscribe_notify,
        reason_one_per_protocol,
        update_contact_matches_2xx,
        refused_update_keeps_session,
        response_on_sent_by_port
    ].

init_per_suite(Config) ->
    application:set_env(
        chappe_sip,
        engine_mod,
        chappe_sip_nif,
        [{persistent, true}]
    ),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(_Case, Config) ->
    EP = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => chappe_sip_core_peer:contact(EP)}),
    Sock = open(),
    [{ep, EP}, {sock, Sock} | Config].

end_per_testcase(_Case, Config) ->
    chappe_sip_core_peer:close(?config(sock, Config)),
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

-define(APP, <<"sip:app@127.0.0.1">>).
-define(SDP_CT, {<<"Content-Type">>, <<"application/sdp">>}).

%% RFC 6665 8.2.1: Event goes on SUBSCRIBE and NOTIFY only. chappe's
%% INVITE, its responses to an INVITE, to a SUBSCRIBE and to a NOTIFY
%% carry none; its NOTIFY does.
%% req: R6665-34
event_only_in_subscribe_notify(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    LP = port(Sock),
    Test = self(),
    ok = chappe_sip:subscribe(fun(Req, Res) ->
        {ok, D} = chappe_sip:create_uas(Req, Res, #{expires => 600}),
        Test ! {notified, chappe_sip_dialog:notify(D, #{state => active})},
        receive
            stop -> ok
        after 5000 -> ok
        end
    end),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, _} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp()})
    end),
    %% SUBSCRIBE: its 200 has no Event, the NOTIFY has
    Sub = request(
        <<"SUBSCRIBE">>,
        ?APP,
        #{
            port => LP,
            headers => [
                {<<"Event">>, <<"conference">>},
                {<<"Expires">>, <<"600">>}
            ]
        }
    ),
    send(Sock, EP, Sub),
    {R200s, _} = recv(Sock, {status, 200, <<"SUBSCRIBE">>}, 3000),
    {Notify, NSrc} = recv(Sock, {method, <<"NOTIFY">>}, 3000),
    ?assertEqual(<<"conference">>, hdr(<<"event">>, Notify)),
    send(Sock, NSrc, response(Notify, 200, #{})),
    receive
        {notified, {ok, _}} -> ok
    after 3000 -> ct:fail(no_notify)
    end,
    %% a NOTIFY chappe has no subscription for: its answer has no Event
    Stray = request(
        <<"NOTIFY">>,
        ?APP,
        #{
            port => LP,
            to_tag => tag(),
            headers => [
                {<<"Event">>, <<"dialog">>},
                {<<"Subscription-State">>, <<"active">>}
            ]
        }
    ),
    send(Sock, EP, Stray),
    {RStray, _} = recv(Sock, fun(B) -> is_response(B, <<"NOTIFY">>) end, 3000),
    %% INVITE answered by the app: the 100 and the 200
    Inv = request(<<"INVITE">>, ?APP, #{port => LP, body => sdp()}),
    send(Sock, EP, Inv),
    {R100, _} = recv(Sock, {status, 100, <<"INVITE">>}, 3000),
    {R200i, _} = recv(Sock, {status, 200, <<"INVITE">>}, 3000),
    send(Sock, EP, chappe_sip_core_peer:ack_for(R200i, #{port => LP})),
    %% chappe's own INVITE
    {ok, _} = chappe_sip_uac:start(peer_uri(Sock), #{local_sdp => sdp()}),
    {Out, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, EP, response(Out, 486, #{to_tag => tag()})),
    [
        ?assertEqual([], hdrs(<<"event">>, M), M)
     || M <- [R200s, RStray, R100, R200i, Out]
    ].

%% RFC 3326 2: several Reason values may go on a request, each of a
%% different protocol. The B2BUA repeats A's BYE Reason on B's BYE: when
%% A sends two of one protocol, only the first of each protocol goes out.
%% req: R3326-04
reason_one_per_protocol(Config) ->
    {EP, A} = {?config(ep, Config), ?config(sock, Config)},
    B = open(),
    Callee = peer_uri(B),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(Req, Res, Callee, #{}),
        _ = chappe_sip_b2b:relay(Legs)
    end),
    Inv = request(<<"INVITE">>, ?APP, #{port => port(A), body => sdp()}),
    send(A, EP, Inv),
    {BInv, BSrc} = recv(B, {method, <<"INVITE">>}, 3000),
    send(
        B,
        BSrc,
        response(
            BInv,
            200,
            #{
                to_tag => tag(),
                body => sdp(42000),
                headers => [{<<"Contact">>, <<"<", Callee/binary, ">">>}]
            }
        )
    ),
    {_, _} = recv(B, {method, <<"ACK">>}, 3000),
    {R200, _} = recv(A, {status, 200, <<"INVITE">>}, 3000),
    send(A, EP, chappe_sip_core_peer:ack_for(R200, #{port => port(A)})),
    Reasons = [
        <<"Q.850;cause=16;text=\"Normal, call clearing\"">>,
        <<"SIP;cause=200;text=\"Call completed elsewhere\"">>,
        <<"Q.850;cause=31">>
    ],
    Bye = request(
        <<"BYE">>,
        contact_uri(R200),
        #{
            port => port(A),
            call_id => hdr(<<"call-id">>, Inv),
            from_tag => from_tag(Inv),
            to_tag => to_tag(R200),
            cseq => 2,
            headers => [{<<"Reason">>, R} || R <- Reasons]
        }
    ),
    send(A, EP, Bye),
    {BBye, BS} = recv(B, {method, <<"BYE">>}, 3000),
    send(B, BS, response(BBye, 200, #{})),
    {_, _} = recv(A, {status, 200, <<"BYE">>}, 3000),
    ?assertEqual(lists:sublist(Reasons, 2), hdrs(<<"reason">>, BBye)),
    chappe_sip_core_peer:close(B).

%% RFC 3311 5.1: an UPDATE answered while a re-INVITE from the peer is
%% pending carries the Contact that the re-INVITE's 2xx then repeats.
%% req: R3311-004
update_contact_matches_2xx(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    LP = port(Sock),
    {Inv, D, R200} = call(Sock, EP, #{handled_events => [modify]}),
    ReInv = indialog(<<"INVITE">>, Inv, R200, LP, 2, sdp(40002)),
    send(Sock, EP, ReInv),
    Res =
        receive
            {chappe_sip_dialog, D, modify, _, Res0} -> Res0
        after 3000 -> ct:fail(no_modify)
        end,
    %% a target refresh without an offer, in the middle of the re-INVITE
    Upd = indialog(<<"UPDATE">>, Inv, R200, LP, 3, <<>>),
    send(Sock, EP, Upd),
    {RUpd, _} = recv(Sock, fun(B) -> is_response(B, <<"UPDATE">>) end, 3000),
    ?assertEqual(200, status(RUpd)),
    ok = chappe_sip_res:send(Res, 200, #{
        body => sdp(41000),
        headers => [?SDP_CT]
    }),
    {R2, _} = recv(Sock, {status, 200, <<"INVITE">>}, 3000),
    send(Sock, EP, chappe_sip_core_peer:ack_for(R2, #{port => LP})),
    ?assertNotEqual(undefined, hdr(<<"contact">>, RUpd)),
    ?assertEqual(hdr(<<"contact">>, RUpd), hdr(<<"contact">>, R2)).

%% RFC 3311 5.3: an UPDATE offer refused with a non-2xx changes nothing;
%% the session stays as the INVITE set it.
%% req: R3311-014
refused_update_keeps_session(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {_Inv, D, _R200} = call(Sock, EP, #{}),
    Local0 = chappe_sip_dialog:local_sdp(D),
    Remote0 = chappe_sip_dialog:remote_sdp(D),
    Upd = async(fun() ->
        chappe_sip_dialog:request(D, #{
            method => <<"UPDATE">>,
            content_type => <<"application/sdp">>,
            body => sdp(45000)
        })
    end),
    {U, USrc} = recv(Sock, {method, <<"UPDATE">>}, 3000),
    send(Sock, USrc, response(U, 488, #{reason => <<"Not Acceptable Here">>})),
    {ok, M} = await(Upd),
    ?assertEqual(488, chappe_sip_msg:status(M)),
    ?assertEqual(Local0, chappe_sip_dialog:local_sdp(D)),
    ?assertEqual(Remote0, chappe_sip_dialog:remote_sdp(D)),
    %% the next offer builds on the session the INVITE set
    Mod = async(fun() -> chappe_sip_dialog:modify(D, hold) end),
    {ReInv, RSrc} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ?assertEqual(
        nomatch,
        binary:match(
            chappe_sip_core_peer:body(ReInv),
            <<"45000">>
        )
    ),
    send(Sock, RSrc, response(ReInv, 200, #{body => sdp()})),
    {ok, _} = await(Mod).

%% RFC 3581 3: with rport in its Via, chappe still takes a response sent
%% to the sent-by port rather than back to the request's source.
%% req: R3581-004
response_on_sent_by_port(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip:request(peer_uri(Sock), #{method => <<"OPTIONS">>}),
    {Opt, _} = recv(Sock, {method, <<"OPTIONS">>}, 3000),
    Via = chappe_sip_core_peer:top_via(Opt),
    ?assertMatch({match, _}, re:run(Via, ";rport")),
    SentBy = sent_by_port(Via),
    ?assertEqual(EP, SentBy),
    Other = open(),
    send(Other, SentBy, response(Opt, 200, #{to_tag => tag()})),
    {ok, M} = chappe_sip_uac:await_response(Ref, 3000),
    ?assertEqual(200, chappe_sip_msg:status(M)),
    chappe_sip_core_peer:close(Other).

%% ---- helpers ----

peer_uri(Sock) ->
    <<"sip:peer@127.0.0.1:", (integer_to_binary(port(Sock)))/binary>>.

is_response(<<"SIP/2.0 ", _/binary>> = B, Method) ->
    element(2, cseq(B)) =:= Method;
is_response(_, _) ->
    false.

contact_uri(Msg) ->
    {ok, #{uri := U}} = chappe_sip_hdr:name_addr(hdr(<<"contact">>, Msg)),
    U.

sent_by_port(Via) ->
    {match, [P]} = re:run(
        Via,
        "^SIP/2.0/[A-Z]+ [^:;]+:([0-9]+)",
        [{capture, all_but_first, binary}]
    ),
    binary_to_integer(P).

%% A confirmed call from the peer (INVITE, 200, ACK); the test process
%% owns the dialog. Returns {Invite, Dialog, 200}.
call(Sock, EP, UasOpts) ->
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, D} = chappe_sip:create_uas(
            Req,
            Res,
            maps:merge(
                #{
                    local_sdp => sdp(41000),
                    owner => Test
                },
                UasOpts
            )
        ),
        Test ! {dialog, D}
    end),
    LP = port(Sock),
    Inv = request(<<"INVITE">>, ?APP, #{port => LP, body => sdp()}),
    send(Sock, EP, Inv),
    {R200, _} = recv(Sock, {status, 200, <<"INVITE">>}, 3000),
    send(Sock, EP, chappe_sip_core_peer:ack_for(R200, #{port => LP})),
    D =
        receive
            {dialog, D0} -> D0
        after 3000 -> ct:fail(no_dialog)
        end,
    receive
        {chappe_sip_dialog, D, ack, _, _} -> ok
    after 3000 -> ct:fail(no_ack)
    end,
    {Inv, D, R200}.

%% an in-dialog request from the peer, CSeq N, with an optional offer
indialog(Method, Inv, R200, LP, N, Body) ->
    request(
        Method,
        contact_uri(R200),
        #{
            port => LP,
            call_id => hdr(<<"call-id">>, Inv),
            from_tag => from_tag(Inv),
            to_tag => to_tag(R200),
            cseq => N,
            body => Body
        }
    ).

async(F) ->
    Test = self(),
    Ref = make_ref(),
    spawn_link(fun() -> Test ! {Ref, F()} end),
    Ref.

await(Ref) ->
    receive
        {Ref, R} -> R
    after 10000 -> ct:fail(no_result)
    end.
