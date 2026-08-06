%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Back-to-back user agent.
%%
%% create_b2bua bridges an incoming INVITE (the A/UAS leg) to a new
%% outgoing INVITE (the B/UAC leg). It runs in the request worker, so it
%% can react to an A-side CANCEL while B is still ringing. It returns
%% {ok, #{uas := ADialog, uac := BDialog}} once both legs are up.
%%
%% relay/1 links the two dialogs' lifecycles: when either leg is torn
%% down, the other is destroyed.
-module(chappe_sip_b2b).

-include("chappe_sip.hrl").
-include("chappe_sip_uac.hrl").

-export([create_b2bua/4, relay/1]).

%% Opts:
%%   local_sdp_b   => offer sent to B (default: A's INVITE body)
%%   local_sdp_a   => answer sent to A: value | fun(SdpB) (default: SdpB)
%%   proxy_request_headers  => [Name] | all | {all, [ExcludeName]}
%%   proxy_response_headers => [Name] (copied from B's 2xx to A's 200)
%%   pass_failure          => boolean (default true)
%%   pass_provisional_responses => boolean (default true)
%%   proxy, auth           => passed to the B-leg UAC
%%   timeout               => overall B answer timeout (default 32000)
-spec create_b2bua(chappe_sip_req:req(), chappe_sip_res:res(), binary(), map()) ->
    {ok, #{
        uas := chappe_sip_dialog:dialog(), uac := chappe_sip_dialog:dialog()
    }}
    | {error, term()}.
create_b2bua(Req, Res, Uri, Opts) ->
    Worker = self(),
    SdpAOffer = chappe_sip_req:body(Req),
    SdpBOffer = maps:get(local_sdp_b, Opts, SdpAOffer),
    ReqHeaders = proxy_request_headers(Req, Opts),
    BOpts0 = #{
        local_sdp => SdpBOffer,
        headers => ReqHeaders,
        notify => Worker,
        owner => Worker
    },
    %% flow' lets the B-leg originate over a registered WS connection
    BOpts = maps:merge(BOpts0, maps:with([proxy, auth, flow], Opts)),
    %% pre-choose the A-leg dialog tag so relayed provisionals and the
    %% final 2xx share one To-tag (otherwise nta auto-tags the first
    %% provisional and the leg tag never matches)
    ATag = chappe_sip_dialog:gen_tag(),
    case chappe_sip_uac:start(Uri, BOpts) of
        {ok, BRef} ->
            %% absolute deadline: provisionals must not extend the B answer
            %% window (a browser streaming 180 would keep the worker forever)
            Deadline =
                erlang:monotonic_time(millisecond) +
                    maps:get(timeout, Opts, 32000),
            b2b_wait(Req, Res, Opts, BRef, ATag, Deadline);
        {error, Reason} ->
            {error, Reason}
    end.

