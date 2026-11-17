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

-export([valid/2, reopen/4, result/1]).
-export([swap/6, abort/3, prepare/6]).

-export_type([won/0]).

%% what a fork adds to the new B's dialog: the destination that answered
%% and its media side
-type won() :: #{
    winner := chappe_sip_b2b:winner(),
    profile := chappe_sip_b2b_media:profile()
}.

%% options of create_b2bua/4 that also apply to the INVITE of a new B
-define(UAC_OPTS, [
    from,
    proxy,
    auth,
    flow,
    session_expires,
    min_se,
    session_refresher,
    call_ref,
    call_ref_header,
    related,
    follow_redirects,
    keep_uri_on_redirect
]).

%% Whether replace_b/3's arguments can go to the relay, checked in the
%% caller: what the relay chokes on would end a live call.
-spec valid(term(), term()) -> boolean().
valid(Target, Opts) when is_map(Opts) ->
    valid_target(Target) andalso valid_opts(Opts) andalso
        chappe_sip_b2b_hdr:valid_from(Opts) andalso
        chappe_sip_call:valid_opts(Opts);
valid(_Target, _Opts) ->
    false.

valid_target(Uri) when is_binary(Uri) -> true;
valid_target({dialog, _}) -> true;
valid_target({parallel, Dests}) -> all(fun valid_dest/1, Dests);
valid_target(_Other) -> false.

valid_dest(Uri) when is_binary(Uri) -> true;
valid_dest({Uri, Opts}) when is_binary(Uri), is_map(Opts) -> valid_opts(Opts);
valid_dest(_Other) -> false.

