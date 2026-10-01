%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% UAC.
%%
%% The app is the UAC (chappe_sip:create_uac / chappe_sip:request); a gen_udp socket
%% in the test plays the UAS peer and scripts responses.
-module(chappe_sip_uac_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("chappe_sip.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([uac_180_200_bye/1, uac_486/1, uac_cancel/1, uac_digest_407/1,
         options_request/1, uac_cap_enforced/1, uac_engine_restart/1,
         uac_redirect_strips_auth/1, uac_raw_body/1, uac_contact_params/1,
         uac_bye_on_ack/1]).

all() ->
    [uac_180_200_bye, uac_486, uac_cancel, uac_digest_407, options_request,
     uac_cap_enforced, uac_engine_restart, uac_redirect_strips_auth,
     uac_raw_body, uac_contact_params, uac_bye_on_ack].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

end_per_testcase(_Case, _Config) ->
    _ = chappe_sip:stop(),
    application:unset_env(chappe_sip, max_uac_transactions),
    ok.

%% the advertised max_uac_transactions ceiling is enforced at start time
uac_cap_enforced(_Config) ->
    {_EnginePort, _UasPort} = setup(),
    application:set_env(chappe_sip, max_uac_transactions, 0),
    ?assertEqual({error, max_uac_transactions},
                 chappe_sip:request(<<"sip:x@127.0.0.1">>, #{method => <<"OPTIONS">>})).

%% F10: after authenticating to authority A, a redirect (302) to a different
%% authority B must not replay A's Authorization to B.
uac_redirect_strips_auth(_Config) ->
    {EnginePort, APort} = setup(),
    BPort = pick(),
    Test = self(),
    %% peer A: challenge, then redirect the authenticated INVITE to peer B
    uas(APort, fun(Ua) ->
        {Inv1, Src} = uas_recv(Ua, <<"INVITE">>),
        false = has_auth(Inv1),
        Chal = <<"Digest realm=\"a\", nonce=\"n1\", qop=\"auth\"">>,
        uas_send(Ua, Src, resp(Inv1, 407, <<"Proxy Authentication Required">>,
                               tag(), [{<<"Proxy-Authenticate">>, Chal}], <<>>)),
        {Inv2, Src2} = uas_recv(Ua, <<"INVITE">>),
        true = has_auth(Inv2),
        BContact = <<"<sip:b@127.0.0.1:",
                     (integer_to_binary(BPort))/binary, ">">>,
        uas_send(Ua, Src2, resp(Inv2, 302, <<"Moved Temporarily">>, tag(),
                                [{<<"Contact">>, BContact}], <<>>))
    end),
    %% peer B: the redirected INVITE must carry no credentials
    uas(BPort, fun(Ub) ->
        {Inv, Src} = uas_recv(Ub, <<"INVITE">>),
        Test ! {b_auth, has_auth(Inv)},
        uas_send(Ub, Src, resp(Inv, 486, <<"Busy Here">>, tag(), [], <<>>))
    end),
    Uri = <<"sip:x@127.0.0.1:", (integer_to_binary(APort))/binary>>,
    {ok, Ref} = chappe_sip_uac:start(Uri, #{contact => contact(EnginePort),
                                      auth => #{user => <<"alice">>,
                                                pass => <<"secret">>},
                                      follow_redirects => true,
                                      notify => self()}),
    receive {b_auth, HasAuth} -> ?assertNot(HasAuth)
    after 6000 -> ct:fail(no_b_invite) end,
    _ = chappe_sip_uac:await(Ref, 4000).

%% F6: an engine restart fails an in-flight UAC transaction cleanly instead of
%% leaving it hung waiting for a reply the new native stack will never deliver.
uac_engine_restart(_Config) ->
    {EnginePort, UasPort} = setup(),
    Test = self(),
    uas(UasPort, fun(Uas) ->
        {_Inv, _Src} = uas_recv(Uas, <<"INVITE">>),
        Test ! got_invite,
        timer:sleep(4000)               % hold the transaction: never reply
    end),
    Uri = <<"sip:hold@127.0.0.1:", (integer_to_binary(UasPort))/binary>>,
    {ok, Ref} = chappe_sip_uac:start(Uri, #{contact => contact(EnginePort),
                                      notify => self()}),
    receive got_invite -> ok after 4000 -> ct:fail(no_invite) end,
    ok = chappe_sip_engine:restart_engine(),
    ?assertEqual({error, engine_restart}, chappe_sip_uac:await(Ref, 4000)).

