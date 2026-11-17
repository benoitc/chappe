%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Registrar location store.
%%
%% A persistent map from AOR to contact bindings, so a REGISTER handler is
%% a few lines and UAS/proxy apps can resolve an AOR to its current
%% contacts. It lives under chappe_sip_sup (above the stack supervisor) so its
%% ETS survives SIP engine restarts.
%%
%% Mutations (register/remove/sweep) are serialized through this
%% gen_server, so a REGISTER is processed atomically and in arrival order
%% (one whose caller already gave up on it, 500, is refused unapplied);
%% lookups read the public ETS directly and filter expired bindings at read
%% time. Binding semantics follow RFC 3261 10.3: the AOR is the canonical To
%% URI, Contact URIs compare by 19.1.4, per-contact or header Expires,
%% expires=0 removes a contact, Contact: * with Expires: 0 clears the AOR,
%% and a non-increasing CSeq on a binding's own Call-ID fails the request.
%% A Path (RFC 3327) is stored with each binding, and a Contact with
%% +sip.instance and reg-id is bound per (instance, reg-id) flow (RFC 5626).
%%
%% The bindings live in a backend (chappe_sip_location): a node-local table
%% by default, or the region's KV with `cluster => chappe_cluster'. How a
%% write is made and indexed is chappe_sip_registry_store's, the Contacts
%% and the bindings they update chappe_sip_registry_contact's. On a
%% cluster:
%% - a REGISTER runs in the request worker, reads the AOR's bindings and
%%   writes them back with a compare-and-swap, again when another node
%%   wrote in between; without a quorum within registrar_cluster_timeout_ms
%%   it fails (the registrar answers 503 with Retry-After);
%% - each binding records the node that took it and, when the contact is
%%   reached over that node's flow (an RFC 5626 flow, a WS connection, a
%%   UDP source behind a NAT), an edge route to it (RFC 5626 5.3);
%% - bindings/1 on another node puts that route ahead of the binding's
%%   path, and leaves its flow out. When that node is gone, a UDP binding
%%   is reached at its address directly; a TCP, TLS or WS one is left out
%%   until the UA registers again;
%% - the sweep is a chappe_cluster singleton (chappe_sip_registry_sweep),
%%   and each node keeps alive (chappe_sip_qualify) and purges only the
%%   bindings it holds.
-module(chappe_sip_registry).
-behaviour(gen_server).

-include("chappe_sip_location.hrl").

-export([start_link/0]).
-export([
    register_contacts/2,
    register_request/2,
    lookup/1,
    bindings/1,
    held/0,
    send_flow/1,
    remove/1,
    remove_contact/2,
    aors/0,
    remove_flow/1,
    remove_conn_flows/0,
    clear/0,
    sweep/1,
    leave_cluster/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export([handle_continue/2]).
-ifdef(TEST).
-export([register_with/3, resync_with/1, modify_with/3]).
-export([resync_apply/4, gen_for_test/0, resync_reads_for_test/3]).
-endif.

-define(TAB, chappe_sip_registry).
-define(HELD, chappe_sip_registry_held).
%% how long a REGISTER waits for the store; one not started this long
%% before that deadline is refused, so it cannot land after its caller
%% has answered 500
-define(REGISTER_TIMEOUT_MS, 5000).
-define(REGISTER_MARGIN_MS, 100).

-type info() :: #{
    path := [binary()], outbound := boolean(), first_hop := boolean()
}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Apply a REGISTER request to the store. Opts: #{flow => term(),
%% default_expires => pos_integer(), domains => any | [binary()]}. Returns
%% the AOR's live bindings for the 200 response, or {error, Status} to
%% reject.
-spec register_contacts(chappe_sip_req:req(), map()) ->
    {ok, [map()]} | {error, 100..699}.
register_contacts(Req, Opts) ->
    case register_request(Req, Opts) of
        {ok, Bindings, _Info} -> {ok, Bindings};
        {error, no_quorum} -> {error, 503};
        {error, _} = E -> E
    end.

