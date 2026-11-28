%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The native backend's join, in the caller of chappe_mrf_conf:join/3
%% (chappe_mrf_conf_native:join/4): a call (chappe_sip_b2b:b2b()) or an
%% endpoint is handed to the room, which runs the join in helpers it
%% watches; an incoming call not answered yet is answered here, straight
%% into the mixer through rtpengine, or, with a pin, first to an endpoint
%% where the caller enters it (chappe_mrf_conf_pin), the room then moving
%% the call into the mixer.
-module(chappe_mrf_conf_native_join).

-include("chappe_mrf_conf.hrl").

-export([join/4]).

%% how long a joiner waits on the room: past the room's own deadline
%% (MRF_JOIN_MAX at most, from when the room took the join, and a call's
%% join whose loopback the mixer answered gets 3 s more), so that the
%% room's answer comes first
-define(JOIN_WAIT, (?MRF_JOIN_MAX + ?MRF_JOIN_MARGIN)).

%% In the caller: an incoming call, a call (chappe_sip_b2b:b2b()) or an
%% endpoint (a pid); any other handle is refused here, before the room. A
%% call joined with a pin names the endpoint it is on (endpoint), where
%% its caller enters the PIN.
-spec join(pid(), map(), term(), map()) -> {ok, binary()} | {error, term()}.
join(Conf, Info, {call, Req, Res}, #{pin := _} = Opts) ->
    pin_call(Conf, Info, Req, Res, Opts);
join(Conf, _Info, {call, Req, Res}, Opts) ->
    join_call(Conf, Req, Res, Opts);
join(Conf, _Info, {Pid, Ref} = B2b, #{pin := _, endpoint := Ep} = Opts) when
    is_pid(Pid), is_reference(Ref)
->
    chappe_mrf_conf:call(Conf, {join, {pin, B2b, Ep, Opts}}, ?JOIN_WAIT);
join(_Conf, _Info, {Pid, Ref}, #{pin := _}) when
    is_pid(Pid), is_reference(Ref)
->
    {error, {bad_option, endpoint}};
join(Conf, _Info, {Pid, Ref} = B2b, Opts) when is_pid(Pid), is_reference(Ref) ->
    chappe_mrf_conf:call(Conf, {join, {b2b, B2b, Opts}}, ?JOIN_WAIT);
join(Conf, _Info, Ep, Opts) when is_pid(Ep) ->
    chappe_mrf_conf:call(Conf, {join, {ep, Ep, Opts}}, ?JOIN_WAIT);
join(_Conf, _Info, _Target, _Opts) ->
    {error, badarg}.

%% An incoming call not answered yet, in its request worker: A is
%% answered by a B2BUA call to the loopback (the mixer behind rtpengine),
%% which then runs in a process of its own.
join_call(Conf, Req, Res, Opts0) ->
    Opts = caller_opts(Req, Opts0),
    case chappe_mrf_conf:call(Conf, {join, {call, Opts}}, 5000) of
        {ok, Token, Uri, AP, Entity} ->
            %% the room's REFERs come to the room (chappe_mrf_conf_refer);
            %% a focus room answers with the conference URI and isfocus
            %% as the member's Contact (RFC 4579 4.2)
            B2bOpts = (chappe_mrf_conf_refer_member:member_opts(Conf, Entity))#{
                media => anchor,
                anchor_params => AP
            },
            Result =
                case chappe_sip:create_b2bua(Req, Res, Uri, B2bOpts) of
                    {ok, Legs} -> relay(Legs, Conf);
                    {error, _} = Err -> Err
                end,
            %% the room answers once the loopback dialog is in too, or
            %% at the join's deadline at the latest
            case
                chappe_mrf_conf:call(
                    Conf, {backend, {call_done, Token, Result}}, ?JOIN_WAIT
                )
            of
                {ok, _} = Joined ->
                    Joined;
                Failed ->
                    %% a call the room did not take is hung up
                    ok = end_call(Result),
                    Failed
            end;
        Err ->
            Err
    end.

end_call({ok, B2b}) ->
    _ = chappe_sip_b2b:hangup(B2b, #{}),
    ok;
end_call(_Failed) ->
    ok.

%% The call runs on its own; its member dialog (leg A) is kept with it so
%% a REFER the call hands the room can be answered in that dialog.
relay(Legs, Conf) ->
    case chappe_sip_b2b:relay_async(Legs, #{notify => Conf}) of
        {ok, B2b} = Ok ->
            ok = chappe_mrf_conf_refer_member:keep_dialog(B2b, Legs),
            Ok;
        Err ->
            Err
    end.

%% An incoming call to a room that asks a PIN, in its request worker. The
%% room checks it may take a member, then chappe answers the caller to an
%% endpoint of this worker's (connect_caller/3, on a node of
%% pin_endpoint), with the room as the call's notify process; the room
%% has the caller enter the PIN there and moves the call into the mixer
%% (a PIN join, chappe_mrf_conf_native). The endpoint then goes: in the
%% room, its channel got the BYE of the move; out of it (a wrong PIN, a
%% refusal, a failed move), the call ends with it, after pin_fail_prompt
%% on a wrong PIN. A worker that dies takes the endpoint, and the call,
%% with it.
pin_call(Conf, Info, Req, Res, Opts0) ->
    Opts = caller_opts(Req, Opts0),
    Member = chappe_mrf_conf_refer_member:member_opts(
        Conf, maps:get(entity, Info, undefined)
    ),
    CallOpts = maps:merge(chappe_mrf_conf_pin:endpoint_opts(Opts), Member),
    maybe
        ok ?= chappe_mrf_conf:call(Conf, {join, check}, 5000),
        {ok, Ep, B2b} ?= chappe_mrf:connect_caller(Req, Res, CallOpts),
        Result = join(Conf, Info, B2b, Opts#{endpoint => Ep}),
        ok =
            case Result of
                {ok, _} -> chappe_mrf:destroy(Ep);
                {error, _} -> chappe_mrf_conf_pin:refuse(Ep, Result, Opts)
            end,
        Result
    end.

%% who the member is, for a REFER's method=BYE: the URI it calls from
caller_opts(Req, Opts) ->
    maps:merge(#{uri => chappe_mrf_conf_refer_member:from_uri(Req)}, Opts).
