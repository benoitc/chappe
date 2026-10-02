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
%% relay/1,2 then carries the call: a re-INVITE or UPDATE with a new offer
%% goes to the other leg and its answer (or failure, 491 included) comes
%% back; one with no offer or an unchanged one (a session refresh, RFC 4028)
%% is answered by its own leg, which also runs its own session timer (RFC
%% 4028 4: a B2BUA is a UA on each side). When either leg is torn down the
%% other is too, with the BYE's Reason (RFC 3326). Both legs are created
%% with modify and update handled by their owner, so the owner must run
%% relay/1,2 (or answer those events itself).
-module(chappe_sip_b2b).

-include("chappe_sip.hrl").
-include("chappe_sip_uac.hrl").

-export([create_b2bua/4, relay/1, relay/2]).

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
%%   privacy               => true | #{session => boolean()}: act as an
%%                            RFC 3323 privacy service for A's Privacy
%%                            header (see chappe_sip_b2b_hdr:privacy/2).
%%                            A critical level it cannot apply (session,
%%                            unless session => true says the app
%%                            anonymizes the media, or an unknown token)
%%                            gets 500 before B is called, and
%%                            {error, {privacy, Unsupported}} is returned.
-spec create_b2bua(chappe_sip_req:req(), chappe_sip_res:res(), binary(), map()) ->
    {ok, #{
        uas := chappe_sip_dialog:dialog(), uac := chappe_sip_dialog:dialog()
    }}
    | {error, term()}.
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

