%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% chappe_sip_handler behaviour used by chappe_sip_handler_SUITE: answer with the caller's
%% SDP and report lifecycle to a test pid carried in the dialog options.
-module(chappe_sip_echo_handler).
-behaviour(chappe_sip_handler).

-export([init/1, handle_dialog/4, terminate/2]).

init(Req) ->
    Test = get(test_pid),
    {answer, #{local_sdp => chappe_sip_req:body(Req), handled_events => [info]}, Test}.

handle_dialog(info, _Req, Res, Test) ->
    _ = chappe_sip_res:send(Res, 200, #{reason => <<"OK">>}),
    Test ! got_info,
    {ok, Test};
handle_dialog(_Event, _Req, _Res, Test) ->
    {ok, Test}.

terminate(Reason, Test) when is_pid(Test) ->
    Test ! {handler_terminated, Reason},
    ok;
terminate(_Reason, _Test) ->
    ok.
