%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The implicit subscription of one accepted REFER (RFC 3515), on the
%% notifier side.
%%
%% It owns what the application should not have to: the NOTIFYs with their
%% message/sipfrag body, the Event header (with the id a second REFER in
%% the dialog needs), Subscription-State, the one-per-second rate limit
%% (RFC 3515 3.10) and the expiry.
%%
%% Two modes:
%%   - invite: the REFER came inside an INVITE dialog. This process keeps
%%     the expiry itself and answers the refreshing SUBSCRIBEs that
%%     chappe_sip_refer:route/3 hands it. The call outlives the
%%     subscription.
%%   - sub: the REFER came outside any dialog and formed its own
%%     subscription dialog (chappe_sip_dialog_fsm keeps the expiry and
%%     answers refreshes; this process is the dialog's owner and hears of
%%     them).
%%
%% Rate limit: a report that comes less than a second after the last
%% NOTIFY waits for the second to pass; a newer report replaces a waiting
%% one, so the referrer always gets the latest state, and a terminal one
%% (the final result) replaces anything and is never dropped.
-module(chappe_sip_refer_sub).
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    mode :: invite | sub,
    dialog :: chappe_sip_dialog:dialog() | undefined,
    event :: binary(),
    owner_mon :: reference(),
    %% invite mode: monotonic ms the subscription ends at, and its bounds
    expires_at = 0 :: integer(),
    expires :: pos_integer(),
    max_expires :: pos_integer(),
    gap :: non_neg_integer(),
    %% the latest status fragment: repeated by refreshes and a timeout
    frag :: binary(),
    %% the report waiting for the rate limit: {Frag, active | {terminated, R}}
    pending :: {binary(), active | {terminated, binary()}} | undefined,
    timer :: reference() | undefined,
    last_at :: integer() | undefined,
    %% a terminal NOTIFY is queued or sent: nothing after it
    closing = false :: boolean()
}).
-type state() :: #state{}.

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-spec init(map()) -> {ok, state()}.
init(#{mode := Mode, event := Event, owner := Owner} = Args) ->
    S = #state{
        mode = Mode,
        event = Event,
        owner_mon = erlang:monitor(process, Owner),
        expires = maps:get(expires, Args),
        max_expires = maps:get(max_expires, Args),
        gap = maps:get(gap, Args),
        frag = chappe_sip_sipfrag:build(100)
    },
    case Mode of
        invite ->
            D = maps:get(dialog, Args),
            {ok, arm_expiry(maps:get(expires, Args), watch(D, S))};
        sub ->
            {ok, S}
    end.

watch(D, S) ->
    _ = chappe_sip_dialog:monitor(D),
    S#state{dialog = D}.

