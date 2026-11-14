%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% chappe_audio's place in the `chappe' pg scope, which it shares with the
%% other chappe apps of the node (chappe_sip runs it too).
%%
%% Whichever app starts the scope first runs it; the others use it. The
%% keeper starts it when nobody has (unlinked and out of the app's process
%% group, so that stopping chappe_audio never takes the other apps' groups
%% with it), and monitors
%% it whoever started it. Every group chappe_audio joins goes through
%% join/2, which the keeper remembers: when the scope goes (the app that
%% ran it stopped), the keeper starts it again and puts each member back,
%% so lookups go on. A lookup while the scope is down returns nobody
%% rather than crashing.
-module(chappe_audio_pg).
-behaviour(gen_server).

-export([start_link/0, join/2, members/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SCOPE, chappe).

-record(state, {
    scope_mon :: reference(),
    %% the groups joined, by member: its monitor and its groups
    joined = #{} :: #{pid() => {reference(), [term()]}}
}).

-type state() :: #state{}.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Put Pid (a local process) in Group, now and whenever the scope comes
%% back.
-spec join(term(), pid()) -> ok.
join(Group, Pid) when node(Pid) =:= node() ->
    gen_server:call(?MODULE, {join, Group, Pid}).

%% The members of Group on every node; nobody while the scope is down.
-spec members(term()) -> [pid()].
members(Group) ->
    try
        pg:get_members(?SCOPE, Group)
    catch
        error:badarg -> []
    end.

-spec init([]) -> {ok, state()}.
init([]) ->
    {ok, #state{scope_mon = monitor(process, scope())}}.

handle_call({join, Group, Pid}, _From, #state{joined = J} = S) ->
    ok = pg:join(?SCOPE, Group, Pid),
    J1 =
        case J of
            #{Pid := {Mon, Groups}} -> J#{Pid := {Mon, [Group | Groups]}};
            _ -> J#{Pid => {monitor(process, Pid), [Group]}}
        end,
    {reply, ok, S#state{joined = J1}};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'DOWN', Mon, process, _, _}, #state{scope_mon = Mon} = S) ->
    %% the scope went: run it again and put the members back
    Mon1 = monitor(process, scope()),
    maps:foreach(
        fun(Pid, {_, Groups}) ->
            [ok = pg:join(?SCOPE, G, Pid) || G <- Groups]
        end,
        S#state.joined
    ),
    {noreply, S#state{scope_mon = Mon1}};
handle_info({'DOWN', _Mon, process, Pid, _}, #state{joined = J} = S) ->
    %% a member went; pg drops it from its groups itself
    {noreply, S#state{joined = maps:remove(Pid, J)}};
handle_info(_Info, S) ->
    {noreply, S}.

%% The running scope, started here when nobody runs it.
scope() ->
    case whereis(?SCOPE) of
        undefined ->
            case pg:start(?SCOPE) of
                {ok, Pid} ->
                    %% out of chappe_audio's process group, so that
                    %% stopping the app does not stop it
                    true = group_leader(outside_leader(), Pid),
                    Pid;
                {error, {already_started, Pid}} ->
                    Pid
            end;
        Pid ->
            Pid
    end.

outside_leader() ->
    case whereis(user) of
        undefined -> whereis(init);
        User -> User
    end.
