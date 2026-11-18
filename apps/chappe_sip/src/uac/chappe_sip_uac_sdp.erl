%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Offer/answer of one UAC INVITE (RFC 3261 13.2.1, RFC 3262 5),
%% pure: which SDP answers the peer's offer, in a PRACK or the 2xx ACK,
%% and which SDP is the peer's session. Used by chappe_sip_uac_fsm.
-module(chappe_sip_uac_sdp).

-include("chappe_sip_uac_fsm.hrl").

-export([first_sdp/2, ack_answer/2, reject_answer/1]).
-export([prack_answer/2, remote_sdp/2]).

%% remember the first SDP any response brought
first_sdp(Msg, #data{first_sdp = <<>>} = D) ->
    D#data{first_sdp = chappe_sip_msg:body(Msg)};
first_sdp(_Msg, D) ->
    D.

%% The ACK body for a 2xx: nothing when our INVITE made the offer or a
%% PRACK already answered it (RFC 3262 5); the app's answer when the 2xx
%% carries the offer (an INVITE without one). Without an answer fun, or
%% when it refuses, the offer is not acceptable.
ack_answer(_Msg, #data{local_answer = A}) when A =/= <<>> ->
    {ok, <<>>};
ack_answer(_Msg, #data{opts = #{no_ack := true}}) ->
    %% 3PCC: the answer goes in the ACK the app sends (chappe_sip_dialog:ack/2)
    {ok, <<>>};
ack_answer(Msg, #data{opts = Opts}) ->
    Offer = chappe_sip_msg:body(Msg),
    case {offered(Opts), Offer} of
        {true, _} ->
            {ok, <<>>};
        {false, <<>>} ->
            {ok, <<>>};
        {false, _} ->
            answer_offer(Offer, Opts)
    end.

answer_offer(Offer, Opts) ->
    case maps:get(answer, Opts, undefined) of
        F when is_function(F, 1) ->
            case F(Offer) of
                {ok, Answer} -> {ok, iolist_to_binary(Answer)};
                _ -> reject
            end;
        _ ->
            reject
    end.

offered(Opts) ->
    maps:is_key(local_sdp, Opts) orelse maps:is_key(body, Opts).

%% A valid answer refusing every stream of the offer: each m= line with
%% port 0 (RFC 3264 6).
reject_answer(Offer) ->
    Lines = binary:split(Offer, <<"\r\n">>, [global, trim_all]),
    iolist_to_binary([[reject_line(L), <<"\r\n">>] || L <- Lines]).

reject_line(<<"m=", Rest/binary>>) ->
    case binary:split(Rest, <<" ">>) of
        [Media, Tail] ->
            [_Port | Proto] = binary:split(Tail, <<" ">>),
            iolist_to_binary([<<"m=">>, Media, <<" 0 ">>, Proto]);
        _ ->
            <<"m=", Rest/binary>>
    end;
reject_line(L) ->
    L.

%% RFC 3262 5: an offer in a reliable 1xx (our INVITE had none) is
%% answered in the PRACK; the 2xx then carries no new offer
prack_answer(Msg, #data{opts = Opts, local_answer = <<>>} = D) ->
    Offer = chappe_sip_msg:body(Msg),
    case offered(Opts) orelse Offer =:= <<>> of
        true ->
            {<<>>, D};
        false ->
            case answer_offer(Offer, Opts) of
                {ok, Answer} -> {Answer, D#data{local_answer = Answer}};
                reject -> {<<>>, D}
            end
    end;
prack_answer(_Msg, D) ->
    {<<>>, D}.

%% the peer's session: the first SDP it sent when we made the offer or
%% answered its offer in a PRACK, else the offer in its 2xx
remote_sdp(Msg, #data{opts = Opts, first_sdp = First, local_answer = A}) ->
    case (offered(Opts) orelse A =/= <<>>) andalso First =/= <<>> of
        true -> First;
        false -> chappe_sip_msg:body(Msg)
    end.
