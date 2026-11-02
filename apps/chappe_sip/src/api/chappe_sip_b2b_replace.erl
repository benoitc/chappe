%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Replacing leg B of an anchored B2BUA call (chappe_sip_b2b:replace_b/3).
%%
%% The relay gets rtpengine's offer for A's side of the session (an offer
%% from A's tag, with A's SDP), so A keeps the addresses it sends to and
%% sees no re-INVITE. call/4 then brings the new B in, off the relay
%% loop: a fresh INVITE to a URI, a re-INVITE of a dialog the app made, or
%% one INVITE per destination of a {parallel, Dests} target. On a 2xx,
%% swap/4 gives rtpengine the new B's answer and moves the relay onto the
%% new dialog; the old B gets a BYE. On a failure the relay hands
%% rtpengine the old B's SDP back.
%%
%% Which tag the answer goes under depends on the offer, as measured
%% against the real rtpengine. One offer (a URI, a dialog, a fork whose
%% destinations all take the same flags) reopens leg B's own media, so the
%% answer keeps leg B's tag: a new to-tag would be a new branch, with other
%% ports than the ones the new B was given. Several offers (a fork with
%% different flags) are each a branch of their own, named by a via-branch:
%% the answer names the winner's via-branch under the winner's To-tag,
%% which the call keeps from then on. Under leg B's old tag, the answer of
%% a via-branch other than the first reaches nobody.
-module(chappe_sip_b2b_replace).

-export([offer/4, call/4, swap/4, abort/3, latched/1]).

-export_type([won/0]).

%% what a fork adds to the new B's dialog: the destination that answered
%% and its media side
-type won() :: #{
    winner := chappe_sip_b2b:winner(),
    profile := chappe_sip_b2b_media:profile()
}.

%% options of create_b2bua/4 that also apply to the INVITE of a new B
-define(UAC_OPTS, [
    proxy, auth, flow, session_expires, min_se, session_refresher
]).

%% rtpengine's offer for A's side, from A's SDP ASdp. {ok, Target1, Sdp, M}
%% hands call/4 what it calls: a fork's destinations carry their own offer.
-spec offer(term(), binary(), map(), chappe_sip_b2b_media:state()) ->
    {ok, term(), binary(), chappe_sip_b2b_media:state()}
    | {reject, 300..699}.
