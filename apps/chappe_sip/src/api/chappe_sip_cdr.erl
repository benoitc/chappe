%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Call detail records.
%%
%% One record per INVITE call attempt and per role: uas (an INVITE we
%% answer), uac (one we send), b2b_a and b2b_b (the two legs of a b2bua,
%% each naming the other in link) and proxy (an INVITE we proxy). A
%% subscriber gets each record three times:
%%   {chappe_sip_cdr, attempt, Record}  the INVITE arrived or went out
%%   {chappe_sip_cdr, start, Record}    the call was answered (2xx)
%%   {chappe_sip_cdr, stop, Record}     the attempt or the call is over
%% A record that never got a 2xx has no start. Every attempt gets exactly
%% one stop: this server is the only writer of the open records, it
%% monitors the process that drives each one (the request worker, the UAC
%% fsm, the dialog fsm), and a driver that dies before it stopped its
%% record stops it with reason {process_down, Why}.
%%
%% Records are kept only while someone subscribes: with no subscriber the
%% stack opens none and pays one ETS size check per INVITE.
-module(chappe_sip_cdr).
-behaviour(gen_server).

-export([start_link/0]).
-export([subscribe/1, unsubscribe/1, open_records/0]).
%% stack hooks
-export([
    active/0,
    open/3,
    update/2,
    bind/3,
    progress/3,
    txn_response/2,
    txn_cancel/1,
    stop/2,
    cancelled/1,
    relabel/2,
    proxy_answered/3,
    proxy_final/3,
    proxy_bye/1
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export_type([cdr/0, reason/0, role/0]).

-define(SUBS, chappe_sip_cdr_subs).
-define(OPEN, chappe_sip_cdr_open).

-type role() :: uas | uac | b2b_a | b2b_b | proxy.
%% Why the call or the attempt ended:
%%   {bye, local | remote}  a BYE ended an answered call (remote also for a
%%                          BYE a record-routing proxy saw pass)
%%   cancel                 the caller CANCELled the INVITE
%%   {final, Status}        the INVITE got this non-2xx final response
%%   timeout                no answer in time (create_uac's timeout, a 408
%%                          to an in-dialog request)
%%   no_ack                 our 2xx was never ACKed
%%   session_expired        the session timer ran out (RFC 4028)
%%   {refresh_failed, S}    a session refresh got 408 or 481
%%   engine_restart         the SIP stack went away (restart, stop, degrade)
%%   owner_down             the process owning the call exited
%%   flow_lost              the WebSocket connection of the call closed
%%   unknown                a proxied call whose end the proxy cannot see
%%   {process_down, Why}    the driving process exited without a reason
-type reason() ::
    {bye, local | remote}
    | cancel
    | {final, 300..699}
    | timeout
    | no_ack
    | session_expired
    | {refresh_failed, 100..699}
    | engine_restart
    | owner_down
    | flow_lost
    | unknown
    | {process_down, term()}.
%% Timestamps are erlang:system_time(millisecond); a field not known (yet)
%% is undefined.
-type cdr() :: #{
    id := binary(),
    role := role(),
    call_id := binary() | undefined,
    from := binary() | undefined,
    to := binary() | undefined,
    request_uri := binary() | undefined,
    local_tag := binary() | undefined,
    remote_tag := binary() | undefined,
    transport := binary() | undefined,
    source := binary() | undefined,
    attempt_at := integer(),
    ringing_at := integer() | undefined,
    answered_at := integer() | undefined,
    ended_at := integer() | undefined,
    final_status := 100..699 | undefined,
    reason := reason() | undefined,
    link := binary() | undefined
}.

-record(state, {
    %% driver monitor => record id
    mons = #{} :: #{reference() => binary()},
    %% server transaction handle => record id (uas, b2b_a and proxy)
    txns = #{} :: #{non_neg_integer() => binary()},
    %% Call-ID => record ids of record-routed proxy calls
    calls = #{} :: #{binary() => [binary()]}
}).
-type state() :: #state{}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% ---- public API ----

%% Send the call records to Pid until unsubscribe/1 or its exit.
-spec subscribe(pid()) -> ok.
subscribe(Pid) when is_pid(Pid) ->
    gen_server:call(?MODULE, {subscribe, Pid}).

-spec unsubscribe(pid()) -> ok.
unsubscribe(Pid) when is_pid(Pid) ->
    gen_server:call(?MODULE, {unsubscribe, Pid}).

%% The records not stopped yet.
-spec open_records() -> [cdr()].
open_records() ->
    case ets:info(?OPEN) of
        undefined -> [];
        _ -> [R || {_Id, R, _Driver, _Mon, _Txn} <- ets:tab2list(?OPEN)]
    end.

%% ---- stack hooks (each a cast: the stack never waits on this server) ----

%% Someone subscribes.
-spec active() -> boolean().
active() ->
    case ets:info(?SUBS, size) of
        N when is_integer(N), N > 0 -> true;
        _ -> false
    end.

%% Open a record driven by Driver; emits attempt. Fields as cdr()
%% plus txn (the server transaction) and id (a caller-chosen id). Returns
%% the id, or undefined when nobody subscribes.
-spec open(role(), map(), pid()) -> binary() | undefined.
open(Role, Fields, Driver) ->
    case active() of
        true ->
            Id = maps:get(id, Fields, new_id()),
            gen_server:cast(
                ?MODULE, {open, Id, Role, Fields, Driver, now_ms()}
            ),
            Id;
        false ->
            undefined
    end.

%% Merge fields (role, link, tags) into an open record.
-spec update(binary() | undefined, map()) -> ok.
update(undefined, _Fields) -> ok;
update(Id, Fields) -> gen_server:cast(?MODULE, {update, Id, Fields}).

%% The record is now driven by Pid (a dialog fsm took the call over).
-spec bind(binary() | undefined, pid(), map()) -> ok.
bind(undefined, _Pid, _Fields) -> ok;
bind(Id, Pid, Fields) -> gen_server:cast(?MODULE, {bind, Id, Pid, Fields}).

%% A response to the INVITE: 101..199 rings, a 2xx answers (start), any
%% other final stops the record with {final, Status}.
-spec progress(binary() | undefined, 100..699, map()) -> ok.
progress(undefined, _Status, _Fields) ->
    ok;
progress(Id, Status, Fields) ->
    gen_server:cast(?MODULE, {progress, Id, Status, Fields, now_ms()}).

%% progress/3 for the record of a server transaction, if it has one.
-spec txn_response(non_neg_integer() | undefined, 100..699) -> ok.
txn_response(TxnH, Status) when is_integer(TxnH), Status > 100 ->
    case active() of
        true ->
            gen_server:cast(?MODULE, {txn_response, TxnH, Status, now_ms()});
        false ->
            ok
    end;
txn_response(_TxnH, _Status) ->
    ok.

%% A CANCEL ended the INVITE of this server transaction (not yet answered).
-spec txn_cancel(non_neg_integer()) -> ok.
txn_cancel(TxnH) ->
    case active() of
        true -> gen_server:cast(?MODULE, {txn_cancel, TxnH, now_ms()});
        false -> ok
    end.

%% Stop the record; a record already stopped is left alone.
-spec stop(binary() | undefined, reason()) -> ok.
stop(undefined, _Reason) ->
    ok;
stop(Id, Reason) ->
    gen_server:cast(?MODULE, {stop, Id, Reason, #{}, now_ms()}).

%% Our INVITE (or the one we proxied) was CANCELled and got its 487.
-spec cancelled(binary() | undefined) -> ok.
cancelled(undefined) ->
    ok;
cancelled(Id) ->
    gen_server:cast(
        ?MODULE, {stop, Id, cancel, #{final_status => 487}, now_ms()}
    ).

%% The record of the INVITE Req carries now has this role (the handler
%% bridged or proxied it); its id, undefined without one.
-spec relabel(chappe_sip_req:req(), role()) -> binary() | undefined.
relabel(Req, Role) ->
    Id = maps:get(cdr, chappe_sip_req:meta(Req), undefined),
    update(Id, #{role => Role}),
    Id.

%% A proxied call was answered with this 2xx (Opts: proxy_request/3's).
%% Record-routed, its BYE
%% passes through us and stops the record (proxy_bye/1); until then the
%% record outlives the request worker, at most record_route_ttl_s (then
%% reason unknown). Not record-routed, we never see the end of the call:
%% the record stops now with reason unknown.
-spec proxy_answered(binary() | undefined, map(), binary()) -> ok.
proxy_answered(undefined, _Opts, _Raw) ->
    ok;
proxy_answered(Id, Opts, Raw) ->
    case
        {chappe_sip_proxy_rules:record_routes(Opts), chappe_sip_msg:parse(Raw)}
    of
        {true, {ok, M}} ->
            gen_server:cast(?MODULE, {hold, Id, chappe_sip_msg:call_id(M)});
        _ ->
            stop(Id, unknown)
    end.

%% The final a proxy relays upstream when no branch answered: the 487
%% after an upstream CANCEL is a cancel (any other final stops the record
%% on its own when it goes out).
-spec proxy_final(binary() | undefined, boolean(), 100..699) -> ok.
proxy_final(Id, true, 487) -> cancelled(Id);
proxy_final(_Id, _Cancelled, _Status) -> ok.

%% A BYE of this call passed through us as a record-routing proxy.
-spec proxy_bye(binary()) -> ok.
proxy_bye(CallId) ->
    case active() of
        true -> gen_server:cast(?MODULE, {proxy_bye, CallId, now_ms()});
        false -> ok
    end.

%% ---- gen_server ----

init([]) ->
    _ = ets:new(?SUBS, [named_table, protected, {read_concurrency, true}]),
    _ = ets:new(?OPEN, [named_table, protected]),
    {ok, #state{}}.

handle_call({subscribe, Pid}, _From, S) ->
    case ets:lookup(?SUBS, Pid) of
        [] -> ets:insert(?SUBS, {Pid, erlang:monitor(process, Pid)});
        _ -> ok
    end,
    {reply, ok, S};
handle_call({unsubscribe, Pid}, _From, S) ->
    case ets:take(?SUBS, Pid) of
        [{Pid, MRef}] -> erlang:demonitor(MRef, [flush]);
        [] -> ok
    end,
    {reply, ok, S}.

handle_cast({open, Id, Role, Fields, Driver, At}, S) ->
    {noreply, open_row(Id, Role, Fields, Driver, At, S)};
handle_cast({update, Id, Fields}, S) ->
    with_open(Id, S, fun(R, Row) ->
        put_row(Row, merge(R, Fields)),
        S
    end);
handle_cast({bind, Id, Pid, Fields}, S) ->
    with_open(Id, S, fun(R, Row) -> bind_row(Row, merge(R, Fields), Pid, S) end);
handle_cast({progress, Id, Status, Fields, At}, S) ->
    with_open(Id, S, fun(R, Row) ->
        progressed(Row, merge(R, Fields), Status, At, S)
    end);
handle_cast({txn_response, TxnH, Status, At}, S) ->
    with_txn(TxnH, S, fun(R, Row) -> progressed(Row, R, Status, At, S) end);
handle_cast({txn_cancel, TxnH, At}, S) ->
    with_txn(TxnH, S, fun
        (#{answered_at := undefined} = R, Row) ->
            close(Row, R#{final_status := 487}, cancel, At, S);
        (_R, _Row) ->
            S
    end);
handle_cast({stop, Id, Reason, Fields, At}, S) ->
    with_open(Id, S, fun(R, Row) ->
        close(Row, merge(R, Fields), Reason, At, S)
    end);
handle_cast({hold, Id, CallId}, S) ->
    with_open(Id, S, fun(R, Row) -> hold_row(Row, R, CallId, S) end);
handle_cast({proxy_bye, CallId, At}, S) ->
    {noreply, proxy_bye_rows(CallId, At, S)}.

handle_info({'DOWN', MRef, process, Pid, Why}, S) ->
    case maps:take(MRef, S#state.mons) of
        {Id, Mons} ->
            S1 = S#state{mons = Mons},
            with_open(Id, S1, fun(R, Row) ->
                close(Row, R, {process_down, Why}, now_ms(), S1)
            end);
        error ->
            %% a subscriber
            ets:delete(?SUBS, Pid),
            {noreply, S}
    end;
handle_info({ttl, Id}, S) ->
    with_open(Id, S, fun(R, Row) -> close(Row, R, unknown, now_ms(), S) end);
handle_info(_Msg, S) ->
    {noreply, S}.

%% ---- internal ----

-spec open_row(binary(), role(), map(), pid(), integer(), state()) -> state().
open_row(Id, Role, Fields, Driver, At, S) ->
    R = new_record(Id, Role, Fields, At),
    MRef = erlang:monitor(process, Driver),
    Txn = maps:get(txn, Fields, undefined),
    ets:insert(?OPEN, {Id, R, Driver, MRef, Txn}),
    link_back(maps:get(link, R), Id),
    emit(attempt, R),
    S1 = S#state{mons = (S#state.mons)#{MRef => Id}},
    case Txn of
        undefined -> S1;
        _ -> S1#state{txns = (S1#state.txns)#{Txn => Id}}
    end.

%% a new driver: the old one's exit no longer stops the record
bind_row({Id, _R, _Driver, MRef, Txn}, R, Pid, S) ->
    demonitor_driver(MRef),
    New = erlang:monitor(process, Pid),
    ets:insert(?OPEN, {Id, R, Pid, New, Txn}),
    S#state{mons = (maps:remove(MRef, S#state.mons))#{New => Id}}.

%% no driver any more: a record-routed proxy call waits for its BYE
hold_row({Id, _R, _Driver, MRef, Txn}, R, CallId, S) ->
    demonitor_driver(MRef),
    ets:insert(?OPEN, {Id, R, undefined, undefined, Txn}),
    Ttl = chappe_sip_config:get(record_route_ttl_s),
    _ = erlang:send_after(Ttl * 1000, self(), {ttl, Id}),
    Calls = S#state.calls,
    S#state{
        mons = maps:remove(MRef, S#state.mons),
        calls = Calls#{CallId => [Id | maps:get(CallId, Calls, [])]}
    }.

proxy_bye_rows(CallId, At, S) ->
    case maps:take(CallId, S#state.calls) of
        {Ids, Calls} ->
            lists:foldl(
                fun(Id, Acc) ->
                    case ets:lookup(?OPEN, Id) of
                        [{Id, R, _, _, _} = Row] ->
                            close(Row, R, {bye, remote}, At, Acc);
                        [] ->
                            Acc
                    end
                end,
                S#state{calls = Calls},
                Ids
            );
        error ->
            S
    end.

demonitor_driver(undefined) -> true;
demonitor_driver(MRef) -> erlang:demonitor(MRef, [flush]).

with_txn(TxnH, S, Fun) ->
    case S#state.txns of
        #{TxnH := Id} -> with_open(Id, S, Fun);
        _ -> {noreply, S}
    end.

merge(R, Fields) ->
    maps:merge(R, maps:with(record_keys(), Fields)).

with_open(Id, S, Fun) ->
    case ets:lookup(?OPEN, Id) of
        [{Id, R, _, _, _} = Row] -> {noreply, Fun(R, Row)};
        [] -> {noreply, S}
    end.

put_row({Id, _R, Driver, MRef, Txn}, R1) ->
    ets:insert(?OPEN, {Id, R1, Driver, MRef, Txn}).

progressed(Row, R, Status, _At, S) when Status =< 100 ->
    put_row(Row, R),
    S;
progressed(Row, #{ringing_at := undefined} = R, Status, At, S) when
    Status < 200
->
    put_row(Row, R#{ringing_at := At}),
    S;
progressed(Row, R, Status, _At, S) when Status < 200 ->
    put_row(Row, R),
    S;
progressed(Row, #{answered_at := undefined} = R, Status, At, S) when
    Status < 300
->
    R1 = R#{answered_at := At, final_status := Status},
    put_row(Row, R1),
    emit(start, R1),
    S;
progressed(Row, R, Status, _At, S) when Status < 300 ->
    put_row(Row, R),
    S;
progressed(Row, #{answered_at := undefined} = R, Status, At, S) ->
    close(Row, R#{final_status := Status}, {final, Status}, At, S);
progressed(Row, R, _Status, _At, S) ->
    %% a failure after the answer (a late final of a forked branch)
    put_row(Row, R),
    S.

%% the only place a record stops: the row goes, so no second stop
close({Id, _R, _Driver, MRef, Txn}, R, Reason, At, S) ->
    ets:delete(?OPEN, Id),
    demonitor_driver(MRef),
    emit(stop, R#{ended_at := At, reason := Reason}),
    S#state{
        mons = maps:remove(MRef, S#state.mons),
        txns =
            case Txn of
                undefined -> S#state.txns;
                _ -> maps:remove(Txn, S#state.txns)
            end
    }.

%% the other leg of a b2bua names this one too
link_back(undefined, _Id) ->
    ok;
link_back(Other, Id) ->
    case ets:lookup(?OPEN, Other) of
        [{Other, R, _, _, _} = Row] -> put_row(Row, R#{link := Id});
        [] -> ok
    end.

new_record(Id, Role, Fields, At) ->
    Base = #{
        id => Id,
        role => Role,
        call_id => undefined,
        from => undefined,
        to => undefined,
        request_uri => undefined,
        local_tag => undefined,
        remote_tag => undefined,
        transport => undefined,
        source => undefined,
        attempt_at => At,
        ringing_at => undefined,
        answered_at => undefined,
        ended_at => undefined,
        final_status => undefined,
        reason => undefined,
        link => undefined
    },
    maps:merge(Base, maps:with(record_keys(), Fields)).

%% the fields a hook may set
record_keys() ->
    [
        role,
        call_id,
        from,
        to,
        request_uri,
        local_tag,
        remote_tag,
        transport,
        source,
        link,
        final_status
    ].

emit(Event, R) ->
    ets:foldl(
        fun({Pid, _}, ok) ->
            Pid ! {?MODULE, Event, R},
            ok
        end,
        ok,
        ?SUBS
    ).

new_id() ->
    binary:encode_hex(crypto:strong_rand_bytes(8), lowercase).

now_ms() ->
    erlang:system_time(millisecond).
