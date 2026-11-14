%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Stateful forking proxy (RFC 3261 16).
%%
%% proxy_request forwards an incoming request to one or more targets and
%% relays responses back upstream. It runs in the request worker. Forking is
%% sequential (try in order until a 2xx) or parallel (all at once, first 2xx
%% wins and the rest are CANCELled). Provisionals are relayed; the best final
%% (16.7 step 6) is relayed when no branch answers 2xx.
%%
%% Each branch rewrites the Request-URI to its target (16.6 step 2) and goes
%% to the top Route when the request carries one (16.6 step 7), else to the
%% Request-URI. Each INVITE branch runs Timer C (16.6 step 11), reset by
%% every provisional: on expiry it is CANCELled and counts as a 408.
%%
%% The first 2xx is relayed on the server transaction. The proxy then hands
%% the client transactions to a process that stays in the RFC 6026 Accepted
%% state for 64*T1: every further 2xx with a new To-tag (a fork downstream)
%% is forwarded statelessly upstream, retransmissions are absorbed.
%%
%% Loop detection (16.3 step 4): the branch of each Via we insert carries a
%% hash of the request as we received it. A request that comes back with
%% one of our Vias and the same hash looped (482); a different hash is a
%% spiral and is forwarded again.
-module(chappe_sip_proxy).

-export([proxy_request/3, forward_indialog/2, forward_indialog_ack/2]).
-export_type([dest/0]).

-type dest() ::
    binary()
    | {ws, integer()}
    | {flow, binary(), chappe_sip_engine:flow()}.

-record(br, {
    dest :: dest(),
    %% Timer C deadline (monotonic ms), set once the branch is sent
    timer_c :: integer() | undefined,
    %% provisional_timeout: dropped when nothing (not even a 100) came by
    %% then; final_timeout: CANCELled or dropped when no final came by then
    prov_by :: integer() | undefined,
    final_by :: integer() | undefined,
    %% 3xx deep this target came from (0: one the app gave)
    depth = 0 :: non_neg_integer(),
    provisional = false :: boolean(),
    %% Timer C fired after a provisional: CANCELled, its final is a 408
    expired = false :: boolean(),
    %% our Record-Route on this branch is a SIPS URI (undefined: none)
    rr_sips :: boolean() | undefined
}).

-record(px, {
    server :: non_neg_integer(),
    %% the request to fork: Max-Forwards decremented, our Route popped,
    %% media anchored
    msg :: chappe_sip_msg:msg(),
    pending = #{} :: #{non_neg_integer() => #br{}},
    remaining = [] :: [dest()],
    opts :: map(),
    mode :: sequential | parallel,
    %% non-2xx finals of the branches: {Status, Raw | undefined}
    finals = [] :: [{100..699, binary() | undefined}],
    responses = [] :: [100..699],
    hash :: binary(),
    up_flow :: integer() | undefined,
    %% the request came over TLS
    in_tls = false :: boolean(),
    %% the listen address it came to, with several (our Record-Route)
    local :: binary() | undefined,
    timer_c :: pos_integer(),
    %% no new branch: upstream CANCEL or a 6xx (16.7 step 5, 16.10)
    closed = false :: boolean(),
    %% upstream CANCELled; the INVITE's call record (chappe_sip_cdr)
    cancelled = false :: boolean(),
    cdr :: binary() | undefined,
    %% per branch: no response at all, no final (ms; undefined: none)
    prov_timeout :: pos_integer() | undefined,
    final_timeout :: pos_integer() | undefined,
    %% follow_redirects: undefined, or the bounds and the policy
    follow :: chappe_sip_proxy_redirect:follow() | undefined,
    %% the URIs in the target set (16.5: each added once), the targets
    %% 3xx Contacts added so far, and the depth of those not launched yet
    tried = [] :: [binary()],
    added = 0 :: non_neg_integer(),
    depths = #{} :: #{dest() => pos_integer()}
}).

-spec proxy_request(chappe_sip_req:req(), dest() | [dest()], map()) ->
    {ok, #{
        final_status := 100..699,
        final_response := binary(),
        responses := [100..699]
    }}
    | {error, term()}.