offer({parallel, Dests0}, ASdp, Opts, #{params := Params} = M) ->
    {parallel, Dests} = chappe_sip_b2b_fork:targets({parallel, Dests0}, Opts),
    case
        chappe_sip_b2b:offers(
            ASdp, Dests, Opts#{anchor_params => Params}, M
        )
    of
        {ok, Offered, M1} -> {ok, {parallel, Offered}, <<>>, M1};
        {reject, _} = Rej -> Rej
    end;
offer(Target, ASdp, _Opts, M) ->
    case chappe_sip_b2b_media:offer(a, ASdp, M) of
        {ok, Sdp, M1} -> {ok, Target, Sdp, M1};
        {reject, _} = Rej -> Rej
    end.

%% The new B answers Sdp (rtpengine's offer): {ok, Dialog, Answer, Won} or
%% {error, _}; Won is undefined but for a fork. Relay owns the new dialog;
%% Handled are its handled_events.
-spec call(term(), binary(), map(), pid()) ->
    {ok, chappe_sip_dialog:dialog(), binary(), won() | undefined}
    | {error, term()}.
call({dialog, D}, Sdp, #{handled := Handled}, Relay) ->
    try
        %% the relay carries the dialog from now on: its events go there
        ok = chappe_sip_dialog:set_owner(D, Relay),
        ok = chappe_sip_dialog:set_handled(D, Handled),
        case chappe_sip_dialog:modify(D, Sdp) of
            {ok, Answer} -> {ok, D, Answer, undefined};
            {error, _} = Err -> Err
        end
    catch
        exit:Why -> {error, Why}
    end;
call({parallel, Dests}, _Sdp, Opts, Relay) ->
    BOpts = uac_opts(Opts, Relay),
    fork_next(
        chappe_sip_b2b_fork:start(
            [D#{bopts => chappe_sip_b2b:dest_bopts(D, BOpts)} || D <- Dests],
            chappe_sip_b2b_fork:ringing(#{
                timer_c => chappe_sip_b2b:timer_c(Opts)
            })
        )
    );
call(Uri, Sdp, Opts, Relay) when is_binary(Uri) ->
    UacOpts = (uac_opts(Opts, Relay))#{local_sdp => Sdp},
    case chappe_sip_uac:start(Uri, UacOpts) of
        {ok, URef} ->
            Deadline =
                erlang:monotonic_time(millisecond) +
                    chappe_sip_b2b:timer_c(Opts),
            ring(URef, Deadline);
        Err ->
            Err
    end.

uac_opts(#{handled := Handled} = Opts, Relay) ->
    maps:merge(maps:with(?UAC_OPTS, Opts), #{
        headers => maps:get(headers, Opts, []),
        owner => Relay,
        notify => self(),
        handled_events => Handled
    }).

%% the new B rings until it answers, Timer C, or the relay ends (abort/3)
ring(URef, Deadline) ->
    receive
        {chappe_sip_uac, URef, {ok, D}} ->
            {ok, D, chappe_sip_dialog:remote_sdp(D), undefined};
        {chappe_sip_uac, URef, {error, _} = Err} ->
            Err;
        {chappe_sip_uac, URef, _} ->
            ring(URef, Deadline);
        abort ->
            %% CANCEL it, BYE a 2xx that still comes
            ok = chappe_sip_uac:abandon(URef, #{}),
            {error, aborted}
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        ok = chappe_sip_uac:abandon(URef, #{why => timeout}),
        {error, timeout}
    end.

fork_next({wait, W}) -> fork_ring(W);
fork_next({failed, Best, _W}) -> {error, Best}.

%% every branch rings until one answers, all fail, Timer C (a provisional
%% does not restart it here: the replace_b/3 caller waits for a bound), or
%% the relay ends (abort/3)
fork_ring(#{branches := Branches, deadline := Deadline} = W) ->
    receive
        {chappe_sip_uac, BRef, Event} when is_map_key(BRef, Branches) ->
            fork_event(BRef, Event, W);
        abort ->
            chappe_sip_b2b_fork:cancel(W, []),
            {error, aborted}
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        chappe_sip_b2b_fork:cancel(W, []),
        {error, timeout}
    end.

fork_event(BRef, {ok, D}, #{branches := Branches} = W) ->
    #{BRef := #{dest := #{profile := Profile}}} = Branches,
    Won = chappe_sip_b2b_fork:won(BRef, D, W),
    {ok, D, chappe_sip_dialog:remote_sdp(D), #{
        winner => chappe_sip_b2b_fork:winner(Won),
        profile => Profile
    }};
fork_event(BRef, {error, Why}, W) ->
    fork_next(chappe_sip_b2b_fork:failed(BRef, Why, W));
fork_event(_BRef, _Other, W) ->
    fork_ring(W).

%% The call ended while the helper Pid (its result tagged Ref) brings a
%% new B in: the new INVITE is CANCELled at once, a new B that answered
%% meanwhile gets a BYE, and the replace_b/3 caller From gets {error,
%% call_ended}.
-spec abort(pid(), reference(), {pid(), term()}) -> ok.
abort(Pid, Ref, {Caller, Tag}) ->
    MRef = erlang:monitor(process, Pid),
    Pid ! abort,
    receive
        {relay_result, Ref, {ok, D, _, _}} ->
            _ = spawn(fun() -> chappe_sip_b2b:destroy_quietly(D, []) end),
            ok;
        {relay_result, Ref, _} ->
            ok;
        {'DOWN', MRef, process, Pid, _} ->
            ok
    after 2000 ->
        exit(Pid, kill)
    end,
    erlang:demonitor(MRef, [flush]),
    Caller ! {Tag, {error, call_ended}},
    ok.

%% The new B answered: rtpengine takes its answer, and the relay state S
%% moves to it ({ok, S1}); the old B gets a BYE and the notify process
%% {replaced, b}. {error, _} when rtpengine refuses the answer (the new B
%% is then torn down).
-spec swap(chappe_sip_dialog:dialog(), binary(), won() | undefined, map()) ->
    {ok, map()} | {error, term()}.
swap(NewB, Answer, Won, #{media := M0, b := OldB, refs := {RefA, RefB}} = S) ->
    case chappe_sip_b2b_media:answer(b, Answer, winner_media(Won, NewB, M0)) of
        {ok, _ForA, M1} ->
            erlang:demonitor(RefB, [flush]),
            RefB1 = chappe_sip_dialog:monitor(NewB),
            _ = spawn(fun() -> chappe_sip_b2b:destroy_quietly(OldB, []) end),
            event({replaced, b}, M1),
            {ok, S#{
                b := NewB,
                refs := {RefA, RefB1},
                media := M1#{via := undefined}
            }};
        {reject, Code} ->
            _ = spawn(fun() -> chappe_sip_b2b:destroy_quietly(NewB, []) end),
            {error, {rejected, Code}}
    end.

%% a fork: the call goes on with the flags of the branch that answered;
%% under a via-branch, with its To-tag too (see above)
winner_media(undefined, _NewB, M) ->
    M;
winner_media(#{profile := #{via := _} = P}, NewB, M) ->
    chappe_sip_b2b_media:set_tag(
        b, chappe_sip_b2b:remote_tag(NewB), with_profile(P, M)
    );
winner_media(#{profile := P}, _NewB, M) ->
    with_profile(P, M).

with_profile(P, M0) ->
    #{params := Params} = M = chappe_sip_b2b_media:branch(P, M0),
    M#{params := latched(Params)}.

%% A never hears of the new offer, so the parameters toward A (those of
%% the answers to A's offers) ask rtpengine to keep A's ports (port
%% latching): an answer to a re-offer otherwise moves A to new local ports.
-spec latched(map()) -> map().
latched(Params) ->
    A = maps:get(a, Params, #{}),
    Flags = maps:get(flags, A, []),
    case lists:member(port_latching, Flags) of
        true -> Params;
        false -> Params#{a => A#{flags => [port_latching | Flags]}}
    end.

event(Ev, #{notify := Pid, ref := Ref}) when is_pid(Pid) ->
    Pid ! {chappe_sip_b2b, Ref, Ev},
    ok;
event(_Ev, _M) ->
    ok.
