%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% chappe_sip_uas_response: the dialog-forming response and the dialog
%% fsm's arguments, as pure functions.
-module(chappe_sip_uas_response_tests).

-include_lib("eunit/include/eunit.hrl").

-define(U, chappe_sip_uas_response).

msg(Method, Uri, Extra) ->
    Raw = iolist_to_binary([
        Method,
        " ",
        Uri,
        " SIP/2.0\r\n",
        "Via: SIP/2.0/UDP 192.0.2.1:5060;branch=z9hG4bK-1\r\n",
        "From: <sip:alice@example.com>;tag=ft\r\n",
        "To: <sip:bob@example.com>\r\n",
        "Call-ID: c1\r\n",
        "CSeq: 7 ",
        Method,
        "\r\n",
        Extra,
        "Content-Length: 0\r\n\r\n"
    ]),
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    Msg.

req(Method, Uri, Extra) ->
    chappe_sip_req:new(msg(Method, Uri, Extra), 42, #{}).

hdr(Name, Block) ->
    [
        V
     || <<N:(byte_size(Name))/binary, ": ", V/binary>> <-
            binary:split(Block, <<"\r\n">>, [global]),
        N =:= Name
    ].

build_2xx_test() ->
    {200, <<"OK">>, Hdrs, <<>>} = ?U:build(#{}, <<"<sip:me@h>">>),
    ?assertEqual([<<"<sip:me@h>">>], hdr(<<"Contact">>, Hdrs)),
    ?assertMatch([_], hdr(<<"Supported">>, Hdrs)),
    ?assertMatch([_], hdr(<<"Allow">>, Hdrs)).

build_sdp_test() ->
    {183, <<"Ringing">>, Hdrs, <<"v=0\r\n">>} =
        ?U:build(
            #{
                status => 183,
                reason => <<"Ringing">>,
                local_sdp => [<<"v=0">>, <<"\r\n">>]
            },
            <<"<sip:me@h>">>
        ),
    ?assertEqual([<<"application/sdp">>], hdr(<<"Content-Type">>, Hdrs)),
    %% a 1xx carries none of ours
    ?assertEqual([], hdr(<<"Contact">>, Hdrs)),
    ?assertEqual([], hdr(<<"Allow">>, Hdrs)).

app_headers_win_test() ->
    Opts = #{
        headers => [
            {<<"contact">>, <<"<sip:app@h>">>},
            {<<"Supported">>, <<"100rel">>}
        ]
    },
    {200, _, Hdrs, _} = ?U:build(Opts, <<"<sip:me@h>">>),
    ?assertEqual([], hdr(<<"Contact">>, Hdrs)),
    ?assertEqual([<<"100rel">>], hdr(<<"Supported">>, Hdrs)),
    ?assertEqual(<<"<sip:app@h>">>, ?U:dialog_contact(Opts, <<"<sip:me@h>">>)),
    ?assertEqual(<<"<sip:me@h>">>, ?U:dialog_contact(#{}, <<"<sip:me@h>">>)).

subscription_test() ->
    %% a subscription's 2xx lists neither Supported nor Allow
    H = ?U:with_allow(
        200,
        #{subscription => x},
        ?U:with_supported(200, #{subscription => x}, [])
    ),
    ?assertEqual([], H),
    ?assert(?U:has_hdr(<<"allow">>, [{<<"ALLOW">>, <<"x">>}, junk])),
    ?assertNot(?U:has_hdr(<<"allow">>, [junk])).

local_contact_test() ->
    ?assertEqual(
        <<"<sip:a@h:5060>">>,
        ?U:local_contact(<<"<sip:a@h:5060;transport=udp>">>)
    ),
    ?assertEqual(<<"<sip:anonymous.invalid>">>, ?U:local_contact(undefined)).

contact_uri_test() ->
    ?assertEqual(
        <<"sip:c@h">>, ?U:contact_uri(<<"<sip:c@h>;q=1">>, <<"<sip:r@h>">>)
    ),
    ?assertEqual(
        <<"sip:r@h">>, ?U:contact_uri(undefined, <<"<sip:r@h>;tag=x">>)
    ).

ack_wait_early_test() ->
    Inv = msg("INVITE", "sip:bob@example.com", ""),
    ?assert(?U:ack_wait(Inv, #{})),
    ?assertNot(?U:ack_wait(Inv, #{status => 180})),
    ?assert(?U:early(Inv, #{status => 180})),
    ?assertNot(?U:early(Inv, #{})),
    Sub = msg("SUBSCRIBE", "sip:bob@example.com", ""),
    ?assertNot(?U:ack_wait(Sub, #{})),
    ?assertNot(?U:early(Sub, #{status => 100})),
    ?assertEqual(7, ?U:remote_cseq(Inv)).

sips_contact_test() ->
    %% a sips Request-URI with no TLS listener falls back to the bound one
    R = req("INVITE", "sips:bob@example.com", ""),
    ?assertEqual(
        <<"<sips:me@h:5061>">>,
        ?U:contact(R, <<"sips:me@h:5061">>, <<"sip:me@h:5060">>)
    ),
    Plain = req("INVITE", "sip:bob@example.com", ""),
    ?assertEqual(
        <<"<sip:me@h:5060>">>,
        ?U:contact(Plain, <<"sips:me@h:5061">>, <<"sip:me@h:5060">>)
    ).

fsm_args_test() ->
    R = req(
        "INVITE",
        "sip:bob@example.com",
        "Contact: <sip:alice@192.0.2.1>\r\n"
        "Record-Route: <sip:p1;lr>\r\n"
    ),
    A = ?U:fsm_args(R, #{
        leg => 9,
        owner => self(),
        local_tag => <<"lt">>,
        contact => <<"<sip:me@h>">>,
        opts => #{cseq => 3}
    }),
    ?assertMatch(
        #{
            leg := 9,
            txn := 42,
            role := uas,
            local_tag := <<"lt">>,
            remote_target := <<"sip:alice@192.0.2.1">>,
            route_set := [<<"<sip:p1;lr>">>],
            call_id := <<"c1">>,
            remote_cseq := 7,
            cseq := 3,
            leg_ready := false,
            ack_wait := true,
            local_contact := <<"<sip:me@h>">>
        },
        A
    ),
    ?assertEqual(<<"<sip:bob@example.com>;tag=lt">>, maps:get(local_addr, A)).