proxy_request(Req, Dest, Opts) when is_binary(Dest) ->
    proxy_request(Req, [Dest], Opts);
proxy_request(Req, {ws, _} = Dest, Opts) ->
    proxy_request(Req, [Dest], Opts);
proxy_request(Req, {flow, _, _} = Dest, Opts) ->
    proxy_request(Req, [Dest], Opts);
proxy_request(_Req, [], _Opts) ->
    {error, no_destination};
proxy_request(Req, Dests, Opts) ->
    %% options checked before anything is sent: a bad one leaves the
    %% request to the worker, which answers 500
    case chappe_sip_proxy_redirect:check_opts(Opts) of
        ok -> proxy_checked(Req, Dests, Opts);
        {error, _} = Err -> Err
    end.

proxy_checked(Req, Dests, Opts) ->
    ServerTxn = chappe_sip_req:txn(Req),
    %% the downstream final (a 487 after a CANCEL, a late 2xx) is ours to
    %% relay: the engine must not answer a CANCEL with its own 487
    _ = chappe_sip_engine:mark_proxied(ServerTxn),
    Msg = chappe_sip_req:msg(Req),
    Result =
        case chappe_sip_proxy_rules:looped(Msg) of
            true ->
                _ = respond(ServerTxn, 482, <<"Loop Detected">>),
                {error, looped};
            false ->
                forward(Req, Msg, Dests, Opts)
        end,
    %% the proxy completed the server transaction itself; stop the worker
    %% exit from sending a spurious 500
    case get(chappe_sip_current_res) of
        undefined -> ok;
        Res -> chappe_sip_res:mark_final(Res)
    end,
    Result.

forward(Req, Msg, Dests, Opts) ->
    ServerTxn = chappe_sip_req:txn(Req),
    case prepare(Msg, Opts) of
        {ok, Msg1} ->
            P = #px{
                server = ServerTxn,
                msg = Msg1,
                opts = Opts,
                mode = maps:get(forking, Opts, sequential),
                hash = chappe_sip_proxy_rules:loop_hash(Msg),
                up_flow = up_flow(Req),
                in_tls =
                    maps:get(transport, chappe_sip_req:meta(Req), undefined) =:=
                        <<"tls">>,
                timer_c = timer_c(Opts),
                cdr = chappe_sip_cdr:relabel(Req, proxy),
                local = chappe_sip_binds:local(chappe_sip_req:meta(Req)),
                prov_timeout = maps:get(provisional_timeout, Opts, undefined),
                final_timeout = maps:get(final_timeout, Opts, undefined),
                follow = chappe_sip_proxy_redirect:follow(Opts),
                tried = [U || U <- Dests, is_binary(U)]
            },
            start(P, Dests);
        {error, {media, _} = MErr} ->
            %% media anchor (offer) failed: fail-closed, do not forward
            _ = respond(ServerTxn, 500, <<"Server Internal Error">>),
            {error, MErr};
        {error, loop_detected} ->
            _ = respond(ServerTxn, 483, <<"Too Many Hops">>),
            {error, loop_detected}
    end.

timer_c(Opts) ->
    case maps:get(timer_c, Opts, undefined) of
        T when is_integer(T), T > 0 -> T;
        _ -> chappe_sip_config:get(timer_c_ms)
    end.

%% 16.6 steps 3 and 4: Max-Forwards, then our own Route off the top (16.4),
%% then the media anchor.
prepare(Msg, Opts) ->
    case chappe_sip_msg:decr_max_forwards(Msg) of
        {ok, M1} ->
            chappe_sip_proxy_dialog:anchor_request(Opts, drop_self_route(M1));
        {error, loop_detected} ->
            {error, loop_detected}
    end.

drop_self_route(Msg) ->
    case chappe_sip_route:routes(Msg) of
        [Top | Rest] ->
            case
                chappe_sip_proxy_rules:is_own_address(
                    chappe_sip_hdr:name_addr_uri(Top)
                )
            of
                true -> chappe_sip_route:set_routes(Rest, Msg);
                false -> Msg
            end;
        [] ->
            Msg
    end.