%% register_contacts/2 plus what the 200 needs besides the bindings: the
%% request's Path to echo (RFC 3327 5.3), whether the registration set up
%% an outbound flow for a UA that supports it (RFC 5626 6: Require:
%% outbound), and whether we are the UA's first hop (a Flow-Timer is then
%% meaningful).
%% On a cluster, {error, no_quorum}: the region could not take the write.
-spec register_request(chappe_sip_req:req(), map()) ->
    {ok, [map()], info()} | {error, 100..699 | no_quorum}.
register_request(Req, Opts) ->
    Store = chappe_sip_location:backend(),
    case chappe_sip_location:write_mode(Store) of
        serialized ->
            Deadline =
                erlang:monotonic_time(millisecond) + ?REGISTER_TIMEOUT_MS,
            gen_server:call(
                ?MODULE, {register, Req, Opts, Deadline}, ?REGISTER_TIMEOUT_MS
            );
        cas ->
            %% compare-and-swap orders it against the other nodes; the
            %% request worker is the caller, so nothing is left behind a
            %% caller that gave up
            cas_register(
                Store, Req, Opts, local, chappe_sip_registry_store:tries()
            )
    end.

-ifdef(TEST).
%% register_request/2 against a given backend (tests)
register_with(Store, Req, Opts) ->
    cas_register(Store, Req, Opts, local, chappe_sip_registry_store:tries()).

resync_with(Store) ->
    chappe_sip_location_cluster:resync(Store).

modify_with(Store, Aor, Fun) ->
    _ = chappe_sip_registry_store:modify(Store, Aor, Fun),
    ok.

resync_apply(Store, Aor, Bs, T0) ->
    chappe_sip_registry_store:resync_apply(Store, Aor, Bs, T0).

gen_for_test() ->
    chappe_sip_registry_store:gen().

resync_reads_for_test(Store, Aors, Owner) ->
    chappe_sip_location_cluster:resync_reads(Store, Aors, Owner, 0).
-endif.

%% The first try reads the local replica; one that lost the compare-and-
%% swap waits a little and reads through the leader, since the replica
%% that misled it may still be behind.
cas_register(_Store, _Req, _Opts, _Mode, 0) ->
    {error, 500};
cas_register(Store, Req, Opts, Mode, N) ->
    case do_register(Store, Req, Opts, Mode) of
        {error, conflict} ->
            chappe_sip_registry_store:backoff(N),
            cas_register(Store, Req, Opts, consistent, N - 1);
        Result ->
            Result
    end.

%% Live contact URIs for an AOR (or a To/Contact header value / URI), the
%% highest q first.
-spec lookup(binary()) -> [binary()].
lookup(AorOrUri) ->
    [maps:get(contact, B) || B <- bindings(AorOrUri)].

