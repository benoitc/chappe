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

-export([start_link/2]).
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
    info :: chappe_sip_peers:info()
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

-spec init({term(), map()}) -> gen_statem:init_result(unknown, state()).
init({Name, Opts0}) ->
    Opts = maps:merge(?DEFAULTS, Opts0),
    Info = #{
        uri => maps:get(uri, Opts),
        group => maps:get(group, Opts),
        priority => maps:get(priority, Opts),
        weight => maps:get(weight, Opts),
        state => unknown,
        last_status => undefined,
        rtt_ms => undefined,
        since => erlang:system_time(millisecond)
    },
    ok = chappe_sip_peers:put(Name, Info),
    S = #state{
        name = Name, uri = maps:get(uri, Opts), opts = Opts, info = Info
    },
    {ok, unknown, S, [{{timeout, probe}, 0, probe}]}.

handle_event({timeout, probe}, probe, _St, #state{opts = Opts} = S) ->
    Next = {{timeout, probe}, maps:get(interval_ms, Opts), probe},
    case send(S) of
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
    ok = chappe_sip_peers:put(S#state.name, Info),
    _ =
        case New of
            Old -> ok;
            _ -> chappe_sip_peers:notify({chappe_sip_peer, S#state.name, New})
        end,
    {next_state, New, S#state{info = Info}, Actions}.

next(Old, #state{oks = Oks}, #{up_after := Up}) when Old =/= up, Oks >= Up ->
    up;
next(Old, #state{fails = Fails}, #{down_after := Down}) when
    Old =/= down, Fails >= Down
->
    down;
next(Old, _S, _Opts) ->
    Old.
