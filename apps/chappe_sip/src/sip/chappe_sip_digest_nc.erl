%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The nonce counts a digest server has accepted (RFC 7616 3.4).
%%
%% One public ETS row per nonce, {Nonce, HighestNc, ExpiresAt}, updated
%% atomically by the verifying process: a count is accepted only when it is
%% above the highest one seen for that nonce, so a replayed response fails.
%% This process owns the table and sweeps the rows of expired nonces (they
%% are refused as stale anyway). It runs under chappe_sip_sup, or starts on
%% first use when the application is not running (unit tests, scripts).
%% The table is bounded: past ?MAX_NONCES live rows a new nonce is refused
%% (the client is re-challenged) rather than accepted untracked.
-module(chappe_sip_digest_nc).
-behaviour(gen_server).

-export([start_link/0, use/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, chappe_sip_digest_nc).
-define(MAX_NONCES, 200000).
-define(SWEEP_MS, 30000).

-record(state, {}).
-type state() :: #state{}.

%% Started by chappe_sip_sup; a table already created on first use keeps
%% its unsupervised owner.
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    case gen_server:start_link({local, ?MODULE}, ?MODULE, [], []) of
        {error, {already_started, _}} -> ignore;
        Other -> Other
    end.

%% Record that nonce count Nc of Nonce was used. ExpiresAt (system time,
%% seconds) is when the nonce goes stale.
-spec use(binary(), pos_integer(), integer()) -> ok | replay.
use(Nonce, Nc, ExpiresAt) ->
    ok = ensure(),
    case ets:insert_new(?TAB, {Nonce, Nc, ExpiresAt}) of
        true ->
            bounded(Nonce);
        false ->
            Higher = [
                {{Nonce, '$1', '$2'}, [{'<', '$1', Nc}], [{{Nonce, Nc, '$2'}}]}
            ],
            case ets:select_replace(?TAB, Higher) of
                1 -> ok;
                0 -> replay
            end
    end.

bounded(Nonce) ->
    case ets:info(?TAB, size) > ?MAX_NONCES of
        false ->
            ok;
        true ->
            _ = sweep(),
            case ets:info(?TAB, size) > ?MAX_NONCES of
                false ->
                    ok;
                true ->
                    ets:delete(?TAB, Nonce),
                    replay
            end
    end.

ensure() ->
    case ets:whereis(?TAB) of
        undefined ->
            case gen_server:start({local, ?MODULE}, ?MODULE, [], []) of
                {ok, _} -> ok;
                {error, {already_started, _}} -> wait_table(50)
            end;
        _ ->
            ok
    end.

%% another process is creating the table right now
wait_table(0) ->
    ok;
wait_table(N) ->
    case ets:whereis(?TAB) of
        undefined ->
            timer:sleep(1),
            wait_table(N - 1);
        _ ->
            ok
    end.

sweep() ->
    Now = erlang:system_time(second),
    ets:select_delete(?TAB, [{{'_', '_', '$1'}, [{'<', '$1', Now}], [true]}]).

-spec init([]) -> {ok, state()}.
init([]) ->
    _ = ets:new(?TAB, [
        named_table,
        public,
        set,
        {write_concurrency, true},
        {read_concurrency, true}
    ]),
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {ok, #state{}}.

-spec handle_call(term(), gen_server:from(), state()) ->
    {reply, {error, unknown}, state()}.
handle_call(_Req, _From, S) ->
    {reply, {error, unknown}, S}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, S) ->
    {noreply, S}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(sweep, S) ->
    _ = sweep(),
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, S};
handle_info(_Info, S) ->
    {noreply, S}.
