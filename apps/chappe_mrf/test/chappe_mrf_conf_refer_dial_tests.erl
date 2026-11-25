%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% What a REFER may put in a FreeSWITCH dial string
%% (chappe_mrf_conf_refer_dial): a plain SIP URI, a Replaces value, and
%% nothing that ends a line or the dial string.
-module(chappe_mrf_conf_refer_dial_tests).

-include_lib("eunit/include/eunit.hrl").

-define(D, chappe_mrf_conf_refer_dial).

%% req: MRF-11
dialable_test() ->
    ?assert(?D:dialable(<<"sip:carol@10.0.0.9:5060;transport=udp">>)),
    ?assertNot(?D:dialable(<<"sip:carol@10.0.0.9,sofia/x/y">>)),
    ?assertNot(?D:dialable(<<"sip:a:_:b@h">>)),
    %% a trailing newline is not the end of the URI
    ?assertNot(?D:dialable(<<"sip:carol@10.0.0.9\n">>)),
    ?assertNot(?D:dialable(<<"sip:carol@10.0.0.9\r\n">>)),
    ?assertNot(?D:dialable(<<"sip:carol@10.0.0.9\nsofia/x/y">>)).

%% req: MRF-17
safe_value_test() ->
    ?assert(?D:safe_value(<<"a/b(c)@h;to-tag=t1;from-tag=f1">>)),
    ?assertNot(?D:safe_value(<<"a{b}@h;to-tag=t1;from-tag=f1">>)),
    ?assertNot(?D:safe_value(<<"c1@h;to-tag=t1;from-tag=f1\n">>)),
    ?assertNot(?D:safe_value(<<"c1@h;to-tag=t1\n;from-tag=f1">>)).

%% dial_codecs goes into a dial string: codec names joined by commas, or
%% inherit; anything FreeSWITCH would read there is refused.
check_codecs_test() ->
    C = fun(V) ->
        chappe_mrf_conf_refer_dial:check_codecs(#{dial_codecs => V})
    end,
    ?assertEqual(ok, chappe_mrf_conf_refer_dial:check_codecs(#{})),
    ?assertEqual(ok, C(inherit)),
    ?assertEqual(ok, C(<<"OPUS,G722,PCMU,PCMA">>)),
    ?assertEqual(ok, C(<<"opus@48000h@20i,G722">>)),
    [
        ?assertEqual({error, {bad_option, dial_codecs}}, C(Bad))
     || Bad <- [
            <<>>,
            <<"PCMU,">>,
            <<"PCMU]sofia/x">>,
            <<"PCMU}">>,
            <<"PCMU PCMA">>,
            <<"PCMU\n">>,
            <<"PCMU:_:x">>,
            "PCMU",
            pcmu
        ]
    ].

%% The codecs a room's default dial string offers: on native by the
%% room's rate, the wideband ones first at 16 kHz and G.711 first at 8 kHz
%% (a G.711 party needs no transcoding); on fs FreeSWITCH's own choice,
%% as before dial_codecs (bgdial has no A-leg: the profile's codecs).
default_codecs_test() ->
    ?assertEqual(
        <<"OPUS,G722,PCMU,PCMA">>, ?D:default_codecs(#{rate => 16000})
    ),
    ?assertEqual(
        <<"OPUS,G722,PCMU,PCMA">>,
        ?D:default_codecs(#{backend => native, rate => 16000})
    ),
    ?assertEqual(<<"PCMU,PCMA,G722,OPUS">>, ?D:default_codecs(#{})),
    ?assertEqual(<<"PCMU,PCMA,G722,OPUS">>, ?D:default_codecs(#{rate => 8000})),
    ?assertEqual(inherit, ?D:default_codecs(#{backend => fs})),
    ?assertEqual(inherit, ?D:default_codecs(#{backend => my_backend})),
    %% the facade's, for a dial fun of your own
    ?assertEqual(
        <<"OPUS,G722,PCMU,PCMA">>, chappe_mrf:dial_codecs(#{rate => 16000})
    ),
    ?assertEqual(inherit, chappe_mrf:dial_codecs(#{backend => fs})).

%% The default dial string: the codecs as the party's own leg variable
%% before sofia/<profile>/<target>, nothing with inherit or without
%% codecs; a dial fun's string is its own.
dial_string_test() ->
    D = fun(Cfg) -> iolist_to_binary(?D:dial_string(Cfg, <<"sip:c@h">>)) end,
    ?assertEqual(
        <<"[^^:absolute_codec_string=OPUS,G722,PCMU,PCMA]sofia/external/c@h">>,
        D(#{codecs => ?D:default_codecs(#{rate => 16000})})
    ),
    ?assertEqual(
        <<"[^^:absolute_codec_string=PCMU,PCMA,G722,OPUS]sofia/carrier/c@h">>,
        D(#{codecs => ?D:default_codecs(#{}), profile => <<"carrier">>})
    ),
    ?assertEqual(
        <<"sofia/external/c@h">>,
        D(#{codecs => ?D:default_codecs(#{backend => fs})})
    ),
    ?assertEqual(<<"sofia/external/c@h">>, D(#{codecs => inherit})),
    ?assertEqual(<<"sofia/external/c@h">>, D(#{})),
    ?assertEqual(
        <<"sofia/mine/c@h">>,
        D(#{codecs => <<"PCMU">>, dial => fun(_) -> <<"sofia/mine/c@h">> end})
    ).
