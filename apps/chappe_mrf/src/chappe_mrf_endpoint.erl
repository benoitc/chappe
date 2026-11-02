%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% One FreeSWITCH channel under chappe_mrf's control (an endpoint).
%%
%% It is registered under its correlation id until FreeSWITCH connects
%% the channel's outbound socket (chappe_mrf_esl); it then starts a
%% chappe_esl_call on that connection, answers the channel, and turns
%% the call's messages into {chappe_mrf, Ep, Event} for its owner:
%%
%%   {dtmf, Digit}       a DTMF digit from the channel
%%   {hangup, Cause}     the channel hung up (or its socket closed)
%%   {node_down, Node}   the FreeSWITCH node went down
%%
%% Commands run in the caller's process on the chappe_esl_call (call/1),
%% so a long playback blocks the caller, not the endpoint: DTMF keeps
%% flowing to the owner meanwhile.
%%
%% Watchers (a conference) get {chappe_mrf_endpoint, Ep, Event}: hangup,
%% {event, Ev} for the channel's CUSTOM events (conference::maintenance),
%% {complete, App, Ev} for an application nobody waited for.
%%
%% An endpoint made by create_endpoint also owns the INVITE dialog to
%% FreeSWITCH until bridge/2 hands it to a call (handed/1).
%%
%% When the owner exits, the endpoint stops: chappe_esl_call then stops
%% the forks and recordings it started and kills the channel, and the
%% dialog, if still ours, is torn down with it.
-module(chappe_mrf_endpoint).
-behaviour(gen_statem).

-export([start/1, start_link/1]).
-export([attach/3, await/2, call/1, info/1, watch/2, set_dialog/2]).
-export([handed/1, destroy/1]).
-export([callback_mode/0, init/1, waiting/3, ready/3, gone/3, terminate/3]).

-export_type([endpoint/0]).

-type endpoint() :: pid().

-define(LINGER, 30000).

-record(state, {
    id :: binary(),
    owner :: pid(),
    owner_mon :: reference(),
    candidates = [] :: [{term(), binary()}],
    node :: term(),
    answer = true :: boolean(),
    linger = ?LINGER :: timeout(),
    call :: pid() | undefined,
    conn :: pid() | undefined,
    uuid :: binary() | undefined,
    dialog :: chappe_sip_dialog:dialog() | undefined,
    handed = false :: boolean(),
    watchers = #{} :: #{pid() => reference()},
    subscribed = [] :: [term()]
}).
-type state() :: #state{}.

