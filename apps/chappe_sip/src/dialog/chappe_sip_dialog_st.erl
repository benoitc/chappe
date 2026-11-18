%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The session timer of a dialog fsm (RFC 4028): its two timers, the
%% peer's refreshes, the refresh it sends (UPDATE, else a re-INVITE) and
%% the response to it.
%%
%% The negotiation is chappe_sip_session_timer's; this module runs it in
%% the fsm, on its #data{}.
-module(chappe_sip_dialog_st).

-export([st_timers/1, st_apply/2, st_incoming/3, st_response/3]).
-export([with_actions/2, start_st_refresh/1, st_refresh_response/5]).

-include("chappe_sip_dialog_fsm.hrl").

-spec st_timers(chappe_sip_session_timer:st() | undefined) -> [tuple()].
st_timers(undefined) -> [];
st_timers(St) -> chappe_sip_session_timer:timeouts(St).

%% a new session timer state restarts both timers (a 2xx refreshed it)
-spec st_apply(chappe_sip_session_timer:st() | undefined, #data{}) ->
    gen_statem:event_handler_result(atom()).
st_apply(undefined, #data{st = undefined} = D) ->
    {keep_state, D};
st_apply(St, D) ->
    {keep_state, D#data{st = St}, chappe_sip_session_timer:timeouts(St)}.

%% the peer's INVITE or UPDATE is a session refresh request (section 9)
-spec st_incoming(binary(), chappe_sip_req:req(), #data{}) ->
    {reject, pos_integer()}
    | {ok, [{binary(), binary()}], chappe_sip_session_timer:st() | undefined}.
st_incoming(Method, Req, #data{st = St, st_cfg = Cfg}) when
    Method =:= <<"INVITE">>; Method =:= <<"UPDATE">>
->
    chappe_sip_session_timer:incoming(chappe_sip_req:msg(Req), Cfg, St);
st_incoming(_Method, _Req, #data{st = St}) ->
    {ok, [], St}.

%% a 2xx to our INVITE or UPDATE refreshes the session (RFC 4028 7.2)
-spec st_response(100..699, binary(), #data{}) -> {#data{}, [tuple()]}.
st_response(Status, Raw, #data{st = St} = D) when Status >= 200, Status < 300 ->
    case chappe_sip_msg:parse(Raw) of
        {ok, Msg} ->
            case chappe_sip_msg:cseq(Msg) of
                {ok, #{method := M}} when
                    M =:= <<"INVITE">>; M =:= <<"UPDATE">>
                ->
                    case chappe_sip_session_timer:response(Msg, Status, St) of
                        undefined when St =:= undefined -> {D, []};
                        St1 -> {D#data{st = St1}, timeouts(St1)}
                    end;
                _ ->
                    {D, []}
            end;
        {error, _} ->
            {D, []}
    end;
st_response(_Status, _Raw, D) ->
    {D, []}.

%% timeouts/1 of undefined cancels both timers
timeouts(St) -> chappe_sip_session_timer:timeouts(St).

-spec with_actions(gen_statem:event_handler_result(atom()), [tuple()]) ->
    gen_statem:event_handler_result(atom()).
with_actions(Result, []) ->
    Result;
with_actions({next_state, S, D}, A) ->
    {next_state, S, D, A};
with_actions({next_state, S, D, A0}, A) ->
    {next_state, S, D, A0 ++ A};
with_actions({keep_state, D}, A) ->
    {keep_state, D, A};
with_actions({keep_state, D, A0}, A) ->
    {keep_state, D, A0 ++ A};
with_actions(Stop, _A) ->
    Stop.

%% Refresh at half the interval (section 10): UPDATE without a body when
%% the peer allows it, else a re-INVITE offering the unchanged SDP (7.4).
-spec start_st_refresh(#data{}) -> gen_statem:event_handler_result(atom()).
start_st_refresh(#data{st = #{peer_update := true}} = D) ->
    send_st_refresh(<<"UPDATE">>, [], <<>>, D);
start_st_refresh(#data{local_sdp = Sdp} = D) ->
    %% the session as we last offered it: an SDP, or the multipart a SIPREC
    %% recording session sends (modify/3 content_type)
    CT = [
        {<<"Content-Type">>, chappe_sip_multipart:content_type(Sdp)}
     || Sdp =/= <<>>
    ],
    send_st_refresh(<<"INVITE">>, CT, Sdp, D).

%% the expiry timer still ends the session when the refresh cannot be sent
send_st_refresh(Method, Headers, Body, #data{st = St} = D) ->
    Seq = D#data.local_cseq + 1,
    Hdrs = Headers ++ chappe_sip_session_timer:refresh_headers(St),
    chappe_sip_dialog_out:transact(
        undefined, {st_refresh, Method}, {Method, Seq, Hdrs, Body}, D
    ).

%% The final response to our refresh; a 2xx already re-armed the timers.
-spec st_refresh_response(
    gen_statem:from() | undefined, term(), 100..699, binary(), #data{}
) -> gen_statem:event_handler_result(atom()).
st_refresh_response(_From, _Kind, Status, _Raw, D) when Status < 200 ->
    {keep_state, D};
st_refresh_response(_From, {st_refresh, Method}, Status, Raw, D) when
    Status < 300
->
    D1 =
        case Method of
            <<"INVITE">> ->
                {ok, Msg} = chappe_sip_msg:parse(Raw),
                _ = chappe_sip_dialog_out:send_ack(D),
                D#data{remote_sdp = chappe_sip_msg:body(Msg)};
            _ ->
                D
        end,
    {next_state, confirmed, st_done(D1)};
st_refresh_response(_From, _Kind, Status, _Raw, D) when
    Status =:= 408; Status =:= 481
->
    %% section 10: the refresh timed out or the dialog is gone
    chappe_sip_dialog_sub:start_teardown(undefined, [], (st_done(D))#data{
        bye_reason = {refresh_failed, Status}
    });
st_refresh_response(_From, _Kind, 422, Raw, #data{st = St} = D) ->
    %% section 7.3: retry with the larger Min-SE the 422 names
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    case chappe_sip_session_timer:retry_after_422(Msg, St) of
        {retry, St1} -> start_st_refresh((st_done(D))#data{st = St1});
        give_up -> {next_state, confirmed, st_done(D)}
    end;
st_refresh_response(_From, _Kind, 491, _Raw, D) ->
    %% RFC 3261 14.1: glare, retry after 2.1 to 4 s
    {next_state, confirmed, st_done(D), [
        {{timeout, st_refresh}, 2100 + rand:uniform(1900), refresh}
    ]};
st_refresh_response(_From, _Kind, _Status, _Raw, D) ->
    %% no retry: the expiry timer ends the session unless the peer refreshes
    {next_state, confirmed, st_done(D)}.

%% the next request takes local_cseq + 1, so a 422 retry is one higher
st_done(D) ->
    D#data{txning = undefined}.
