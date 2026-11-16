%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc One OPTIONS-monitored peer (see chappe_sip_peers).
%%
%% States: unknown (no probe settled yet), up, down. Every interval_ms it
%% sends an OPTIONS and waits timeout_ms for its final response. up_after
%% answered probes in a row make it up, down_after failed ones make it
%% down; each change is written to the peers table and told to the
%% subscribers.
-module(chappe_sip_peer).
-behaviour(gen_statem).

-include("chappe_sip.hrl").

-export([start_link/2, initial/1, share/3]).
-export([init/1, callback_mode/0, handle_event/4]).

-record(state, {
    name :: term(),
    uri :: binary(),
    opts :: map(),
    %% the probe in flight and when it went
    ref :: term(),
    sent :: integer() | undefined,
    %% answered and failed probes in a row
    oks = 0 :: non_neg_integer(),
    fails = 0 :: non_neg_integer(),
    info :: chappe_sip_peers:info(),
    %% singleton: this process has written the KV once
    shared = false :: boolean()
}).
-type state() :: #state{}.

-define(DEFAULTS, #{
    group => default,
    priority => 10,
    weight => 1,
    interval_ms => 10000,
    timeout_ms => 2000,
    up_after => 1,
    down_after => 2
}).

-spec start_link(term(), map()) -> gen_statem:start_ret().
start_link(Name, Opts) ->
    gen_statem:start_link(?MODULE, {Name, Opts}, []).

callback_mode() -> handle_event_function.

%% A peer's row before its first probe.
-spec initial(map()) -> chappe_sip_peers:info().
initial(Opts0) ->
    Opts = maps:merge(?DEFAULTS, Opts0),
    #{
        uri => maps:get(uri, Opts),
        group => maps:get(group, Opts),
        priority => maps:get(priority, Opts),
        weight => maps:get(weight, Opts),
        state => unknown,
        last_status => undefined,
        rtt_ms => undefined,
        since => erlang:system_time(millisecond)
    }.

-spec init({term(), map()}) ->
    gen_statem:init_result(unknown | up | down, state()).
init({Name, Opts0}) ->
    Opts = maps:merge(?DEFAULTS, Opts0),
    Info = start_info(Name, Opts),
    S = #state{
        name = Name, uri = maps:get(uri, Opts), opts = Opts, info = Info
    },
    {ok, maps:get(state, Info), S, [{{timeout, probe}, 0, probe}]}.

