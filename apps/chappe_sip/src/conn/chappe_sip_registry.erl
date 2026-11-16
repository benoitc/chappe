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
%% by default, or the region's KV with `cluster => chappe_cluster'. On a
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
-export([register_with/3]).
-endif.

%% a write that lost a compare-and-swap this many times in a row fails 500
-define(TAB, chappe_sip_registry).
-define(HELD, chappe_sip_registry_held).
-define(FLOWS, chappe_sip_registry_flows).
-define(CAS_TRIES, 5).
%% an edge route stays valid this long past its binding's expiry, for a
%% request already on its way
-define(EDGE_GRACE_S, 32).
%% a purge the region could not take is tried again this often, and at
%% most this many wait
-define(PURGE_RETRY_MS, 1000).
-define(MAX_PENDING, 10000).
%% how long a REGISTER waits for the store; one not started this long
%% before that deadline is refused, so it cannot land after its caller
%% has answered 500
-define(REGISTER_TIMEOUT_MS, 5000).
-define(REGISTER_MARGIN_MS, 100).

%% a Contact of the REGISTER: its URI, requested expiry and identity
-record(contact, {
    uri :: binary(),
    expires :: integer(),
    q :: binary() | undefined,
    instance :: binary() | undefined,
    reg_id :: binary() | undefined,
    params :: map()
}).

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
    case chappe_sip_location:backend() of
        chappe_sip_location_ets ->
            Deadline =
                erlang:monotonic_time(millisecond) + ?REGISTER_TIMEOUT_MS,
            gen_server:call(
                ?MODULE, {register, Req, Opts, Deadline}, ?REGISTER_TIMEOUT_MS
            );
        Store ->
            %% compare-and-swap orders it against the other nodes; the
            %% request worker is the caller, so nothing is left behind a
            %% caller that gave up
            cas_register(Store, Req, Opts, local, ?CAS_TRIES)
    end.

-ifdef(TEST).
%% register_request/2 against a given backend (tests)
register_with(Store, Req, Opts) ->
    cas_register(Store, Req, Opts, local, ?CAS_TRIES).
-endif.

%% The first try reads the local replica; one that lost the compare-and-
%% swap waits a little and reads through the leader, since the replica
%% that misled it may still be behind.
cas_register(_Store, _Req, _Opts, _Mode, 0) ->
    {error, 500};
cas_register(Store, Req, Opts, Mode, N) ->
    case do_register(Store, Req, Opts, Mode) of
        {error, conflict} ->
            backoff(N),
            cas_register(Store, Req, Opts, consistent, N - 1);
        Result ->
            Result
    end.

%% 2, 5, 10, 20 ms before the tries after the first: under 40 ms in all
backoff(N) ->
    timer:sleep((5 bsl (?CAS_TRIES - N)) div 2).

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
            by_q(lists:append([view(Store, B, Now) || B <- live(Bs, Now)]));
        {error, _} ->
            []
    end.

%% The live bindings this node took, as {Aor, Binding} (bindings/1 maps):
%% the ones whose flows it holds and keeps alive.
-spec held() -> [{binary(), map()}].
held() ->
    [
        {Aor, B}
     || Aor <- mine(),
        #{node := N} = B <- bindings(Aor),
        N =:= node()
    ].

