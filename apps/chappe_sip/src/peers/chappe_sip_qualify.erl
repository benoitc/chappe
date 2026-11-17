%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The registrar's keepalive of UDP contacts (qualify).
%%
%% With the registrar's qualify_interval_ms set, every registered contact
%% reached over UDP (its RFC 5626 UDP flow, or a contact URI with no
%% transport or transport=udp, and no Path) gets an OPTIONS each interval,
%% sent to the address its REGISTER came from (RFC 3581), not its Contact.
%% The answers keep the NAT binding in front of the UA open. A contact
%% that leaves down_after OPTIONS in a row unanswered (a timeout, 408 or
%% 503) is dropped from the location store, and the subscribers of
%% chappe_sip_peers get {chappe_sip_qualify, Aor, Contact, unreachable}.
%% On a cluster each node probes only the bindings it took.
-module(chappe_sip_qualify).
-behaviour(gen_server).

-include("chappe_sip.hrl").

-export([start_link/0, configure/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
    interval :: pos_integer() | undefined,
    down_after = 2 :: pos_integer(),
    timeout_ms = 2000 :: pos_integer(),
    tref :: reference() | undefined,
    %% failed OPTIONS in a row, by {Aor, Contact}
    fails = #{} :: #{{binary(), binary()} => pos_integer()},
    %% the OPTIONS in flight: uac ref => {Aor, Contact}
    inflight = #{} :: #{term() => {binary(), binary()}}
}).
-type state() :: #state{}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Opts: #{interval_ms := pos_integer(), down_after => pos_integer()
%% (default 2), timeout_ms => pos_integer() (default 2000)}.
-spec configure(map()) -> ok.
configure(Opts) ->
    gen_server:call(?MODULE, {configure, Opts}).

-spec init([]) -> {ok, state()}.
init([]) ->
    {ok, #state{}}.

handle_call({configure, Opts}, _From, S0) ->
    S = S0#state{
        interval = maps:get(interval_ms, Opts),
        down_after = maps:get(down_after, Opts, S0#state.down_after),
        timeout_ms = maps:get(timeout_ms, Opts, S0#state.timeout_ms)
    },
    {reply, ok, schedule(S)};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(tick, S) ->
    {noreply, schedule((probe_all(S))#state{tref = undefined})};
handle_info({chappe_sip_uac, Ref, Event}, #state{inflight = In} = S) ->
    case {maps:find(Ref, In), final(Event)} of
        {{ok, _}, none} -> {noreply, S};
        {{ok, Key}, Status} -> {noreply, settle(Ref, Key, Status, S)};
        {error, _} -> {noreply, S}
    end;
handle_info({qualify_timeout, Ref}, #state{inflight = In} = S) ->
    case maps:find(Ref, In) of
        {ok, Key} -> {noreply, settle(Ref, Key, timeout, S)};
        error -> {noreply, S}
    end;
handle_info(_Info, S) ->
    {noreply, S}.

schedule(#state{interval = undefined} = S) ->
    S;
schedule(#state{tref = undefined, interval = I} = S) ->
    S#state{tref = erlang:send_after(I, self(), tick)};
schedule(S) ->
    S.

%% the bindings this node took: on a cluster each node keeps alive the
%% flows it holds
probe_all(S) ->
    lists:foldl(
        fun({Aor, B}, Acc) -> probe(Aor, B, Acc) end,
        S,
        [{Aor, B} || {Aor, B} <- chappe_sip_registry:held(), udp(B)]
    ).

probe(Aor, #{contact := Contact} = B, #state{inflight = In} = S) ->
    Opts0 = #{method => <<"OPTIONS">>, notify => self(), owner => self()},
    %% the address the REGISTER came from (RFC 3581): the NAT binding to
    %% keep open is that one, not the Contact's
    Opts =
        case {maps:get(flow, B, undefined), maps:get(received, B, undefined)} of
            {undefined, undefined} -> Opts0;
            {undefined, Received} -> Opts0#{flow => Received};
            {Flow, _} -> Opts0#{flow => Flow}
        end,
    case chappe_sip:request(Contact, Opts) of
        {ok, Ref} ->
            erlang:send_after(
                S#state.timeout_ms, self(), {qualify_timeout, Ref}
            ),
            S#state{inflight = In#{Ref => {Aor, Contact}}};
        {error, _} ->
            S
    end.

%% a contact we reach over UDP and no proxy
udp(#{path := [_ | _]}) ->
    false;
udp(#{flow := {udp, _, _}}) ->
    true;
udp(#{flow := {udp, _, _, _}}) ->
    true;
udp(#{flow := Flow}) when Flow =/= undefined ->
    false;
udp(#{contact := Contact}) ->
    case chappe_sip_uri:parse(Contact) of
        {ok, #{scheme := sip, params := Params}} ->
            case maps:get(<<"transport">>, Params, <<"udp">>) of
                T when is_binary(T) -> string:lowercase(T) =:= <<"udp">>;
                _ -> false
            end;
        _ ->
            false
    end.

final({response, Msg}) ->
    case chappe_sip_msg:status(Msg) of
        St when is_integer(St), St >= 200 -> St;
        _ -> none
    end;
final({error, #chappe_sip_error{status = St}}) when is_integer(St) -> St;
final({error, _}) ->
    timeout;
final(_) ->
    none.

settle(
    Ref, {Aor, Contact} = Key, Status, #state{fails = F, inflight = In} = S0
) ->
    S = S0#state{inflight = maps:remove(Ref, In)},
    case Status =/= timeout andalso Status =/= 408 andalso Status =/= 503 of
        true ->
            S#state{fails = maps:remove(Key, F)};
        false ->
            N = maps:get(Key, F, 0) + 1,
            case N >= S#state.down_after of
                true ->
                    ok = chappe_sip_registry:remove_contact(Aor, Contact),
                    logger:notice(
                        "chappe_sip_qualify: ~s of ~s unreachable, binding dropped",
                        [Contact, Aor]
                    ),
                    chappe_sip_peers:notify(
                        {chappe_sip_qualify, Aor, Contact, unreachable}
                    ),
                    S#state{fails = maps:remove(Key, F)};
                false ->
                    S#state{fails = F#{Key => N}}
            end
    end.
