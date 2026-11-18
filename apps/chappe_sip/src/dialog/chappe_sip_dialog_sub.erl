%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The subscription side of a dialog fsm (RFC 6665, RFC 3515), and
%% how a dialog ends: the refreshes it answers (200, 423, 403), the
%% NOTIFYs it sends, their outcome, and the teardown, a final NOTIFY for a
%% subscription and a BYE (or a final response, early) for an INVITE
%% dialog.
%%
%% The subscription itself, a map, is chappe_sip_subscription's; this
%% module runs it in the fsm, on its #data{}.
-module(chappe_sip_dialog_sub).

-export([handle_refresh/3, expire/1, after_request/3, term_reason/1]).
-export([start_teardown/3, start_final_notify/4, start_notify/3]).
-export([notify_headers/2]).

-include("chappe_sip_dialog_fsm.hrl").

%% NOTIFY responses that remove a subscription (RFC 6665 4.2.2), plus the
%% 408 of a Timer F timeout
-define(NOTIFY_ENDS_SUB(S),
    (S =:= 404 orelse S =:= 405 orelse S =:= 408 orelse S =:= 410 orelse
        S =:= 416 orelse (S >= 480 andalso S =< 485) orelse S =:= 489 orelse
        S =:= 501 orelse S =:= 604)
).

%% ---- refreshes (RFC 6665 4.2.1) ----