%% Where to send to a binding (a bindings/1 map): its flow, or, for a UDP
%% contact that is not where its REGISTER came from (a NAT in between),
%% that source; undefined: to the contact.
-spec send_flow(map()) -> chappe_sip_engine:flow() | undefined.
send_flow(#{flow := Flow}) when Flow =/= undefined ->
    Flow;
send_flow(#{contact := Contact} = B) ->
    Received = maps:get(received, B, undefined),
    case chappe_sip_route:nated(Contact, Received) of
        true -> Received;
        false -> undefined
    end.

%% Drop all bindings for an AOR.
-spec remove(binary()) -> ok.
remove(AorOrUri) ->
    mutate({remove, aor_key(AorOrUri)}).

%% Drop one binding of an AOR (its contact URI, compared by RFC 3261
%% 19.1.4), the AOR with it when it was the last one.
-spec remove_contact(binary(), binary()) -> ok.
remove_contact(AorOrUri, Contact) ->
    mutate({remove_contact, aor_key(AorOrUri), Contact}).

%% the ets backend's writes go through this process; a cluster's are
%% ordered by compare-and-swap, from the caller
mutate(Op) ->
    case chappe_sip_location:backend() of
        chappe_sip_location_ets -> gen_server:call(?MODULE, {mutate, Op});
        Store -> apply_op(Store, Op)
    end.

apply_op(Store, {remove, Aor}) ->
    _ = modify(Store, Aor, fun(_) -> [] end),
    ok;
apply_op(Store, {remove_contact, Aor, Contact}) ->
    Keep = fun(#binding{contact = C}) ->
        not chappe_sip_uri:equal(C, Contact)
    end,
    _ = modify(Store, Aor, fun(Bs) -> lists:filter(Keep, Bs) end),
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
                    modify(Store, Aor, fun(Bs) -> live(Bs, now_s()) end)
        end,
        chappe_sip_location:aors(Store)
    ).

%% Stop contending for the cluster sweep from this node (the app stops).
-spec leave_cluster() -> ok.
leave_cluster() ->
    case chappe_sip_location:backend() of
        chappe_sip_location_cluster ->
            try
                chappe_cluster:stop_singleton(chappe_sip_registry_sweep:name())
            of
                _ -> ok
            catch
                %% chappe_cluster stopped first
                exit:_ -> ok
            end;
        _ ->
            ok
    end.

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
    case chappe_sip_location:backend() of
        chappe_sip_location_ets -> {ok, schedule_sweep(#{})};
        _ -> {ok, #{}, {continue, cluster}}
    end.

%% On a cluster the sweep is one singleton for the region. chappe_cluster
%% is started here, on first use, not as a dependency of the app.
%% chappe_sip refuses to start without it (chappe_sip_config:
%% check_cluster/0); one that fails to start is logged, and the sweep is
%% left to the other nodes, rather than crash-looping this supervisor.
handle_continue(cluster, S) ->
    case application:ensure_all_started(chappe_cluster) of
        {ok, _} ->
            case
                chappe_cluster:singleton(
                    chappe_sip_registry_sweep:name(),
                    chappe_sip_registry_sweep:child_spec()
                )
            of
                ok -> ok;
                {error, already_started} -> ok;
                {error, Why} -> no_sweep(Why)
            end;
        {error, Why} ->
            no_sweep(Why)
    end,
    {noreply, S}.

no_sweep(Why) ->
    logger:error(
        "chappe_sip_registry: cluster => chappe_cluster, but chappe_cluster "
        "did not start (~p): this node does not sweep the location store",
        [Why]
    ).

handle_call({register, Req, Opts, Deadline}, {Caller, _}, S) ->
    %% RFC 3261 10.3: a REGISTER whose caller gave up (its call timed out
    %% and the request failed 500) must leave no binding behind
    case
        erlang:monotonic_time(millisecond) < Deadline - ?REGISTER_MARGIN_MS andalso
            is_process_alive(Caller)
    of
        true -> {reply, do_register(chappe_sip_location_ets, Req, Opts), S};
        false -> {reply, {error, 500}, S}
    end;
handle_call({mutate, Op}, _From, S) ->
    {reply, apply_op(chappe_sip_location_ets, Op), S};
handle_call(clear, _From, S) ->
    true = ets:delete_all_objects(?FLOWS),
    true = ets:delete_all_objects(?HELD),
    {reply, chappe_sip_location:clear(chappe_sip_location:backend()), S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({remove_flow, Flow}, S) ->
    {noreply, purge_or_retry({flow, Flow}, S)};
handle_cast(remove_conn_flows, S) ->
    {noreply, purge_or_retry(conns, S)};
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(sweep, S) ->
    ok = sweep(fun() -> true end),
    {noreply, schedule_sweep(S)};
handle_info(retry_purge, #{pending := Pending} = S0) ->
    S = S0#{pending := #{}, retry := undefined},
    {noreply,
        maps:fold(
            fun(What, _, Acc) -> purge_or_retry(What, Acc) end, S, Pending
        )};
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
            case chappe_sip_location:read(Store, Aor, Mode) of
                {ok, Bs, Version} ->
                    register_aor({Store, Aor, Bs, Version}, Msg, Opts);
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
                    {ok, by_q([to_map(B, Now) || B <- live(stored(Ctx), Now)]),
                        Info};
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
    case contacts(Values, Msg, Opts) of
        {ok, Contacts0} ->
            case outbound(Contacts0, Info, Supported) of
                {ok, Contacts, Outbound} ->
                    apply_contacts(
                        Ctx, Contacts, Msg, Opts, Info#{outbound => Outbound}
                    );
                {error, _} = E ->
                    E
            end;
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
             || #binding{callid = C, cseq = Prev} = B <- live(
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

%% step 7: each Contact with its requested expiry; a Contact that is not a
%% URI makes the REGISTER a 400 rather than being silently dropped
contacts(Entries, Msg, Opts) ->
    HdrExpires = header_expires(Msg, Opts),
    case lists:all(fun parses/1, Entries) of
        false ->
            {error, 400};
        true ->
            {ok, [
                #contact{
                    uri = Uri,
                    expires = contact_expires(P, HdrExpires),
                    q = param(<<"q">>, P),
                    instance = param(<<"+sip.instance">>, P),
                    reg_id = param(<<"reg-id">>, P),
                    params = P
                }
             || #{uri := Uri, params := P} <- Entries
            ]}
    end.

param(K, P) ->
    case maps:get(K, P, undefined) of
        V when is_binary(V) -> V;
        _ -> undefined
    end.

parses(#{uri := Uri}) ->
    %% name_addr accepts a bare token as a URI; require an actual URI
    case chappe_sip_uri:parse(Uri) of
        {ok, _} -> true;
        _ -> false
    end.

%% RFC 5626 6. A reg-id counts only beside a +sip.instance and when we are
%% the first hop or the first Path URI carries "ob"; otherwise it is
%% ignored, or a 439 when the UA asked for outbound. A reg-id with more
%% than one Contact of non-zero expiry is a 400. The flag is true when a
%% flow was registered for a UA that lists outbound in Supported.
outbound(Contacts0, #{path := Path, first_hop := FirstHop}, Supported) ->
    ObOk = FirstHop orelse first_ob(Path),
    WantsOb = lists:member(<<"outbound">>, Supported),
    Contacts = [no_lone_reg_id(C) || C <- Contacts0],
    HasRegId = lists:any(
        fun(#contact{reg_id = R}) -> R =/= undefined end, Contacts
    ),
    NonZero = [C || #contact{expires = E} = C <- Contacts, E =/= 0],
    case {HasRegId, ObOk, NonZero} of
        {true, false, _} when WantsOb ->
            {error, 439};
        {Reg, Ok, _} when not Reg; not Ok ->
            {ok, [C#contact{reg_id = undefined} || C <- Contacts], false};
        {_, _, [_, _ | _]} ->
            {error, 400};
        _ ->
            {ok, Contacts, WantsOb}
    end.

no_lone_reg_id(#contact{instance = undefined} = C) ->
    C#contact{reg_id = undefined};
no_lone_reg_id(C) ->
    C.

first_ob([First | _]) ->
    case chappe_sip_hdr:name_addr(First) of
        {ok, #{uri := U}} ->
            case chappe_sip_uri:parse(U) of
                {ok, #{params := P}} -> maps:is_key(<<"ob">>, P);
                _ -> false
            end;
        _ ->
            false
    end;
first_ob([]) ->
    false.

apply_contacts(Ctx, Contacts, Msg, Opts, Info) ->
    case below_min(Contacts) of
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
                boot = chappe_sip_route:boot()
            },
            Max = chappe_sip_config:get(registrar_max_expires),
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
            case
                update(Contacts, Template, Max, ObFlow, live(stored(Ctx), Now))
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

%% RFC 3261 10.3 step 7: true if a contact asks for an expiry above zero,
%% under an hour and below the configured floor. A floor of 0 disables it.
below_min(Contacts) ->
    case chappe_sip_config:get(registrar_min_expires) of
        Min when Min =< 0 ->
            false;
        Min ->
            lists:any(
                fun(#contact{expires = E}) ->
                    E > 0 andalso E < 3600 andalso E < Min
                end,
                Contacts
            )
    end.

%% Each contact in turn against the bindings: the same binding is the one
%% with the same instance and reg-id for a flow, else the one whose URI is
%% equal (19.1.4). On another Call-ID it is replaced (or removed with
%% expiry 0); on the same Call-ID only when the CSeq is higher, otherwise
%% the whole request fails and nothing is written.
update([], _T, _Max, _ObFlow, Acc) ->
    {ok, Acc};
update([C | Rest], T, Max, ObFlow, Acc) ->
    Match = [B || B <- Acc, same_binding(C, B)],
    Reordered = [
        B
     || #binding{callid = Cid, cseq = Prev} = B <- Match,
        Cid =:= T#binding.callid,
        T#binding.cseq =< Prev
    ],
    case {Reordered, clamp(C#contact.expires, Max)} of
        {[_ | _], _} ->
            {error, 400};
        {[], 0} ->
            update(Rest, T, Max, ObFlow, Acc -- Match);
        {[], Exp} ->
            B = T#binding{
                contact = C#contact.uri,
                expiry = T#binding.expiry + Exp,
                q = C#contact.q,
                instance = C#contact.instance,
                reg_id = C#contact.reg_id,
                params = C#contact.params,
                flow = binding_flow(C, T, ObFlow)
            },
            update(Rest, T, Max, ObFlow, replace(Match, with_edge(B), Acc))
    end.

%% an outbound binding (a reg-id kept by outbound/3) on a direct flow is
%% tied to that flow; a re-registration over another one moves it there
%% (RFC 5626 6)
binding_flow(#contact{reg_id = R}, _T, ObFlow) when
    R =/= undefined, ObFlow =/= undefined
->
    ObFlow;
binding_flow(_C, #binding{flow = F}, _ObFlow) ->
    F.

%% a refreshed binding keeps its place, so equal-q order stays stable
replace([], B, Acc) ->
    Acc ++ [B];
replace([Old | Dups], B, Acc) ->
    [
        case X of
            Old -> B;
            _ -> X
        end
     || X <- Acc -- Dups
    ].

same_binding(#contact{reg_id = R, instance = I}, #binding{
    reg_id = R, instance = I
}) when
    R =/= undefined
->
    true;
same_binding(#contact{reg_id = R}, _B) when R =/= undefined ->
    false;
same_binding(_C, #binding{reg_id = R}) when R =/= undefined ->
    false;
same_binding(#contact{uri = U}, #binding{contact = BU}) ->
    chappe_sip_uri:equal(U, BU).

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
                ok -> {ok, by_q([to_map(B, Now) || B <- Updated])};
                {error, _} = E -> E
            end
    end.

write({Store, Aor, _Bs, Version}, Updated) ->
    case chappe_sip_location:write(Store, Aor, Version, Updated) of
        ok -> held(Store, Aor, Updated);
        {error, full} -> {error, 503};
        {error, too_large} -> {error, 403};
        {error, conflict} -> {error, conflict};
        {error, no_quorum} -> {error, no_quorum}
    end.

stored({_Store, _Aor, Bs, _Version}) ->
    Bs.

%% the bindings not expired, and not bound to a connection or WS flow of
%% an earlier boot of this node (those flows are gone)
live(Bs, Now) ->
    Boot = chappe_sip_route:boot(),
    [B || B <- Bs, B#binding.expiry > Now, not stale_flow(B, Boot)].

stale_flow(#binding{node = N, boot = B, flow = F}, Boot) when
    N =:= node(), B =/= Boot
->
    is_conn(F) orelse is_integer(F);
stale_flow(_B, _Boot) ->
    false.

%% Apply Fun to an AOR's bindings and write the result, reading again when
%% another writer got in between.
modify(Store, Aor, Fun) ->
    modify(Store, Aor, Fun, local, ?CAS_TRIES).

modify(_Store, _Aor, _Fun, _Mode, 0) ->
    {error, conflict};
modify(Store, Aor, Fun, Mode, N) ->
    case chappe_sip_location:read(Store, Aor, Mode) of
        {ok, Bs, Version} ->
            case Fun(Bs) of
                Bs ->
                    ok;
                New ->
                    case chappe_sip_location:write(Store, Aor, Version, New) of
                        ok ->
                            held(Store, Aor, New);
                        {error, conflict} ->
                            backoff(N),
                            modify(Store, Aor, Fun, consistent, N - 1);
                        {error, _} = E ->
                            E
                    end
            end;
        {error, _} = E ->
            E
    end.

is_conn({conn, _}) -> true;
is_conn(_) -> false.

%% Drop the bindings of a flow that went (or of every connection). On a
%% cluster without a quorum the write cannot be made: the purge is kept
%% and tried again every ?PURGE_RETRY_MS until the region takes it, so a
%% dead flow does not stay bound. At most ?MAX_PENDING purges wait; past
%% that one is dropped, logged, and its bindings expire on their own.
purge_or_retry(What, S) ->
    case purge(keep(What)) of
        ok ->
            S;
        retry ->
            Pending = maps:get(pending, S, #{}),
            case map_size(Pending) < ?MAX_PENDING of
                true ->
                    arm_retry(S#{pending => Pending#{What => true}});
                false ->
                    logger:warning(
                        "chappe_sip_registry: purge of ~p dropped, too many waiting",
                        [What]
                    ),
                    S
            end
    end.

%% what to keep, and the AORs to look at: the ones the flow index has
%% for that flow (or for any connection), not every AOR of the store
keep({flow, Flow}) ->
    {fun(#binding{flow = F}) -> F =/= Flow end, aors_on(Flow)};
keep(conns) ->
    {fun(#binding{flow = F}) -> not is_conn(F) end, aors_on({conn, '_'})}.

aors_on(Flow) ->
    lists:usort(ets:select(?FLOWS, [{{{flow, Flow, '$1'}}, [], ['$1']}])).

arm_retry(#{retry := TRef} = S) when TRef =/= undefined ->
    S;
arm_retry(S) ->
    S#{retry => erlang:send_after(?PURGE_RETRY_MS, self(), retry_purge)}.

%% Keep the bindings of this node that Keep accepts, deleting an AOR left
%% empty. Another node's bindings are its own to purge. retry when a write
%% could not be made for want of a quorum.
purge({Keep, Aors}) ->
    Store = chappe_sip_location:backend(),
    Mine = fun(#binding{node = N} = B) ->
        (N =/= node() andalso N =/= undefined) orelse Keep(B)
    end,
    Results = [
        modify(Store, Aor, fun(Bs) -> lists:filter(Mine, Bs) end)
     || Aor <- Aors
    ],
    case lists:member({error, no_quorum}, Results) of
        true -> retry;
        false -> ok
    end.

%% The AORs that may hold a binding this node took: every one on a single
%% node; on a cluster, the ones this node wrote one for (an index, so a
%% dropped connection does not read the whole region).
mine() ->
    case chappe_sip_location:backend() of
        chappe_sip_location_ets -> aors();
        _ -> [Aor || {Aor} <- ets:tab2list(?HELD)]
    end.

%% After a write: index the flows of this node's bindings of the AOR and,
%% on a cluster, that this node holds some.
held(Store, Aor, Bs) ->
    ok = index_flows(Aor, Bs),
    held_aor(Store, Aor, Bs).

index_flows(Aor, Bs) ->
    Old = ets:select(?FLOWS, [{{{aor, Aor, '$1'}}, [], ['$1']}]),
    New = lists:usort([
        F
     || #binding{node = N, flow = F} <- Bs,
        F =/= undefined,
        N =:= node() orelse N =:= undefined
    ]),
    _ = [
        ets:delete(?FLOWS, K)
     || F <- Old -- New, K <- [{aor, Aor, F}, {flow, F, Aor}]
    ],
    true = ets:insert(
        ?FLOWS, [{{aor, Aor, F}} || F <- New] ++ [{{flow, F, Aor}} || F <- New]
    ),
    ok.

held_aor(chappe_sip_location_ets, _Aor, _Bs) ->
    ok;
held_aor(_Store, Aor, Bs) ->
    _ =
        case lists:any(fun(#binding{node = N}) -> N =:= node() end, Bs) of
            true -> ets:insert(?HELD, {Aor});
            false -> ets:delete(?HELD, Aor)
        end,
    ok.

schedule_sweep(S) ->
    TRef = erlang:send_after(
        chappe_sip_config:get(registrar_sweep_ms), self(), sweep
    ),
    S#{sweep => TRef}.

%% Cluster mode: a binding this node reaches over its own flow (an RFC
%% 5626 flow, a WS connection, a UDP source behind a NAT) gets the route
%% other nodes reach it through (RFC 5626 5.3). A binding behind a Path is
%% reached through that Path from anywhere; any other contact directly.
with_edge(#binding{path = [_ | _]} = B) ->
    B;
with_edge(B) ->
    case chappe_sip_location:backend() of
        chappe_sip_location_cluster -> B#binding{edge = edge_route(B)};
        _ -> B
    end.

edge_route(#binding{expiry = Exp} = B) ->
    case send_flow(to_map(B, 0)) of
        undefined ->
            undefined;
        Flow ->
            case chappe_sip_binds:contact_or_primary(local(Flow), false) of
                Uri when is_binary(Uri) ->
                    chappe_sip_route:edge_route(
                        Uri, Flow, edge_transport(Flow, B), Exp + ?EDGE_GRACE_S
                    );
                _ ->
                    undefined
            end
    end.

local({udp, _, _, Local}) -> Local;
local(_Flow) -> undefined.

edge_transport(Flow, _B) when is_integer(Flow) -> <<"ws">>;
edge_transport(_Flow, #binding{transport = T}) when is_binary(T) -> T;
edge_transport(_Flow, _B) -> <<"udp">>.

%% How a binding looks from this node (bindings/1). Ours as stored. One
%% another node holds: no flow or received (they name that node's
%% connections) and its edge route ahead of its path; when that node is
%% gone, a UDP one is reached at its address, any other is left out.
view(chappe_sip_location_ets, B, Now) ->
    %% one node: every binding is this node's, whatever it is called now
    [to_map(B, Now)];
view(_Store, #binding{node = N} = B, Now) when N =:= node(); N =:= undefined ->
    [to_map(B, Now)];
view(_Store, #binding{edge = undefined} = B, Now) ->
    [(to_map(B, Now))#{flow => undefined, received => undefined}];
view(_Store, #binding{node = N, edge = Edge, path = Path} = B, Now) ->
    Up = [node() | nodes()],
    M = (to_map(B, Now))#{flow => undefined, received => undefined},
    case {lists:member(N, Up), send_flow(to_map(B, Now))} of
        {true, _} -> [M#{path => [Edge | Path]}];
        {false, {udp, Ip, Port}} -> [M#{flow => {udp, Ip, Port}}];
        {false, {udp, Ip, Port, _}} -> [M#{flow => {udp, Ip, Port}}];
        {false, _} -> []
    end.

header_expires(Msg, Opts) ->
    Default = maps:get(
        default_expires,
        Opts,
        chappe_sip_config:get(registrar_default_expires)
    ),
    case chappe_sip_msg:get(<<"expires">>, Msg) of
        undefined -> Default;
        V -> chappe_sip_lib:to_int(V, Default)
    end.

contact_expires(Params, HdrExpires) ->
    case maps:get(<<"expires">>, Params, undefined) of
        V when is_binary(V) -> chappe_sip_lib:to_int(V, HdrExpires);
        _ -> HdrExpires
    end.

clamp(N, _Max) when N =< 0 -> 0;
clamp(N, Max) when is_integer(Max), N > Max -> Max;
clamp(N, _Max) -> N.

by_q(Maps) ->
    lists:sort(fun(A, B) -> q_value(A) >= q_value(B) end, Maps).

q_value(#{q := Q}) when is_binary(Q) ->
    try
        binary_to_float(Q)
    catch
        _:_ ->
            try
                float(binary_to_integer(Q))
            catch
                _:_ -> 1.0
            end
    end;
q_value(_) ->
    1.0.

to_map(
    #binding{
        contact = C,
        expiry = E,
        callid = Cid,
        cseq = Cs,
        q = Q,
        flow = F,
        path = P,
        instance = I,
        reg_id = R,
        params = Ps,
        received = Rcv,
        transport = Tr,
        node = N,
        edge = Edge
    },
    Now
) ->
    #{
        contact => C,
        expires => max(0, E - Now),
        callid => Cid,
        cseq => Cs,
        q => Q,
        flow => F,
        received => Rcv,
        transport => Tr,
        path => P,
        instance => I,
        reg_id => R,
        params => Ps,
        node => N,
        edge => Edge
    }.

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
