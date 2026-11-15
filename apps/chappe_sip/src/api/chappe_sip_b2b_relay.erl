%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The relay loop of a B2BUA call (chappe_sip_b2b:relay/1,2).
%%
%% It runs in the process that owns both dialogs and carries what one leg
%% sends to the other, one offer at a time:
%%   - a re-INVITE or UPDATE with a new offer goes to the other leg, its
%%     answer (or failure) comes back;
%%   - an offerless re-INVITE goes to the other leg offerless: that leg's
%%     offer comes back in our 2xx, and the answer in the ACK goes on in
%%     the ACK to that leg (RFC 3261 14.1, the dialog's manual ACK);
%%   - an UPDATE without an offer, or an offer with the o= version its leg
%%     sent last (RFC 3264 8, a session refresh), is answered by its leg;
%%   - set_media/2 re-INVITEs A without an offer and carries A's offer to
%%     B through (or around) rtpengine.
%% A second offer while one is pending gets 500 with Retry-After (RFC 3261
%% 14.2, RFC 3311 5.2). Each SDP goes through chappe_sip_b2b_media (the
%% app's hook, then the anchor); when the far leg refuses an anchored
%% offer, rtpengine gets that leg's last good SDP back as the answer.
%%
%% The requests the call claims (create_b2bua's requests option) go to the
%% notify process as {chappe_sip_b2b, Ref, {request, a | b, Method, Req,
%% Res}}, and with relay_info an INFO goes on to the other leg. hangup/2
%% ends both legs, replace_b/3 swaps leg B (see chappe_sip_b2b).
-module(chappe_sip_b2b_relay).

-include("chappe_sip.hrl").

-export([run/2, retry_later/1]).

-spec run(chappe_sip_b2b:legs(), map()) ->
    {done, a_bye | b_bye | hangup | term()}.
run(#{uas := A, uac := B} = Legs, Opts) ->
    RefA = chappe_sip_dialog:monitor(A),
    RefB = chappe_sip_dialog:monitor(B),
    M0 =
        case Legs of
            #{media := M} -> M;
            _ -> new_media(A)
        end,
    Requests = maps:get(requests, Opts, maps:get(requests, Legs, [])),
    RelayInfo = maps:get(relay_info, Opts, maps:get(relay_info, Legs, false)),
    {Mode, TOpts} = chappe_sip_b2b_transfer:options(Opts, Legs),
    Handled = chappe_sip_b2b_requests:handled(Requests, RelayInfo, Mode),
    _ =
        case
            maps:is_key(requests, Opts) orelse maps:is_key(relay_info, Opts) orelse
                maps:is_key(transfer, Opts)
        of
            true -> [set_handled(D, Handled) || D <- [A, B]];
            false -> ok
        end,
    loop(#{
        a => A,
        b => B,
        refs => {RefA, RefB},
        ref => maps:get(ref, M0),
        requests => Requests,
        relay_info => RelayInfo,
        winner => maps:get(winner, Legs, undefined),
        %% who the app authenticated on each leg (create_b2bua/4)
        principal => maps:get(principal, Legs, #{}),
        transfer => Mode,
        transfer_opts => TOpts,
        %% the transfer at work ({Pid, Monitor}) and how many the call made
        transferring => undefined,
        %% the transferor's leg, gone while its transfer runs: {Leg,
        %% Dialog, Why} (see gone/4)
        left => undefined,
        owner_mon => maps:get(owner_mon, Opts, undefined),
        transfers => 0,
        media => with_opts(Opts, M0),
        %% a late offer: B's 2xx waits for the answer in A's ACK
        pending =>
            case Legs of
                #{late := true} -> #{step => {ack, a}};
                _ -> undefined
            end
    }).

set_handled(D, Handled) ->
    try
        chappe_sip_dialog:set_handled(D, Handled)
    catch
        exit:_ -> ok
    end.

new_media(A) ->
    chappe_sip_b2b_media:new(
        #{
            mode => direct,
            call_id => chappe_sip_dialog:call_id(A),
            a_tag => chappe_sip_dialog:remote_tag(A),
            ref => make_ref()
        },
        #{}
    ).

%% relay/2's own rewrite_sdp, notify and anchor_params win over the ones
%% given to create_b2bua/4
with_opts(Opts, M) ->
    M1 =
        case maps:find(rewrite_sdp, Opts) of
            {ok, F} -> M#{rewrite := chappe_sip_b2b_media:hook(F)};
            error -> M
        end,
    M2 =
        case maps:find(notify, Opts) of
            {ok, Pid} -> M1#{notify := Pid};
            error -> M1
        end,
    case maps:find(anchor_params, Opts) of
        {ok, P} -> M2#{params := P};
        error -> M2
    end.

loop(#{a := A, b := B, refs := {RefA, RefB}, ref := Ref, pending := P} = S) ->
    HelperMon = helper_mon(P),
    TransferMon = chappe_sip_b2b_transfer:monitor(S),
    OwnerMon = maps:get(owner_mon, S),
    receive
        {'DOWN', OwnerMon, process, _, _} ->
            %% relay_async/2's owner is gone: so is the call
            hangup({self(), owner_down}, #{}, S);
        {'DOWN', HelperMon, process, _, Why} ->
            loop(helper_down(Why, S));
        {'DOWN', TransferMon, process, _, Why} ->
            next(chappe_sip_b2b_transfer:down(Why, S));
        {chappe_sip_dialog, A, destroy, Why} ->
            next(chappe_sip_b2b_transfer:leg_gone(a, Why, RefA, S));
        {chappe_sip_dialog, B, destroy, Why} ->
            next(chappe_sip_b2b_transfer:leg_gone(b, Why, RefB, S));
        %% an abnormal fsm exit emits no destroy message; tear the peer down
        {'DOWN', RefA, process, _, _} ->
            next(chappe_sip_b2b_transfer:leg_gone(a, undefined, RefA, S));
        {'DOWN', RefB, process, _, _} ->
            next(chappe_sip_b2b_transfer:leg_gone(b, undefined, RefB, S));
        {chappe_sip_dialog, X, Event, Req, Res} when
            (X =:= A orelse X =:= B) andalso
                (Event =:= modify orelse Event =:= update)
        ->
            loop(offer(leg(X, S), Event, Req, Res, S));
        {chappe_sip_dialog, X, ack, Ack, _} when X =:= A orelse X =:= B ->
            loop(acked(leg(X, S), chappe_sip_req:body(Ack), S));
        {chappe_sip_dialog, X, refer, Req, Res} when X =:= A orelse X =:= B ->
            loop(chappe_sip_b2b_transfer:refer(leg(X, S), Req, Res, S));
        {chappe_sip_dialog, X, Event, Req, Res} when
            (X =:= A orelse X =:= B) andalso
                (Event =:= refer orelse Event =:= info orelse
                    Event =:= message orelse Event =:= notify orelse
                    Event =:= options)
        ->
            ok = chappe_sip_b2b_requests:request(leg(X, S), Event, Req, Res, S),
            loop(S);
        {relay_result, PRef, Result} ->
            loop(relayed(PRef, Result, S));
        {chappe_sip_b2b, Ref, {call, From, {hangup, Opts}}} ->
            hangup(From, Opts, S);
        {chappe_sip_b2b, Ref, {call, From, {detach, D}}} ->
            case chappe_sip_b2b_join:detach(From, D, S) of
                {loop, S1} -> loop(S1);
                Done -> Done
            end;
        {chappe_sip_b2b, Ref, {call, From, Req}} ->
            loop(handle_call(From, Req, S));
        {chappe_sip_uac, _, {ok, Late}} ->
            %% a fork's branch answered after another won: end it
            _ = spawn(fun() -> chappe_sip_b2b:destroy_quietly(Late, []) end),
            loop(S);
        {chappe_sip_uac, _, _} ->
            loop(S);
        {chappe_sip_dialog, _, _, _} ->
            loop(S);
        {chappe_sip_dialog, _, _, _, _} ->
            loop(S)
    end.

%% what the transfer module says of a leg that ended, or of the transfer
%% that ended: the call goes on, or Leg's peer is alone and gets its BYE
next({loop, S}) -> loop(S);
next({ended, a, Why, #{b := B} = S}) -> done(S, B, Why, a_bye);
next({ended, b, Why, #{a := A} = S}) -> done(S, A, Why, b_bye).

leg(X, #{a := X}) -> a;
leg(_X, _S) -> b.

other(a) -> b;
other(b) -> a.

done(#{pending := P, media := M}, Peer, Why, Tag) ->
    stop_pending(P),
    _ = chappe_sip_b2b_media:stop(M),
    _ = chappe_sip_dialog:destroy(Peer, #{
        headers => chappe_sip_b2b_hdr:reason_headers(Why)
    }),
    {done, Tag}.

stop_pending(#{
    pid := Pid, ref := Ref, mon := Mon, step := {replace, From, _}
}) ->
    erlang:demonitor(Mon, [flush]),
    chappe_sip_b2b_replace:abort(Pid, Ref, From);
stop_pending(#{pid := Pid, mon := Mon}) ->
    erlang:demonitor(Mon, [flush]),
    exit(Pid, kill),
    ok;
stop_pending(_P) ->
    ok.

%% hangup/2: a BYE on each leg with the reason and headers of Opts, both
%% sent before the loop ends (the dialogs would otherwise see their owner
%% go first)
hangup(From, Opts, #{a := A, b := B, pending := P, media := M}) ->
    Hdrs =
        [
            {<<"Reason">>, R}
         || R <- [maps:get(reason, Opts, undefined)], R =/= undefined
        ] ++
            maps:get(headers, Opts, []),
    stop_pending(P),
    _ = chappe_sip_b2b_media:stop(M),
    Pids = [
        spawn_monitor(fun() -> chappe_sip_b2b:destroy_quietly(D, Hdrs) end)
     || D <- [A, B]
    ],
    lists:foreach(
        fun({_Pid, MRef}) ->
            receive
                {'DOWN', MRef, process, _, _} -> ok
            end
        end,
        Pids
    ),
    reply(From, ok),
    {done, hangup}.

%% ---- offers from a leg ----

%% An offer from leg X. None in an UPDATE, or the SDP X sent last (same o=
%% line, RFC 3264 8), is a session refresh: X's leg answers with the SDP
%% it has. An offerless re-INVITE and anything else go to the other leg.
offer(X, Event, Req, Res, S) ->
    Dlg = maps:get(X, S),
    Offer = chappe_sip_req:body(Req),
    Last = chappe_sip_b2b:remote_sdp(Dlg),
    Refresh =
        (Offer =:= <<>> andalso Event =:= update) orelse
            (Offer =/= <<>> andalso chappe_sip_sdp:same_version(Offer, Last)),
    case Refresh of
        true ->
            answer_locally(Event, Offer, Dlg, Res),
            S;
        false when map_get(pending, S) =/= undefined ->
            %% RFC 3261 14.2 / RFC 3311 5.2: another offer of the call is
            %% still on its way
            retry_later(Res),
            S;
        false when Offer =:= <<>> ->
            spawn_step(
                {peer_offer, X, Res},
                fun() -> offerless(maps:get(other(X), S)) end,
                S
            );
        false ->
            forward(X, Event, Offer, Res, S)
    end.

answer_locally(update, <<>>, _Dlg, Res) ->
    _ = chappe_sip_res:send(Res, 200, #{reason => <<"OK">>}),
    ok;
answer_locally(_Event, _Offer, Dlg, Res) ->
    _ = chappe_sip_res:send(Res, 200, sdp_reply(local_sdp(Dlg))),
    ok.

%% 500 with Retry-After: another offer, or transfer, of the call is
%% under way.
-spec retry_later(chappe_sip_res:res()) -> ok.
retry_later(Res) ->
    RA = integer_to_binary(rand:uniform(11) - 1),
    _ = chappe_sip_res:send(Res, 500, #{
        reason => <<"Server Internal Error">>,
        headers => [{<<"Retry-After">>, RA}]
    }),
    ok.

forward(X, Event, Offer, Res, #{media := M} = S) ->
    case chappe_sip_b2b_media:offer(X, Offer, M) of
        {ok, Sdp, M1} ->
            Peer = maps:get(other(X), S),
            spawn_step(
                {answer, X, Res},
                fun() -> send_offer(Event, Peer, Sdp) end,
                S#{media := M1}
            );
        {reject, Code} ->
            _ = chappe_sip_res:send(Res, Code, #{}),
            S
    end.

%% ---- the other leg's result ----

relayed(
    Ref, Result, #{pending := #{ref := Ref, mon := Mon, step := Step}} = S0
) ->
    erlang:demonitor(Mon, [flush]),
    step(Step, Result, S0#{pending := undefined});
relayed(_Ref, _Result, S) ->
    S.

%% the other leg answered X's offer, or refused it
step({answer, X, Res}, {ok, Answer}, #{media := M} = S) ->
    Y = other(X),
    case chappe_sip_b2b_media:answer(Y, Answer, M) of
        {ok, Out, M1} ->
            _ = chappe_sip_res:send(Res, 200, sdp_reply(Out)),
            S#{media := M1};
        {reject, Code} ->
            _ = chappe_sip_res:send(Res, Code, #{}),
            S
    end;
step({answer, X, Res}, Error, S) ->
    send_failure(Res, Error),
    restore(other(X), S);
%% X's offerless re-INVITE: the other leg's offer goes into X's 2xx, and
%% the answer in X's ACK is awaited
step({peer_offer, X, Res}, {ok, PeerOffer}, #{media := M} = S) ->
    Y = other(X),
    case chappe_sip_b2b_media:offer(Y, PeerOffer, M) of
        {ok, Out, M1} ->
            _ = chappe_sip_res:send(Res, 200, sdp_reply(Out)),
            S#{media := M1, pending := #{step => {ack, X}}};
        {reject, Code} ->
            _ = chappe_sip_res:send(Res, Code, #{}),
            ack_leg(Y, local_sdp(maps:get(Y, S)), S),
            S
    end;
step({peer_offer, _X, Res}, Error, S) ->
    send_failure(Res, Error),
    S;
%% set_media/2: A's fresh offer goes to B
step({switch_offer, From, Old}, {ok, AOffer}, #{media := M, b := B} = S) ->
    case chappe_sip_b2b_media:offer(a, AOffer, M) of
        {ok, Out, M1} ->
            spawn_step(
                {switch_answer, From, Old},
                fun() -> send_offer(modify, B, Out) end,
                S#{media := M1}
            );
        {reject, Code} ->
            switch_back(From, Old, {rejected, Code}, S)
    end;
step({switch_offer, From, Old}, Error, S) ->
    switch_failed(From, Old, Error, S);
step({switch_answer, From, Old}, {ok, BAnswer}, #{media := M} = S) ->
    case chappe_sip_b2b_media:answer(b, BAnswer, M) of
        {ok, Out, M1} ->
            ack_leg(a, Out, S),
            reply(From, ok),
            switched(Old, S#{media := M1});
        {reject, Code} ->
            switch_back(From, Old, {rejected, Code}, S)
    end;
step({switch_answer, From, Old}, Error, S) ->
    switch_back(From, Old, Error, S);
step({replace, From, Params}, Result, S) ->
    replaced(From, Params, Result, S).

%% the switch failed after A's offer: B kept its session, and A gets its
%% previous answer back in the ACK
switch_back(From, Old, Error, S) ->
    ack_leg(a, local_sdp(maps:get(a, S)), S),
    switch_failed(From, Old, Error, S).

%% the ACK of our 2xx to X's offerless re-INVITE: its answer goes on in
%% the ACK of the other leg's 2xx
acked(X, Answer, #{pending := #{step := {ack, X}}, media := M} = S) ->
    Y = other(X),
    S1 = S#{pending := undefined},
    case Answer =/= <<>> andalso chappe_sip_b2b_media:answer(X, Answer, M) of
        {ok, Out, M1} ->
            ack_leg(Y, Out, S1),
            S1#{media := M1};
        _ ->
            %% no usable answer: the other leg keeps the session it had
            ack_leg(Y, local_sdp(maps:get(Y, S)), S1),
            restore(X, S1)
    end;
acked(_X, _Answer, S) ->
    S.

%% rtpengine took an offer the far leg Y refused: Y's last good SDP
restore(Y, #{media := M} = S) ->
    Last = chappe_sip_b2b:remote_sdp(maps:get(Y, S)),
    S#{media := chappe_sip_b2b_media:rejected(Y, Last, M)}.

send_failure(Res, {error, #chappe_sip_error{status = St, reason = Reason}}) when
    St >= 300
->
    _ = chappe_sip_res:send(Res, St, #{reason => Reason}),
    ok;
send_failure(Res, _Other) ->
    _ = chappe_sip_res:send(Res, 500, #{reason => <<"Server Internal Error">>}),
    ok.

%% ---- set_media/2 and info/1 ----

handle_call(From, info, #{media := M, pending := P} = S) ->
    reply(From, (maps:with([hold, call_id, call_ref, related], M))#{
        media => chappe_sip_b2b_media:mode(M),
        session => chappe_sip_b2b_media:session(M),
        pending => P =/= undefined,
        winner => maps:get(winner, S),
        parties => chappe_sip_b2b:parties(S)
    }),
    S;
handle_call(From, {set_media, Mode}, #{media := #{mode := Mode}} = S) ->
    reply(From, ok),
    S;
handle_call(From, {set_media, _Mode}, #{pending := P} = S) when
    P =/= undefined
->
    reply(From, {error, busy}),
    S;
handle_call(From, {set_media, Mode}, #{media := M, a := A} = S) ->
    Old = M,
    case chappe_sip_b2b_media:start(chappe_sip_b2b_media:set_mode(Mode, M)) of
        {ok, M1} ->
            spawn_step(
                {switch_offer, From, Old},
                fun() -> offerless(A) end,
                S#{media := M1}
            );
        {error, Why} ->
            reply(From, {error, {media, Why}}),
            S
    end;
handle_call(From, {principal, D}, S) ->
    reply(From, chappe_sip_b2b_transfer:principal(D, S)),
    S;
handle_call(From, {replace_b, Target, Opts}, S) ->
    replace(From, b, Target, Opts, S);
handle_call(From, {replace, Leg, Target, Opts}, S) ->
    replace(From, Leg, Target, Opts, S);
handle_call(From, _Req, S) ->
    reply(From, {error, badarg}),
    S.

%% ---- replace_b/3 and transfers (see chappe_sip_b2b_replace) ----

%% Replace the party on Leg (b for replace_b/3; a or b for a transfer,
%% the leg that sent the REFER). The other side keeps its media.
replace(From, _Leg, _Target, _Opts, #{media := #{mode := direct}} = S) ->
    reply(From, {error, not_anchored}),
    S;
replace(From, _Leg, _Target, _Opts, #{pending := P} = S) when
    P =/= undefined
->
    reply(From, {error, busy}),
    S;
replace(From, _Leg, {parallel, []}, _Opts, S) ->
    reply(From, {error, none_up}),
    S;
replace(From, Leg, Target, Opts, S) ->
    KeepSdp = chappe_sip_b2b:remote_sdp(maps:get(other(Leg), S)),
    case chappe_sip_b2b_replace:prepare(From, Leg, Target, KeepSdp, Opts, S) of
        {ok, Step, Fun, M1} ->
            spawn_step(Step, Fun, S#{media := M1});
        {reject, Code} ->
            %% nothing reached rtpengine
            reply(From, {error, {rejected, Code}}),
            S;
        {reject, Code, Old, M} ->
            %% some of the fork's offers went through
            reply(From, {error, {rejected, Code}}),
            keep_old(Leg, {Old, true}, S#{media := M})
    end.

%% the new party answered and carries the call, or the old one keeps it
%% and rtpengine gets the old party's SDP back as the answer
replaced(From, {Leg, Old, Moved, Keeper}, {ok, New, Answer, Won}, S) ->
    case chappe_sip_b2b_replace:swap(Leg, New, Answer, Won, Keeper, S) of
        {ok, #{principal := Ps} = S1} ->
            reply(From, chappe_sip_b2b_replace:result(Won)),
            %% the new party is not who the app authenticated there
            S1#{principal := maps:remove(Leg, Ps)};
        Error ->
            reply(From, Error),
            keep_old(Leg, {Old, Moved}, S)
    end;
replaced(From, {Leg, Old, Moved, _Keeper}, Error, S) ->
    reply(From, failure(Error)),
    keep_old(Leg, {Old, Moved}, S).

%% rtpengine gets the old party's SDP back; an offer that took other flags
%% toward it moved its media with them (another interface, say), which
%% the answer does not undo, so one more exchange takes them back
keep_old(Leg, {Old, true}, S) ->
    reopen(Leg, restore(Leg, old_params(Old, S)));
keep_old(Leg, {Old, false}, S) ->
    restore(Leg, old_params(Old, S)).

reopen(Leg, #{media := M} = S) ->
    KeepSdp = chappe_sip_b2b:remote_sdp(maps:get(other(Leg), S)),
    OldSdp = chappe_sip_b2b:remote_sdp(maps:get(Leg, S)),
    S#{media := chappe_sip_b2b_replace:reopen(Leg, KeepSdp, OldSdp, M)}.

%% the old party keeps the call, and the anchor_params and flags it had
old_params(Old, #{media := M} = S) ->
    S#{media := maps:merge(M, Old)}.

%% the call went direct: its rtpengine session is released
switched(#{session := Old}, #{media := #{mode := direct} = M} = S) when
    Old =/= undefined
->
    S#{media := chappe_sip_b2b_media:stop(M#{session := Old})};
switched(_Old, S) ->
    S.

%% back to the media the call had; a session the switch started goes
switch_failed(From, Old, Error, #{media := M} = S) ->
    _ =
        case
            chappe_sip_b2b_media:session(M) =/=
                chappe_sip_b2b_media:session(Old)
        of
            true -> chappe_sip_b2b_media:stop(M);
            false -> M
        end,
    reply(From, failure(Error)),
    S#{media := Old}.

failure({error, _} = E) -> E;
failure(Other) -> {error, Other}.

reply({Pid, Tag}, Reply) ->
    Pid ! {Tag, Reply},
    ok.

%% ---- helpers run off the loop ----

%% Run Fun in a helper so the loop keeps answering both legs meanwhile;
%% its result comes back as relay_result and runs Step. A helper that dies
%% runs Step with an error (helper_down/3), so the call is not left with
%% its offer pending for good.
spawn_step(Step, Fun, S) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Mon} = spawn_monitor(fun() ->
        Parent ! {relay_result, Ref, Fun()}
    end),
    S#{pending := #{ref => Ref, pid => Pid, mon => Mon, step => Step}}.

%% the monitor of the helper at work, to match its 'DOWN' and no other
helper_mon(#{mon := Mon}) -> Mon;
helper_mon(_P) -> undefined.

helper_down(Why, #{pending := #{step := Step}} = S) ->
    logger:warning("chappe_sip_b2b: relay helper died: ~p", [Why]),
    step(Step, {error, {helper_down, Why}}, S#{pending := undefined}).

%% the ACK of a 2xx we left unACKed carries Sdp; off the loop, since the
%% leg may be busy with its own session refresh
ack_leg(Leg, Sdp, S) ->
    Dlg = maps:get(Leg, S),
    _ = spawn(fun() ->
        try chappe_sip_dialog:ack(Dlg, #{local_sdp => Sdp}) of
            _ -> ok
        catch
            exit:_ -> ok
        end
    end),
    ok.

offerless(Peer) ->
    try
        chappe_sip_dialog:modify(Peer, none, #{ack => manual})
    catch
        exit:Why -> {error, Why}
    end.

send_offer(modify, Peer, Sdp) ->
    try
        chappe_sip_dialog:modify(Peer, Sdp)
    catch
        exit:Why -> {error, Why}
    end;
send_offer(update, Peer, Sdp) ->
    Spec = #{
        method => <<"UPDATE">>,
        content_type => <<"application/sdp">>,
        body => Sdp
    },
    try chappe_sip_dialog:request(Peer, Spec) of
        {ok, Msg} ->
            case chappe_sip_msg:status(Msg) of
                St when St >= 200, St < 300 -> {ok, chappe_sip_msg:body(Msg)};
                St -> {error, sip_error(St, Msg)}
            end;
        Err ->
            Err
    catch
        exit:Why -> {error, Why}
    end.

sdp_reply(<<>>) ->
    #{reason => <<"OK">>};
sdp_reply(Sdp) ->
    #{
        reason => <<"OK">>,
        headers => [{<<"Content-Type">>, <<"application/sdp">>}],
        body => Sdp
    }.

local_sdp(Dlg) ->
    try chappe_sip_dialog:local_sdp(Dlg) of
        Sdp -> Sdp
    catch
        exit:_ -> <<>>
    end.

sip_error(Status, Msg) ->
    Reason =
        case chappe_sip_msg:reason(Msg) of
            undefined -> <<>>;
            R -> R
        end,
    #chappe_sip_error{status = Status, reason = Reason, response = Msg}.