b2b_wait(Req, Res, Opts, BRef, ATag, Deadline) ->
    ATxn = chappe_sip_res:req_txn(Res),
    receive
        {chappe_sip_uac, BRef, {request_sent, _}} ->
            b2b_wait(Req, Res, Opts, BRef, ATag, Deadline);
        {chappe_sip_uac, BRef, {provisional, BMsg}} ->
            maybe_relay_provisional(ATxn, ATag, BMsg, Opts),
            b2b_wait(Req, Res, Opts, BRef, ATag, Deadline);
        {chappe_sip_uac, BRef, {ok, BDialog}} ->
            answer_a(Req, Res, Opts, BDialog, ATag);
        {chappe_sip_uac, BRef, {error, SipError}} ->
            handle_b_failure(Res, SipError, Opts);
        {chappe_sip_cancel, ATxn} ->
            chappe_sip_uac:cancel(BRef),
            _ = chappe_sip_res:send(Res, 487, #{
                reason => <<"Request Terminated">>
            }),
            {error, cancelled}
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        chappe_sip_uac:cancel(BRef),
        _ = chappe_sip_res:send(Res, 504, #{reason => <<"Server Time-out">>}),
        {error, timeout}
    end.

answer_a(Req, Res, Opts, BDialog, ATag) ->
    SdpBAnswer = chappe_sip_dialog:remote_sdp(BDialog),
    SdpAAnswer = compute_sdp_a(Opts, SdpBAnswer),
    RespHeaders = proxy_response_headers(BDialog, Opts),
    UasOpts = #{
        local_sdp => SdpAAnswer,
        headers => RespHeaders,
        local_tag => ATag,
        owner => self()
    },
    case chappe_sip:create_uas(Req, Res, UasOpts) of
        {ok, ADialog} ->
            {ok, #{uas => ADialog, uac => BDialog}};
        {error, Reason} ->
            chappe_sip_dialog:destroy(BDialog),
            {error, Reason}
    end.

handle_b_failure(
    Res,
    #chappe_sip_error{status = Status, reason = Reason},
    Opts
) ->
    case maps:get(pass_failure, Opts, true) of
        true ->
            _ = chappe_sip_res:send(Res, Status, #{reason => Reason}),
            {error, #chappe_sip_error{status = Status, reason = Reason}};
        false ->
            {error, #chappe_sip_error{status = Status, reason = Reason}}
    end;
handle_b_failure(Res, Other, _Opts) ->
    %% the B leg failed below the SIP layer (a bad target, engine down, ...)
    _ = chappe_sip_res:send(Res, 500, #{reason => <<"Server Internal Error">>}),
    {error, Other}.

maybe_relay_provisional(ATxn, ATag, BMsg, Opts) ->
    case maps:get(pass_provisional_responses, Opts, true) of
        true ->
            Status = chappe_sip_msg:status(BMsg),
            case Status of
                % never relay 100 Trying
                100 ->
                    ok;
                _ ->
                    Reason = default_reason(chappe_sip_msg:reason(BMsg)),
                    %% tag the provisional with the pre-chosen A-leg tag so
                    %% the early dialog matches the eventual 2xx
                    _ = chappe_sip_engine:dialog_respond(
                        ATxn,
                        Status,
                        Reason,
                        <<>>,
                        <<>>,
                        ATag
                    )
            end;
        false ->
            ok
    end.

compute_sdp_a(Opts, SdpB) ->
    case maps:get(local_sdp_a, Opts, undefined) of
        undefined -> SdpB;
        Fun when is_function(Fun, 1) -> Fun(SdpB);
        Val -> Val
    end.

%% Link the two dialogs: block until either is torn down, then destroy
%% the other. Runs in the process that owns both dialogs (the worker).
-spec relay(#{
    uas := chappe_sip_dialog:dialog(), uac := chappe_sip_dialog:dialog()
}) ->
    {done, a_bye | b_bye | term()}.
relay(#{uas := A, uac := B}) ->
    RefA = chappe_sip_dialog:monitor(A),
    RefB = chappe_sip_dialog:monitor(B),
    relay_loop(A, B, RefA, RefB).

relay_loop(A, B, RefA, RefB) ->
    receive
        {chappe_sip_dialog, A, destroy, _} ->
            _ = chappe_sip_dialog:destroy(B),
            {done, a_bye};
        {chappe_sip_dialog, B, destroy, _} ->
            _ = chappe_sip_dialog:destroy(A),
            {done, b_bye};
        %% an abnormal fsm exit emits no destroy message; tear the peer down
        {'DOWN', RefA, process, _, _} ->
            _ = chappe_sip_dialog:destroy(B),
            {done, a_bye};
        {'DOWN', RefB, process, _, _} ->
            _ = chappe_sip_dialog:destroy(A),
            {done, b_bye};
        {chappe_sip_dialog, _, _, _} ->
            relay_loop(A, B, RefA, RefB);
        {chappe_sip_dialog, _, _, _, _} ->
            relay_loop(A, B, RefA, RefB)
    end.

%% ---- header proxying ----

%% default headers never copied verbatim between legs
excluded() ->
    [
        <<"via">>,
        <<"route">>,
        <<"record-route">>,
        <<"cseq">>,
        <<"call-id">>,
        <<"from">>,
        <<"to">>,
        <<"contact">>,
        <<"content-length">>,
        <<"max-forwards">>,
        <<"content-type">>,
        <<"authorization">>,
        <<"proxy-authorization">>,
        <<"www-authenticate">>,
        <<"proxy-authenticate">>
    ].

proxy_request_headers(Req, Opts) ->
    Msg = chappe_sip_req:msg(Req),
    case maps:get(proxy_request_headers, Opts, []) of
        [] ->
            [];
        all ->
            copy_all(Msg, []);
        {all, Exclude} ->
            copy_all(Msg, [string:lowercase(N) || N <- Exclude]);
        Names when is_list(Names) ->
            copy_named(Msg, Names)
    end.

proxy_response_headers(_BDialog, _Opts) ->
    %% Copying selected headers from B's 2xx to A's 200 needs the raw 2xx,
    %% which the dialog does not retain. Left for a later refinement; the
    %% common case (SDP passthrough) is covered by local_sdp_a.
    [].

copy_named(Msg, Names) ->
    lists:flatten(
        [[{N, V} || V <- chappe_sip_msg:get_all(N, Msg)] || N <- Names]
    ).

copy_all(Msg, ExtraExclude) ->
    Exclude = excluded() ++ ExtraExclude,
    [
        {Name, Value}
     || {Norm, Name, Value} <- chappe_sip_msg:all_headers(Msg),
        not lists:member(Norm, Exclude)
    ].

default_reason(undefined) -> <<"Session Progress">>;
default_reason(<<>>) -> <<"Session Progress">>;
default_reason(R) -> R.