%% an in-dialog SUBSCRIBE refreshes this subscription only when its Event
%% names it (RFC 6665 8.2.1: type and id). Another one would be a second
%% subscription sharing the dialog, which is refused 403 (RFC 6665 4.5.2);
%% for the refer package that is also a subscription REFER did not create
%% (RFC 3515 2.4.4).
-spec handle_refresh(non_neg_integer(), chappe_sip_req:req(), #data{}) ->
    gen_statem:event_handler_result(atom()).
handle_refresh(TxnH, Req, #data{sub = #{event := Event}} = D) ->
    case
        chappe_sip_subscription:same_event(
            chappe_sip_req:get(<<"event">>, Req), Event
        )
    of
        true ->
            refresh(TxnH, Req, D);
        false ->
            _ = chappe_sip_dialog_out:respond(TxnH, 403, <<"Forbidden">>),
            {keep_state, D}
    end.

%% Expires 0 unsubscribes (the owner then sends the final NOTIFY), anything
%% else refreshes the expiry within max/min
refresh(TxnH, Req, #data{sub = #{max := Max, min := Min}} = D) ->
    case chappe_sip_subscription:requested_expires(Req, Max) of
        0 ->
            refreshed(TxnH, 0, unsubscribed, Req, D);
        N when N < Min ->
            Hdrs = [{<<"Min-Expires">>, integer_to_binary(Min)}],
            _ = chappe_sip_dialog_out:respond(
                TxnH, 423, <<"Interval Too Brief">>, Hdrs
            ),
            {keep_state, D};
        N ->
            Granted = min(N, Max),
            refreshed(TxnH, Granted, {refreshed, Granted}, Req, D)
    end.

%% the 200 to a refresh, the owner told, the expiry re-armed
refreshed(TxnH, Expires, Event, Req, #data{sub = Sub} = D) ->
    ok = refresh_respond(TxnH, Expires, D),
    chappe_sip_dialog_owner:notify4(D, Event, Req),
    Sub1 =
        case Event of
            unsubscribed -> chappe_sip_subscription:unsubscribed(Sub);
            {refreshed, _} -> chappe_sip_subscription:refreshed(Sub, Expires)
        end,
    {keep_state, D#data{sub = Sub1}, chappe_sip_subscription:timer(Sub1)}.

refresh_respond(TxnH, Expires, #data{sub = #{contact := Contact}}) ->
    Hdrs =
        [{<<"Expires">>, integer_to_binary(Expires)}] ++
            [{<<"Contact">>, Contact} || Contact =/= undefined],
    _ = chappe_sip_dialog_out:respond(TxnH, 200, <<"OK">>, Hdrs),
    ok.

%% the subscription's expiry timer
-spec expire(#data{}) -> gen_statem:event_handler_result(atom()).
expire(#data{sub = Sub} = D) ->
    case maps:get(expires_at, Sub) > now_ms() of
        true ->
            %% postponed during a NOTIFY, then refreshed meanwhile: the
            %% re-armed timer stands
            {keep_state, D};
        false ->
            start_final_notify(undefined, <<"timeout">>, expired, D)
    end.

now_ms() -> erlang:monotonic_time(millisecond).

%% ---- the end of a dialog ----

%% an INVITE dialog ends with a BYE (carrying the caller's extra headers,
%% e.g. a Reason, RFC 3326), a subscription with a final NOTIFY
-spec start_teardown(
    gen_statem:from() | undefined, [{binary(), iodata()}], #data{}
) -> gen_statem:event_handler_result(atom()).
start_teardown(
    From,
    Hdrs,
    #data{sub = undefined, role = uas, index_state = early, txn = Txn} = D
) when Txn =/= undefined ->
    %% RFC 3261 15: the callee sends no BYE on an early dialog; its INVITE
    %% gets a final response instead
    _ = chappe_sip_dialog_out:respond(
        Txn, 480, <<"Temporarily Unavailable">>, Hdrs
    ),
    chappe_sip_dialog_owner:reply(From, ok),
    D1 =
        case D#data.cdr_why of
            undefined -> D#data{cdr_why = {final, 480}};
            _ -> D
        end,
    chappe_sip_dialog_owner:stop(byed, D1);
start_teardown(From, Hdrs, #data{sub = undefined} = D) ->
    chappe_sip_dialog_out:start_bye(From, Hdrs, D);
start_teardown(From, _Hdrs, D) ->
    start_final_notify(From, <<"noresource">>, terminated, D).

-spec start_final_notify(
    gen_statem:from() | undefined, binary(), term(), #data{}
) -> gen_statem:event_handler_result(atom()).
start_final_notify(
    From, Reason, TermReason, #data{pending = undefined, sub = Sub} = D
) ->
    Seq = D#data.local_cseq + 1,
    {Sub1, Headers, Body} =
        chappe_sip_subscription:final_notify(Sub, Reason, TermReason),
    D1 = D#data{local_cseq = Seq, sub = Sub1},
    case chappe_sip_dialog_out:send(<<"NOTIFY">>, Seq, Headers, Body, D1) of
        {ok, TxnH} ->
            {next_state, terminating, D1#data{pending = {From, TxnH}}};
        {error, Why} ->
            chappe_sip_dialog_owner:reply(From, {error, Why}),
            chappe_sip_dialog_owner:stop(TermReason, D1)
    end;
start_final_notify(From, _Reason, _TermReason, D) ->
    %% final NOTIFY already in flight
    {keep_state, D, [{reply, From, ok}]}.

%% the reason the owner hears once the dialog's last request completes
-spec term_reason(#data{}) -> term().
term_reason(#data{sub = #{term_reason := R}}) -> R;
term_reason(#data{bye_reason = R}) when R =/= undefined -> R;
term_reason(_) -> byed.

%% ---- NOTIFY ----

%% NOTIFY built from notify/2's spec: Event defaults to the subscription's,
%% Subscription-State carries the remaining expires for active/pending
-spec start_notify(gen_statem:from(), map(), #data{}) ->
    gen_statem:event_handler_result(atom()).
start_notify(From, Spec, D) ->
    case notify_headers(Spec, D) of
        {ok, Headers, Terminal} ->
            ReqSpec = #{
                method => <<"NOTIFY">>,
                headers => Headers ++ maps:get(headers, Spec, []),
                body => maps:get(body, Spec, <<>>),
                content_type => maps:get(content_type, Spec, undefined)
            },
            D1 = D#data{
                sub = chappe_sip_subscription:keep_body(ReqSpec, D#data.sub)
            },
            chappe_sip_dialog_out:start_request(From, ReqSpec, D1, {
                notify, Terminal
            });
        {error, Reason} ->
            {keep_state, D, [{reply, From, {error, Reason}}]}
    end.

-spec notify_headers(map(), #data{}) ->
    {ok, [{binary(), binary()}], boolean()} | {error, atom()}.
notify_headers(Spec, D) ->
    case maps:get(event, Spec, sub_event(D)) of
        undefined ->
            {error, no_event};
        Event when D#data.sub =:= undefined ->
            %% RFC 6665 4.2.1: no subscription but by SUBSCRIBE, save
            %% REFER's implicit one (RFC 3515)
            case chappe_sip_hdr:event(Event) of
                {ok, #{type := T}} when T =:= <<"refer">>; T =:= <<"REFER">> ->
                    notify_state(Event, Spec, D);
                _ ->
                    {error, no_subscription}
            end;
        Event ->
            notify_state(Event, Spec, D)
    end.

notify_state(Event, Spec, D) ->
    State = maps:get(state, Spec, undefined),
    case chappe_sip_subscription:state_value(State, Spec, D#data.sub) of
        {ok, Value, Terminal} ->
            Headers =
                chappe_sip_subscription:event_header(Event) ++
                    [{<<"Subscription-State">>, Value}],
            {ok, Headers, Terminal andalso D#data.sub =/= undefined};
        error ->
            {error, badarg}
    end.

sub_event(#data{sub = #{event := E}}) -> E;
sub_event(_) -> undefined.

%% INVITE dialogs are unaffected by the response. A subscription ends on
%% the NOTIFY failures of RFC 6665 4.2.2 (and a Timer F 408) and once a
%% terminated NOTIFY is answered.
-spec after_request(term(), 100..699, #data{}) ->
    gen_statem:event_handler_result(atom()).
after_request(_Kind, Status, #data{sub = undefined} = D) when
    Status =:= 481; Status =:= 408
->
    %% RFC 3261 12.2.1.2: a 481 or 408 to an in-dialog request ends the
    %% dialog
    chappe_sip_dialog_owner:stop({request_failed, Status}, D);
after_request(_Kind, _Status, #data{sub = undefined} = D) ->
    {next_state, confirmed, D};
after_request(_Kind, Status, D) when ?NOTIFY_ENDS_SUB(Status) ->
    chappe_sip_dialog_owner:stop({notify_failed, Status}, D);
after_request({notify, true}, _Status, #data{sub = Sub} = D) ->
    %% a zero state timeout runs after the calls postponed meanwhile, so a
    %% destroy/1 waiting on this NOTIFY is answered before the fsm stops
    {next_state, confirmed, D#data{sub = Sub#{state := terminated}}, [
        {state_timeout, 0, sub_done}
    ]};
after_request(_Kind, _Status, D) ->
    {next_state, confirmed, D}.