%% INVITE -> 180 -> 200 -> app gets dialog, UAS gets ACK; app destroys ->
%% BYE -> 200
uac_180_200_bye(_Config) ->
    {EnginePort, UasPort} = setup(),
    Test = self(),
    uas(UasPort, fun(Uas) ->
        {Inv, Src} = uas_recv(Uas, <<"INVITE">>),
        uas_send(Uas, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        ToTag = tag(),
        uas_send(Uas, Src, resp(Inv, 200, <<"OK">>, ToTag,
                                [{<<"Contact">>, contact(UasPort)}], sdp())),
        {_Ack, _} = uas_recv(Uas, <<"ACK">>),
        Test ! acked,
        {Bye, BSrc} = uas_recv(Uas, <<"BYE">>),
        uas_send(Uas, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>)),
        Test ! byed
    end),
    Uri = <<"sip:callee@127.0.0.1:", (integer_to_binary(UasPort))/binary>>,
    {ok, Dialog} = chappe_sip:create_uac(Uri, #{contact => contact(EnginePort),
                                          local_sdp => sdp()}),
    receive acked -> ok after 4000 -> ct:fail(no_ack) end,
    ok = chappe_sip_dialog:destroy(Dialog),
    receive byed -> ok after 4000 -> ct:fail(no_bye) end.

%% A body that is not application/sdp: `body' plus `content_type' send it
%% verbatim (a SIPREC multipart of SDP and rs-metadata here), and the peer's
%% answer still comes back through the dialog.
uac_raw_body(_Config) ->
    {EnginePort, UasPort} = setup(),
    Test = self(),
    Body = multipart(),
    uas(UasPort, fun(Uas) ->
        {Inv, Src} = uas_recv(Uas, <<"INVITE">>),
        {ok, Msg} = chappe_sip_msg:parse(Inv),
        Test ! {invite, chappe_sip_msg:get(<<"content-type">>, Msg),
                chappe_sip_msg:body(Msg)},
        ToTag = tag(),
        uas_send(Uas, Src, resp(Inv, 200, <<"OK">>, ToTag,
                                [{<<"Contact">>, contact(UasPort)}], sdp())),
        {_Ack, _} = uas_recv(Uas, <<"ACK">>),
        Test ! acked,
        {Bye, BSrc} = uas_recv(Uas, <<"BYE">>),
        uas_send(Uas, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>))
    end),
    Uri = <<"sip:srs@127.0.0.1:", (integer_to_binary(UasPort))/binary>>,
    {ok, Dialog} = chappe_sip:create_uac(Uri, #{
        contact => contact(EnginePort),
        body => Body,
        content_type => <<"multipart/mixed;boundary=chappe">>
    }),
    receive
        {invite, CT, Received} ->
            ?assertEqual(<<"multipart/mixed;boundary=chappe">>, CT),
            ?assertEqual(Body, Received)
    after 4000 -> ct:fail(no_invite)
    end,
    receive acked -> ok after 4000 -> ct:fail(no_ack) end,
    ?assertEqual(sdp(), chappe_sip_dialog:remote_sdp(Dialog)),
    ok = chappe_sip_dialog:destroy(Dialog).

