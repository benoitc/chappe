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
    timer_c :: pos_integer(),
    %% no new branch: upstream CANCEL or a 6xx (16.7 step 5, 16.10)
    closed = false :: boolean(),
    %% upstream CANCELled; the INVITE's call record (chappe_sip_cdr)
    cancelled = false :: boolean(),
    cdr :: binary() | undefined
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
                cdr = chappe_sip_cdr:relabel(Req, proxy)
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
                    chappe_sip_proxy_rules:uri_of(Top)
                )
            of
                true -> chappe_sip_route:set_routes(Rest, Msg);
                false -> Msg
            end;
        [] ->
            Msg
    end.

start(#px{mode = parallel} = P, Dests) ->
    P1 = lists:foldl(
        fun(Dest, Acc) ->
            case launch(Acc, Dest) of
                {ok, Acc1} -> Acc1;
                {error, Acc1} -> Acc1
            end
        end,
        P,
        Dests
    ),
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
    case [T || #br{timer_c = T} <- maps:values(Pending)] of
        [] -> infinity;
        Ts -> max(0, lists:min(Ts) - Now)
    end.

%% 16.8: a branch whose Timer C fired is CANCELled when it had a
%% provisional, else dropped; either way it counts as a 408. A CANCELled
%% branch gets 64*T1 to answer the CANCEL before it is dropped too.
timer_c_fired(#px{pending = Pending} = P) ->
    Now = erlang:monotonic_time(millisecond),
    maps:fold(
        fun
            (TxnH, #br{timer_c = T} = B, Acc) when T =< Now ->
                expire_branch(Acc, TxnH, B, Now);
            (_TxnH, _B, Acc) ->
                Acc
        end,
        P,
        Pending
    ).

expire_branch(P, TxnH, #br{provisional = true, expired = false} = B, Now) ->
    _ = chappe_sip_engine:cancel_txn(TxnH),
    P#px{
        pending = (P#px.pending)#{
            TxnH => B#br{expired = true, timer_c = Now + 32000}
        }
    };
expire_branch(P, TxnH, _B, _Now) ->
    _ = chappe_sip_engine:finish_txn(TxnH),
    P#px{
        pending = maps:remove(TxnH, P#px.pending),
        finals = [{408, undefined} | P#px.finals],
        responses = [408 | P#px.responses]
    }.

on_response(P, _TxnH, 100, _Raw) ->
    % never relay 100 Trying; it does not reset Timer C either (16.7 step 2)
    loop(P);
on_response(#px{server = ServerTxn} = P, TxnH, Status, Raw) when
    Status < 200
->
    B = maps:get(TxnH, P#px.pending),
    _ = relay_answered(ServerTxn, P, Status, upstream_rr(P, B, Raw)),
    B1 = B#br{
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
    _ = relay_answered(
        ServerTxn, P, Status, upstream_rr(P, maps:get(TxnH, P#px.pending), Raw)
    ),
    P1 = P#px{
        pending = maps:remove(TxnH, P#px.pending),
        responses = [Status | P#px.responses]
    },
    cancel_all(P1),
    accepted(P1, TxnH, Raw),
    chappe_sip_cdr:proxy_answered(P1#px.cdr, P1#px.opts, Raw),
    {ok, #{
        final_status => Status,
        final_response => Raw,
        responses => lists:reverse(P1#px.responses)
    }};
on_response(P, TxnH, Status, Raw) ->
    _ = chappe_sip_engine:finish_txn(TxnH),
    #br{expired = Expired} = maps:get(TxnH, P#px.pending),
    Final =
        case Expired of
            %% our own CANCEL after Timer C: report the timeout
            true -> {408, undefined};
            false -> {Status, Raw}
        end,
    P1 = P#px{
        pending = maps:remove(TxnH, P#px.pending),
        finals = [Final | P#px.finals],
        responses = [Status | P#px.responses]
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

%% RFC 6026 Accepted state, off the request worker: forward each new 2xx
%% (a To-tag not seen yet) for 64*T1, absorb retransmissions, drain the
%% CANCELled branches, then release every client transaction.
accepted(#px{pending = Pending}, WinTxn, WinRaw) ->
    Txns = [WinTxn | maps:keys(Pending)],
    Seen = [to_tag(WinRaw)],
    Window = chappe_sip_config:get(proxy_accepted_ms),
    Pid = spawn(fun() ->
        receive
            {chappe_sip_proxy_accepted, go} -> ok
        after 5000 -> ok
        end,
        accepted_loop(
            Txns, Seen, erlang:monotonic_time(millisecond) + Window
        )
    end),
    lists:foreach(fun(H) -> chappe_sip_engine:reg_handle(H, Pid) end, Txns),
    %% what reached the worker before the handover goes to the new owner
    hand_over(Txns, Pid),
    Pid ! {chappe_sip_proxy_accepted, go},
    ok.

hand_over(Txns, Pid) ->
    receive
        {chappe_sip_response, H, _, _} = M ->
            case lists:member(H, Txns) of
                true -> Pid ! M;
                false -> ok
            end,
            hand_over(Txns, Pid)
    after 0 -> ok
    end.

accepted_loop(Txns, Seen, Until) ->
    receive
        {chappe_sip_response, TxnH, #{status := St}, Raw} when
            St >= 200, St < 300
        ->
            Tag = to_tag(Raw),
            case lists:member(Tag, Seen) of
                true ->
                    accepted_loop(Txns, Seen, Until);
                false ->
                    %% a forked 2xx: forward with our top Via intact
                    _ = chappe_sip_engine:forward_response(Raw),
                    accepted_loop(
                        lists:usort([TxnH | Txns]), [Tag | Seen], Until
                    )
            end;
        {chappe_sip_response, _TxnH, _Meta, _Raw} ->
            accepted_loop(Txns, Seen, Until);
        {chappe_sip_op, _TxnH, _} ->
            accepted_loop(Txns, Seen, Until)
    after max(0, Until - erlang:monotonic_time(millisecond)) ->
        lists:foreach(fun chappe_sip_engine:finish_txn/1, Txns)
    end.

to_tag(Raw) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, M} -> chappe_sip_msg:to_tag(M);
        {error, _} -> undefined
    end.

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
            {Route, M3} = next_hop(Dest, Via, M2),
            send_branch(P, #br{dest = Dest, rr_sips = RRSips}, Route, M3);
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
            B = B0#br{
                timer_c = erlang:monotonic_time(millisecond) + P#px.timer_c
            },
            {ok, P#px{pending = (P#px.pending)#{TxnH => B}}};
        {error, _} ->
            %% 16.9: a transport error counts as a 503
            {error, P#px{
                finals = [{503, undefined} | P#px.finals],
                responses = [503 | P#px.responses]
            }}
    end.

record_route(#px{opts = Opts} = P, Dest, Msg) ->
    case chappe_sip_proxy_rules:record_routes(Opts) of
        true ->
            Contact = rr_contact(Msg),
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
                chappe_sip_proxy_rules:is_sips(
                    chappe_sip_proxy_rules:uri_of(Contact)
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
    #px{in_tls = InTls, up_flow = Up}, #br{rr_sips = Sips} = B, Raw
) when
    is_boolean(Sips), Sips =/= InTls
->
    Down = down_flow(B#br.dest),
    Contact =
        case InTls of
            true -> chappe_sip_engine:tls_contact();
            false -> chappe_sip_engine:contact()
        end,
    case {Contact, chappe_sip_msg:parse(Raw)} of
        {C, {ok, M}} when is_binary(C) ->
            CallId = chappe_sip_msg:call_id(M),
            RRs = [
                case chappe_sip_route:is_self(V, undefined, CallId) of
                    true ->
                        chappe_sip_route:record_route(C, {Up, Down}, CallId);
                    false ->
                        V
                end
             || H <- chappe_sip_msg:get_all(<<"record-route">>, M),
                V <- chappe_sip_hdr:split_list(H)
            ],
            M1 = lists:foldr(
                fun(V, Acc) ->
                    chappe_sip_msg:prepend(<<"Record-Route">>, V, Acc)
                end,
                chappe_sip_msg:remove(<<"record-route">>, M),
                RRs
            ),
            iolist_to_binary(chappe_sip_msg:encode(M1));
        _ ->
            Raw
    end;
upstream_rr(_P, _B, Raw) ->
    Raw.

%% a WS target goes over its flow. Otherwise the top Route is the next hop
%% when there is one: a loose router (;lr) keeps the Request-URI, a strict
%% one takes it, the Request-URI going to the end of the Route set (16.6
%% step 6). With no Route the Request-URI is the next hop, or the SIPS
%% target a SIP request goes to over TLS.
next_hop({ws, _} = D, _Via, Msg) ->
    {D, Msg};
next_hop({flow, _Uri, Flow}, _Via, Msg) ->
    %% RFC 5626 5.3: a binding's flow is the way to reach it
    {chappe_sip_route:flow_route(Flow), Msg};
next_hop(_Dest, Via, Msg) ->
    case chappe_sip_route:routes(Msg) of
        [] when is_binary(Via) ->
            {Via, Msg};
        [] ->
            {chappe_sip_msg:uri(Msg), Msg};
        [Top | Rest] ->
            TopUri = chappe_sip_proxy_rules:uri_of(Top),
            case chappe_sip_proxy_rules:is_loose(TopUri) of
                true ->
                    {TopUri, Msg};
                false ->
                    RUri = chappe_sip_msg:uri(Msg),
                    Msg1 = chappe_sip_route:set_routes(
                        Rest ++ [<<"<", RUri/binary, ">">>],
                        chappe_sip_msg:set_uri(TopUri, Msg)
                    ),
                    {TopUri, Msg1}
            end
    end.

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

%% 16.6 step 4 (and RFC 5630): the Record-Route is a SIPS URI, our TLS
%% address, when the forwarded request's Request-URI or top Route is a SIPS
%% URI, and a SIP URI otherwise, also for a request that came over TLS
rr_contact(Msg) ->
    Top =
        case chappe_sip_route:routes(Msg) of
            [R | _] -> chappe_sip_proxy_rules:uri_of(R);
            [] -> undefined
        end,
    Secure =
        chappe_sip_proxy_rules:is_sips(chappe_sip_msg:uri(Msg)) orelse
            chappe_sip_proxy_rules:is_sips(Top),
    case {Secure, chappe_sip_engine:tls_contact()} of
        {true, Tls} when is_binary(Tls) -> Tls;
        _ -> chappe_sip_engine:contact()
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