start_b2bua(Req, Res, Uri, Opts) ->
    Worker = self(),
    SdpAOffer = chappe_sip_req:body(Req),
    SdpBOffer = maps:get(local_sdp_b, Opts, SdpAOffer),
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
    BOpts = maps:merge(
        BOpts1, maps:with([proxy, auth, flow | st_opts()], Opts)
    ),
    %% pre-choose the A-leg dialog tag so relayed provisionals and the
    %% final 2xx share one To-tag (otherwise nta auto-tags the first
    %% provisional and the leg tag never matches)
    ATag = chappe_sip_dialog:gen_tag(),
    case chappe_sip_uac:start(Uri, BOpts) of
        {ok, BRef} ->
            %% Timer C: B may ring as long as it keeps sending provisionals,
            %% each one restarting the timer
            TimerC = timer_c(Opts),
            Deadline = erlang:monotonic_time(millisecond) + TimerC,
            b2b_wait(#{
                timer_c => TimerC,
                req => Req,
                res => Res,
                opts => Opts,
                bref => BRef,
                atag => ATag,
                deadline => Deadline,
                arel => ARel,
                %% a reliable 1xx to A not PRACKed yet: {true, CarriedSdp}
                prack_wait => false,
                queue => [],
                answer => undefined,
                %% the first SDP B answered with (a 183's or the 2xx's)
                b_sdp => <<>>,
                ready => undefined
            });
        {error, Reason} ->
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
    receive
        {chappe_sip_uac, BRef, {request_sent, _}} ->
            b2b_wait(W);
        {chappe_sip_uac, BRef, {early_dialog, _}} ->
            %% B's early dialog answers B's requests itself; the 2xx hands
            %% over the same dialog
            b2b_wait(W);
        {chappe_sip_uac, BRef, {provisional, BMsg}} ->
            b2b_wait(provisional(BMsg, b_sdp(BMsg, restart_timer_c(BMsg, W))));
        {chappe_sip_uac, BRef, {answer, BMsg}} ->
            b2b_wait(b_sdp(BMsg, W#{answer := BMsg}));
        {chappe_sip_uac, BRef, {ok, BDialog}} ->
            answered(W#{ready := BDialog});
        {chappe_sip_uac, BRef, {error, SipError}} ->
            handle_b_failure(Res, SipError, maps:get(opts, W));
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
answer_a(#{req := Req, res := Res, opts := Opts, atag := ATag} = W, BDialog) ->
    SdpBAnswer =
        case remote_sdp(BDialog) of
            <<>> -> maps:get(b_sdp, W);
            Sdp -> Sdp
        end,
    SdpAAnswer = compute_sdp_a(Opts, SdpBAnswer),
    RespHeaders = chappe_sip_b2b_hdr:proxy_response_headers(
        maps:get(answer, W), Opts
    ),
    UasOpts = maps:merge(maps:with(st_opts(), Opts), #{
        local_sdp => SdpAAnswer,
        headers => RespHeaders,
        local_tag => ATag,
        owner => self(),
        handled_events => ?RELAYED
    }),
    case chappe_sip:create_uas(Req, Res, UasOpts) of
        {ok, ADialog} ->
            {ok, #{uas => ADialog, uac => BDialog}};
        {error, Reason} ->
            %% B may be gone already
            try chappe_sip_dialog:destroy(BDialog) of
                _ -> ok
            catch
                exit:_ -> ok
            end,
            {error, Reason}
    end.

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
send_provisional(BMsg, #{res := Res, atag := ATag, opts := Opts} = W) ->
    Status = chappe_sip_msg:status(BMsg),
    Reason = default_reason(chappe_sip_msg:reason(BMsg)),
    {CT, Body} = early_body(BMsg, Opts),
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
    case Reliable of
        true -> W#{prack_wait := {true, Body =/= <<>>}};
        false -> W
    end.

early_body(BMsg, Opts) ->
    case
        {
            chappe_sip_msg:body(BMsg),
            chappe_sip_msg:get(<<"content-type">>, BMsg)
        }
    of
        {<<>>, _} ->
            {[], <<>>};
        {Sdp, CT} when CT =:= undefined; CT =:= <<"application/sdp">> ->
            Early = iolist_to_binary(compute_sdp_a(Opts, Sdp)),
            {[{<<"Content-Type">>, <<"application/sdp">>}], Early};
        {Body, CT} ->
            {[{<<"Content-Type">>, CT}], Body}
    end.

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
-spec relay(#{
    uas := chappe_sip_dialog:dialog(), uac := chappe_sip_dialog:dialog()
}) ->
    {done, a_bye | b_bye | term()}.
relay(Legs) ->
    relay(Legs, #{}).

%% Block until either leg is torn down, then destroy the other with the
%% BYE's Reason. Meanwhile relay offers (re-INVITE, UPDATE) between the
%% legs. Opts:
%%   rewrite_sdp => fun(From :: a | b, Sdp) -> Sdp, applied to an offer or
%%                  answer coming from leg From before it goes to the other
%%                  (default: unchanged)
-spec relay(
    #{uas := chappe_sip_dialog:dialog(), uac := chappe_sip_dialog:dialog()},
    map()
) ->
    {done, a_bye | b_bye | term()}.
relay(#{uas := A, uac := B}, Opts) ->
    RefA = chappe_sip_dialog:monitor(A),
    RefB = chappe_sip_dialog:monitor(B),
    Rewrite = maps:get(rewrite_sdp, Opts, fun(_From, Sdp) -> Sdp end),
    relay_loop(#{
        a => A,
        b => B,
        refs => {RefA, RefB},
        rewrite => Rewrite,
        pending => undefined
    }).

relay_loop(#{a := A, b := B, refs := {RefA, RefB}} = S) ->
    receive
        {chappe_sip_dialog, A, destroy, Why} ->
            done(S, B, Why, a_bye);
        {chappe_sip_dialog, B, destroy, Why} ->
            done(S, A, Why, b_bye);
        %% an abnormal fsm exit emits no destroy message; tear the peer down
        {'DOWN', RefA, process, _, _} ->
            done(S, B, undefined, a_bye);
        {'DOWN', RefB, process, _, _} ->
            done(S, A, undefined, b_bye);
        {chappe_sip_dialog, X, Event, Req, Res} when
            (X =:= A orelse X =:= B) andalso
                (Event =:= modify orelse Event =:= update)
        ->
            relay_loop(offer(leg(X, S), Event, Req, Res, S));
        {relay_result, Ref, Result} ->
            relay_loop(relayed(Ref, Result, S));
        {chappe_sip_dialog, _, _, _} ->
            relay_loop(S);
        {chappe_sip_dialog, _, _, _, _} ->
            relay_loop(S)
    end.

leg(X, #{a := X}) -> a;
leg(_X, _S) -> b.

other(a) -> b;
other(b) -> a.

done(#{pending := P}, Peer, Why, Tag) ->
    _ =
        case P of
            #{pid := Pid} -> exit(Pid, kill);
            _ -> ok
        end,
    _ = chappe_sip_dialog:destroy(Peer, #{
        headers => chappe_sip_b2b_hdr:reason_headers(Why)
    }),
    {done, Tag}.

%% An offer from leg X. None (a refresh UPDATE, an offerless re-INVITE) or
%% the SDP X sent last (same o= line, RFC 3264 8) is a session refresh:
%% X's leg answers with the SDP it has; anything else goes to the other leg.
offer(X, Event, Req, Res, S) ->
    Dlg = maps:get(X, S),
    Offer = chappe_sip_req:body(Req),
    case Offer =:= <<>> orelse same_version(Offer, remote_sdp(Dlg)) of
        true ->
            answer_locally(Event, Offer, Dlg, Res),
            S;
        false when map_get(pending, S) =/= undefined ->
            %% RFC 3261 14.2 / RFC 3311 5.2: the other leg's offer is still
            %% on its way
            RA = integer_to_binary(rand:uniform(11) - 1),
            _ = chappe_sip_res:send(Res, 500, #{
                reason => <<"Server Internal Error">>,
                headers => [{<<"Retry-After">>, RA}]
            }),
            S;
        false ->
            forward(X, Event, Offer, Res, S)
    end.

answer_locally(update, <<>>, _Dlg, Res) ->
    _ = chappe_sip_res:send(Res, 200, #{reason => <<"OK">>}),
    ok;
answer_locally(_Event, _Offer, Dlg, Res) ->
    _ = chappe_sip_res:send(Res, 200, sdp_reply(local_sdp(Dlg))),
    ok.

forward(X, Event, Offer, Res, #{rewrite := Rw} = S) ->
    Y = other(X),
    Peer = maps:get(Y, S),
    Sdp = Rw(X, Offer),
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn(fun() ->
        Parent ! {relay_result, Ref, send_offer(Event, Peer, Sdp)}
    end),
    S#{pending := #{ref => Ref, pid => Pid, from => X, res => Res}}.

%% Run in a helper so the relay keeps answering both legs meanwhile.
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

%% the other leg's answer or refusal goes back to the offering leg as is
relayed(Ref, Result, #{pending := #{ref := Ref} = P, rewrite := Rw} = S) ->
    #{from := X, res := Res} = P,
    _ =
        case Result of
            {ok, Answer} ->
                chappe_sip_res:send(Res, 200, sdp_reply(Rw(other(X), Answer)));
            {error, #chappe_sip_error{status = St, reason = Reason}} when
                St >= 300
            ->
                chappe_sip_res:send(Res, St, #{reason => Reason});
            _ ->
                chappe_sip_res:send(Res, 500, #{
                    reason => <<"Server Internal Error">>
                })
        end,
    S#{pending := undefined};
relayed(_Ref, _Result, S) ->
    S.

sdp_reply(<<>>) ->
    #{reason => <<"OK">>};
sdp_reply(Sdp) ->
    #{
        reason => <<"OK">>,
        headers => [{<<"Content-Type">>, <<"application/sdp">>}],
        body => Sdp
    }.

remote_sdp(Dlg) ->
    try chappe_sip_dialog:remote_sdp(Dlg) of
        Sdp -> Sdp
    catch
        exit:_ -> <<>>
    end.

local_sdp(Dlg) ->
    try chappe_sip_dialog:local_sdp(Dlg) of
        Sdp -> Sdp
    catch
        exit:_ -> <<>>
    end.

%% RFC 3264 8: an unchanged session keeps the o= line (its version)
same_version(A, B) ->
    case {origin(A), origin(B)} of
        {undefined, _} -> A =:= B;
        {O, O} -> true;
        _ -> false
    end.

origin(Sdp) ->
    case
        re:run(Sdp, <<"^o=([^\r\n]*)">>, [
            multiline, {capture, all_but_first, binary}
        ])
    of
        {match, [O]} -> O;
        nomatch -> undefined
    end.

sip_error(Status, Msg) ->
    Reason =
        case chappe_sip_msg:reason(Msg) of
            undefined -> <<>>;
            R -> R
        end,
    #chappe_sip_error{status = Status, reason = Reason, response = Msg}.

default_reason(undefined) -> <<"Session Progress">>;
default_reason(<<>>) -> <<"Session Progress">>;
default_reason(R) -> R.