%% Live bindings for an AOR as maps #{contact, expires, callid, cseq, q,
%% flow, received, transport, path, instance, reg_id, params, node,
%% edge}, the highest q first (a binding without q counts as 1.0; equal q
%% keep their registration order). node is the node that took the
%% REGISTER. On a cluster, a binding another node holds comes with its
%% edge route first in path and no flow or received (they name that
%% node's connections); edge is that route, or undefined for a contact
%% reached directly.
-spec bindings(binary()) -> [map()].
bindings(AorOrUri) ->
    Aor = aor_key(AorOrUri),
    Now = now_s(),
    Store = chappe_sip_location:backend(),
    case chappe_sip_location:read(Store, Aor) of
        {ok, Bs, _} ->
            chappe_sip_registry_store:by_q(
                lists:append([
                    chappe_sip_location:view(Store, B, Now)
                 || B <- chappe_sip_registry_store:live(Bs, Now)
                ])
            );
        {error, _} ->
            []
    end.

%% The live bindings this node took, as {Aor, Binding} (bindings/1 maps):
%% the ones whose flows it holds and keeps alive.
-spec held() -> [{binary(), map()}].
held() ->
    [
        {Aor, B}
     || Aor <- chappe_sip_location:mine(chappe_sip_location:backend()),
        #{node := N} = B <- bindings(Aor),
        N =:= node()
    ].

%% Where to send to a binding (a bindings/1 map): its flow, or, for a UDP
%% contact that is not where its REGISTER came from (a NAT in between),
%% that source; undefined: to the contact.
-spec send_flow(map()) -> chappe_sip_engine:flow() | undefined.
send_flow(B) ->
    chappe_sip_registry_store:send_flow(B).

%% Drop all bindings for an AOR.
-spec remove(binary()) -> ok.
remove(AorOrUri) ->
    mutate({remove, aor_key(AorOrUri)}).

%% Drop one binding of an AOR (its contact URI, compared by RFC 3261
%% 19.1.4), the AOR with it when it was the last one.
-spec remove_contact(binary(), binary()) -> ok.
remove_contact(AorOrUri, Contact) ->
    mutate({remove_contact, aor_key(AorOrUri), Contact}).

%% a serialized backend's writes go through this process; a cas one's
%% are ordered by compare-and-swap, from the caller
mutate(Op) ->
    Store = chappe_sip_location:backend(),
    case chappe_sip_location:write_mode(Store) of
        serialized -> gen_server:call(?MODULE, {mutate, Op});
        cas -> apply_op(Store, Op)
    end.

apply_op(Store, {remove, Aor}) ->
    _ = chappe_sip_registry_store:modify(Store, Aor, fun(_) -> [] end),
    ok;
apply_op(Store, {remove_contact, Aor, Contact}) ->
    Keep = fun(#binding{contact = C}) ->
        not chappe_sip_uri:equal(C, Contact)
    end,
    _ = chappe_sip_registry_store:modify(Store, Aor, fun(Bs) ->
        lists:filter(Keep, Bs)
    end),
    ok.

%% Every AOR with a binding, live or not yet swept.
-spec aors() -> [binary()].
aors() ->
    chappe_sip_location:aors(chappe_sip_location:backend()).

%% Drop every binding learned on a transport flow, whatever its AOR. A WS UA
%% is reachable only over its flow (RFC 5626 7), so when the flow drops the
%% binding is dead; the WS transport calls this on disconnect. An outbound
%% UA with two flows keeps the binding of the other one. undefined (UDP) is
%% a no-op.
-spec remove_flow(term()) -> ok.
remove_flow(undefined) ->
    ok;
remove_flow(Flow) ->
    gen_server:cast(?MODULE, {remove_flow, Flow}).

%% Drop every binding learned on a TCP/TLS connection of the native stack:
%% the engine restarted and those connections are gone.
-spec remove_conn_flows() -> ok.
remove_conn_flows() ->
    gen_server:cast(?MODULE, remove_conn_flows).

%% Drop the whole store (tests, reconfiguration).
-spec clear() -> ok.
clear() ->
    gen_server:call(?MODULE, clear).

%% Delete the expired bindings of every AOR while Continue() is true (the
%% sweep on a cluster checks its lease before each write).
%% An AOR is judged only on its own bindings, read just before the write:
%% one missing from a partial aors/0 (a page that failed to read) is left
%% for the next sweep, never deleted.
-spec sweep(fun(() -> boolean())) -> ok.
sweep(Continue) ->
    Store = chappe_sip_location:backend(),
    lists:foreach(
        fun(Aor) ->
            _ =
                Continue() andalso
                    chappe_sip_registry_store:modify(Store, Aor, fun(Bs) ->
                        chappe_sip_registry_store:live(Bs, now_s())
                    end)
        end,
        chappe_sip_location:aors(Store)
    ).

%% Stop contending for the cluster sweep from this node (the app stops).
-spec leave_cluster() -> ok.
leave_cluster() ->
    chappe_sip_location:stop(chappe_sip_location:backend()).

%% gen_server

init([]) ->
    %% the table is owned by chappe_sip_registry_keeper (started first) so it
    %% survives a crash of this gen_server; create it only as a fallback
    _ =
        case ets:info(?TAB) of
            undefined ->
                ets:new(?TAB, [
                    named_table,
                    set,
                    public,
                    {read_concurrency, true}
                ]);
            _ ->
                ?TAB
        end,
    {ok, schedule_tick(#{}), {continue, start}}.

%% what the backend starts with the registry (on a cluster, the sweep
%% singleton)
handle_continue(start, S) ->
    ok = chappe_sip_location:start(chappe_sip_location:backend()),
    {noreply, S}.

handle_call({register, Req, Opts, Deadline}, {Caller, _}, S) ->
    %% RFC 3261 10.3: a REGISTER whose caller gave up (its call timed out
    %% and the request failed 500) must leave no binding behind
    case
        erlang:monotonic_time(millisecond) < Deadline - ?REGISTER_MARGIN_MS andalso
            is_process_alive(Caller)
    of
        true ->
            {reply, do_register(chappe_sip_location:backend(), Req, Opts), S};
        false ->
            {reply, {error, 500}, S}
    end;
handle_call({mutate, Op}, _From, S) ->
    {reply, apply_op(chappe_sip_location:backend(), Op), S};
handle_call(clear, _From, S) ->
    ok = chappe_sip_registry_store:clear_index(),
    true = ets:delete_all_objects(?HELD),
    {reply, chappe_sip_location:clear(chappe_sip_location:backend()), S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({remove_flow, Flow}, S) ->
    {noreply, chappe_sip_registry_store:purge_or_retry({flow, Flow}, S)};
handle_cast(remove_conn_flows, S) ->
    {noreply, chappe_sip_registry_store:purge_or_retry(conns, S)};
handle_cast(_Msg, S) ->
    {noreply, S}.

%% every registrar_sweep_ms: the backend's periodic job (the sweep on one
%% node, the index resync on a cluster)
handle_info(tick, S) ->
    Store = chappe_sip_location:backend(),
    Job = chappe_sip_location:periodic(
        Store, self(), maps:get(job, S, undefined)
    ),
    {noreply, schedule_tick(S#{job => Job})};
handle_info({resync_read, Aor, Bs, T0}, S) ->
    ok = chappe_sip_registry_store:resync_apply(
        chappe_sip_location:backend(), Aor, Bs, T0
    ),
    {noreply, S};
handle_info({'DOWN', Ref, process, _Pid, _Why}, #{job := Ref} = S) ->
    {noreply, S#{job := undefined}};
handle_info(retry_purge, #{pending := _} = S) ->
    {noreply, chappe_sip_registry_store:retry_purge(S)};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    ok.

%% internal

%% RFC 3261 10.3 steps 1 and 5 to 8 (authentication and authorization,
%% steps 3 and 4, are the caller's), with RFC 3327 5.3 and RFC 5626 6. The
%% AOR's bindings are read once; the write names the version read, and a
%% backend that saw another write in between refuses it ({error,
%% conflict}: read and apply again).
do_register(Store, Req, Opts) ->
    do_register(Store, Req, Opts, local).

do_register(Store, Req, Opts, Mode) ->
    Msg = chappe_sip_req:msg(Req),
    case aor_of(Msg, Opts) of
        {ok, Aor} ->
            T0 = chappe_sip_registry_store:gen(),
            case chappe_sip_location:read(Store, Aor, Mode) of
                {ok, Bs, Version} ->
                    register_aor({Store, Aor, Bs, Version, T0}, Msg, Opts);
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

register_aor(Ctx, Msg, Opts) ->
    Path = path(Msg),
    Supported = chappe_sip_msg:option_tags(<<"supported">>, Msg),
    case Path =/= [] andalso not lists:member(<<"path">>, Supported) of
        true ->
            %% RFC 3327 5.3: a Path the UA does not support; the
            %% recommended policy is a 420 naming path
            {error, 420};
        false ->
            Info = #{
                path => Path, outbound => false, first_hop => first_hop(Msg)
            },
            case contact_values(Msg) of
                {ok, []} ->
                    %% a query: the current bindings, unchanged (step 6)
                    Now = now_s(),
                    Live = chappe_sip_registry_store:live(stored(Ctx), Now),
                    {ok,
                        chappe_sip_registry_store:by_q([
                            chappe_sip_registry_store:to_map(B, Now)
                         || B <- Live
                        ]), Info};
                {ok, Values} ->
                    case lists:member(star, Values) of
                        true -> star(Ctx, Values, Msg, Info);
                        false -> bind(Ctx, Values, Msg, Opts, Info, Supported)
                    end;
                {error, _} = E ->
                    E
            end
    end.

bind(Ctx, Values, Msg, Opts, Info, Supported) ->
    case
        chappe_sip_registry_contact:contacts(Values, Msg, Opts, Info, Supported)
    of
        {ok, Contacts, Outbound} ->
            Info1 = Info#{outbound => Outbound},
            apply_contacts(Ctx, Contacts, Msg, Opts, Info1);
        {error, _} = E ->
            E
    end.

%% step 5: the AOR is the canonical To URI, in a domain we serve (404
%% otherwise, or for a To we cannot read)
aor_of(Msg, Opts) ->
    Domains = maps:get(domains, Opts, chappe_sip_config:get(registrar_domains)),
    case to_uri(chappe_sip_msg:get(<<"to">>, Msg)) of
        undefined ->
            {error, 404};
        ToUri ->
            Served =
                served(Domains, chappe_sip_msg:uri(Msg)) andalso
                    served(Domains, ToUri),
            case {chappe_sip_uri:aor(ToUri), Served} of
                {{ok, Aor}, true} -> {ok, Aor};
                _ -> {error, 404}
            end
    end.

to_uri(undefined) ->
    undefined;
to_uri(Value) ->
    case chappe_sip_hdr:name_addr(Value) of
        {ok, #{uri := U}} -> U;
        _ -> undefined
    end.

served(any, _Uri) ->
    true;
served(Domains, Uri) ->
    case chappe_sip_uri:parse(Uri) of
        {ok, #{host := Host}} ->
            lists:member(chappe_sip_lib:lower(Host), [
                chappe_sip_lib:lower(D)
             || D <- Domains
            ]);
        _ ->
            false
    end.

%% RFC 3327: the Path values in order, each as <uri>
path(Msg) ->
    lists:append([
        case chappe_sip_hdr:name_addr_list(V) of
            {ok, Entries} -> [<<"<", U/binary, ">">> || #{uri := U} <- Entries];
            {error, _} -> []
        end
     || V <- chappe_sip_msg:get_all(<<"path">>, Msg)
    ]).

%% RFC 5626 6: a single Via means the UA sent the REGISTER to us directly
first_hop(Msg) ->
    Vias = [
        V
     || Line <- chappe_sip_msg:get_all(<<"via">>, Msg),
        V <- binary:split(Line, <<",">>, [global]),
        chappe_sip_lib:trim(V) =/= <<>>
    ],
    case Vias of
        [_] -> true;
        _ -> false
    end.

%% every Contact value of every Contact header, comma-joined or not; "*"
%% becomes the atom star
contact_values(Msg) ->
    lists:foldr(
        fun
            (_V, {error, _} = E) ->
                E;
            (V, {ok, Acc}) ->
                case chappe_sip_hdr:name_addr_list(V) of
                    {ok, Entries} -> {ok, [star_or(E) || E <- Entries] ++ Acc};
                    {error, _} -> {error, 400}
                end
        end,
        {ok, []},
        chappe_sip_msg:get_all(<<"contact">>, Msg)
    ).

star_or(#{uri := <<"*">>}) -> star;
star_or(Entry) -> Entry.

%% step 6: "*" alone, with Expires: 0, removes every binding, unless one of
%% them has this Call-ID and a CSeq at least as high as the request's (the
%% update is then aborted). With other Contacts, or any other Expires, the
%% request is invalid.
star(Ctx, [star], Msg, Info) ->
    case raw_expires(Msg) of
        0 ->
            {CallId, CSeq} = callid_cseq(Msg),
            Stale = [
                B
             || #binding{callid = C, cseq = Prev} = B <- chappe_sip_registry_store:live(
                    stored(Ctx), now_s()
                ),
                C =:= CallId,
                CSeq =< Prev
            ],
            case Stale of
                [] ->
                    case write(Ctx, []) of
                        ok -> {ok, [], Info};
                        {error, _} = E -> E
                    end;
                _ ->
                    {error, 400}
            end;
        _ ->
            {error, 400}
    end;
star(_Ctx, _Values, _Msg, _Info) ->
    {error, 400}.

raw_expires(Msg) ->
    case chappe_sip_msg:get(<<"expires">>, Msg) of
        undefined -> undefined;
        V -> chappe_sip_lib:to_int(V, undefined)
    end.

callid_cseq(Msg) ->
    CSeq =
        case chappe_sip_msg:cseq(Msg) of
            {ok, #{seq := N}} -> N;
            _ -> 0
        end,
    {chappe_sip_msg:call_id(Msg), CSeq}.

apply_contacts(Ctx, Contacts, Msg, Opts, Info) ->
    case chappe_sip_registry_contact:below_min(Contacts) of
        true ->
            % RFC 3261 10.3 step 7
            {error, 423};
        false ->
            {CallId, CSeq} = callid_cseq(Msg),
            Now = now_s(),
            Template = #binding{
                contact = <<>>,
                expiry = Now,
                callid = CallId,
                cseq = CSeq,
                flow = maps:get(flow, Opts, undefined),
                path = maps:get(path, Info),
                received = maps:get(received, Opts, undefined),
                transport = maps:get(transport, Opts, undefined),
                node = node(),
                boot = chappe_sip_flow:boot()
            },
            %% RFC 5626 6: a UA with a direct flow to us has its outbound
            %% bindings tied to that flow; past an edge proxy the flow is
            %% the edge's, not ours
            ObFlow =
                case Info of
                    #{first_hop := true} ->
                        maps:get(outbound_flow, Opts, undefined);
                    _ ->
                        undefined
                end,
            Live = chappe_sip_registry_store:live(stored(Ctx), Now),
            case
                chappe_sip_registry_contact:update(
                    Contacts, Template, ObFlow, Live, store(Ctx)
                )
            of
                {ok, Updated} ->
                    case commit(Ctx, Updated, Now) of
                        {ok, Bs} -> {ok, Bs, Info};
                        {error, _} = E -> E
                    end;
                {error, _} = E ->
                    E
            end
    end.

%% Enforce the store bounds before writing: 403 when one AOR would hold too
%% many contacts (or, on a cluster, more than one KV value holds), 503 when
%% a new AOR would exceed the distinct-AOR cap.
commit(Ctx, Updated, Now) ->
    MaxPerAor = chappe_sip_config:get(registrar_max_bindings_per_aor),
    case length(Updated) > MaxPerAor of
        true ->
            {error, 403};
        false ->
            case write(Ctx, Updated) of
                ok ->
                    {ok,
                        chappe_sip_registry_store:by_q([
                            chappe_sip_registry_store:to_map(B, Now)
                         || B <- Updated
                        ])};
                {error, _} = E ->
                    E
            end
    end.

write({Store, Aor, _Bs, Version, T0}, Updated) ->
    case chappe_sip_registry_store:write(Store, Aor, Version, Updated, T0) of
        ok -> ok;
        {error, full} -> {error, 503};
        {error, too_large} -> {error, 403};
        {error, conflict} -> {error, conflict};
        {error, no_quorum} -> {error, no_quorum}
    end.

stored({_Store, _Aor, Bs, _Version, _T0}) ->
    Bs.

store({Store, _Aor, _Bs, _Version, _T0}) ->
    Store.

schedule_tick(S) ->
    TRef = erlang:send_after(
        chappe_sip_config:get(registrar_sweep_ms), self(), tick
    ),
    S#{tick => TRef}.

%% AOR key (RFC 3261 10.3 step 5) of a To/Contact header value or a bare
%% URI: see chappe_sip_uri:aor/1. A value that is not a URI keys as is.
aor_key(undefined) ->
    <<>>;
aor_key(Value) ->
    Uri =
        case chappe_sip_hdr:name_addr(Value) of
            {ok, #{uri := U}} -> U;
            _ -> Value
        end,
    case chappe_sip_uri:aor(Uri) of
        {ok, Aor} -> Aor;
        error -> Uri
    end.

now_s() ->
    erlang:system_time(second).
