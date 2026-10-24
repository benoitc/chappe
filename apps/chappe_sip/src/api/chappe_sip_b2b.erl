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
-module(chappe_sip_b2b).

-include("chappe_sip.hrl").
-include("chappe_sip_uac.hrl").

-export([create_b2bua/4, relay/1, relay/2, set_media/2, info/1]).
-export([call/2, contact/0]).

-export_type([b2b/0, legs/0, target/0]).

%% A running call, for set_media/2 and info/1: the process that runs
%% relay/1,2 and the reference its events carry.
-type b2b() :: {pid(), reference()}.
-type legs() :: #{
    uas := chappe_sip_dialog:dialog(),
    uac := chappe_sip_dialog:dialog(),
    b2b => b2b(),
    media => chappe_sip_b2b_media:state()
}.
%% Where leg B goes: a URI, or a group of OPTIONS-monitored peers
%% (chappe_sip_peers), tried in turn while one fails with 408, 503 or a
%% transport error.
-type target() :: binary() | {peer_group, term()}.

%% in-dialog events relay/2 answers
-define(RELAYED, [modify, update]).

%% Opts:
%%   local_sdp_b   => offer sent to B (default: A's INVITE body)
%%   local_sdp_a   => answer sent to A: value | fun(SdpB) (default: SdpB);
%%                    also applied to early media SDP
%%   proxy_request_headers  => [Name] | all | {all, [ExcludeName]}
%%   proxy_response_headers => [Name] | all | {all, [ExcludeName]}
%%                    (copied from B's 2xx to A's)
%%   pass_failure          => boolean (default true)
%%   pass_provisional_responses => boolean (default true)
%%   proxy, auth           => passed to the B-leg UAC
%%   session_expires, min_se, session_refresher => each leg's session timer
%%   timer_c               => Timer C on the B leg in ms (RFC 3261 16.6
%%                            step 11): how long B may ring, restarted by
%%                            each provisional; on expiry B is CANCELled and
%%                            A gets 408 (default: the timer_c_ms config,
%%                            185000). `timeout' is the old name.
%%   media                 => direct | anchor | fun((CallInfo) -> direct | anchor)
%%                            direct (default) passes SDP through; anchor
%%                            puts rtpengine in the media path. CallInfo:
%%                            #{req, uri, sdp, source} (source: the
%%                            caller's signalling address). An offerless
%%                            INVITE is always direct.
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
%%   privacy               => true | #{session => boolean()}: act as an
%%                            RFC 3323 privacy service for A's Privacy
%%                            header (see chappe_sip_b2b_hdr:privacy/2).
%%                            A critical level it cannot apply (session,
%%                            unless session => true says the app
%%                            anonymizes the media, or an unknown token)
%%                            gets 500 before B is called, and
%%                            {error, {privacy, Unsupported}} is returned.
%% The result also carries b2b (the handle of set_media/2 and info/1, the
%% reference in its events) and the media state relay/1,2 continues with.
-spec create_b2bua(chappe_sip_req:req(), chappe_sip_res:res(), target(), map()) ->
    {ok, legs()} | {error, term()}.
create_b2bua(Req, Res, Uri, Opts) ->
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
    case targets(Target, Opts) of
        [] ->
            _ = chappe_sip_res:send(Res, 503, #{
                reason => <<"Service Unavailable">>
            }),
            {error, none_up};
        [Uri | _] = Uris ->
            Ref = make_ref(),
            M = chappe_sip_b2b_media:new(media_init(Req, Uri, Ref, Opts), Opts),
            case chappe_sip_b2b_media:start(M) of
                {ok, M1} ->
                    offer_b(Req, Res, Uris, Opts, M1);
                {error, Why} ->
                    _ = chappe_sip_res:send(Res, 500, #{
                        reason => <<"Server Internal Error">>
                    }),
                    {error, {media, Why}}
            end
    end.

targets({peer_group, Group}, Opts) ->
    chappe_sip_peers:candidates(Group, maps:get(peer_policy, Opts, priority));
targets(Uri, _Opts) when is_binary(Uri) ->
    [Uri].

media_init(Req, Uri, Ref, Opts) ->
    Sdp = chappe_sip_req:body(Req),
    Info = #{
        req => Req,
        uri => Uri,
        sdp => Sdp,
        source => chappe_sip_req:source_ip(Req)
    },
    Mode =
        case {Sdp, maps:get(media, Opts, direct)} of
            {<<>>, _} -> direct;
            {_, F} when is_function(F, 1) -> F(Info);
            {_, Mode0} -> Mode0
        end,
    #{
        mode => Mode,
        call_id => chappe_sip_req:call_id(Req),
        a_tag => chappe_sip_req:from_tag(Req),
        a_webrtc => Sdp =/= <<>> andalso chappe_sip_sdp:webrtc(Sdp),
        b_webrtc => ws_uri(Uri),
        ref => Ref
    }.

%% a WS target is a browser: WebRTC media
ws_uri(Uri) ->
    case chappe_sip_uri:parse(Uri) of
        {ok, #{params := #{<<"transport">> := T}}} when is_binary(T) ->
            lists:member(string:lowercase(T), [<<"ws">>, <<"wss">>]);
        _ ->
            false
    end.

%% the offer to B: A's (or local_sdp_b) through the hook and the anchor
offer_b(Req, Res, Uris, Opts, M) ->
    Offer = iolist_to_binary(
        maps:get(local_sdp_b, Opts, chappe_sip_req:body(Req))
    ),
    case chappe_sip_b2b_media:offer(a, Offer, M) of
        {ok, SdpBOffer, M1} ->
            start_b(Req, Res, Uris, Opts, SdpBOffer, M1);
        {reject, Code} ->
            _ = chappe_sip_b2b_media:stop(M),
            _ = chappe_sip_res:send(Res, Code, #{}),
            {error, {rejected, Code}}
    end.

start_b(Req, Res, Uris, Opts, SdpBOffer, M) ->
    Worker = self(),
    ReqHeaders = chappe_sip_b2b_hdr:proxy_request_headers(Req, Opts),
    ARel = rel100(Req),
    BOpts0 = #{
        local_sdp => SdpBOffer,
        headers => ReqHeaders,
        notify => Worker,
        owner => Worker,
        handled_events => ?RELAYED,
        report_answer => true
    },
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
    BOpts = maps:merge(
        BOpts1#{cdr => #{role => b2b_b, link => ACdr}},
        maps:with([proxy, auth, flow | st_opts()], Opts)
    ),
    %% pre-choose the A-leg dialog tag so relayed provisionals and the
    %% final 2xx share one To-tag (otherwise nta auto-tags the first
    %% provisional and the leg tag never matches)
    ATag = chappe_sip_dialog:gen_tag(),
    attempt(Uris, #{
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
        early_up => undefined
    }).

%% Call the next target. Timer C: B may ring as long as it keeps sending
%% provisionals, each one restarting the timer.
attempt([Uri | Rest], #{bopts := BOpts, timer_c := TimerC} = W) ->
    case chappe_sip_uac:start(Uri, BOpts) of
        {ok, BRef} ->
            b2b_wait(W#{
                bref => BRef,
                rest => Rest,
                deadline => erlang:monotonic_time(millisecond) + TimerC,
                answer => undefined,
                %% the first SDP B answered with (a 183's or the 2xx's)
                b_sdp => <<>>,
                ready => undefined,
                bearly => undefined
            });
        {error, _} when Rest =/= [] ->
            attempt(Rest, W);
        {error, Reason} ->
            _ = chappe_sip_b2b_media:stop(maps:get(media, W)),
            {error, Reason}
    end.

st_opts() -> [session_expires, min_se, session_refresher].

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

b2b_wait(#{res := Res, bref := BRef, deadline := Deadline} = W) ->
    ATxn = chappe_sip_res:req_txn(Res),
    ALeg = maps:get(aleg, W, none),
    BEarly = maps:get(bearly, W),
    receive
        {chappe_sip_uac, BRef, {request_sent, _}} ->
            b2b_wait(W);
        {chappe_sip_uac, BRef, {early_dialog, D}} ->
            %% an UPDATE in it goes to A's early dialog (RFC 3311); the 2xx
            %% hands over the same dialog
            b2b_wait(W#{bearly := D});
        {chappe_sip_dialog, BEarly, update, UReq, URes} ->
            b2b_wait(chappe_sip_b2b_early:b_update(UReq, URes, W));
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
        {chappe_sip_uac, BRef, {provisional, BMsg}} ->
            b2b_wait(provisional(BMsg, b_sdp(BMsg, restart_timer_c(BMsg, W))));
        {chappe_sip_uac, BRef, {answer, BMsg}} ->
            b2b_wait(b_sdp(BMsg, W#{answer := BMsg}));
        {chappe_sip_uac, BRef, {ok, BDialog}} ->
            answered(W#{ready := BDialog});
        {chappe_sip_uac, BRef, {error, SipError}} ->
            b_failed(SipError, W);
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
            {error, cancelled}
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        %% Timer C fired (RFC 3261 16.8): CANCEL B, A gets a 408
        cancel_b(W, []),
        _ = chappe_sip_res:send(Res, 408, #{reason => <<"Request Timeout">>}),
        {error, timeout}
    end.

%% B answered after all: its dialog is torn down, not cancelled
cancel_b(#{ready := BDialog}, Hdrs) when BDialog =/= undefined ->
    _ = chappe_sip_dialog:destroy(BDialog, #{headers => Hdrs}),
    ok;
cancel_b(#{bref := BRef}, Hdrs) ->
    chappe_sip_uac:cancel(BRef, #{headers => Hdrs}).

%% RFC 3262 3: a 2xx waits for the PRACK of a reliable 1xx carrying SDP
answered(#{prack_wait := {true, true}} = W) ->
    b2b_wait(W);
answered(#{ready := BDialog} = W) ->
    answer_a(W, BDialog).

pracked(#{queue := [Next | Rest]} = W) ->
    b2b_wait(send_provisional(Next, W#{queue := Rest}));
pracked(#{ready := undefined} = W) ->
    b2b_wait(W);
pracked(W) ->
    answered(W).

b_sdp(BMsg, #{b_sdp := <<>>} = W) ->
    W#{b_sdp := chappe_sip_msg:body(BMsg)};
b_sdp(_BMsg, W) ->
    W.

%% B may hang up the moment it has our ACK, before A is answered: A still
%% gets the 2xx, and relay/2 then passes B's BYE (and its Reason) on
answer_a(#{opts := Opts, media := M0} = W, BDialog) ->
    SdpBAnswer =
        case remote_sdp(BDialog) of
            <<>> -> maps:get(b_sdp, W);
            Sdp -> Sdp
        end,
    M = chappe_sip_b2b_media:set_tag(b, remote_tag(BDialog), M0),
    case chappe_sip_b2b_media:answer(b, SdpBAnswer, M) of
        {ok, Out, M1} ->
            create_a(W#{media := M1}, BDialog, compute_sdp_a(Opts, Out));
        {reject, Code} ->
            _ = destroy_quietly(BDialog),
            _ = chappe_sip_b2b_media:stop(M),
            _ = chappe_sip_res:send(maps:get(res, W), Code, #{}),
            {error, {rejected, Code}}
    end.

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
        handled_events => ?RELAYED
    }),
    %% A's early leg becomes its dialog, past the CSeq numbers it used
    UasOpts =
        case W of
            #{aleg := Leg, acseq := N} when is_integer(Leg) ->
                UasOpts0#{leg => Leg, cseq => max(1, N)};
            _ ->
                UasOpts0
        end,
    case chappe_sip:create_uas(Req, Res, UasOpts) of
        {ok, ADialog} ->
            {ok, #{
                uas => ADialog,
                uac => BDialog,
                b2b => {self(), maps:get(ref, M)},
                media => M
            }};
        {error, Reason} ->
            %% B may be gone already
            _ = destroy_quietly(BDialog),
            _ = chappe_sip_b2b_media:stop(M),
            {error, Reason}
    end.

destroy_quietly(Dialog) ->
    try chappe_sip_dialog:destroy(Dialog) of
        R -> R
    catch
        exit:_ -> ok
    end.

%% A peer group moves on to its next up peer on 408, 503 or a failure
%% below SIP (RFC 3263 4.3 treats a 503 the same way)
b_failed(SipError, #{rest := [_ | _] = Rest} = W) ->
    case failover(SipError) of
        true -> attempt(Rest, W);
        false -> b_failed(SipError, W#{rest := []})
    end;
b_failed(SipError, #{res := Res, opts := Opts, media := M}) ->
    _ = chappe_sip_b2b_media:stop(M),
    handle_b_failure(Res, SipError, Opts).

failover(#chappe_sip_error{status = St}) -> St =:= 408 orelse St =:= 503;
failover(_Other) -> true.

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

%% ---- provisionals ----

provisional(BMsg, #{opts := Opts} = W) ->
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
                    W#{queue := maps:get(queue, W) ++ [BMsg]};
                _ ->
                    send_provisional(BMsg, W)
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
-spec relay(legs(), map()) -> {done, a_bye | b_bye | term()}.
relay(Legs, Opts) ->
    chappe_sip_b2b_relay:run(Legs, Opts).

%% Switch a live call between direct and anchored media. It re-INVITEs A
%% without an offer, sends A's new offer to B (through rtpengine when it
%% now anchors), and ACKs A with B's answer. {error, busy} while another
%% offer of the call is pending. Returns once the switch is done.
-spec set_media(b2b(), direct | anchor) -> ok | {error, term()}.
set_media(B2b, Mode) when Mode =:= direct; Mode =:= anchor ->
    call(B2b, {set_media, Mode}).

%% What the call is doing: #{media := direct | anchor, hold := #{a, b},
%% call_id := binary(), session := chappe_sip_media:session() | undefined,
%% pending := boolean()}.
-spec info(b2b()) -> map() | {error, term()}.
info(B2b) ->
    call(B2b, info).

%% A request to the relay loop of a call.
-spec call(b2b(), term()) -> term().
call({Pid, _Ref}, _Req) when Pid =:= self() ->
    %% the relay loop runs in this process: it cannot answer itself
    {error, relay_process};
call({Pid, Ref}, Req) ->
    MRef = erlang:monitor(process, Pid),
    Pid ! {chappe_sip_b2b, Ref, {call, {self(), MRef}, Req}},
    receive
        {MRef, Reply} ->
            erlang:demonitor(MRef, [flush]),
            Reply;
        {'DOWN', MRef, process, _, _} ->
            {error, noproc}
    after 80000 ->
        erlang:demonitor(MRef, [flush]),
        {error, timeout}
    end.

remote_sdp(Dlg) ->
    try chappe_sip_dialog:remote_sdp(Dlg) of
        Sdp -> Sdp
    catch
        exit:_ -> <<>>
    end.

remote_tag(Dlg) ->
    try chappe_sip_dialog:remote_tag(Dlg) of
        Tag -> Tag
    catch
        exit:_ -> undefined
    end.

default_reason(undefined) -> <<"Session Progress">>;
default_reason(<<>>) -> <<"Session Progress">>;
default_reason(R) -> R.