%% Args: id (required), owner (default the caller), candidates ([{Node,
%% SipUri}], the nodes the INVITE may land on), answer (answer the
%% channel when it connects, default true), linger (ms the endpoint
%% stays after the hangup, for a late node_down; default 30 s).
-spec start(map()) -> {ok, endpoint()} | {error, term()}.
start(Args) ->
    chappe_mrf_sup:start_endpoint(maps:merge(#{owner => self()}, Args)).

-spec start_link(map()) -> gen_statem:start_ret().
start_link(Args) ->
    gen_statem:start_link(?MODULE, Args, []).

%% The outbound socket of the endpoint's channel connected.
-spec attach(endpoint(), pid(), chappe_esl_event:event()) ->
    ok | {error, term()}.
attach(Ep, Conn, Channel) ->
    safe(Ep, {attach, Conn, Channel}, 10000).

%% Wait until the channel is connected and answered: {ok, Uuid}.
-spec await(endpoint(), timeout()) -> {ok, binary()} | {error, term()}.
await(Ep, Timeout) ->
    case safe(Ep, await, Timeout) of
        {error, {timeout, _}} -> {error, timeout};
        Other -> Other
    end.

%% The chappe_esl_call that drives the channel.
-spec call(endpoint()) -> {ok, chappe_esl_call:call()} | {error, term()}.
call(Ep) ->
    safe(Ep, call, 5000).

-spec info(endpoint()) -> map() | {error, term()}.
info(Ep) ->
    safe(Ep, info, 5000).

%% Pid gets {chappe_mrf_endpoint, Ep, Event} from now on.
-spec watch(endpoint(), pid()) -> ok | {error, term()}.
watch(Ep, Pid) ->
    safe(Ep, {watch, Pid}, 5000).

%% The INVITE dialog of an endpoint made by create_endpoint.
-spec set_dialog(endpoint(), chappe_sip_dialog:dialog()) ->
    ok | {error, term()}.
set_dialog(Ep, Dialog) ->
    safe(Ep, {set_dialog, Dialog}, 5000).

%% The dialog was handed to a call (bridge/2): it is not the endpoint's
%% to tear down any more.
-spec handed(endpoint()) -> {ok, chappe_sip_dialog:dialog()} | {error, term()}.
handed(Ep) ->
    safe(Ep, handed, 5000).

%% Hang the channel up and stop.
-spec destroy(endpoint()) -> ok.
destroy(Ep) ->
    _ = safe(Ep, destroy, 15000),
    ok.

safe(Ep, Req, Timeout) ->
    try
        gen_statem:call(Ep, Req, Timeout)
    catch
        exit:{timeout, _} -> {error, {timeout, Req}};
        exit:_ -> {error, gone}
    end.

%% gen_statem

callback_mode() -> state_functions.

-spec init(map()) -> {ok, waiting, state()} | {stop, term()}.
init(#{id := Id, owner := Owner} = Args) ->
    case chappe_mrf_registry:put({call, Id}, self()) of
        ok ->
            {ok, waiting, #state{
                id = Id,
                owner = Owner,
                owner_mon = monitor(process, Owner),
                candidates = maps:get(candidates, Args, []),
                answer = maps:get(answer, Args, true),
                linger = maps:get(linger, Args, ?LINGER)
            }};
        {error, exists} ->
            {stop, {already_registered, Id}}
    end.

waiting({call, From}, {attach, Conn, Channel}, Data) ->
    case chappe_esl_call:start(Conn, #{owner => self()}) of
        {ok, Call} ->
            ok = chappe_mrf_registry:delete({call, Data#state.id}),
            Node = node_of(Channel, Data#state.candidates),
            Data1 = subscribe(Node, Data#state{
                call = Call,
                conn = Conn,
                node = Node,
                uuid = chappe_esl_call:uuid(Call)
            }),
            {keep_state, Data1, [
                {reply, From, ok}, {next_event, internal, answer}
            ]};
        {error, _} = Err ->
            {keep_state_and_data, [{reply, From, Err}]}
    end;
waiting(internal, answer, #state{answer = false} = Data) ->
    {next_state, ready, Data};
waiting(internal, answer, #state{call = Call} = Data) ->
    case chappe_esl_call:answer(Call) of
        ok -> {next_state, ready, Data};
        {error, Why} -> hungup(cause(Why), Data)
    end;
waiting({call, _From}, await, _Data) ->
    {keep_state_and_data, [postpone]};
waiting(EventType, Msg, Data) ->
    common(EventType, Msg, waiting, Data).

ready({call, From}, Req, Data) when Req =:= await; Req =:= call ->
    {keep_state_and_data, [{reply, From, {ok, ready_value(Req, Data)}}]};
ready(info, {chappe_esl_call, Call, Msg}, #state{call = Call} = Data) ->
    call_msg(Msg, Data);
ready(EventType, Msg, Data) ->
    common(EventType, Msg, ready, Data).

gone({call, From}, Req, _Data) when Req =:= await; Req =:= call ->
    {keep_state_and_data, [{reply, From, {error, hangup}}]};
gone(state_timeout, linger, _Data) ->
    {stop, normal};
gone(info, {chappe_esl_call, _, _}, _Data) ->
    keep_state_and_data;
gone(EventType, Msg, Data) ->
    common(EventType, Msg, gone, Data).

%% in every state

common({call, From}, info, State, Data) ->
    {keep_state_and_data, [{reply, From, info_map(State, Data)}]};
common({call, From}, {watch, Pid}, _State, #state{watchers = W} = Data) ->
    W1 =
        case W of
            #{Pid := _} -> W;
            _ -> W#{Pid => monitor(process, Pid)}
        end,
    {keep_state, Data#state{watchers = W1}, [{reply, From, ok}]};
common({call, From}, {set_dialog, D}, _State, Data) ->
    {keep_state, Data#state{dialog = D, handed = false}, [{reply, From, ok}]};
common({call, From}, handed, _State, #state{dialog = D, handed = H} = Data) ->
    case {D, H} of
        {undefined, _} ->
            {keep_state_and_data, [{reply, From, {error, no_dialog}}]};
        {_, true} ->
            {keep_state_and_data, [{reply, From, {error, already_bridged}}]};
        _ ->
            {keep_state, Data#state{handed = true}, [{reply, From, {ok, D}}]}
    end;
common({call, From}, destroy, _State, Data) ->
    teardown(Data),
    {stop_and_reply, normal, [{reply, From, ok}]};
common({call, From}, {attach, _, _}, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, attached}}]};
common(info, {'DOWN', Mon, process, _, _}, _State, #state{owner_mon = Mon}) ->
    %% chappe_esl_call cleans the channel up when it sees us go, and the
    %% dialog fsm tears a dialog still ours down with its owner
    {stop, normal};
common(info, {'DOWN', Mon, process, Pid, _}, _State, #state{watchers = W} = D) ->
    case W of
        #{Pid := Mon} ->
            {keep_state, D#state{watchers = maps:remove(Pid, W)}};
        _ ->
            keep_state_and_data
    end;
common(info, {chappe_esl_node, Node, down}, State, #state{node = Node} = Data) ->
    notify(Data, {node_down, Node}),
    case State of
        gone -> {stop, normal};
        _ -> keep_state_and_data
    end;
common(
    info, {chappe_sip_dialog, D, destroy, _}, _State, #state{dialog = D} = Data
) ->
    {keep_state, Data#state{dialog = undefined}};
common(_EventType, _Msg, _State, _Data) ->
    keep_state_and_data.

call_msg({dtmf, Digit}, Data) ->
    notify(Data, {dtmf, Digit}),
    keep_state_and_data;
call_msg({hangup, Cause}, Data) ->
    hungup(Cause, Data);
call_msg(linger, _Data) ->
    keep_state_and_data;
call_msg(disconnect, _Data) ->
    keep_state_and_data;
call_msg(closed, Data) ->
    hungup(<<"CONNECTION_CLOSED">>, Data#state{call = undefined});
call_msg({event, Ev}, Data) ->
    case chappe_esl_event:name(Ev) of
        <<"CUSTOM">> -> tell(Data, {event, Ev});
        _ -> ok
    end,
    keep_state_and_data;
call_msg({complete, App, Ev}, Data) ->
    tell(Data, {complete, App, Ev}),
    keep_state_and_data.

hungup(Cause, #state{linger = Linger} = Data) ->
    notify(Data, {hangup, Cause}),
    tell(Data, hangup),
    {next_state, gone, Data, [{state_timeout, Linger, linger}]}.

ready_value(await, #state{uuid = Uuid}) -> Uuid;
ready_value(call, #state{call = Call}) -> Call.

%% destroy/1: the channel goes, then the dialog if it is still ours
teardown(#state{call = Call, uuid = Uuid} = Data) ->
    _ = is_pid(Call) andalso kill(Call, Uuid),
    case Data of
        #state{dialog = D, handed = false} when D =/= undefined ->
            _ = spawn(fun() -> chappe_mrf_lib:destroy_dialog(D) end),
            ok;
        _ ->
            ok
    end.

kill(Call, Uuid) ->
    _ = chappe_esl_call:api(Call, [<<"uuid_kill ">>, Uuid]),
    chappe_esl_call:stop(Call).

%% watchers hear of an endpoint that goes before its hangup (destroy/1,
%% the owner's exit)
terminate(_Reason, gone, _Data) ->
    ok;
terminate(_Reason, _State, Data) ->
    tell(Data, hangup).

%% helpers

notify(#state{owner = Owner}, Event) ->
    Owner ! {chappe_mrf, self(), Event},
    ok.

tell(#state{watchers = W}, Event) ->
    _ = [Pid ! {chappe_mrf_endpoint, self(), Event} || Pid <- maps:keys(W)],
    ok.

subscribe(undefined, Data) ->
    Data;
subscribe(Node, Data) ->
    try chappe_esl:node_subscribe(Node) of
        ok -> Data#state{subscribed = [Node]}
    catch
        _:_ -> Data
    end.

%% The node the INVITE landed on: the candidate whose address the
%% channel's request URI names.
node_of(_Channel, []) ->
    undefined;
node_of(_Channel, [{Node, _}]) ->
    Node;
node_of(Channel, [{First, _} | _] = Candidates) ->
    Host = chappe_esl_event:header(<<"variable_sip_req_host">>, Channel),
    Port = chappe_esl_event:header(<<"variable_sip_req_port">>, Channel),
    Match = [
        Node
     || {Node, Uri} <- Candidates,
        {ok, #{host := H} = U} <- [chappe_sip_uri:parse(Uri)],
        H =:= Host,
        Port =:= undefined orelse
            integer_to_binary(maps:get(port, U, 5060)) =:= Port
    ],
    case Match of
        [Node | _] -> Node;
        [] -> First
    end.

info_map(State, Data) ->
    #{
        state => State,
        id => Data#state.id,
        node => Data#state.node,
        uuid => Data#state.uuid,
        conn => Data#state.conn,
        owner => Data#state.owner,
        dialog => Data#state.dialog,
        bridged => Data#state.handed
    }.

cause(hangup) -> <<"NORMAL_CLEARING">>;
cause(closed) -> <<"CONNECTION_CLOSED">>;
cause(Other) when is_binary(Other) -> Other;
cause(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).