%% all_nodes: a fresh row in the local table. singleton: the region's
%% last word on the peer, so a takeover goes on from it (an up peer stays
%% up while the new prober counts).
start_info(Name, #{probe := singleton} = Opts) ->
    case chappe_cluster:get(chappe_sip_peers:kv_key(Name)) of
        {ok, #{info := Info}, _Version} -> Info;
        _ -> initial(Opts)
    end;
start_info(Name, Opts) ->
    Info = initial(Opts),
    ok = chappe_sip_peers:put(Name, Info),
    Info.

handle_event({timeout, probe}, probe, _St, #state{opts = Opts} = S) ->
    Next = {{timeout, probe}, maps:get(interval_ms, Opts), probe},
    case probing(S) andalso send(S) of
        false ->
            %% the singleton's lease is gone: no OPTIONS from here
            {keep_state_and_data, [Next]};
        {ok, Ref} ->
            {keep_state,
                S#state{ref = Ref, sent = erlang:monotonic_time(millisecond)}, [
                    Next, {{timeout, answer}, maps:get(timeout_ms, Opts), Ref}
                ]};
        {error, _} ->
            outcome(timeout, S#state{ref = undefined}, [Next])
    end;
handle_event({timeout, answer}, Ref, _St, #state{ref = Ref} = S) ->
    outcome(timeout, S#state{ref = undefined}, []);
handle_event({timeout, answer}, _Stale, _St, _S) ->
    keep_state_and_data;
handle_event(info, {chappe_sip_uac, Ref, Event}, _St, #state{ref = Ref} = S) ->
    case final(Event) of
        none ->
            keep_state_and_data;
        Status ->
            outcome(Status, S#state{ref = undefined}, [
                {{timeout, answer}, cancel}
            ])
    end;
handle_event(info, _Other, _St, _S) ->
    keep_state_and_data;
handle_event({call, From}, _Req, _St, _S) ->
    {keep_state_and_data, [{reply, From, {error, unknown_call}}]};
handle_event(cast, _Msg, _St, _S) ->
    keep_state_and_data.

send(#state{uri = Uri, opts = Opts}) ->
    Base = maps:with([from, proxy], Opts),
    try
        chappe_sip:request(Uri, Base#{
            method => <<"OPTIONS">>, notify => self(), owner => self()
        })
    catch
        exit:Why -> {error, Why}
    end.

final({response, Msg}) ->
    case chappe_sip_msg:status(Msg) of
        St when is_integer(St), St >= 200 -> St;
        _ -> none
    end;
final({error, #chappe_sip_error{status = St}}) when is_integer(St) ->
    St;
final({error, _}) ->
    timeout;
final(_Other) ->
    none.

alive(timeout, _Opts) ->
    false;
alive(St, #{alive_codes := Codes}) ->
    lists:member(St, Codes);
alive(St, _Opts) ->
    St =/= 408 andalso St =/= 503.

outcome(Status, #state{opts = Opts, info = Info0} = S0, Actions) ->
    Rtt =
        case Status of
            timeout -> maps:get(rtt_ms, Info0);
            _ -> erlang:monotonic_time(millisecond) - S0#state.sent
        end,
    S =
        case alive(Status, Opts) of
            true -> S0#state{oks = S0#state.oks + 1, fails = 0};
            false -> S0#state{oks = 0, fails = S0#state.fails + 1}
        end,
    Old = maps:get(state, Info0),
    New = next(Old, S, Opts),
    Info1 = Info0#{last_status => Status, rtt_ms => Rtt},
    Info =
        case New of
            Old -> Info1;
            _ -> Info1#{state => New, since => erlang:system_time(millisecond)}
        end,
    {next_state, New, publish(S#state{info = Info}, Info0), Actions}.

probing(#state{name = Name, opts = #{probe := singleton}}) ->
    chappe_cluster:singleton_valid(chappe_sip_peers:singleton(Name));
probing(_S) ->
    true.

%% singleton: to the KV, fenced, when the state or the last status
%% changed (an rtt alone is not worth a Raft write); all_nodes: to the
%% local table, and a change to the subscribers.
publish(#state{opts = #{probe := singleton}, info = New} = S, Old) ->
    Same =
        maps:with([state, last_status], Old) =:=
            maps:with([state, last_status], New),
    case Same andalso S#state.shared of
        true -> S;
        false -> S#state{shared = kv_write(S#state.name, New)}
    end;
publish(#state{name = Name, info = #{state := New} = Info} = S, #{state := Old}) ->
    ok = chappe_sip_peers:put(Name, Info),
    _ =
        case New of
            Old -> ok;
            _ -> chappe_sip_peers:notify({chappe_sip_peer, Name, New})
        end,
    S.

kv_write(Name, Info) ->
    case chappe_cluster:singleton_fence(chappe_sip_peers:singleton(Name)) of
        {ok, Fence} ->
            case share(Name, Info, Fence) of
                ok ->
                    true;
                {error, Why} ->
                    logger:notice(
                        "chappe_sip_peer ~0p: state not shared: ~0p", [
                            Name, Why
                        ]
                    ),
                    false
            end;
        none ->
            false
    end.

%% A singleton pinger's word on the peer, under Fence: this node's table
%% takes it at once (a lost quorum does not hide the peer's state from
%% the node that sees it), then the region's KV, by compare and set, and
%% only while no greater fence is there: a paused pinger that wakes up
%% after the takeover cannot overwrite the new one.
-spec share(term(), chappe_sip_peers:info(), chappe_cluster:fence()) ->
    ok | {error, stale | term()}.
share(Name, Info, Fence) ->
    Value = #{info => Info, fence => Fence},
    ok = chappe_sip_peers:local(Name, Value),
    cas(chappe_sip_peers:kv_key(Name), Value, 3).

cas(_Key, _Value, 0) ->
    {error, contended};
cas(Key, #{fence := {_, _, Seq}} = Value, Tries) ->
    case chappe_cluster:get(Key) of
        {ok, #{fence := {_, _, Cur}}, _Version} when Cur > Seq ->
            {error, stale};
        {ok, _Old, Version} ->
            cas_put(Key, Version, Value, Tries);
        not_found ->
            cas_put(Key, 0, Value, Tries);
        {error, _} = Err ->
            Err
    end.

cas_put(Key, Version, Value, Tries) ->
    case chappe_cluster:cas(Key, Version, Value) of
        {ok, _} -> ok;
        {error, {version, _}} -> cas(Key, Value, Tries - 1);
        {error, _} = Err -> Err
    end.

next(Old, #state{oks = Oks}, #{up_after := Up}) when Old =/= up, Oks >= Up ->
    up;
next(Old, #state{fails = Fails}, #{down_after := Down}) when
    Old =/= down, Fails >= Down
->
    down;
next(Old, _S, _Opts) ->
    Old.
