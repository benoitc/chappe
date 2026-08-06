%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

-module(chappe_sip_msg_tests).
-include_lib("eunit/include/eunit.hrl").

invite() ->
    <<"INVITE sip:bob@biloxi.com SIP/2.0\r\n"
      "Via: SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bK776asdhds\r\n"
      "Max-Forwards: 70\r\n"
      "To: Bob <sip:bob@biloxi.com>\r\n"
      "From: Alice <sip:alice@atlanta.com>;tag=1928301774\r\n"
      "Call-ID: a84b4c76e66710@pc33.atlanta.com\r\n"
      "CSeq: 314159 INVITE\r\n"
      "Contact: <sip:alice@pc33.atlanta.com>\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: 4\r\n"
      "\r\n"
      "v=0\r\n">>.

response_200() ->
    <<"SIP/2.0 200 OK\r\n"
      "Via: SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bK776asdhds;received=192.0.2.1\r\n"
      "To: Bob <sip:bob@biloxi.com>;tag=a6c85cf\r\n"
      "From: Alice <sip:alice@atlanta.com>;tag=1928301774\r\n"
      "Call-ID: a84b4c76e66710@pc33.atlanta.com\r\n"
      "CSeq: 314159 INVITE\r\n"
      "Content-Length: 0\r\n"
      "\r\n">>.

parse_request_test() ->
    {ok, M} = chappe_sip_msg:parse(invite()),
    ?assertEqual(request, chappe_sip_msg:type(M)),
    ?assertEqual(<<"INVITE">>, chappe_sip_msg:method(M)),
    ?assertEqual(<<"sip:bob@biloxi.com">>, chappe_sip_msg:uri(M)),
    ?assertEqual(<<"a84b4c76e66710@pc33.atlanta.com">>, chappe_sip_msg:call_id(M)),
    ?assertEqual(<<"v=0\r\n">>, chappe_sip_msg:body(M)),
    ?assertEqual(<<"70">>, chappe_sip_msg:get(<<"Max-Forwards">>, M)).

parse_response_test() ->
    {ok, M} = chappe_sip_msg:parse(response_200()),
    ?assertEqual(response, chappe_sip_msg:type(M)),
    ?assertEqual(200, chappe_sip_msg:status(M)),
    ?assertEqual(<<"OK">>, chappe_sip_msg:reason(M)),
    ?assertEqual(<<"a6c85cf">>, chappe_sip_msg:to_tag(M)).

roundtrip_fidelity_test() ->
    In = invite(),
    {ok, M} = chappe_sip_msg:parse(In),
    ?assertEqual(In, iolist_to_binary(chappe_sip_msg:encode(M))),
    In2 = response_200(),
    {ok, M2} = chappe_sip_msg:parse(In2),
    ?assertEqual(In2, iolist_to_binary(chappe_sip_msg:encode(M2))).

compact_forms_test() ->
    Raw = <<"MESSAGE sip:x@y SIP/2.0\r\n"
            "v: SIP/2.0/UDP h:5060;branch=z9hG4bK1\r\n"
            "f: <sip:a@b>;tag=t1\r\n"
            "t: <sip:x@y>\r\n"
            "i: cid1@h\r\n"
            "l: 0\r\n"
            "\r\n">>,
    {ok, M} = chappe_sip_msg:parse(Raw),
    ?assertEqual(<<"cid1@h">>, chappe_sip_msg:call_id(M)),
    ?assertEqual(<<"t1">>, chappe_sip_msg:from_tag(M)),
    ?assertEqual(<<"0">>, chappe_sip_msg:get(<<"Content-Length">>, M)),
    %% compact spelling survives re-encoding untouched
    ?assertEqual(Raw, iolist_to_binary(chappe_sip_msg:encode(M))).

