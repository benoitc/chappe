%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The processes of B2BUA calls that outlive the function that
%% starts them: one chappe_sip_b2b_async per call relay_async/2 carries,
%% and one chappe_sip_b2b_transfer per transfer a call carries out.
%% Children are temporary: a relay or a transfer that ends or crashes is
%% not restarted (a transfer's call goes on; a relay's call ends, its
%% dialogs seeing their owner go).
-module(chappe_sip_b2b_sup).
-behaviour(supervisor).

-export([start_link/0, start_transfer/1, start_relay/1]).
-export([init/1]).

-define(TRANSFERS, chappe_sip_b2b_transfers).
-define(RELAYS, chappe_sip_b2b_relays).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, top).

%% A transfer of a call (chappe_sip_b2b_transfer:start_link/1).
-spec start_transfer(map()) -> {ok, pid()} | {error, term()}.
start_transfer(Args) ->
    supervisor:start_child(?TRANSFERS, [Args]).

%% The relay of a call (chappe_sip_b2b_async:start_link/1).
-spec start_relay(map()) -> {ok, pid()} | {error, term()}.
start_relay(Args) ->
    supervisor:start_child(?RELAYS, [Args]).

init(top) ->
    Children = [
        dynamic(?RELAYS, relays),
        dynamic(?TRANSFERS, transfers)
    ],
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, Children}};
init(relays) ->
    one_kind(chappe_sip_b2b_async);
init(transfers) ->
    one_kind(chappe_sip_b2b_transfer).

dynamic(Name, Kind) ->
    #{
        id => Name,
        start => {supervisor, start_link, [{local, Name}, ?MODULE, Kind]},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [?MODULE]
    }.

one_kind(Mod) ->
    Child = #{
        id => Mod,
        start => {Mod, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [Mod]
    },
    {ok,
        {#{strategy => simple_one_for_one, intensity => 10, period => 10}, [
            Child
        ]}}.
