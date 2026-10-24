%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The SBC of the SBC interop lab: a B2BUA on the public chappe_sip API in
%% front of two FreeSWITCH nodes (a peer group monitored with OPTIONS) and
%% rtpengine. Every INVITE goes to the up FreeSWITCH of the group, failing
%% over to the other on 408, 503 or a transport error. The Request-URI user
%% picks the media mode:
%%
%%   anchor...   rtpengine anchors the call
%%   direct...   the SDP passes through
%%   glare       direct, then set_media(anchor) right after the ACK: the
%%               caller's own re-INVITE crosses ours (RFC 3261 14.2)
%%   any other   chappe_sip_media:bypass/2 decides (the lab's network is
%%               one private network, so direct)
%%
%% Kamailio pings the node (its dispatcher) and the node pings Kamailio
%% (a peer of group kam). chappe_sbc_interop_SUITE drives the node with
%% erl_call: calls/0, set_media/2, query/1, events/1, peers/0. Every event
%% is printed on stdout.
-module(chappe_sbc_node).

-export([start/1]).
-export([calls/0, set_media/2, query/1, events/1, peers/0]).

-define(RTPE, "10.253.9.20").
-define(FS1, <<"sip:10.253.9.31:5080">>).
-define(FS2, <<"sip:10.253.9.32:5080">>).
-define(KAM, <<"sip:10.253.9.40:5060">>).
-define(NETWORKS, [<<"10.253.9.0/24">>]).

-spec start(string()) -> ok.
start(Ip) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Keeper = keeper(),
    ok = chappe_sip:start(#{
        contact => iolist_to_binary(["sip:", Ip, ":5060"]),
        media => #{rtpengine => #{nodes => [#{name => rtpe, host => ?RTPE, port => 2223}]}}
    }),
    Peer = #{interval_ms => 1000, timeout_ms => 1000, up_after => 1, down_after => 2},
    ok = chappe_sip:peer_add(fs1, Peer#{uri => ?FS1, group => fs, priority => 1}),
    ok = chappe_sip:peer_add(fs2, Peer#{uri => ?FS2, group => fs, priority => 2}),
    ok = chappe_sip:peer_add(kam, Peer#{uri => ?KAM, group => kam}),
    ok = chappe_sip:peer_subscribe(Keeper),
    ok = chappe_sip:options(fun(Req, Res) ->
        log("options from ~s", [chappe_sip_req:source_ip(Req)]),
        _ = chappe_sip_res:send(Res, 200),
        ok
    end),
    ok = chappe_sip:invite(fun(Req, Res) -> invite(Keeper, Req, Res) end),
    log("chappe_sbc_node up", []),
    ok.

%% the tables live in a process of their own, which also logs the peer
%% and hold events
keeper() ->
    Self = self(),
    Pid = spawn(fun() ->
        _ = ets:new(sbc_calls, [named_table, public]),
        _ = ets:new(sbc_events, [named_table, public, bag]),
        Self ! {keeper, self()},
        keep()
    end),
    receive {keeper, Pid} -> Pid end.

keep() ->
    receive
        {chappe_sip_peer, Name, State} ->
            log("peer ~p ~p", [Name, State]);
        {chappe_sip_b2b, Ref, Event} ->
            case ets:match(sbc_calls, {'$1', {'_', Ref}, '_'}) of
                [[CallId] | _] ->
                    true = ets:insert(sbc_events, {CallId, Event}),
                    log("call ~s ~p", [CallId, Event]);
                [] ->
                    ok
            end;
        _ ->
            ok
    end,
    keep().

invite(Keeper, Req, Res) ->
    CallId = chappe_sip_req:call_id(Req),
    User = user(Req),
    Media = media(User),
    Opts = #{media => Media, notify => Keeper},
    case chappe_sip:create_b2bua(Req, Res, {peer_group, fs}, Opts) of
        {ok, #{b2b := B2b, uac := B, media := M} = Legs} ->
            true = ets:insert(sbc_calls, {CallId, B2b, User}),
            log("call ~s up media ~p to ~s", [
                CallId, chappe_sip_b2b_media:mode(M), chappe_sip_dialog:call_id(B)
            ]),
            _ = User =:= <<"glare">> andalso glare(CallId, B2b),
            Done = chappe_sip_b2b:relay(Legs),
            ets:delete(sbc_calls, CallId),
            log("call ~s ~p", [CallId, Done]);
        {error, Why} ->
            log("call ~s failed ~p", [CallId, Why])
    end.

media(<<"anchor", _/binary>>) -> anchor;
media(<<"direct", _/binary>>) -> direct;
media(<<"glare">>) -> direct;
media(_) ->
    fun(#{sdp := Sdp, source := Source}) ->
        %% leg B is a FreeSWITCH of the lab network
        chappe_sip_media:bypass(
            #{a => #{sdp => Sdp, source => Source}, b => {10, 253, 9, 31}},
            #{networks => ?NETWORKS}
        )
    end.

%% our re-INVITE goes once the caller's ACK is in; its own crosses it
glare(CallId, B2b) ->
    spawn(fun() ->
        log("call ~s set_media anchor ~p", [CallId, chappe_sip_b2b:set_media(B2b, anchor)])
    end).

user(Req) ->
    case chappe_sip_uri:parse(chappe_sip_req:uri(Req)) of
        {ok, #{user := U}} -> U;
        _ -> <<>>
    end.

mode(B2b) ->
    case chappe_sip_b2b:info(B2b) of
        #{media := M} -> M;
        _ -> unknown
    end.

%% ---- control (erl_call) ----

%% Call-IDs as strings: erl_call prints a binary as #Bin<...>
-spec calls() -> [{string(), atom()}].
calls() ->
    [{binary_to_list(CallId), mode(B2b)} || {CallId, B2b, _} <- ets:tab2list(sbc_calls)].

-spec set_media(binary() | string(), direct | anchor) -> ok | {error, term()}.
set_media(CallId, Mode) ->
    case ets:lookup(sbc_calls, bin(CallId)) of
        [{_, B2b, _}] -> chappe_sip_b2b:set_media(B2b, Mode);
        [] -> {error, no_call}
    end.

%% RTP packets rtpengine relayed for the call (all its streams).
-spec query(binary() | string()) -> non_neg_integer() | {error, term()}.
query(CallId) ->
    case chappe_rtpengine:query(rtpe, #{call_id => bin(CallId)}) of
        {ok, Reply} ->
            Totals = maps:get(<<"totals">>, Reply, #{}),
            maps:get(<<"packets">>, maps:get(<<"RTP">>, Totals, #{}), 0);
        {error, Why, _} ->
            {error, Why};
        {error, Why} ->
            {error, Why}
    end.

-spec events(binary() | string()) -> [term()].
events(CallId) ->
    [E || {_, E} <- ets:lookup(sbc_events, bin(CallId))].

-spec peers() -> [{term(), atom()}].
peers() ->
    [{N, maps:get(state, I)} || {N, I} <- chappe_sip:peers()].

bin(B) when is_binary(B) -> B;
bin(L) when is_list(L) -> list_to_binary(L).

log(Fmt, Args) ->
    io:format("sbc " ++ Fmt ++ "~n", Args).