start(#px{mode = parallel} = P, Dests) ->
    P1 = launch_all(P, Dests),
    case map_size(P1#px.pending) of
        % no branch launched: their failures (16.9) make the best final
        0 -> finish(P1);
        _ -> loop(P1)
    end;
start(#px{mode = sequential} = P, Dests) ->
    next_branch(P#px{remaining = Dests}).

%% sequential: launch the next target, skipping those that fail to launch
next_branch(#px{closed = true} = P) ->
    finish(P);
next_branch(#px{remaining = []} = P) ->
    finish(P);
next_branch(#px{remaining = [Dest | Rest]} = P) ->
    case launch(P#px{remaining = Rest}, Dest) of
        {ok, P1} -> loop(P1);
        {error, P1} -> next_branch(P1)
    end.

loop(#px{server = ServerTxn} = P) ->
    receive
        {chappe_sip_response, TxnH, #{status := Status}, Raw} when
            is_map_key(TxnH, P#px.pending)
        ->
            on_response(P, TxnH, Status, Raw);
        {chappe_sip_op, TxnH, {error, _Reason}} when
            is_map_key(TxnH, P#px.pending)
        ->
            %% branch send failed at nta layer: 16.9, as if it got a 503
            branch_done(P#px{finals = [{503, undefined} | P#px.finals]}, TxnH);
        {chappe_sip_op, _TxnH, _} ->
            loop(P);
        {chappe_sip_response, _TxnH, _Meta, _Raw} ->
            %% a branch already dropped (Timer C)
            loop(P);
        {chappe_sip_cancel, ServerTxn, _CancelReq} ->
            %% 16.10: CANCEL every pending branch, start no new one, and
            %% relay what they answer (487)
            cancel_all(P),
            loop(P#px{closed = true, remaining = [], cancelled = true})
    after next_timeout(P) ->
        loop_or_finish(timer_c_fired(P))
    end.

next_timeout(#px{pending = Pending}) ->
    Now = erlang:monotonic_time(millisecond),
    case [deadline(B) || B <- maps:values(Pending)] of
        [] -> infinity;
        Ts -> max(0, lists:min(Ts) - Now)
    end.

%% the first of a branch's timers: Timer C, the provisional and the final
%% timeout
deadline(#br{timer_c = C, prov_by = P, final_by = F}) ->
    lists:min([T || T <- [C, P, F], is_integer(T)]).

%% 16.8: a branch whose Timer C fired is CANCELled when it had a
%% provisional, else dropped; either way it counts as a 408. A CANCELled
%% branch gets 64*T1 to answer the CANCEL before it is dropped too. The
%% provisional and final timeouts end a branch the same way.
timer_c_fired(#px{pending = Pending} = P) ->
    Now = erlang:monotonic_time(millisecond),
    maps:fold(
        fun(TxnH, B, Acc) ->
            case deadline(B) =< Now of
                true -> expire_branch(Acc, TxnH, B, Now);
                false -> Acc
            end
        end,
        P,
        Pending
    ).

expire_branch(P, TxnH, #br{provisional = true, expired = false} = B, Now) ->
    %% RFC 3261 9.1: a CANCEL only once a provisional came
    _ = chappe_sip_engine:cancel_txn(TxnH),
    P#px{
        pending = (P#px.pending)#{
            TxnH => B#br{
                expired = true,
                timer_c = Now + 32000,
                prov_by = undefined,
                final_by = undefined
            }
        }
    };
expire_branch(P, TxnH, _B, _Now) ->
    _ = chappe_sip_engine:finish_txn(TxnH),
    P#px{
        pending = maps:remove(TxnH, P#px.pending),
        finals = [{408, undefined} | P#px.finals],
        responses = [408 | P#px.responses]
    }.

on_response(P, TxnH, 100, _Raw) ->
    % never relay 100 Trying; it does not reset Timer C either (16.7 step
    % 2), but it shows the branch is alive (provisional_timeout)
    B = maps:get(TxnH, P#px.pending),
    loop(P#px{pending = (P#px.pending)#{TxnH => B#br{prov_by = undefined}}});
on_response(#px{server = ServerTxn} = P, TxnH, Status, Raw) when
    Status < 200
->
    B = maps:get(TxnH, P#px.pending),
    _ = relay_answered(ServerTxn, P, Status, upstream_rr(P, B, Raw)),
    B1 = B#br{
        prov_by = undefined,
        provisional = true,
        timer_c =
            case B#br.expired of
                true -> B#br.timer_c;
                false -> erlang:monotonic_time(millisecond) + P#px.timer_c
            end
    },
    loop(P#px{pending = (P#px.pending)#{TxnH => B1}});
on_response(#px{server = ServerTxn} = P, TxnH, Status, Raw) when
    Status < 300
->
    %% a record-routed call's record waits for the BYE (chappe_sip_cdr):
    %% it is held before the 2xx goes out, so a BYE right behind the 2xx
    %% finds it; any other record stops once the 2xx is relayed
    RR = chappe_sip_proxy_rules:record_routes(P#px.opts),
    _ = RR andalso chappe_sip_cdr:proxy_answered(P#px.cdr, P#px.opts, Raw),
    _ = relay_answered(
        ServerTxn, P, Status, upstream_rr(P, maps:get(TxnH, P#px.pending), Raw)
    ),
    _ = RR orelse chappe_sip_cdr:proxy_answered(P#px.cdr, P#px.opts, Raw),
    P1 = P#px{
        pending = maps:remove(TxnH, P#px.pending),
        responses = [Status | P#px.responses]
    },
    cancel_all(P1),
    accepted(P1, TxnH, Raw),
    {ok, #{
        final_status => Status,
        final_response => Raw,
        responses => lists:reverse(P1#px.responses)
    }};
on_response(P, TxnH, Status, Raw) ->
    _ = chappe_sip_engine:finish_txn(TxnH),
    #br{expired = Expired, depth = Depth} = maps:get(TxnH, P#px.pending),
    {Final, P0} =
        case Expired of
            %% our own CANCEL after Timer C: report the timeout
            true -> {[{408, undefined}], P};
            false -> recurse(P, Status, Raw, Depth)
        end,
    P1 = P0#px{
        pending = maps:remove(TxnH, P0#px.pending),
        finals = Final ++ P0#px.finals,
        responses = [Status | P0#px.responses]
    },
    case Status >= 600 of
        true ->
            %% 16.7 step 5: a 6xx ends the search; CANCEL the rest and
            %% relay the 6xx once they are done
            cancel_all(P1),
            loop_or_finish(P1#px{closed = true, remaining = []});
        false ->
            loop_or_finish(P1)
    end.

%% RFC 3261 16.7 step 4, with follow_redirects: a 3xx's Contacts join the
%% target set within the bounds of chappe_sip_proxy_redirect:recurse/3,
%% and what is left of the 3xx is a candidate final.
recurse(#px{follow = Follow} = P, Status, Raw, Depth) when
    Follow =/= undefined, Status >= 300, Status < 400
->
    case chappe_sip_msg:parse(Raw) of
        {ok, M} ->
            {Targets, Left} = chappe_sip_proxy_redirect:recurse(
                #{
                    follow => Follow,
                    tried => P#px.tried,
                    added => P#px.added,
                    closed => P#px.closed,
                    sips => chappe_sip_uri:is_sips(
                        chappe_sip_msg:uri(P#px.msg)
                    ),
                    depth => Depth
                },
                Raw,
                M
            ),
            P1 = P#px{
                tried = Targets ++ P#px.tried,
                added = P#px.added + length(Targets),
                depths = maps:merge(
                    P#px.depths, #{T => Depth + 1 || T <- Targets}
                )
            },
            {[{Status, R} || R <- Left], add_targets(P1, Targets)};
        {error, _} ->
            {[{Status, Raw}], P}
    end;
recurse(P, Status, Raw, _Depth) ->
    {[{Status, Raw}], P}.

%% sequential: the redirect targets are tried next, in q order; parallel:
%% they are sent at once
add_targets(#px{mode = sequential} = P, Targets) ->
    P#px{remaining = Targets ++ P#px.remaining};
add_targets(#px{mode = parallel} = P, Targets) ->
    launch_all(P, Targets).

%% launch each target; one that fails to launch leaves its final (16.9)
launch_all(P, Dests) ->
    lists:foldl(
        fun(Dest, Acc) ->
            case launch(Acc, Dest) of
                {ok, Acc1} -> Acc1;
                {error, Acc1} -> Acc1
            end
        end,
        P,
        Dests
    ).

loop_or_finish(P) ->
    case after_branch(P) of
        #px{} = P1 -> loop(P1);
        Done -> Done
    end.

%% a branch reached a final or failed: start the next one (sequential) or
%% finish once nothing is pending
branch_done(P, TxnH) ->
    loop_or_finish(P#px{pending = maps:remove(TxnH, P#px.pending)}).

after_branch(#px{pending = Pending} = P) when map_size(Pending) > 0 ->
    P;
after_branch(#px{mode = sequential, closed = false, remaining = [_ | _]} = P) ->
    next_branch(P);
after_branch(P) ->
    finish(P).

%% RFC 6026 Accepted state, off the request worker
accepted(#px{pending = Pending}, WinTxn, WinRaw) ->
    chappe_sip_proxy_accepted:start(WinTxn, WinRaw, maps:keys(Pending)).

%% no 2xx: relay the best final upstream; with no final at all, a 408
%% (16.7 step 6)
finish(#px{finals = [], server = ServerTxn} = P) ->
    _ = respond(ServerTxn, 408, <<"Request Timeout">>),
    {ok, #{
        final_status => 408,
        final_response => <<>>,
        responses => lists:reverse(P#px.responses)
    }};
finish(#px{finals = Finals, server = ServerTxn} = P) ->
    {Status, Raw} = chappe_sip_proxy_rules:best_response(lists:reverse(Finals)),
    chappe_sip_cdr:proxy_final(P#px.cdr, P#px.cancelled, Status),
    _ =
        case Raw of
            undefined ->
                respond(ServerTxn, Status, reason(Status));
            _ ->
                relay(ServerTxn, Status, chappe_sip_route:strip_via(Raw))
        end,
    {ok, #{
        final_status => Status,
        final_response =>
            case Raw of
                undefined -> <<>>;
                _ -> Raw
            end,
        responses => lists:reverse(P#px.responses)
    }}.

reason(408) -> <<"Request Timeout">>;
reason(500) -> <<"Server Internal Error">>;
reason(_) -> <<>>.

%% ---- branches ----

%% One client transaction per target: the Request-URI is the target (16.6
%% step 2), a Record-Route of ours when asked (step 4), the next hop is the
%% top Route when there is one (steps 6 and 7) and the branch carries the
%% loop hash (step 8).
launch(#px{msg = Msg} = P, Dest) ->
    case chappe_sip_proxy_rules:retarget(Dest, Msg) of
        {ok, M1, Via} ->
            {RRSips, M2} = record_route(P, Dest, M1),
            {Route, M3} = chappe_sip_proxy_rules:next_hop(Dest, Via, M2),
            Uri = chappe_sip_msg:uri(M1),
            P1 = P#px{
                tried = [Uri | lists:delete(Uri, P#px.tried)],
                depths = maps:remove(Dest, P#px.depths)
            },
            B = #br{
                dest = Dest,
                rr_sips = RRSips,
                depth = maps:get(Dest, P#px.depths, 0)
            },
            send_branch(P1, B, Route, M3);
        {error, _} ->
            %% RFC 5630 5.3: a SIPS request never goes to a SIP target;
            %% RFC 3261 19.1.1: nor to a SIPS target naming UDP
            {error, P#px{
                finals = [{480, undefined} | P#px.finals],
                responses = [480 | P#px.responses]
            }}
    end.

send_branch(P, #br{dest = Dest} = B0, Route, Msg) ->
    Raw = iolist_to_binary(chappe_sip_msg:encode(Msg)),
    Opts =
        case down_flow(Dest) of
            undefined ->
                #{branch => chappe_sip_proxy_rules:new_branch(P#px.hash)};
            _ ->
                #{}
        end,
    case chappe_sip_engine:send_request(Route, Raw, self(), Opts) of
        {ok, TxnH} ->
            Now = erlang:monotonic_time(millisecond),
            B = B0#br{
                timer_c = Now + P#px.timer_c,
                prov_by = after_ms(Now, P#px.prov_timeout),
                final_by = after_ms(Now, P#px.final_timeout)
            },
            {ok, P#px{pending = (P#px.pending)#{TxnH => B}}};
        {error, _} ->
            %% 16.9: a transport error counts as a 503
            {error, P#px{
                finals = [{503, undefined} | P#px.finals],
                responses = [503 | P#px.responses]
            }}
    end.

after_ms(_Now, undefined) -> undefined;
after_ms(Now, Ms) -> Now + Ms.

record_route(#px{opts = Opts} = P, Dest, Msg) ->
    case chappe_sip_proxy_rules:record_routes(Opts) of
        true ->
            Contact = chappe_sip_proxy_rules:rr_contact(Msg, P#px.local),
            %% the flow tokens name the WS legs (the inbound one and this
            %% branch's) so in-dialog requests route back over those
            %% connections; the marker MAC binds them with the Call-ID
            Down = down_flow(Dest),
            RR = chappe_sip_route:record_route(
                Contact,
                {P#px.up_flow, Down},
                chappe_sip_msg:call_id(Msg)
            ),
            {
                chappe_sip_uri:is_sips(
                    chappe_sip_hdr:name_addr_uri(Contact)
                ),
                chappe_sip_msg:prepend(<<"Record-Route">>, RR, Msg)
            };
        false ->
            {undefined, Msg}
    end.

%% 16.7 step 8: a request that came over TLS and left on a SIP Record-Route
%% (or the other way round) has our Record-Route in its 1xx/2xx rewritten
%% for the upstream side, signed for that address, so each side routes
%% back to us over its own transport.
upstream_rr(
    #px{in_tls = InTls, up_flow = Up, local = Local},
    #br{rr_sips = Sips, dest = Dest},
    Raw
) when
    is_boolean(Sips), Sips =/= InTls
->
    chappe_sip_proxy_rules:rewrite_rr(
        Raw,
        chappe_sip_binds:contact_or_primary(Local, InTls),
        {Up, down_flow(Dest)}
    );
upstream_rr(_P, _B, Raw) ->
    Raw.

cancel_all(#px{pending = Pending}) ->
    maps:foreach(
        fun(TxnH, _) -> chappe_sip_engine:cancel_txn(TxnH) end, Pending
    ).

%% the WS flow a target is reached over, if any
down_flow({ws, F}) -> F;
down_flow({flow, _Uri, F}) when is_integer(F) -> F;
down_flow(_Dest) -> undefined.

%% the WS flow the request came in on, if any
up_flow(Req) ->
    case maps:get(flow, chappe_sip_req:meta(Req), undefined) of
        Flow when is_integer(Flow) -> Flow;
        _ -> undefined
    end.

%% ---- in-dialog forwarding: chappe_sip_proxy_dialog ----

%% Forward one in-dialog transit request through our record route.
-spec forward_indialog(chappe_sip_req:req(), chappe_sip_res:res()) -> ok.
forward_indialog(Req, Res) ->
    chappe_sip_proxy_dialog:forward_indialog(Req, Res).

%% Forward a 2xx ACK through our record route, statelessly.
-spec forward_indialog_ack(binary(), udp | {ws, integer()}) -> ok.
forward_indialog_ack(Raw, ArrivedVia) ->
    chappe_sip_proxy_dialog:forward_indialog_ack(Raw, ArrivedVia).

%% Relay a response upstream, rewriting its SDP with the rtpengine answer first
%% when media anchoring is on for this proxy transaction.
relay_answered(ServerTxn, P, Status, Raw) ->
    relay(
        ServerTxn,
        Status,
        chappe_sip_route:strip_via(
            chappe_sip_proxy_dialog:answer_sdp(P#px.opts, Status, Raw)
        )
    ).

relay(ServerTxn, Status, Raw) ->
    chappe_sip_engine:relay_response(ServerTxn, Status, Raw).

respond(ServerTxn, Status, Reason) ->
    chappe_sip_engine:dialog_respond(
        ServerTxn, Status, Reason, <<>>, <<>>, <<>>
    ).
