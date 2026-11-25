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