handle_call({attach, D}, _From, #state{mode = sub} = S) ->
    %% a report made before the dialog existed goes out now
    _ = S#state.pending =/= undefined andalso (self() ! flush),
    {reply, ok, watch(D, S)};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

%% start: the REFER was answered; RFC 6665 4.2.1.2 wants a NOTIFY right away
handle_cast(start, S) ->
    report(S#state.frag, active, S);
handle_cast({emit, Frag, SubState}, S) ->
    report(Frag, SubState, S).

%% a refreshing SUBSCRIBE in the INVITE dialog (routed by chappe_sip_refer)
handle_info({subscribe, Req, Res}, #state{mode = invite} = S) ->
    refresh(Req, Res, S);
handle_info(flush, S) ->
    flush(S#state{timer = undefined});
handle_info(expire, #state{mode = invite} = S) ->
    case S#state.expires_at > now_ms() of
        true -> {noreply, S};
        false -> report(S#state.frag, {terminated, <<"timeout">>}, S)
    end;
%% sub mode: the subscription dialog reports refreshes and unsubscribes
handle_info({chappe_sip_dialog, _, {refreshed, _}, _Req}, S) ->
    report(S#state.frag, active, S);
handle_info({chappe_sip_dialog, _, unsubscribed, _Req}, S) ->
    report(S#state.frag, {terminated, <<"timeout">>}, S);
handle_info({chappe_sip_dialog, _, destroy, _}, S) ->
    {stop, normal, S};
handle_info({'DOWN', MRef, process, _, _}, #state{owner_mon = MRef} = S) ->
    %% the application is gone: nothing more will be learned about the
    %% referenced request, so end the subscription on what is known
    report(S#state.frag, {terminated, <<"noresource">>}, S);
handle_info({'DOWN', _MRef, process, _, _}, S) ->
    %% the dialog is gone: no NOTIFY can be sent any more
    {stop, normal, S};
handle_info(_Other, S) ->
    {noreply, S}.

%% the registry drops our row when it sees us go down
terminate(_Reason, _S) ->
    ok.

%% ---- reports and the rate limit ----

report(_Frag, _SubState, #state{closing = true} = S) ->
    {noreply, S};
report(Frag, SubState, S) ->
    Closing = SubState =/= active,
    S1 = S#state{
        frag = Frag, pending = {Frag, SubState}, closing = Closing
    },
    case S1#state.timer of
        undefined -> schedule(S1);
        _ -> {noreply, S1}
    end.

schedule(#state{last_at = undefined} = S) ->
    flush(S);
schedule(#state{last_at = Last, gap = Gap} = S) ->
    case Last + Gap - now_ms() of
        Wait when Wait =< 0 ->
            flush(S);
        Wait ->
            {noreply, S#state{timer = erlang:send_after(Wait, self(), flush)}}
    end.

flush(#state{pending = undefined} = S) ->
    {noreply, S};
flush(#state{dialog = undefined} = S) ->
    %% sub mode, before attach: kept until the dialog is there
    {noreply, S};
flush(#state{pending = {Frag, SubState}, dialog = D} = S) ->
    S1 = S#state{pending = undefined, last_at = now_ms()},
    Spec = #{
        event => S#state.event,
        state => sub_state(SubState),
        content_type => chappe_sip_sipfrag:content_type(),
        body => Frag
    },
    Result = chappe_sip_dialog:notify(D, with_expires(SubState, Spec, S1)),
    case {SubState, Result} of
        {active, {ok, Msg}} ->
            case ends_subscription(chappe_sip_msg:status(Msg)) of
                true -> {stop, normal, S1};
                false -> {noreply, S1}
            end;
        _ ->
            %% terminal NOTIFY sent, or the dialog cannot take any more
            {stop, normal, S1}
    end.

%% RFC 6665 4.2.2: a NOTIFY failing with one of these removes the
%% subscription
ends_subscription(St) ->
    lists:member(St, [404, 405, 408, 410, 416, 489, 501, 604]) orelse
        (St >= 480 andalso St =< 485).

sub_state(active) -> active;
sub_state({terminated, Reason}) -> {terminated, Reason}.

%% an INVITE dialog has no subscription of its own, so the remaining
%% expiry is ours to state; a subscription dialog adds it itself
with_expires(active, Spec, #state{mode = invite} = S) ->
    Spec#{expires => max(0, (S#state.expires_at - now_ms() + 999) div 1000)};
with_expires(_SubState, Spec, _S) ->
    Spec.

%% ---- refresh (invite mode) ----

refresh(Req, Res, #state{max_expires = Max, dialog = D} = S) ->
    Default = S#state.expires,
    Contact = [
        {<<"Contact">>, C}
     || C <- [chappe_sip_dialog:local_contact(D)],
        C =/= undefined
    ],
    case chappe_sip_subscription:requested_expires(Req, Default) of
        0 ->
            ok = answer(Res, 0, Contact),
            report(S#state.frag, {terminated, <<"timeout">>}, S);
        N ->
            Granted = min(N, Max),
            ok = answer(Res, Granted, Contact),
            report(S#state.frag, active, arm_expiry(Granted, S))
    end.

answer(Res, Expires, Contact) ->
    _ = chappe_sip_res:send(Res, 200, #{
        reason => <<"OK">>,
        headers => [{<<"Expires">>, integer_to_binary(Expires)} | Contact]
    }),
    ok.

arm_expiry(Seconds, S) ->
    _ = erlang:send_after(Seconds * 1000, self(), expire),
    S#state{expires_at = now_ms() + Seconds * 1000}.

now_ms() -> erlang:monotonic_time(millisecond).