folded_header_test() ->
    Raw = <<"OPTIONS sip:x@y SIP/2.0\r\n"
            "Subject: first line\r\n"
            " second line\r\n"
            "Call-ID: f1@h\r\n"
            "\r\n">>,
    {ok, M} = chappe_sip_msg:parse(Raw),
    ?assertEqual(<<"first line second line">>, chappe_sip_msg:get(<<"Subject">>, M)),
    ?assertEqual(Raw, iolist_to_binary(chappe_sip_msg:encode(M))).

%% RFC 4475 3.1.1.1 flavor: exotic but valid spacing and casing
torture_spacing_test() ->
    Raw = <<"INVITE sip:vivisimo@chair-dnrc.example.com SIP/2.0\r\n"
            "TO :\r\n"
            " sip:vivisimo@chair-dnrc.example.com ;   tag    = 1918181833n\r\n"
            "from   : \"J Rosenberg \\\"\"       <sip:jdrosen@example.com>\r\n"
            "  ;\r\n"
            "  tag = 98asjd8\r\n"
            "MaX-fOrWaRdS: 0068\r\n"
            "Call-ID: wsinv.ndaksdj@192.0.2.1\r\n"
            "CSeq: 0009\r\n"
            "  INVITE\r\n"
            "Content-Length: 0\r\n"
            "\r\n">>,
    {ok, M} = chappe_sip_msg:parse(Raw),
    ?assertEqual(<<"0068">>, chappe_sip_msg:get(<<"max-forwards">>, M)),
    {ok, #{seq := 9, method := <<"INVITE">>}} = chappe_sip_msg:cseq(M),
    ?assertEqual(Raw, iolist_to_binary(chappe_sip_msg:encode(M))).

%% Vendor P-headers carry RFC 3261 token characters in the name - notably
%% dots (P-Com.Nokia.B2BUA-Involved, P-com.Siemens.IMSI-ID) and !%*+`'~. A
%% parser that stops the name at a dot drops them (a real drachtio interop
%% bug). They must parse, be retrievable, and survive re-encoding.
vendor_header_names_test() ->
    Names = [<<"P-Com.Nokia.B2BUA-Involved">>, <<"P-com.Siemens.IMSI-ID">>,
             <<"P-NOKIA.Traffica">>, <<"X-Header!Bang">>, <<"X-Header%Pct">>,
             <<"X-Header*Star">>, <<"X-Header+Plus">>, <<"X-Header~Tilde">>],
    Lines = [[N, <<": v">>, integer_to_binary(I), <<"\r\n">>]
             || {N, I} <- lists:zip(Names, lists:seq(1, length(Names)))],
    Raw = iolist_to_binary(
            [<<"OPTIONS sip:x@y SIP/2.0\r\n">>,
             <<"Via: SIP/2.0/UDP h;branch=z9hG4bK1\r\n">>,
             <<"Call-ID: vh@h\r\n">>, Lines, <<"Content-Length: 0\r\n\r\n">>]),
    {ok, M} = chappe_sip_msg:parse(Raw),
    [?assertEqual(<<"v", (integer_to_binary(I))/binary>>,
                  chappe_sip_msg:get(N, M))
     || {N, I} <- lists:zip(Names, lists:seq(1, length(Names)))],
    ?assertEqual(Raw, iolist_to_binary(chappe_sip_msg:encode(M))).

%% parse/1 is total: even a non-UTF-8 header name (which the old Unicode
%% lowercase raised on) must return a result, never throw. A crafted UDP
%% packet must not crash the request worker.
parse_total_test() ->
    Bad = <<"OPTIONS sip:x@y SIP/2.0\r\n",
            "Via: SIP/2.0/UDP h;branch=z9hG4bK1\r\n",
            16#FF, 16#FE, ": junk\r\n",              % invalid UTF-8 header name
            "From: <sip:a@b>;tag=1\r\nTo: <sip:x@y>\r\n",
            "Call-ID: t@h\r\nCSeq: 1 OPTIONS\r\nContent-Length: 0\r\n\r\n">>,
    ?assertMatch({ok, _}, chappe_sip_msg:parse(Bad)),
    %% arbitrary garbage never throws
    ?assertMatch({_, _}, chappe_sip_msg:parse(<<0, 1, 2, 255, "\r\n\r\n">>)),
    ?assertMatch({_, _}, chappe_sip_msg:parse(<<>>)).

%% RFC 3261 8.1.1: a message missing a mandatory header is rejected upstream
%% (the ingress answers 400).
validate_test() ->
    {ok, Ok} = chappe_sip_msg:parse(invite()),
    ?assertEqual(ok, chappe_sip_msg:validate(Ok)),
    NoTo = <<"OPTIONS sip:x@y SIP/2.0\r\n"
             "Via: SIP/2.0/UDP h;branch=z9hG4bK1\r\n"
             "From: <sip:a@b>;tag=1\r\n"
             "Call-ID: t@h\r\nCSeq: 1 OPTIONS\r\n\r\n">>,
    {ok, M} = chappe_sip_msg:parse(NoTo),
    ?assertEqual({error, missing_header}, chappe_sip_msg:validate(M)).

multiple_headers_test() ->
    Raw = <<"INVITE sip:x@y SIP/2.0\r\n"
            "Route: <sip:p1.example.com;lr>\r\n"
            "Route: <sip:p2.example.com;lr>\r\n"
            "Call-ID: m1@h\r\n"
            "\r\n">>,
    {ok, M} = chappe_sip_msg:parse(Raw),
    ?assertEqual([<<"<sip:p1.example.com;lr>">>, <<"<sip:p2.example.com;lr>">>],
                 chappe_sip_msg:get_all(<<"Route">>, M)).

set_add_remove_test() ->
    {ok, M0} = chappe_sip_msg:parse(invite()),
    M1 = chappe_sip_msg:set(<<"Max-Forwards">>, <<"69">>, M0),
    ?assertEqual(<<"69">>, chappe_sip_msg:get(<<"Max-Forwards">>, M1)),
    M2 = chappe_sip_msg:add(<<"X-Custom">>, <<"abc">>, M1),
    ?assertEqual(<<"abc">>, chappe_sip_msg:get(<<"X-Custom">>, M2)),
    M3 = chappe_sip_msg:remove(<<"X-Custom">>, M2),
    ?assertEqual(undefined, chappe_sip_msg:get(<<"X-Custom">>, M3)).

set_body_test() ->
    {ok, M0} = chappe_sip_msg:parse(invite()),
    M1 = chappe_sip_msg:set_body(<<"v=0\r\no=x\r\n">>, M0),
    ?assertEqual(<<"10">>, chappe_sip_msg:get(<<"Content-Length">>, M1)),
    ?assertEqual(<<"v=0\r\no=x\r\n">>, chappe_sip_msg:body(M1)).

can_form_dialog_test() ->
    {ok, Inv} = chappe_sip_msg:parse(invite()),
    ?assert(chappe_sip_msg:can_form_dialog(Inv)),
    %% in-dialog request has a To tag
    Raw = <<"BYE sip:bob@biloxi.com SIP/2.0\r\n"
            "To: <sip:bob@biloxi.com>;tag=xyz\r\n"
            "From: <sip:alice@atlanta.com>;tag=abc\r\n"
            "Call-ID: c@h\r\n"
            "\r\n">>,
    {ok, Bye} = chappe_sip_msg:parse(Raw),
    ?assertNot(chappe_sip_msg:can_form_dialog(Bye)).

builder_test() ->
    M = chappe_sip_msg:new_request(<<"OPTIONS">>, <<"sip:ping@example.com">>,
                             [{<<"Max-Forwards">>, <<"70">>},
                              {<<"Call-ID">>, <<"b1@h">>}]),
    Enc = iolist_to_binary(chappe_sip_msg:encode(M)),
    ?assertMatch({0, _}, binary:match(Enc, <<"OPTIONS sip:ping@example.com SIP/2.0\r\n">>)),
    {ok, Re} = chappe_sip_msg:parse(Enc),
    ?assertEqual(<<"b1@h">>, chappe_sip_msg:call_id(Re)).
