%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Back-to-back user agent.
%%
%% create_b2bua bridges an incoming INVITE (the A/UAS leg) to a new
%% outgoing INVITE (the B/UAC leg). It runs in the request worker, so it
%% can react to an A-side CANCEL while B is still ringing. It returns
%% {ok, #{uas := ADialog, uac := BDialog}} once both legs are up.
%%
%% While B rings, its provisionals reach A with their body (early media).
%% Each leg does 100rel on its own (RFC 3262): B's reliable 1xx is PRACKed
%% by the B leg, A gets a reliable 1xx when it asked for 100rel, and a 2xx
%% waits for A's PRACK of a reliable 1xx that carried SDP.
%%
%% relay/1,2 then carries the call (see chappe_sip_b2b_relay): a re-INVITE
%% or UPDATE with a new offer goes to the other leg and its answer (or
%% failure, 491 included) comes back; an offerless re-INVITE goes to the
%% other leg offerless, and the answer in the ACK follows it; an unchanged
%% offer or an UPDATE without one (a session refresh, RFC 4028) is answered
%% by its own leg, which also runs its own session timer (RFC 4028 4: a
%% B2BUA is a UA on each side). When either leg is torn down the other is
%% too, with the BYE's Reason (RFC 3326). Both legs are created with modify
%% and update handled by their owner, so the owner must run relay/1,2 (or
%% answer those events itself).
%%
%% Media is direct (the SDP passes through, RTP flows between the
%% endpoints) or anchored in rtpengine through a chappe_sip_media session
%% (see chappe_sip_b2b_media); set_media/2 switches a live call.
%%
%% A {parallel, Dests} target rings every destination at once, one UAC per
%% branch, under one To-tag toward A: the first 2xx wins, the other
%% branches are CANCELled (a 2xx of theirs that still comes is ACKed and
%% BYEd), and when every branch fails A gets the best final (RFC 3261 16.7,
%% shared with chappe_sip_proxy). Timer C covers the whole fork. A
%% destination may carry its own flow, headers and anchor_params. Anchored,
%% each branch answers the rtpengine offer of its flags under its own
%% To-tag: one offer when every branch takes the same flags, else one per
%% distinct set, each under a via-branch of its own. The result names the
%% destination that answered (winner).
%%
%% On a live call, hangup/2 ends both legs with a Reason, and replace_b/3
%% swaps leg B for a new callee, or the first of a fork to answer, behind
%% rtpengine without A seeing a re-INVITE.
%%
%% While a fork rings, every branch's provisionals reach A under its one
%% To-tag, so A plays the early media of whichever branch sent the last
%% 1xx with SDP, and an UPDATE from A goes to the last early dialog a
%% branch formed. Once a branch answers, rtpengine drops the other
%% branches' early media sessions.
-module(chappe_sip_b2b).

-include("chappe_sip.hrl").
-include("chappe_sip_uac.hrl").

-export([create_b2bua/4, relay/1, relay/2, relay_async/2, set_media/2, info/1]).
-export([hangup/2, replace_b/3]).
-export([call/2, call/3, contact/0]).
%% helpers of the chappe_sip_b2b_* modules
-export([timer_c/1, remote_tag/1, destroy_quietly/2, offers/4, dest_bopts/2]).

-export_type([b2b/0, legs/0, target/0, dest/0, branch_opts/0, winner/0]).

%% A running call, for set_media/2 and info/1: the process that runs
%% relay/1,2 and the reference its events carry.
-type b2b() :: {pid(), reference()}.
-type legs() :: #{
    uas := chappe_sip_dialog:dialog(),
    uac := chappe_sip_dialog:dialog(),
    b2b => b2b(),
    media => chappe_sip_b2b_media:state(),
    late => true,
    requests => [request()],
    relay_info => boolean(),
    winner => winner(),
    call_ref => binary()
}.
%% Where leg B goes: a destination, a list of them, or a group of
%% OPTIONS-monitored peers (chappe_sip_peers); a list or a group is tried
%% in turn while one fails with 408, 503 or a transport error.
%% {parallel, Dests} rings them all at once.
-type target() ::
    dest() | [dest()] | {peer_group, term()} | {parallel, [dest()]}.
%% A destination: a URI, or a URI with options of its own.
-type dest() :: binary() | {binary(), branch_opts()}.
%% What one destination changes over the call's options:
%%   flow          the registered flow its INVITE goes over (the call's
%%                 flow option when absent or undefined)
%%   headers       added to its INVITE after the call's b_headers
%%   anchor_params #{a | b => map()}, merged flag by flag over the call's
%%                 anchor_params for that leg
-type branch_opts() :: #{
    flow => chappe_sip_engine:flow() | undefined,
    headers => [{binary(), iodata()}],
    anchor_params => #{a | b => map()}
}.
%% The destination that answered: its URI, its branch options (#{} for a
%% bare URI) and its place in the target, from 1 (for a peer group, in the
%% candidates of the call).
-type winner() :: #{
    uri := binary(), index := pos_integer(), opts := branch_opts()
}.
%% in-dialog requests the requests option hands to the notify process
-type request() :: refer | info | message | notify | options.
-export_type([request/0]).

%% in-dialog events relay/2 answers
-define(RELAYED, [modify, update]).

