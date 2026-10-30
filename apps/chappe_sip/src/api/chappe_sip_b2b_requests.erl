%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The in-dialog requests a B2BUA call claims besides offers.
%%
%% create_b2bua/4's requests option names the requests (REFER, INFO,
%% MESSAGE, NOTIFY, OPTIONS) that go to the call's notify process as
%%   {chappe_sip_b2b, Ref, {request, a | b, Method, Req, Res}}
%% for it to answer with chappe_sip_res:send/3. With relay_info an INFO
%% from one leg (SIP INFO DTMF, RFC 6086) goes on to the other and its
%% final comes back. Without a notify process a claimed request gets what
%% the dialog would have answered: REFER 603, the others 200.
-module(chappe_sip_b2b_requests).

-export([handled/2, request/5]).

%% the events every leg of a relayed call leaves to the relay: offers
-define(RELAYED, [modify, update]).
-define(REQUESTS, [refer, info, message, notify, options]).

%% The handled_events of each leg of a call.
-spec handled([atom()], boolean()) -> [atom()].
handled(Requests, RelayInfo) ->
    ?RELAYED ++
        lists:usort(
            [R || R <- Requests, lists:member(R, ?REQUESTS)] ++
                [info || RelayInfo]
        ).

%% A claimed request from leg X. S: the relay state (a, b, requests,
%% relay_info, media).
-spec request(a | b, atom(), chappe_sip_req:req(), chappe_sip_res:res(), map()) ->
    ok.
request(X, info, Req, Res, #{relay_info := true} = S) ->
    Peer = maps:get(other(X), S),
    _ = spawn(fun() -> relay_info(Peer, Req, Res) end),
    ok;
request(X, Event, Req, Res, #{media := #{notify := Pid, ref := Ref}} = S) when
    is_pid(Pid)
->
    case lists:member(Event, maps:get(requests, S)) of
        true ->
            Pid ! {chappe_sip_b2b, Ref, {request, X, Event, Req, Res}},
            ok;
        false ->
            default_answer(Event, Res)
    end;
request(_X, Event, _Req, Res, _S) ->
    default_answer(Event, Res).

%% what a dialog answers a request nobody claimed
default_answer(refer, Res) ->
    _ = chappe_sip_res:send(Res, 603, #{reason => <<"Declined">>}),
    ok;
default_answer(_Event, Res) ->
    _ = chappe_sip_res:send(Res, 200, #{reason => <<"OK">>}),
    ok.

other(a) -> b;
other(b) -> a.

relay_info(Peer, Req, Res) ->
    Spec0 = #{
        method => <<"INFO">>,
        headers => [
            {<<"Info-Package">>, V}
         || V <- chappe_sip_req:get_all(<<"info-package">>, Req)
        ]
    },
    Spec =
        case chappe_sip_req:body(Req) of
            <<>> ->
                Spec0;
            Body ->
                Spec0#{
                    content_type => chappe_sip_req:get(<<"content-type">>, Req),
                    body => Body
                }
        end,
    Final =
        try chappe_sip_dialog:request(Peer, Spec) of
            {ok, Msg} -> {chappe_sip_msg:status(Msg), reason(Msg)};
            _ -> {500, <<"Server Internal Error">>}
        catch
            exit:_ -> {500, <<"Server Internal Error">>}
        end,
    {Status, Reason} = Final,
    _ = chappe_sip_res:send(Res, Status, #{reason => Reason}),
    ok.

reason(Msg) ->
    case chappe_sip_msg:reason(Msg) of
        undefined -> <<>>;
        R -> R
    end.
