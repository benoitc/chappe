%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The notifier side of one event package (RFC 6665), for packages
%% whose every NOTIFY carries the full state of a resource: presence
%% (chappe_sip_presence) and message waiting (chappe_sip_mwi).
%%
%% The SUBSCRIBE handler answers the SUBSCRIBE with create_uas/3, naming
%% this process as the dialog owner, then calls add/4. From there:
%%   - the watcher gets the full state at once (RFC 6665 4.2.1.2), again on
%%     every refresh, and in the terminated NOTIFY of an unsubscribe;
%%   - changed/2 sends the state to every watcher of the resource, never
%%     two NOTIFYs to one watcher closer than min_interval ms: a change
%%     held back goes out when the interval has passed, so none is lost;
%%   - NOTIFYs go through one process per watcher, in order, so a slow
%%     watcher never blocks the others.
%% The state itself comes from the callback module: Mod:body(Key, WState,
%% Data) -> {ContentType, Body}, where WState is the watcher's
%% (active, pending or polite) and Data what put/3 stored for Key.
-module(chappe_sip_notifier).
-behaviour(gen_server).

-export([
    start_link/3,
    start_link/4,
    add/4, add/5,
    changed/2,
    put/3,
    put/4,
    put_async/4,
    get/2,
    put_next/4,
    set_state/3,
    set_interval/2,
    watchers/2
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% The full state a watcher of Key gets: its content type and body.
-callback body(Key :: term(), WState :: atom(), Data :: term()) ->
    {binary(), binary()}.

-record(state, {
    mod :: module(),
    interval :: non_neg_integer(),
    %% dialog pid => watcher
    watchers = #{} :: #{pid() => map()},
    %% Key => what the callback renders from (MWI counts)
    data = #{} :: #{term() => term()},
    %% Key => the version of its data, for put/4: an older one is ignored
    versions = #{} :: #{term() => term()}
}).
-type state() :: #state{}.

-spec start_link(atom(), module(), non_neg_integer()) ->
    {ok, pid()} | {error, term()}.
start_link(Name, Mod, Interval) ->
    start_link(Name, Mod, Interval, #{}).

%% Opts: group => term(), a pg group of the chappe_sip scope the notifier
%% joins, so a put/3 on one node can reach the watchers of every node
%% (chappe_sip_mwi:update/2 casts to its members).
-spec start_link(atom(), module(), non_neg_integer(), map()) ->
    {ok, pid()} | {error, term()}.
start_link(Name, Mod, Interval, Opts) ->
    gen_server:start_link(
        {local, Name}, ?MODULE, {Mod, Interval, Opts}, []
    ).

%% A subscription to Key accepted by the SUBSCRIBE handler (its dialog is
%% owned by this process): send it the state now.
-spec add(
    atom(), chappe_sip_dialog:dialog(), term(), active | pending | polite
) ->
    ok.
add(Name, Dialog, Key, WState) ->
    add(Name, Dialog, Key, WState, false).

%% add/4 for a fetch (a SUBSCRIBE with Expires: 0) when Fetch: the state
%% goes out once, in a terminated NOTIFY (RFC 6665 4.4.3).
-spec add(atom(), chappe_sip_dialog:dialog(), term(), atom(), boolean()) -> ok.
add(Name, Dialog, Key, WState, Fetch) ->
    gen_server:call(Name, {add, Dialog, Key, WState, Fetch}).

%% Key's state changed: every watcher of it gets a NOTIFY.
-spec changed(atom(), term()) -> ok.
changed(Name, Key) ->
    gen_server:cast(Name, {changed, Key}).

%% Store Key's data and notify its watchers.
-spec put(atom(), term(), term()) -> ok.
put(Name, Key, Data) ->
    gen_server:call(Name, {put, Key, Data}).

%% put/3 with a Version: the data is taken only when Version is greater
%% (in term order) than the one Key holds, so puts made on several nodes
%% end the same on every node, whatever order they arrive in.
-spec put(atom(), term(), term(), term()) -> ok.
put(Name, Key, Data, Version) ->
    gen_server:call(Name, {put, Key, Data, Version}).

%% put/4 without waiting, to a notifier by name or pid (one on another
%% node, found in its group).
-spec put_async(atom() | pid(), term(), term(), term()) -> ok.
put_async(Server, Key, Data, Version) ->
    gen_server:cast(Server, {put, Key, Data, Version}).

%% put/4 with the version Next(Last) makes from the one last taken for
%% Key (undefined: none), in the notifier as it takes the data, so the
%% new version is later than whatever came before it here. Returns that
%% version, for the other nodes. Next runs in the notifier.
-spec put_next(atom(), term(), term(), fun((term()) -> term())) ->
    {ok, term()}.
put_next(Name, Key, Data, Next) when is_function(Next, 1) ->
    gen_server:call(Name, {put_next, Key, Data, Next}).

-spec get(atom(), term()) -> term() | undefined.
get(Name, Key) ->
    gen_server:call(Name, {get, Key}).

%% Move the watchers of Key whose state is From to To (a pending
%% subscription authorized), and notify them.
-spec set_state(atom(), term(), fun((pid(), atom()) -> atom())) -> ok.
set_state(Name, Key, Fun) ->
    gen_server:call(Name, {set_state, Key, Fun}).

%% The least time between two NOTIFYs to one watcher, ms.
-spec set_interval(atom(), non_neg_integer()) -> ok.
set_interval(Name, Ms) ->
    gen_server:call(Name, {interval, Ms}).

%% The watchers of Key: [{DialogPid, WState}].
-spec watchers(atom(), term()) -> [{pid(), atom()}].
watchers(Name, Key) ->
    gen_server:call(Name, {watchers, Key}).

%% ---- gen_server ----

-spec init({module(), non_neg_integer(), map()}) -> {ok, state()}.
init({Mod, Interval, Opts}) ->
    %% a sender that crashes must not take the notifier down
    process_flag(trap_exit, true),
    ok =
        case Opts of
            #{group := Group} ->
                pg:join(chappe_sip_call:scope(), Group, self());
            #{} ->
                ok
        end,
    {ok, #state{mod = Mod, interval = Interval}}.

handle_call({interval, I}, _From, S) ->
    {reply, ok, S#state{interval = I}};
handle_call({add, Dialog, Key, WState, Fetch}, _From, S) ->
    Pid = chappe_sip_dialog:pid(Dialog),
    Self = self(),
    Sender = spawn_link(fun() -> sender(Self, Dialog) end),
    W = #{
        dialog => Dialog,
        key => Key,
        wstate => WState,
        sender => Sender,
        last => undefined,
        held => false
    },
    S1 = S#state{watchers = (S#state.watchers)#{Pid => W}},
    First =
        case {Fetch, WState} of
            {true, _} -> {terminated, timeout};
            {false, rejected} -> {terminated, rejected};
            {false, _} -> active_state(WState)
        end,
    {reply, ok, notify_now(Pid, First, S1)};
handle_call({put, Key, Data}, _From, S) ->
    S1 = S#state{data = (S#state.data)#{Key => Data}},
    {reply, ok, notify_key(Key, S1)};
handle_call({put, Key, Data, Version}, _From, S) ->
    {reply, ok, versioned(Key, Data, Version, S)};
handle_call({put_next, Key, Data, Next}, _From, S) ->
    Version = Next(maps:get(Key, S#state.versions, undefined)),
    {reply, {ok, Version}, versioned(Key, Data, Version, S)};
handle_call({get, Key}, _From, S) ->
    {reply, maps:get(Key, S#state.data, undefined), S};
handle_call({set_state, Key, Fun}, _From, S) ->
    {reply, ok, set_state_of(Key, Fun, S)};
handle_call({watchers, Key}, _From, S) ->
    {reply,
        [
            {P, WS}
         || P := #{key := K, wstate := WS} <- S#state.watchers, K =:= Key
        ],
        S}.

set_state_of(Key, Fun, S) ->
    Moved = [
        {Pid, New}
     || {Pid, WS, New} <- [
            {P, WS0, Fun(P, WS0)}
         || P := #{key := K, wstate := WS0} <- S#state.watchers, K =:= Key
        ],
        New =/= WS
    ],
    lists:foldl(
        fun({Pid, New}, Acc) ->
            W = maps:get(Pid, Acc#state.watchers),
            Acc1 = Acc#state{
                watchers = (Acc#state.watchers)#{Pid := W#{wstate := New}}
            },
            case New of
                rejected -> notify_now(Pid, {terminated, rejected}, Acc1);
                _ -> notify_now(Pid, current, Acc1)
            end
        end,
        S,
        Moved
    ).

handle_cast({changed, Key}, S) ->
    {noreply, notify_key(Key, S)};
handle_cast({put, Key, Data, Version}, S) ->
    %% a put/4 made on another node (see start_link/4's group); its
    %% stamp moves this node's clock (chappe_sip_hlc)
    ok = seen(Version),
    {noreply, versioned(Key, Data, Version, S)}.

seen({Stamp, _Node, _N}) -> chappe_sip_hlc:seen(Stamp);
seen(_Version) -> ok.

handle_info({chappe_sip_dialog, D, {refreshed, _}, _Req}, S) ->
    %% RFC 6665 4.2.1.2: a NOTIFY after every accepted refresh
    Pid = chappe_sip_dialog:pid(D),
    {noreply, notify_now(Pid, current, S)};
handle_info({chappe_sip_dialog, D, unsubscribed, _Req}, S) ->
    %% the state once more, in the terminated NOTIFY (RFC 6665 4.4.3)
    {noreply, notify_now(chappe_sip_dialog:pid(D), {terminated, timeout}, S)};
handle_info({chappe_sip_dialog, D, destroy, _Why}, S) ->
    {noreply, drop(chappe_sip_dialog:pid(D), S)};
handle_info({chappe_sip_dialog, _D, _Event, _Req}, S) ->
    {noreply, S};
handle_info({chappe_sip_dialog, _D, _Event, _Req, _Res}, S) ->
    {noreply, S};
handle_info({flush, Pid}, S) ->
    case S#state.watchers of
        #{Pid := #{held := true} = W} ->
            S1 = S#state{
                watchers = (S#state.watchers)#{Pid := W#{held := false}}
            },
            {noreply, notify_now(Pid, current, S1)};
        _ ->
            {noreply, S}
    end;
handle_info({chappe_sip_esc, changed, Key, _Event}, S) ->
    {noreply, notify_key(Key, S)};
handle_info({'EXIT', _Sender, _Why}, S) ->
    {noreply, S};
handle_info(_Msg, S) ->
    {noreply, S}.

%% ---- internal ----

versioned(Key, Data, Version, #state{versions = V} = S) ->
    case V of
        #{Key := Old} when Old >= Version ->
            S;
        _ ->
            S1 = S#state{
                data = (S#state.data)#{Key => Data},
                versions = V#{Key => Version}
            },
            notify_key(Key, S1)
    end.

active_state(pending) -> pending;
active_state(_) -> active.

%% the state of a watcher's key, to every watcher of it, throttled
notify_key(Key, S) ->
    maps:fold(
        fun
            (Pid, #{key := K}, Acc) when K =:= Key -> throttled(Pid, Acc);
            (_Pid, _W, Acc) -> Acc
        end,
        S,
        S#state.watchers
    ).

throttled(Pid, #state{interval = I} = S) ->
    #{last := Last, held := Held} = W = maps:get(Pid, S#state.watchers),
    Now = erlang:monotonic_time(millisecond),
    case Last of
        _ when Held ->
            S;
        L when is_integer(L), Now - L < I ->
            _ = erlang:send_after(L + I - Now, self(), {flush, Pid}),
            S#state{watchers = (S#state.watchers)#{Pid := W#{held := true}}};
        _ ->
            notify_now(Pid, current, S)
    end.

%% send the watcher the state of its key now, as State (current: as its
%% wstate says)
notify_now(Pid, State, #state{mod = Mod} = S) ->
    case S#state.watchers of
        #{Pid := #{key := Key, wstate := WS, sender := Sender} = W} ->
            {CT, Body} = Mod:body(
                Key, WS, maps:get(Key, S#state.data, undefined)
            ),
            SubState =
                case State of
                    current -> active_state(WS);
                    Other -> Other
                end,
            Sender !
                {notify, #{state => SubState, content_type => CT, body => Body}},
            Now = erlang:monotonic_time(millisecond),
            S#state{watchers = (S#state.watchers)#{Pid := W#{last := Now}}};
        _ ->
            S
    end.

drop(Pid, S) ->
    case maps:take(Pid, S#state.watchers) of
        {#{sender := Sender}, Ws} ->
            Sender ! stop,
            S#state{watchers = Ws};
        error ->
            S
    end.

%% one per watcher: its NOTIFYs go out one after the other
sender(Owner, Dialog) ->
    MRef = chappe_sip_dialog:monitor(Dialog),
    sender_loop(Owner, Dialog, MRef).

sender_loop(Owner, Dialog, MRef) ->
    receive
        {notify, Spec} ->
            _ =
                try
                    chappe_sip_dialog:notify(Dialog, Spec)
                catch
                    exit:_ -> {error, gone}
                end,
            sender_loop(Owner, Dialog, MRef);
        stop ->
            ok;
        {'DOWN', MRef, process, _, _} ->
            ok
    end.