%% Opts:
%%   local_sdp_b   => offer sent to B (default: A's INVITE body)
%%   local_sdp_a   => answer sent to A: value | fun(SdpB) (default: SdpB);
%%                    also applied to early media SDP
%%   b_headers   => [{Name, Value}] added to the INVITE to B (a correlation
%%                  header for the far end, say); a destination's own
%%                  headers come after them
%%   from        => the From of the INVITE to B (default: A's display name
%%                  and URI, anonymous under user or header privacy). A
%%                  malformed one (chappe_sip_hdr:valid_name_addr/1) reaches
%%                  no leg: {error, badarg}, and A gets a 500 unless
%%                  pass_failure is false
%%   proxy_request_headers  => [Name] | all | {all, [ExcludeName]}
%%   proxy_response_headers => [Name] | all | {all, [ExcludeName]}
%%                    (copied from B's 2xx to A's)
%%   pass_failure          => boolean (default true). false: when B fails
%%                            (its final, Timer C, a transport error, a
%%                            target that cannot be called) A is not
%%                            answered and {error, _} comes back, so the
%%                            app can try elsewhere with the same Req, Res
%%   requests              => [refer | info | message | notify | options]:
%%                            these in-dialog requests, from either leg,
%%                            go to the notify process as {chappe_sip_b2b,
%%                            Ref, {request, a | b, Method, Req, Res}};
%%                            answer them with chappe_sip_res:send/3.
%%                            Without a notify process the relay answers
%%                            them as a dialog does: REFER 603, others 200
%%   relay_info            => boolean (default false): an INFO from one
%%                            leg (DTMF, RFC 6086) goes to the other, and
%%                            its final comes back
%%   pass_provisional_responses => boolean (default true)
%%   proxy, auth           => passed to the B-leg UAC
%%   session_expires, min_se, session_refresher => each leg's session timer
%%   timer_c               => Timer C on the B leg in ms (RFC 3261 16.6
%%                            step 11): how long B may ring, restarted by
%%                            each provisional (of any branch of a fork);
%%                            on expiry B is CANCELled and A gets 408
%%                            (default: the timer_c_ms config, 185000).
%%                            `timeout' is the old name.
%%   media                 => direct | anchor | fun((CallInfo) -> direct | anchor)
%%                            direct (default) passes SDP through; anchor
%%                            puts rtpengine in the media path. CallInfo:
%%                            #{req, uri, sdp, source} (source: the
%%                            caller's signalling address). An offerless
%%                            INVITE (late offer) is anchored as well: B's
%%                            offer in its 2xx and A's answer in its ACK
%%                            go through rtpengine.
%%   anchor_params         => #{a | b => map()} rtpengine flags for the SDP
%%                            sent to that leg, over the defaults (ICE and
%%                            DTLS-SRTP for a WebRTC leg, plain RTP else)
%%   rewrite_sdp           => fun(Leg, offer | answer, Sdp) -> Sdp | {reject, Code}
%%                            (or the older fun(Leg, Sdp) -> Sdp): every
%%                            SDP from Leg before it goes on, as the leg
%%                            sent it; relay/2 takes it over
%%   notify                => pid(): gets {chappe_sip_b2b, Ref, Event}
%%   peer_policy           => priority | round_robin | weighted, for a
%%                            {peer_group, G} target (default priority)
%%   call_ref              => binary(): the call this B2BUA serves
%%                            (chappe_sip_call), for a ref an upstream node
%%                            gave; default the request's
%%                            (chappe_sip_req:call_ref/1). It goes to B as
%%                            X-Chappe-Call (unless b_headers carries one,
%%                            or call_ref_header is false), in both legs'
%%                            call records and in HEP, and finds the call
%%                            with chappe_sip:calls/1. A's own
%%                            X-Chappe-Call is never copied to B. Not a
%%                            token of 1 to 128 characters: as a bad from
%%   call_ref_header       => boolean() (default true)
%%   related               => binary(): the call_ref of the call a transfer
%%                            brought this one from, in the call records
%%   privacy               => true | #{session => boolean()}: act as an
%%                            RFC 3323 privacy service for A's Privacy
%%                            header (see chappe_sip_b2b_hdr:privacy/2).
%%                            A critical level it cannot apply (session,
%%                            unless session => true says the app
%%                            anonymizes the media, or an unknown token)
%%                            gets 500 before B is called, and
%%                            {error, {privacy, Unsupported}} is returned.
%% The result also carries b2b (the handle of set_media/2 and info/1, the
%% reference in its events), the media state relay/1,2 continues with,
%% winner, the destination that answered (winner()), and call_ref. The media fun's
%% CallInfo uri is the first destination's.
-spec create_b2bua(chappe_sip_req:req(), chappe_sip_res:res(), target(), map()) ->
    {ok, legs()} | {error, term()}.
create_b2bua(Req, Res, Uri, Opts) ->
    case
        chappe_sip_b2b_hdr:valid_from(Opts) andalso
            chappe_sip_call:valid_opts(Opts)
    of
        true -> check_privacy(Req, Res, Uri, with_call_ref(Req, Opts));
        false -> chappe_sip_b2b_fork:refuse(Res, badarg, Opts)
    end.

%% the call the B2BUA serves: the app's call_ref, else the request's
with_call_ref(_Req, #{call_ref := _} = Opts) ->
    Opts;
with_call_ref(Req, Opts) ->
    case chappe_sip_req:call_ref(Req) of
        undefined -> Opts#{call_ref => chappe_sip_call:new_ref()};
        Ref -> Opts#{call_ref => Ref}
    end.

check_privacy(Req, Res, Uri, Opts) ->
    case chappe_sip_b2b_hdr:privacy_unsupported(Req, Opts) of
        [] ->
            start_b2bua(Req, Res, Uri, Opts);
        Unsupported ->
            %% RFC 3323 5: fail the request, naming what could not be done
            _ = chappe_sip_res:send(Res, 500, #{
                reason => chappe_sip_b2b_hdr:privacy_failure(Unsupported)
            }),
            {error, {privacy, Unsupported}}
    end.

start_b2bua(Req, Res, Target, Opts) ->
    case chappe_sip_b2b_fork:targets(Target, Opts) of
        {_Fork, []} ->
            _ = chappe_sip_res:send(Res, 503, #{
                reason => <<"Service Unavailable">>
            }),
            {error, none_up};
        {Fork, [First | _] = Dests} ->
            Ref = make_ref(),
            #{call_ref := CallRef} = Opts,
            M = chappe_sip_b2b_media:new(
                media_init(Req, First, Ref, Opts), Opts
            ),
            %% the call is found by its call_ref while it rings, and while
            %% the relay carries it
            ok = chappe_sip_b2b_media:serve(M),
            Result =
                case chappe_sip_b2b_media:start(M) of
                    {ok, M1} ->
                        offer_b(Req, Res, {Fork, Dests}, Opts, M1);
                    {error, Why} ->
                        _ = chappe_sip_res:send(Res, 500, #{
                            reason => <<"Server Internal Error">>
                        }),
                        {error, {media, Why}}
                end,
            case Result of
                {ok, _} -> ok;
                {error, _} -> chappe_sip_call:leave(CallRef, b2b)
            end,
            Result
    end.

media_init(Req, #{uri := Uri} = First, Ref, Opts) ->
    Sdp = chappe_sip_req:body(Req),
    Info = #{
        req => Req,
        uri => Uri,
        sdp => Sdp,
        source => chappe_sip_req:source_ip(Req)
    },
    Mode =
        case maps:get(media, Opts, direct) of
            F when is_function(F, 1) -> F(Info);
            Mode0 -> Mode0
        end,
    #{
        mode => Mode,
        call_id => chappe_sip_req:call_id(Req),
        a_tag => chappe_sip_req:from_tag(Req),
        a_webrtc => Sdp =/= <<>> andalso chappe_sip_sdp:webrtc(Sdp),
        b_webrtc => webrtc(First, Opts),
        ref => Ref,
        call_ref => maps:get(call_ref, Opts),
        related => maps:get(related, Opts, undefined)
    }.

%% a destination over a WebSocket (its URI or its flow) is a browser:
%% WebRTC media
webrtc(#{uri := Uri, opts := BranchOpts}, Opts) ->
    Flow =
        case BranchOpts of
            #{flow := F} when F =/= undefined -> F;
            _ -> maps:get(flow, Opts, undefined)
        end,
    ws_uri(Uri) orelse is_integer(Flow).

%% the media side of a destination: its WebRTC flag and its anchor params
%% merged flag by flag over the call's
profile(#{opts := BranchOpts} = Dest, Opts) ->
    Params = maps:fold(
        fun(Leg, P, Acc) ->
            Acc#{Leg => maps:merge(maps:get(Leg, Acc, #{}), P)}
        end,
        maps:get(anchor_params, Opts, #{}),
        maps:get(anchor_params, BranchOpts, #{})
    ),
    #{webrtc => webrtc(Dest, Opts), params => Params}.

ws_uri(Uri) when not is_binary(Uri) ->
    false;
ws_uri(Uri) ->
    case chappe_sip_uri:parse(Uri) of
        {ok, #{params := #{<<"transport">> := T}}} when is_binary(T) ->
            lists:member(string:lowercase(T), [<<"ws">>, <<"wss">>]);
        _ ->
            false
    end.

%% the offer to B: A's (or local_sdp_b) through the hook and the anchor,
%% one per media profile of the destinations
offer_b(Req, Res, {Fork, Dests}, Opts, M) ->
    Offer = iolist_to_binary(
        maps:get(local_sdp_b, Opts, chappe_sip_req:body(Req))
    ),
    case offers(Offer, Dests, Opts, M) of
        {ok, Dests1, M1} ->
            start_b(Req, Res, {Fork, Dests1}, Opts, Offer =:= <<>>, M1);
        {reject, Code} ->
            offer_rejected(Res, Code, M);
        {reject, Code, offered} ->
            offer_rejected(Res, Code, M)
    end.

offer_rejected(Res, Code, M) ->
    _ = chappe_sip_b2b_media:stop(M),
    _ = chappe_sip_res:send(Res, Code, #{}),
    {error, {rejected, Code}}.

%% Each destination with its media side (profile) and the SDP it gets
%% from rtpengine's offer of Offer (sdp).
-spec offers(
    binary(),
    [chappe_sip_b2b_fork:dest()],
    map(),
    chappe_sip_b2b_media:state()
) ->
    {ok, [chappe_sip_b2b_fork:dest()], chappe_sip_b2b_media:state()}
    | {reject, 300..699}
    | {reject, 300..699, offered}.
offers(Offer, Dests, Opts, M) ->
    Profiles = [profile(D, Opts) || D <- Dests],
    case chappe_sip_b2b_media:fork_offer(Offer, Profiles, M) of
        {ok, Offers, M1} ->
            {ok,
                lists:zipwith(
                    fun(D, {P, Sdp}) -> D#{profile => P, sdp => Sdp} end,
                    Dests,
                    Offers
                ),
                M1};
        Rej ->
            Rej
    end.

start_b(Req, Res, {Fork, Dests}, Opts, LateOffer, M) ->
    Worker = self(),
    %% A's X-Chappe-Call names A's upstream call, not this one: B gets the
    %% call's own (from the UAC, unless b_headers carries one)
    ReqHeaders =
        not_call_ref(chappe_sip_b2b_hdr:proxy_request_headers(Req, Opts)) ++
            maps:get(b_headers, Opts, []),
    ARel = rel100(Req),
    %% a late offer: B's 2xx carries the offer, and its ACK must wait for
    %% A's answer (in A's ACK, see chappe_sip_b2b_relay)
    Late = [{no_ack, true} || LateOffer],
    BOpts0 = maps:merge(maps:from_list(Late), #{
        from => chappe_sip_b2b_hdr:b_from(Req, Opts),
        headers => ReqHeaders,
        notify => Worker,
        owner => Worker,
        handled_events => handled(Opts),
        report_answer => true
    }),
    %% B may send reliable 1xx only if A can take them on its own leg
    BOpts1 =
        case ARel of
            none -> BOpts0;
            _ -> BOpts0#{rel100 => supported}
        end,
    %% flow' lets the B-leg originate over a registered flow (a WS or an
    %% RFC 5626 TCP/TLS/UDP one)
    %% the call records of the two legs name each other
    ACdr = chappe_sip_cdr:relabel(Req, b2b_a),
    ok = chappe_sip_cdr:update(ACdr, maps:with([call_ref, related], Opts)),
    BOpts = maps:merge(
        BOpts1#{cdr => #{role => b2b_b, link => ACdr}},
        maps:with(
            [proxy, auth, flow, call_ref, call_ref_header, related | st_opts()],
            Opts
        )
    ),
    %% pre-choose the A-leg dialog tag so relayed provisionals and the
    %% final 2xx share one To-tag (otherwise nta auto-tags the first
    %% provisional and the leg tag never matches); an earlier attempt on
    %% this request (a hunt) chose it already
    A = a_side(Res),
    ATag = maps:get(atag, A, chappe_sip_dialog:gen_tag()),
    W0 = #{
        fork => Fork,
        timer_c => timer_c(Opts),
        req => Req,
        res => Res,
        opts => Opts,
        bopts => BOpts,
        atag => ATag,
        arel => ARel,
        %% a reliable 1xx to A not PRACKed yet: {true, CarriedSdp}
        prack_wait => false,
        queue => [],
        media => M,
        %% an UPDATE relayed in the early dialogs, waiting for its answer
        early_up => undefined,
        %% the finals of the branches that failed, in arrival order
        finals => []
    },
    W = maps:merge(W0, maps:with([aleg, acseq], A)),
    Dests1 = [D#{bopts => dest_bopts(D, BOpts)} || D <- Dests],
    case Fork of
        serial ->
            attempt(Dests1, W);
        parallel ->
            fork_next(
                chappe_sip_b2b_fork:start(
                    Dests1, chappe_sip_b2b_fork:ringing(W)
                )
            )
    end.

not_call_ref(Hdrs) ->
    Name = chappe_sip_lib:lower(chappe_sip_call:header()),
    [{N, V} || {N, V} <- Hdrs, chappe_sip_lib:lower(N) =/= Name].

%% The UAC options of a destination: its offer, its flow, and its headers
%% after the call's.
-spec dest_bopts(chappe_sip_b2b_fork:dest(), map()) -> map().
dest_bopts(#{opts := BranchOpts, sdp := Sdp}, #{headers := Hdrs} = BOpts) ->
    B1 = BOpts#{
        local_sdp => Sdp,
        headers := Hdrs ++ maps:get(headers, BranchOpts, [])
    },
    case BranchOpts of
        #{flow := Flow} when Flow =/= undefined -> B1#{flow => Flow};
        _ -> B1
    end.

%% Call the next target. Timer C: B may ring as long as it keeps sending
%% provisionals, each one restarting the timer.
attempt([#{uri := Uri, bopts := BOpts} = Dest | Rest], W) ->
    case chappe_sip_uac:start(Uri, BOpts) of
        {ok, BRef} ->
            b2b_wait((chappe_sip_b2b_fork:ringing(W))#{
                bref => BRef,
                branches => #{BRef => chappe_sip_b2b_fork:branch(Dest)},
                rest => Rest
            });
        {error, _} when Rest =/= [] ->
            attempt(Rest, W);
        {error, Reason} ->
            %% the last target could not even be called: A gets its answer
            %% now (unless pass_failure is false), not the engine's 500
            chappe_sip_b2b_fork:fail(Reason, W)
    end.

%% a fork goes on while a branch rings (see chappe_sip_b2b_fork)
fork_next({wait, W}) -> b2b_wait(W);
fork_next({failed, Error, W}) -> chappe_sip_b2b_fork:fail(Error, W).

%% the in-dialog events each leg leaves to its owner (the relay)
handled(Opts) ->
    chappe_sip_b2b_requests:handled(
        maps:get(requests, Opts, []), maps:get(relay_info, Opts, false)
    ).

st_opts() -> [session_expires, min_se, session_refresher].

%% Timer C of Opts (timer_c, or its old name timeout), in ms.
-spec timer_c(map()) -> pos_integer().
timer_c(Opts) ->
    case maps:get(timer_c, Opts, maps:get(timeout, Opts, undefined)) of
        T when is_integer(T), T > 0 -> T;
        _ -> chappe_sip_config:get(timer_c_ms)
    end.

%% a provisional other than 100 restarts Timer C (RFC 3261 16.7 step 2)
restart_timer_c(BMsg, #{timer_c := TimerC} = W) ->
    case chappe_sip_msg:status(BMsg) of
        100 ->
            W;
        _ ->
            W#{deadline := erlang:monotonic_time(millisecond) + TimerC}
    end.

b2b_wait(#{res := Res, branches := Branches, deadline := Deadline} = W) ->
    keep_a_side(W),
    ATxn = chappe_sip_res:req_txn(Res),
    ALeg = maps:get(aleg, W, none),
    receive
        {chappe_sip_uac, BRef, Event} when is_map_key(BRef, Branches) ->
            b_event(BRef, Event, W);
        {chappe_sip_dialog, BEarly, update, UReq, URes} ->
            %% an UPDATE in an early dialog of B (of a branch, when forking)
            b2b_wait(
                chappe_sip_b2b_early:b_update(UReq, URes, W#{bearly := BEarly})
            );
        {chappe_sip_indialog, ALeg, TxnH, _Meta, Raw} ->
            b2b_wait(chappe_sip_b2b_early:a_request(TxnH, Raw, W));
        {chappe_sip_op, ALeg, _} ->
            b2b_wait(W);
        {chappe_sip_b2b_early, ERef, Result} ->
            b2b_wait(chappe_sip_b2b_early:result(ERef, Result, W));
        {chappe_sip_response, TxnH, #{status := St}, Raw} when
            map_get(early_up, W) =/= undefined
        ->
            b2b_wait(chappe_sip_b2b_early:a_response(TxnH, St, Raw, W));
        {chappe_sip_prack, ATxn, _Raw} ->
            %% A acknowledged our reliable 1xx: the next one may go, or the
            %% 2xx that waited for it
            pracked(W#{prack_wait := false});
        {chappe_sip_prack, ATxn, _Raw, PrackH} ->
            %% an offer in A's PRACK (RFC 3262 5) is not carried to a
            %% ringing B: refuse it, the 1xx is acknowledged all the same
            _ = chappe_sip_res:send(
                chappe_sip_res:prack_res(Res, PrackH), 488, #{}
            ),
            pracked(W#{prack_wait := false});
        {chappe_sip_cancel, ATxn, CancelReq} ->
            %% RFC 3326 2: the CANCEL to B carries A's Reason
            cancel_b(W, chappe_sip_b2b_hdr:reason_headers(CancelReq)),
            _ = chappe_sip_res:send(Res, 487, #{
                reason => <<"Request Terminated">>
            }),
            _ = chappe_sip_b2b_media:stop(maps:get(media, W)),
            {error, cancelled}
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        %% Timer C fired (RFC 3261 16.8): CANCEL B (every branch), A gets a
        %% 408 unless pass_failure is false
        cancel_b(W, []),
        _ =
            maps:get(pass_failure, maps:get(opts, W), true) andalso
                chappe_sip_res:send(Res, 408, #{reason => <<"Request Timeout">>}),
        _ = chappe_sip_b2b_media:stop(maps:get(media, W)),
        {error, timeout}
    end.

%% an event of the UAC of a branch
b_event(_BRef, {request_sent, _}, W) ->
    b2b_wait(W);
b_event(_BRef, {early_dialog, D}, W) ->
    %% an UPDATE in it goes to A's early dialog (RFC 3311); the 2xx hands
    %% over the same dialog
    b2b_wait(W#{bearly := D});
b_event(BRef, {provisional, BMsg}, W) ->
    b2b_wait(
        provisional(
            BRef,
            BMsg,
            chappe_sip_b2b_fork:sdp(BRef, BMsg, restart_timer_c(BMsg, W))
        )
    );
b_event(BRef, {answer, BMsg}, W) ->
    b2b_wait(
        chappe_sip_b2b_fork:answer(
            BRef, BMsg, chappe_sip_b2b_fork:sdp(BRef, BMsg, W)
        )
    );
b_event(BRef, {ok, BDialog}, W) ->
    answered(chappe_sip_b2b_fork:won(BRef, BDialog, W));
b_event(BRef, {error, SipError}, W) ->
    b_failed(BRef, SipError, W);
b_event(_BRef, _Other, W) ->
    b2b_wait(W).

%% B answered after all: its dialog is torn down, not cancelled
cancel_b(#{ready := BDialog}, Hdrs) when BDialog =/= undefined ->
    _ = chappe_sip_dialog:destroy(BDialog, #{headers => Hdrs}),
    ok;
cancel_b(#{fork := serial, bref := BRef}, Hdrs) ->
    chappe_sip_uac:cancel(BRef, #{headers => Hdrs});
cancel_b(W, Hdrs) ->
    chappe_sip_b2b_fork:cancel(W, Hdrs).

%% RFC 3262 3: a 2xx waits for the PRACK of a reliable 1xx carrying SDP
answered(#{prack_wait := {true, true}} = W) ->
    b2b_wait(W);
answered(#{ready := BDialog} = W) ->
    answer_a(W, BDialog).

pracked(#{queue := [{BRef, Next} | Rest]} = W) ->
    b2b_wait(
        send_provisional(
            Next, chappe_sip_b2b_fork:media(BRef, W#{queue := Rest})
        )
    );
pracked(#{ready := undefined} = W) ->
    b2b_wait(W);
pracked(W) ->
    answered(W).

%% B may hang up the moment it has our ACK, before A is answered: A still
%% gets the 2xx, and relay/2 then passes B's BYE (and its Reason) on
answer_a(W0, BDialog) ->
    %% the call goes on with the flags of the branch that answered
    #{opts := Opts, media := M0} =
        W = chappe_sip_b2b_fork:media(maps:get(bref, W0), W0),
    SdpBAnswer =
        case remote_sdp(BDialog) of
            <<>> -> maps:get(b_sdp, W);
            Sdp -> Sdp
        end,
    M = chappe_sip_b2b_media:set_tag(b, remote_tag(BDialog), M0),
    case b_sdp_to_a(W, SdpBAnswer, M) of
        {ok, Out, M1} ->
            create_a(W#{media := M1}, BDialog, compute_sdp_a(Opts, Out));
        {reject, Code} ->
            _ = destroy_quietly(BDialog, []),
            _ = chappe_sip_b2b_media:stop(M),
            _ = chappe_sip_res:send(maps:get(res, W), Code, #{}),
            {error, {rejected, Code}}
    end.

%% B's SDP in its 2xx: the answer to A's offer, or, for a late offer, B's
%% own offer
b_sdp_to_a(#{bopts := #{no_ack := true}}, Sdp, M) ->
    chappe_sip_b2b_media:offer(b, Sdp, M);
b_sdp_to_a(#{fork := parallel}, Sdp, M) ->
    chappe_sip_b2b_media:final_answer(b, Sdp, M);
b_sdp_to_a(_W, Sdp, M) ->
    chappe_sip_b2b_media:answer(b, Sdp, M).

late(#{bopts := #{no_ack := true}}) -> true;
late(_W) -> false.

create_a(
    #{req := Req, res := Res, opts := Opts, atag := ATag, media := M} = W,
    BDialog,
    SdpAAnswer
) ->
    RespHeaders = chappe_sip_b2b_hdr:proxy_response_headers(
        maps:get(answer, W), Opts
    ),
    UasOpts0 = maps:merge(maps:with(st_opts(), Opts), #{
        local_sdp => SdpAAnswer,
        headers => RespHeaders,
        local_tag => ATag,
        owner => self(),
        handled_events => handled(Opts),
        call_ref => maps:get(call_ref, Opts)
    }),
    %% A's early leg becomes its dialog, past the CSeq numbers it used
    UasOpts1 =
        case W of
            #{aleg := Leg, acseq := N} when is_integer(Leg) ->
                UasOpts0#{leg => Leg, cseq => max(1, N)};
            _ ->
                UasOpts0
        end,
    UasOpts = nat_flow(Req, UasOpts1),
    Winner = chappe_sip_b2b_fork:winner(W),
    case chappe_sip:create_uas(Req, Res, UasOpts) of
        {ok, ADialog} ->
            _ = erase(a_side_key(Res)),
            Legs = #{
                uas => ADialog,
                uac => BDialog,
                b2b => {self(), maps:get(ref, M)},
                media => M,
                requests => maps:get(requests, Opts, []),
                relay_info => maps:get(relay_info, Opts, false),
                winner => Winner,
                call_ref => maps:get(call_ref, Opts)
            },
            {ok, maps:merge(Legs, maps:from_list([{late, true} || late(W)]))};
        {error, Reason} ->
            %% B may be gone already
            _ = destroy_quietly(BDialog, []),
            _ = chappe_sip_b2b_media:stop(M),
            {error, Reason}
    end.

%% A's To-tag and early leg, kept in the request worker across the
%% create_b2bua/4 calls of a hunt (pass_failure => false), so the 1xx a
%% first target made A see and the 2xx of a later one share a dialog.
a_side_key(Res) ->
    {?MODULE, a_side, chappe_sip_res:req_txn(Res)}.

a_side(Res) ->
    case get(a_side_key(Res)) of
        undefined -> #{};
        A -> A
    end.

keep_a_side(#{res := Res} = W) ->
    _ = put(a_side_key(Res), maps:with([atag, aleg, acseq], W)),
    ok.

%% A caller behind a NAT sends a Contact it cannot be reached at: the
%% requests of its dialog (our re-INVITE, BYE) go to where its INVITE came
%% from instead (RFC 3581, Kamailio's fix_nated_contact)
nat_flow(Req, Opts) ->
    Flow = chappe_sip_route:received_flow(chappe_sip_req:meta(Req)),
    case chappe_sip_route:nated(chappe_sip_req:get(<<"contact">>, Req), Flow) of
        true -> Opts#{flow => Flow};
        false -> Opts
    end.

%% Tear a leg down (with Hdrs on its BYE), whether or not it is still
%% there.
-spec destroy_quietly(chappe_sip_dialog:dialog(), [{binary(), iodata()}]) ->
    ok | {error, term()}.
destroy_quietly(Dialog, Hdrs) ->
    try chappe_sip_dialog:destroy(Dialog, #{headers => Hdrs}) of
        R -> R
    catch
        exit:_ -> ok
    end.

%% A list or a peer group moves on to its next target on 408, 503 or a
%% failure below SIP (RFC 3263 4.3 treats a 503 the same way). A fork
%% waits for its last branch, or a 6xx (RFC 3261 16.7 step 5), then
%% answers A with the best final (16.7 step 6).
b_failed(_BRef, SipError, #{fork := serial, rest := [_ | _] = Rest} = W) ->
    case chappe_sip_b2b_fork:failover(SipError) of
        true -> attempt(Rest, W);
        false -> chappe_sip_b2b_fork:fail(SipError, W)
    end;
b_failed(_BRef, SipError, #{fork := serial} = W) ->
    chappe_sip_b2b_fork:fail(SipError, W);
b_failed(BRef, SipError, W) ->
    fork_next(chappe_sip_b2b_fork:failed(BRef, SipError, W)).

%% ---- provisionals ----

provisional(BRef, BMsg, #{opts := Opts} = W) ->
    case
        maps:get(pass_provisional_responses, Opts, true) andalso
            chappe_sip_msg:status(BMsg) =/= 100
    of
        false ->
            % never relay 100 Trying
            W;
        true ->
            case {reliable(BMsg, W), maps:get(prack_wait, W)} of
                {true, {true, _}} ->
                    %% RFC 3262 3: one unacknowledged reliable 1xx at a time
                    W#{queue := maps:get(queue, W) ++ [{BRef, BMsg}]};
                _ ->
                    send_provisional(BMsg, chappe_sip_b2b_fork:media(BRef, W))
            end
    end.

%% A gets a reliable 1xx when it requires 100rel, or supports it and B's
%% was reliable (RFC 3262 3)
reliable(_BMsg, #{arel := require}) ->
    true;
reliable(BMsg, #{arel := supported}) ->
    chappe_sip_msg:get(<<"rseq">>, BMsg) =/= undefined;
reliable(_BMsg, _W) ->
    false.

%% relay B's 1xx to A under the pre-chosen tag, with its body (early media)
send_provisional(BMsg, #{res := Res, atag := ATag} = W0) ->
    Status = chappe_sip_msg:status(BMsg),
    Reason = default_reason(chappe_sip_msg:reason(BMsg)),
    {CT, Body, W} = early_body(BMsg, W0),
    Reliable = reliable(BMsg, W),
    %% every relayed 1xx carries A's To-tag, so it establishes an early
    %% dialog and needs our Contact (RFC 3261 12.1.1)
    Hdrs = CT ++ [{<<"Contact">>, contact()}],
    _ = chappe_sip_res:send(Res, Status, #{
        reason => Reason,
        headers => Hdrs,
        body => Body,
        to_tag => ATag,
        reliable => Reliable
    }),
    W1 = chappe_sip_b2b_early:leg(W),
    case Reliable of
        true -> W1#{prack_wait := {true, Body =/= <<>>}};
        false -> W1
    end.

%% early media SDP goes through the hook and the anchor as B's answer; a
%% hook refusing it leaves the 1xx without a body
early_body(BMsg, #{opts := Opts, media := M0} = W) ->
    case
        {
            chappe_sip_msg:body(BMsg),
            chappe_sip_msg:get(<<"content-type">>, BMsg)
        }
    of
        {<<>>, _} ->
            {[], <<>>, W};
        {Sdp, CT} when CT =:= undefined; CT =:= <<"application/sdp">> ->
            M = chappe_sip_b2b_media:set_tag(
                b, chappe_sip_msg:to_tag(BMsg), M0
            ),
            case chappe_sip_b2b_media:answer(b, Sdp, M) of
                {ok, Out, M1} ->
                    Early = iolist_to_binary(compute_sdp_a(Opts, Out)),
                    {[{<<"Content-Type">>, <<"application/sdp">>}], Early, W#{
                        media := M1
                    }};
                {reject, _} ->
                    {[], <<>>, W#{media := M}}
            end;
        {Body, CT} ->
            {[{<<"Content-Type">>, CT}], Body, W}
    end.

%% The Contact a B2BUA puts on what it sends A.
-spec contact() -> binary().
contact() ->
    case chappe_sip_engine:contact() of
        undefined ->
            <<"<sip:anonymous.invalid>">>;
        C ->
            case chappe_sip_hdr:name_addr(C) of
                {ok, #{uri := Uri}} -> <<"<", Uri/binary, ">">>;
                _ -> <<"<", C/binary, ">">>
            end
    end.

rel100(Req) ->
    case {has_tag(<<"require">>, Req), has_tag(<<"supported">>, Req)} of
        {true, _} -> require;
        {false, true} -> supported;
        _ -> none
    end.

has_tag(Name, Req) ->
    lists:member(
        <<"100rel">>,
        [
            string:lowercase(string:trim(T))
         || V <- chappe_sip_req:get_all(Name, Req),
            T <- binary:split(V, <<",">>, [global])
        ]
    ).

compute_sdp_a(Opts, SdpB) ->
    case maps:get(local_sdp_a, Opts, undefined) of
        undefined -> SdpB;
        Fun when is_function(Fun, 1) -> Fun(SdpB);
        Val -> Val
    end.

%% ---- relay ----

%% Link the two dialogs and carry offers across. Runs in the process that
%% owns both dialogs (the worker). See relay/2.
-spec relay(legs()) -> {done, a_bye | b_bye | term()}.
relay(Legs) ->
    relay(Legs, #{}).

%% Block until either leg is torn down, then destroy the other with the
%% BYE's Reason. Meanwhile relay offers (re-INVITE, UPDATE) between the
%% legs and answer set_media/2 and info/1. Opts:
%%   rewrite_sdp => fun(Leg, offer | answer, Sdp) -> Sdp | {reject, Code},
%%                  or fun(Leg, Sdp) -> Sdp: applied to every offer or
%%                  answer coming from Leg before it goes to the other
%%                  (default: the one given to create_b2bua/4, else none)
%%   notify      => pid(): gets {chappe_sip_b2b, Ref, {hold | unhold, Leg}}
%%                  when Leg's offer puts the call on hold or takes it off
%%   anchor_params => as for create_b2bua/4
%%   requests, relay_info => as for create_b2bua/4 (the default: the ones
%%                  given to it)
-spec relay(legs(), map()) -> {done, a_bye | b_bye | hangup | term()}.
relay(Legs, Opts) ->
    try
        chappe_sip_b2b_relay:run(Legs, Opts)
    after
        %% the call is over: this process no longer serves it
        chappe_sip_call:leave(maps:get(call_ref, Legs, undefined), b2b)
    end.

%% Carry the call in a process of its own, so the caller is free (to
%% drive a media server on the call, say): relay/2 runs there with Opts,
%% both dialogs and the call's rtpengine session move to it, and its
%% handle comes back. The notify process (Opts' notify, else the one
%% given to create_b2bua/4) gets {chappe_sip_b2b, Ref, {done, Result}},
%% Result as relay/2 returns it, when the call ends. Call it from the
%% process create_b2bua/4 ran in.
-spec relay_async(legs(), map()) -> {ok, b2b()}.
relay_async(Legs, Opts) ->
    chappe_sip_b2b_async:run(Legs, Opts).

%% Switch a live call between direct and anchored media. It re-INVITEs A
%% without an offer, sends A's new offer to B (through rtpengine when it
%% now anchors), and ACKs A with B's answer. {error, busy} while another
%% offer of the call is pending. Returns once the switch is done.
-spec set_media(b2b(), direct | anchor) -> ok | {error, term()}.
set_media(B2b, Mode) when Mode =:= direct; Mode =:= anchor ->
    call(B2b, {set_media, Mode}).

%% What the call is doing: #{media := direct | anchor, hold := #{a, b},
%% call_id := binary(), session := chappe_sip_media:session() | undefined,
%% pending := boolean(), winner := winner() | undefined, call_ref :=
%% binary() | undefined, related := binary() | undefined}. winner is the
%% destination leg B is now: the one that answered create_b2bua/4 or a
%% replace_b/3 fork (undefined for legs made another way, or after
%% replace_b/3 to a URI or a dialog).
-spec info(b2b()) -> map() | {error, term()}.
info(B2b) ->
    call(B2b, info).

%% End the call: both legs get a BYE carrying Opts' headers, and reason
%% (a Reason header value, RFC 3326, such as <<"Q.850;cause=16">>) as a
%% Reason header. relay/1,2 returns {done, hangup}. Opts:
%%   #{headers => [{binary(), iodata()}], reason => binary()}
-spec hangup(b2b(), #{headers => [{binary(), iodata()}], reason => binary()}) ->
    ok | {error, term()}.
hangup(B2b, Opts) ->
    call(B2b, {hangup, Opts}).

%% Replace leg B of an anchored call. Target is a URI, called with a fresh
%% INVITE, or {dialog, D}, a confirmed dialog of yours that gets a
%% re-INVITE (create it with owner => the B2b pid, so its events reach the
%% relay). Either way the offer is rtpengine's for A's side of the
%% session, so A keeps its media addresses and sees no re-INVITE. On a 2xx
%% the relay carries the call with the new B and the old B gets a BYE; on
%% a failure the call keeps the old B. Opts:
%%   headers  => [{binary(), iodata()}] on the INVITE to a URI
%%   from     => the From of the INVITE to a URI or to every destination of
%%               a fork, as for create_b2bua/4, with no default from A: the
%%               INVITE otherwise names this node. A re-INVITE stays in its
%%               dialog and keeps its identity (RFC 3261 12.2.1.1), so
%%               {dialog, D} ignores it, like the other options of a new
%%               INVITE. A malformed one is refused for every target
%%   proxy, auth, flow, session_expires, min_se, session_refresher => as
%%               for create_b2bua/4
%%   timer_c  => how long the new B may ring, in ms (default: timer_c_ms)
%%   anchor_params => #{a | b => map()}: rtpengine flags for that leg from
%%               now on, over the call's (the new B on another network,
%%               a media server behind another rtpengine interface, say);
%%               on a failure the call keeps the ones it had
%% {error, not_anchored} when the call's media is direct, {error, busy}
%% while another offer of the call is pending. The notify process gets
%% {chappe_sip_b2b, Ref, {replaced, b}}. The ACK of a re-INVITE needs no
%% hook here: a dialog's owner gets {chappe_sip_dialog, D, ack, AckReq, _}.
%%
%% {parallel, Dests} rings every destination at once (dest(), as for
%% create_b2bua/4, each with its own flow, headers and anchor_params): the
%% first 2xx wins and {ok, #{winner := winner()}} comes back, the other
%% branches are CANCELled (a 2xx of theirs that still comes gets a BYE).
%% When every branch fails the call keeps the old B and {error, _} carries
%% the best final (a 486 when all are busy), {error, timeout} on Timer C,
%% which covers the whole fork and no provisional restarts. {error,
%% none_up} for an empty list. Destinations with different flags need one
%% rtpengine offer each; on a call whose first offer came from B (a late
%% offer) that gives {error, {rejected, 488}}.
%%
%% {error, badarg} for a malformed Target or Opts, and the call goes on.
-spec replace_b(
    b2b(),
    binary() | {dialog, chappe_sip_dialog:dialog()} | {parallel, [dest()]},
    map()
) ->
    ok | {ok, #{winner := winner()}} | {error, term()}.
replace_b(B2b, Target, Opts) ->
    case chappe_sip_b2b_replace:valid(Target, Opts) of
        true -> call(B2b, {replace_b, Target, Opts}, timer_c(Opts) + 10000);
        false -> {error, badarg}
    end.

%% A request to the relay loop of a call.
-spec call(b2b(), term()) -> term().
call(B2b, Req) ->
    call(B2b, Req, 80000).

-spec call(b2b(), term(), timeout()) -> term().
call({Pid, _Ref}, _Req, _Timeout) when Pid =:= self() ->
    %% the relay loop runs in this process: it cannot answer itself
    {error, relay_process};
call({Pid, Ref}, Req, Timeout) ->
    MRef = erlang:monitor(process, Pid),
    Pid ! {chappe_sip_b2b, Ref, {call, {self(), MRef}, Req}},
    receive
        {MRef, Reply} ->
            erlang:demonitor(MRef, [flush]),
            Reply;
        {'DOWN', MRef, process, _, _} ->
            {error, noproc}
    after Timeout ->
        erlang:demonitor(MRef, [flush]),
        {error, timeout}
    end.

remote_sdp(Dlg) ->
    try chappe_sip_dialog:remote_sdp(Dlg) of
        Sdp -> Sdp
    catch
        exit:_ -> <<>>
    end.

-spec remote_tag(chappe_sip_dialog:dialog()) -> binary() | undefined.
remote_tag(Dlg) ->
    try chappe_sip_dialog:remote_tag(Dlg) of
        Tag -> Tag
    catch
        exit:_ -> undefined
    end.

default_reason(undefined) -> <<"Session Progress">>;
default_reason(<<>>) -> <<"Session Progress">>;
default_reason(R) -> R.