valid_opts(Opts) ->
    all(fun valid_header/1, maps:get(headers, Opts, [])) andalso
        valid_params(maps:get(anchor_params, Opts, #{})).

valid_header({Name, _Value}) -> is_binary(Name);
valid_header(_Other) -> false.

valid_params(Params) when is_map(Params) ->
    all(fun valid_leg/1, maps:to_list(Params));
valid_params(_Other) ->
    false.

valid_leg({a, Params}) -> valid_leg_params(Params);
valid_leg({b, Params}) -> valid_leg_params(Params);
valid_leg(_Other) -> false.

valid_leg_params(Params) when is_map(Params) ->
    all(fun(_Flag) -> true end, maps:get(flags, Params, []));
valid_leg_params(_Other) ->
    false.

%% false as well for anything but a proper list
all(_Pred, []) -> true;
all(Pred, [H | T]) -> Pred(H) andalso all(Pred, T);
all(_Pred, _Other) -> false.

%% rtpengine's offer for the side that stays (A when Leg is b, B when Leg
%% is a, a transfer from A), from its SDP KeepSdp. {ok, Target1, Sdp, M}
%% hands call/4 what it calls: a fork's destinations carry their own
%% offer. Only leg B is replaced by a fork.
-spec offer(
    chappe_sip_b2b_media:leg(),
    term(),
    binary(),
    map(),
    chappe_sip_b2b_media:state()
) ->
    {ok, term(), binary(), chappe_sip_b2b_media:state()}
    | {reject, 300..699}
    | {reject, 300..699, offered}.
offer(b, {parallel, Dests0}, ASdp, Opts, #{params := Params} = M) ->
    {parallel, Dests} = chappe_sip_b2b_fork:targets({parallel, Dests0}, Opts),
    case
        chappe_sip_b2b:offers(
            ASdp, Dests, Opts#{anchor_params => Params}, M
        )
    of
        {ok, Offered, M1} -> {ok, {parallel, Offered}, <<>>, M1};
        Rej -> Rej
    end;
offer(Leg, Target, KeepSdp, _Opts, M) ->
    case chappe_sip_b2b_media:offer(other(Leg), KeepSdp, M) of
        {ok, Sdp, M1} -> {ok, Target, Sdp, M1};
        {reject, _} = Rej -> Rej
    end.

%% How the relay (its state S) brings a new party in on Leg: the step it
%% runs off its loop (with what a failure goes back to), the fun that
%% calls the new party, and the media state after rtpengine's offer for
%% the side that stays (from its SDP KeepSdp), which keeps the addresses
%% it sends to. keep_old in Opts: the caller (From) ends the old party
%% itself, a transfer that NOTIFYs the referrer first.
-spec prepare(
    {pid(), term()},
    chappe_sip_b2b_media:leg(),
    term(),
    binary(),
    map(),
    map()
) ->
    {ok, term(), fun(() -> term()), chappe_sip_b2b_media:state()}
    | {reject, 300..699}
    | {reject, 300..699, map(), chappe_sip_b2b_media:state()}.
prepare({Caller, _} = From, Leg, Target, KeepSdp, Opts, #{media := M0} = S) ->
    Keep = other(Leg),
    %% the new party may sit on another network than the old one (a media
    %% server): its anchor_params replace the call's for each leg named
    Params = latched(Keep, maps:get(params, M0)),
    M = M0#{
        params := latched(
            Keep, maps:merge(Params, maps:get(anchor_params, Opts, #{}))
        )
    },
    %% what the old party goes back to on a failure
    Old = #{params => Params, webrtc => maps:get(webrtc, M0)},
    Keeper =
        case maps:get(keep_old, Opts, false) of
            true -> Caller;
            false -> undefined
        end,
    case offer(Leg, Target, KeepSdp, Opts, M) of
        {ok, Target1, Sdp, M1} ->
            Handled = chappe_sip_b2b_requests:handled(
                maps:get(requests, S), maps:get(relay_info, S)
            ),
            Relay = self(),
            Moved = moved(Leg, Target1, M0, M1),
            %% the new party serves the call: same call_ref, X-Chappe-Call
            UacOpts = maps:merge(
                chappe_sip_b2b_media:call_opts(M0),
                (maps:without([keep_old], Opts))#{handled => Handled}
            ),
            {ok, {replace, From, {Leg, Old, Moved, Keeper}},
                fun() -> call(Target1, Sdp, UacOpts, Relay) end, M1};
        {reject, Code} ->
            {reject, Code};
        {reject, Code, offered} ->
            {reject, Code, Old, M}
    end.

%% Whether the offers of Target took other flags toward Leg than the old
%% party's (M0, the media before them; M1, after them).
-spec moved(
    chappe_sip_b2b_media:leg(),
    term(),
    chappe_sip_b2b_media:state(),
    chappe_sip_b2b_media:state()
) -> boolean().
moved(b, {parallel, Dests}, M0, _M1) ->
    Old = chappe_sip_b2b_media:b_flags(M0),
    lists:any(
        fun(#{profile := P}) ->
            chappe_sip_b2b_media:b_flags(chappe_sip_b2b_media:branch(P, M0)) =/=
                Old
        end,
        Dests
    );
moved(Leg, _Target, M0, M1) ->
    chappe_sip_b2b_media:flags(Leg, M0) =/= chappe_sip_b2b_media:flags(Leg, M1).

%% One more offer and answer with the old party's own SDP (OldSdp, on Leg)
%% and M's flags, which brings its media back from where other flags
%% moved it; KeepSdp is the other side's.
-spec reopen(
    chappe_sip_b2b_media:leg(), binary(), binary(), chappe_sip_b2b_media:state()
) ->
    chappe_sip_b2b_media:state().
reopen(Leg, KeepSdp, OldSdp, M) ->
    case chappe_sip_b2b_media:offer(other(Leg), KeepSdp, M) of
        {ok, _ForB, M1} ->
            case chappe_sip_b2b_media:answer(Leg, OldSdp, M1) of
                {ok, _ForA, M2} -> M2;
                {reject, _} -> M
            end;
        {reject, _} ->
            M
    end.

%% What replace_b/3 returns once the new B carries the call.
-spec result(won() | undefined) ->
    ok | {ok, #{winner := chappe_sip_b2b:winner()}}.
result(undefined) -> ok;
result(#{winner := Winner}) -> {ok, #{winner => Winner}}.

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
            ring(URef, Deadline, maps:get(on_progress, Opts, undefined));
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

%% the new B rings until it answers, Timer C, or the relay ends (abort/3);
%% OnProgress (replace_leg/4's on_progress, a transfer's NOTIFY) hears of
%% each 1xx above 100
ring(URef, Deadline, OnProgress) ->
    receive
        {chappe_sip_uac, URef, {ok, D}} ->
            answered(D, undefined);
        {chappe_sip_uac, URef, {error, _} = Err} ->
            Err;
        {chappe_sip_uac, URef, {provisional, Msg}} ->
            ok = progress(OnProgress, chappe_sip_msg:status(Msg)),
            ring(URef, Deadline, OnProgress);
        {chappe_sip_uac, URef, _} ->
            ring(URef, Deadline, OnProgress);
        abort ->
            %% CANCEL it, BYE a 2xx that still comes
            ok = chappe_sip_uac:abandon(URef, #{}),
            {error, aborted}
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        ok = chappe_sip_uac:abandon(URef, #{why => timeout}),
        {error, timeout}
    end.

progress(F, St) when is_function(F, 1), St > 100, St < 200 ->
    _ = F(St),
    ok;
progress(_F, _St) ->
    ok.

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
    answered(D, #{
        winner => chappe_sip_b2b_fork:winner(Won),
        profile => Profile
    });
fork_event(BRef, {error, Why}, W) ->
    fork_next(chappe_sip_b2b_fork:failed(BRef, Why, W));
fork_event(_BRef, _Other, W) ->
    fork_ring(W).

%% the new B's answer; a dialog already gone leaves the call with the old B
answered(D, Won) ->
    try chappe_sip_dialog:remote_sdp(D) of
        Sdp -> {ok, D, Sdp, Won}
    catch
        exit:Why -> {error, {new_b_down, Why}}
    end.

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

%% The new party on Leg answered: rtpengine takes its answer, and the
%% relay state S moves to it ({ok, S1}); the old party gets a BYE and the
%% notify process {replaced, Leg}. Keeper, a pid, keeps the old party
%% instead: its dialog goes to that process, which ends it (a transfer
%% that still owes the referrer a NOTIFY). {error, _} when rtpengine
%% refuses the answer (the new party is then torn down).
-spec swap(
    chappe_sip_b2b_media:leg(),
    chappe_sip_dialog:dialog(),
    binary(),
    won() | undefined,
    pid() | undefined,
    map()
) ->
    {ok, map()} | {error, term()}.
swap(Leg, New, Answer, Won, Keeper, #{media := M0, refs := Refs} = S) ->
    Old = maps:get(Leg, S),
    case chappe_sip_b2b_media:answer(Leg, Answer, winner_media(Won, New, M0)) of
        {ok, _ForA, M1} ->
            erlang:demonitor(ref(Leg, Refs), [flush]),
            Refs1 = set_ref(Leg, chappe_sip_dialog:monitor(New), Refs),
            ok = release_old(Old, Keeper),
            chappe_sip_b2b_media:event({replaced, Leg}, M1),
            {ok, S#{
                Leg := New,
                refs := Refs1,
                winner := won_winner(Won),
                %% the old party took its hold with it
                media := chappe_sip_b2b_media:unhold(Leg, M1#{via := undefined})
            }};
        {reject, Code} ->
            _ = spawn(fun() -> chappe_sip_b2b:destroy_quietly(New, []) end),
            {error, {rejected, Code}}
    end.

ref(a, {RefA, _}) -> RefA;
ref(b, {_, RefB}) -> RefB.

set_ref(a, R, {_, RefB}) -> {R, RefB};
set_ref(b, R, {RefA, _}) -> {RefA, R}.

release_old(Old, undefined) ->
    _ = spawn(fun() -> chappe_sip_b2b:destroy_quietly(Old, []) end),
    ok;
release_old(Old, Keeper) ->
    try chappe_sip_dialog:set_owner(Old, Keeper) of
        _ -> ok
    catch
        exit:_ -> ok
    end.

other(a) -> b;
other(b) -> a.

won_winner(undefined) -> undefined;
won_winner(#{winner := Winner}) -> Winner.

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
    M#{params := latched(a, Params)}.

%% The side that stays (Keep: A when B is replaced) never hears of the
%% new offer, so the parameters toward it ask rtpengine to keep its ports
%% (port latching): an answer to a re-offer otherwise moves it to new
%% local ports.
-spec latched(chappe_sip_b2b_media:leg(), map()) -> map().
latched(Keep, Params) ->
    P = maps:get(Keep, Params, #{}),
    Flags = maps:get(flags, P, []),
    case lists:member(port_latching, Flags) of
        true -> Params;
        false -> Params#{Keep => P#{flags => [port_latching | Flags]}}
    end.