%% contact_params ride after the Contact's angle brackets (a conference
%% focus sends `;isfocus', RFC 4579), and the dialog repeats that Contact
%% on the in-dialog requests that need one (NOTIFY, REFER: RFC 6665 4.1.2.2
%% and RFC 3515), so the peer keeps seeing the same target.
uac_contact_params(_Config) ->
    {EnginePort, UasPort} = setup(),
    Test = self(),
    uas(UasPort, fun(Uas) ->
        {Inv, Src} = uas_recv(Uas, <<"INVITE">>),
        Test ! {contact, invite, header(Inv, <<"contact">>)},
        ToTag = tag(),
        uas_send(Uas, Src, resp(Inv, 200, <<"OK">>, ToTag,
                                [{<<"Contact">>, contact(UasPort)}], sdp())),
        {_Ack, _} = uas_recv(Uas, <<"ACK">>),
        [begin
             {Req, RSrc} = uas_recv(Uas, M),
             Test ! {contact, M, header(Req, <<"contact">>)},
             uas_send(Uas, RSrc, resp(Req, 200, <<"OK">>, ToTag, [], <<>>))
         end || M <- [<<"NOTIFY">>, <<"REFER">>, <<"BYE">>]]
    end),
    Uri = <<"sip:conf@127.0.0.1:", (integer_to_binary(UasPort))/binary>>,
    Expected = <<"<", (contact(EnginePort))/binary, ">;isfocus">>,
    {ok, Dialog} = chappe_sip:create_uac(Uri, #{
        contact => contact(EnginePort),
        contact_params => <<";isfocus">>,
        local_sdp => sdp()
    }),
    ?assertEqual(Expected, recv_contact(invite)),
    {ok, _} = chappe_sip_dialog:request(Dialog, #{
        method => <<"NOTIFY">>,
        headers => [{<<"Event">>, <<"refer">>},
                    {<<"Subscription-State">>, <<"active">>}]
    }),
    ?assertEqual(Expected, recv_contact(<<"NOTIFY">>)),
    {ok, _} = chappe_sip_dialog:request(Dialog, #{
        method => <<"REFER">>,
        headers => [{<<"Refer-To">>, <<"<sip:x@127.0.0.1>">>}]
    }),
    ?assertEqual(Expected, recv_contact(<<"REFER">>)),
    ok = chappe_sip_dialog:destroy(Dialog),
    %% BYE is not a target refresh request: no Contact needed
    _ = recv_contact(<<"BYE">>).

recv_contact(What) ->
    receive {contact, What, C} -> C after 4000 -> ct:fail({no, What}) end.

header(Bin, Name) ->
    {ok, Msg} = chappe_sip_msg:parse(Bin),
    chappe_sip_msg:get(Name, Msg).

%% INVITE -> 486 -> app gets SipError 486
uac_486(_Config) ->
    {EnginePort, UasPort} = setup(),
    uas(UasPort, fun(Uas) ->
        {Inv, Src} = uas_recv(Uas, <<"INVITE">>),
        uas_send(Uas, Src, resp(Inv, 486, <<"Busy Here">>, tag(), [], <<>>))
    end),
    Uri = <<"sip:busy@127.0.0.1:", (integer_to_binary(UasPort))/binary>>,
    Res = chappe_sip:create_uac(Uri, #{contact => contact(EnginePort)}),
    ?assertMatch({error, #chappe_sip_error{status = 486}}, Res).

%% INVITE -> 180 -> app cancels -> CANCEL -> 487
uac_cancel(_Config) ->
    {EnginePort, UasPort} = setup(),
    Test = self(),
    uas(UasPort, fun(Uas) ->
        {Inv, Src} = uas_recv(Uas, <<"INVITE">>),
        uas_send(Uas, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        Test ! ringing,
        {Cancel, CSrc} = uas_recv(Uas, <<"CANCEL">>),
        %% 200 to CANCEL, 487 to INVITE
        uas_send(Uas, CSrc, resp(Cancel, 200, <<"OK">>, tag(), [], <<>>)),
        uas_send(Uas, Src, resp(Inv, 487, <<"Request Terminated">>, tag(),
                                [], <<>>))
    end),
    Uri = <<"sip:slow@127.0.0.1:", (integer_to_binary(UasPort))/binary>>,
    {ok, Ref} = chappe_sip_uac:start(Uri, #{contact => contact(EnginePort),
                                      notify => self()}),
    receive ringing -> ok after 4000 -> ct:fail(no_ring) end,
    receive {chappe_sip_uac, Ref, {provisional, _}} -> ok
    after 4000 -> ct:fail(no_provisional) end,
    ok = chappe_sip_uac:cancel(Ref),
    Res = chappe_sip_uac:await(Ref, 4000),
    ?assertMatch({error, #chappe_sip_error{status = 487}}, Res).

%% INVITE -> 407 challenge -> app retries with auth -> 200
uac_digest_407(_Config) ->
    {EnginePort, UasPort} = setup(),
    Test = self(),
    uas(UasPort, fun(Uas) ->
        {Inv1, Src} = uas_recv(Uas, <<"INVITE">>),
        false = has_auth(Inv1),
        Chal = <<"Digest realm=\"test\", nonce=\"abc123\", qop=\"auth\"">>,
        uas_send(Uas, Src, resp(Inv1, 407, <<"Proxy Authentication Required">>,
                                tag(), [{<<"Proxy-Authenticate">>, Chal}], <<>>)),
        %% nta auto-ACKs the 407; then the authenticated INVITE arrives
        {Inv2, Src2} = uas_recv(Uas, <<"INVITE">>),
        true = has_auth(Inv2),
        ToTag = tag(),
        uas_send(Uas, Src2, resp(Inv2, 200, <<"OK">>, ToTag,
                                 [{<<"Contact">>, contact(UasPort)}], sdp())),
        {_Ack, _} = uas_recv(Uas, <<"ACK">>),
        Test ! authed
    end),
    Uri = <<"sip:secure@127.0.0.1:", (integer_to_binary(UasPort))/binary>>,
    {ok, _Dialog} = chappe_sip:create_uac(Uri,
                                    #{contact => contact(EnginePort),
                                      local_sdp => sdp(),
                                      auth => #{user => <<"alice">>,
                                                pass => <<"secret">>}}),
    receive authed -> ok after 5000 -> ct:fail(no_auth_invite) end.

%% OPTIONS out-of-dialog request -> 200 via await_response
options_request(_Config) ->
    {EnginePort, UasPort} = setup(),
    uas(UasPort, fun(Uas) ->
        {Req, Src} = uas_recv(Uas, <<"OPTIONS">>),
        uas_send(Uas, Src, resp(Req, 200, <<"OK">>, tag(),
                                [{<<"Allow">>, <<"INVITE, BYE, OPTIONS">>}],
                                <<>>))
    end),
    Uri = <<"sip:ping@127.0.0.1:", (integer_to_binary(UasPort))/binary>>,
    {ok, Ref} = chappe_sip:request(Uri, #{method => <<"OPTIONS">>,
                                    contact => contact(EnginePort)}),
    {ok, Msg} = chappe_sip_uac:await_response(Ref, 4000),
    ?assertEqual(200, chappe_sip_msg:status(Msg)),
    ?assertEqual(<<"INVITE, BYE, OPTIONS">>, chappe_sip_msg:get(<<"Allow">>, Msg)).

%% The callee hangs up the moment the ACK reaches it, which can be before
%% the UAC dialog has finished setting up its leg. The BYE must still be
%% answered 200 and the owner told, not dropped.
%% req: R3261-12.2.2-1
uac_bye_on_ack(_Config) ->
    {EnginePort, UasPort} = setup(),
    Test = self(),
    chappe_sip_test_ua:peer(UasPort, fun(Sock) ->
        {Inv, Src} = chappe_sip_test_ua:recv_req(Sock, <<"INVITE">>),
        Tag = tag(),
        chappe_sip_test_ua:send(Sock, Src, resp(Inv, 200, <<"OK">>, Tag,
                                [{<<"Contact">>, contact(UasPort)}], sdp())),
        {_Ack, _} = chappe_sip_test_ua:recv_req(Sock, <<"ACK">>),
        D = chappe_sip_test_ua:dialog_from_invite(Sock, Inv, Tag, Src),
        {Bye, _} = chappe_sip_test_ua:in_dialog(D, <<"BYE">>, [], <<>>),
        chappe_sip_test_ua:send(Sock, EnginePort, Bye),
        Test ! {bye_answer, chappe_sip_test_ua:recv_any(Sock, 4000)}
    end),
    Uri = <<"sip:callee@127.0.0.1:", (integer_to_binary(UasPort))/binary>>,
    {ok, Dialog} = chappe_sip:create_uac(Uri, #{contact => contact(EnginePort),
                                          local_sdp => sdp()}),
    receive {bye_answer, R} -> ?assertEqual(200, chappe_sip_test_ua:status(R))
    after 6000 -> ct:fail(no_bye_answer) end,
    receive {chappe_sip_dialog, Dialog, destroy, _} -> ok
    after 4000 -> ct:fail(no_destroy) end.

%% ---- helpers ----

setup() ->
    EnginePort = pick(),
    UasPort = pick(),
    ok = chappe_sip:start(#{contact => contact_bind(EnginePort)}),
    {EnginePort, UasPort}.

%% Spawn the UAS peer so it owns its socket (udp messages must reach the
%% process that recvs them). Blocks until the socket is bound.
uas(UasPort, ScenarioFun) ->
    Parent = self(),
    Pid = spawn_link(fun() ->
        {ok, Sock} = gen_udp:open(UasPort, [binary, {active, true},
                                            {ip, {127,0,0,1}}]),
        Parent ! {uas_ready, self()},
        ScenarioFun(Sock)
    end),
    receive {uas_ready, Pid} -> ok after 2000 -> ct:fail(uas_not_ready) end,
    Pid.

pick() -> chappe_sip_test_port:pick().
contact_bind(P) -> <<"sip:127.0.0.1:", (integer_to_binary(P))/binary>>.
contact(P) -> <<"sip:chappe@127.0.0.1:", (integer_to_binary(P))/binary>>.
tag() -> binary:encode_hex(crypto:strong_rand_bytes(5), lowercase).
sdp() ->
    <<"v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
      "t=0 0\r\nm=audio 40000 RTP/AVP 0\r\n">>.

%% A SIPREC body: the recording offer plus its metadata part.
multipart() ->
    <<"--chappe\r\nContent-Type: application/sdp\r\n\r\n",
      (sdp())/binary,
      "\r\n--chappe\r\nContent-Type: application/rs-metadata+xml\r\n\r\n"
      "<recording xmlns=\"urn:ietf:params:xml:ns:recording:1\"/>\r\n"
      "--chappe--\r\n">>.

uas_recv(Sock, Method) ->
    Len = byte_size(Method),
    receive
        {udp, Sock, _Ip, SrcPort, <<M:Len/binary, " ", _/binary>> = Bin}
          when M =:= Method ->
            {Bin, SrcPort};
        {udp, Sock, _Ip, _Src, _Other} ->
            uas_recv(Sock, Method)
    after 5000 -> ct:fail({uas_no, Method})
    end.

uas_send(Sock, DstPort, Bin) ->
    gen_udp:send(Sock, {127,0,0,1}, DstPort, Bin).

has_auth(ReqBin) ->
    {ok, Msg} = chappe_sip_msg:parse(ReqBin),
    chappe_sip_msg:has(<<"authorization">>, Msg) orelse
        chappe_sip_msg:has(<<"proxy-authorization">>, Msg).

%% Build a response echoing the request's Via/From/Call-ID/CSeq; add a To
%% tag if the request's To has none.
resp(ReqBin, Status, Reason, ToTag, ExtraHeaders, Body) ->
    {ok, Msg} = chappe_sip_msg:parse(ReqBin),
    Vias = chappe_sip_msg:get_all(<<"via">>, Msg),
    From = chappe_sip_msg:get(<<"from">>, Msg),
    To0 = chappe_sip_msg:get(<<"to">>, Msg),
    To = case chappe_sip_msg:to_tag(Msg) of
             undefined when Status > 100 -> <<To0/binary, ";tag=", ToTag/binary>>;
             _ -> To0
         end,
    Call = chappe_sip_msg:call_id(Msg),
    CSeq = chappe_sip_msg:get(<<"cseq">>, Msg),
    ViaLines = [[<<"Via: ">>, V, <<"\r\n">>] || V <- Vias],
    Extra = [[N, <<": ">>, Val, <<"\r\n">>] || {N, Val} <- ExtraHeaders],
    CL = integer_to_binary(byte_size(Body)),
    iolist_to_binary(
      [<<"SIP/2.0 ">>, integer_to_binary(Status), <<" ">>, Reason, <<"\r\n">>,
       ViaLines,
       <<"From: ">>, From, <<"\r\n">>,
       <<"To: ">>, To, <<"\r\n">>,
       <<"Call-ID: ">>, Call, <<"\r\n">>,
       <<"CSeq: ">>, CSeq, <<"\r\n">>,
       Extra,
       <<"Content-Length: ">>, CL, <<"\r\n\r\n">>, Body]).
