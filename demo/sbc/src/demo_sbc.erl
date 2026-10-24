%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% A small SBC to try chappe_sip by hand (`make demo`, see README.md).
%%
%% It runs a registrar for the users of demo.config, sends a call to a
%% registered user through the B2BUA, decides per call whether rtpengine
%% anchors the media (chappe_sip_media:bypass/2: a WebRTC side, a NAT or
%% two private networks anchor), keeps UDP contacts open with OPTIONS, and
%% pings Kamailio. It serves the JsSIP page of web/ for a browser softphone.
%%
%% 1000 (echo), 1001 (a tone) and 1002 (a conference) go to the FreeSWITCH
%% pool: chappe_esl picks the node (node_select/1, by its load), the call
%% fails over through the chappe_sip peers of the same names, and its
%% X-Chappe-Call header comes back in the node's CHANNEL_CREATE, which ties
%% the FreeSWITCH channel to the call.
%%
%% From `make demo-shell':
%%   demo_sbc:calls()        the calls up, with their media mode
%%   demo_sbc:anchor(CallId) move a call's media into rtpengine
%%   demo_sbc:direct(CallId) and back out of it
%%   demo_sbc:peers()        the OPTIONS state of the peers
%%   demo_sbc:nodes()        the FreeSWITCH nodes, their state and load
%%   demo_sbc:drain(fs1)     stop sending calls to a node (resume/1 undoes)
%%
%% route/1 maps a dialled user to where the call goes. It is the one place
%% to add targets: a FreeSWITCH pool, for one, is a {peer_group, G} there.
-module(demo_sbc).

-export([start/1]).
-export([calls/0, anchor/1, direct/1, peers/0, nodes/0, drain/1, resume/1]).
-export([route/1]).

-define(CALLS, demo_sbc_calls).
%% call id => {FreeSWITCH node, channel uuid}
-define(FS, demo_sbc_fs).

%% Start with the settings of File (demo/sbc/demo.config).
-spec start(file:filename()) -> ok.
start(File) ->
    {ok, [Cfg]} = file:consult(File),
    persistent_term:put({?MODULE, cfg}, Cfg),
    {ok, _} = application:ensure_all_started(chappe_sip),
    %% the FreeSWITCH nodes, registered with chappe_esl when it starts
    ok = application:load(chappe_esl),
    ok = application:set_env(chappe_esl, nodes, maps:get(fs_nodes, Cfg, [])),
    {ok, _} = application:ensure_all_started(chappe_esl),
    Keeper = keeper(),
    Ip = env("DEMO_IP", maps:get(ip, Cfg)),
    SipPort = env("DEMO_SIP_PORT", maps:get(sip_port, Cfg)),
    ok = chappe_sip:start(#{
        contact => iolist_to_binary(["sip:", Ip, ":", SipPort]),
        ws => #{port => list_to_integer(env("DEMO_WS_PORT", maps:get(ws_port, Cfg)))},
        media => #{rtpengine => #{nodes => [maps:get(rtpengine, Cfg)]}}
    }),
    ok = chappe_sip:peer_subscribe(Keeper),
    _ = [chappe_sip:peer_add(Name, Opts) || {Name, Opts} <- maps:get(peers, Cfg, [])],
    Users = maps:get(users, Cfg),
    Registrar = chappe_sip:registrar(#{
        auth => #{realm => maps:get(realm, Cfg), domain => domains(Cfg),
                  secret => fun(U) -> secret(U, Users) end},
        domains => any,
        qualify_interval_ms => 30000
    }),
    ok = chappe_sip:register(Registrar),
    ok = chappe_sip:invite(fun(Req, Res) -> invite(Keeper, Req, Res) end),
    ok = http(
        list_to_integer(env("DEMO_HTTP_PORT", maps:get(http_port, Cfg))),
        filename:join(filename:dirname(File), "web/index.html")
    ),
    log("demo up: SIP ~s:~s, WS ~s, page http://localhost:~s/", [
        Ip, SipPort, env("DEMO_WS_PORT", maps:get(ws_port, Cfg)),
        env("DEMO_HTTP_PORT", maps:get(http_port, Cfg))
    ]),
    ok.

env(Name, Default) ->
    case os:getenv(Name) of
        false -> to_list(Default);
        "" -> to_list(Default);
        V -> V
    end.

to_list(V) when is_integer(V) -> integer_to_list(V);
to_list(V) when is_binary(V) -> binary_to_list(V);
to_list(V) -> V.

secret(User, Users) ->
    case lists:keyfind(User, 1, Users) of
        {_, Pass} -> {ok, Pass};
        false -> error
    end.

%% ---- calls ----

%% Where a dialled user's call goes, and the options it needs:
%% {ok, Target, Opts} or {error, Status}.
-spec route(binary()) -> {ok, chappe_sip_b2b:target(), map()} | {error, 400..699}.
route(User) ->
    Cfg = persistent_term:get({?MODULE, cfg}),
    case
        {lists:keymember(User, 1, maps:get(users, Cfg)),
            lists:member(User, maps:get(extensions, Cfg, []))}
    of
        {true, _} -> registered(User, Cfg);
        {_, true} -> pool(User);
        _ -> extra_route(User, Cfg)
    end.

%% A FreeSWITCH number: the node chappe_esl picks first, then the other up
%% peers of the pool; FreeSWITCH reaches rtpengine on its docker side
pool(Ext) ->
    First =
        case chappe_esl:node_select(#{}) of
            {ok, Node} ->
                case chappe_esl:node_status(Node) of
                    {ok, #{sip_uri := Uri}} when is_binary(Uri) -> [Uri];
                    _ -> []
                end;
            {error, _} ->
                []
        end,
    Rest = [U || U <- chappe_sip_peers:candidates(fs, priority), not lists:member(U, First)],
    case [with_user(U, Ext) || U <- First ++ Rest] of
        [] ->
            {error, 503};
        Uris ->
            {ok, Uris, #{
                b_side => fs,
                anchor_params => #{
                    a => #{direction => [docker, host]},
                    b => #{direction => [host, docker]}
                }
            }}
    end.

with_user(Uri, User) ->
    {ok, U} = chappe_sip_uri:parse(Uri),
    iolist_to_binary(chappe_sip_uri:format(U#{user => User})).

registered(User, Cfg) ->
    case located(User, domains(Cfg)) of
        {ok, Uri, Flow} when is_integer(Flow) ->
            %% a browser over WebSocket: WebRTC media, always anchored
            {ok, Uri, #{flow => Flow, b_side => ws}};
        {ok, Uri, {udp, Ip, _Port} = Flow} ->
            %% location_flow/1 gives the address the REGISTER came from when
            %% the Contact is not reachable (a NAT): the call and its
            %% dialog's requests go there
            {ok, Uri, #{flow => Flow, b_side => {Ip, Uri}}};
        {ok, Uri, Flow} when Flow =/= undefined ->
            {ok, Uri, #{flow => Flow}};
        {ok, Uri, undefined} ->
            {ok, Uri, #{}};
        {error, not_found} ->
            {error, 480}
    end.

%% the users register under any of the demo's domains
located(_User, []) ->
    {error, not_found};
located(User, [D | Ds]) ->
    case chappe_sip:location_flow(<<"sip:", User/binary, "@", D/binary>>) of
        {ok, _, _} = Found -> Found;
        {error, not_found} -> located(User, Ds)
    end.

domains(Cfg) ->
    lists:usort([list_to_binary(env("DEMO_IP", maps:get(ip, Cfg))) | maps:get(domains, Cfg)]).

%% the targets that are not registered users (demo.config `routes')
extra_route(User, Cfg) ->
    case lists:keyfind(User, 1, maps:get(routes, Cfg, [])) of
        {_, Target} -> {ok, Target, #{}};
        false -> {error, 404}
    end.

invite(Keeper, Req, Res) ->
    CallId = chappe_sip_req:call_id(Req),
    Called = user(chappe_sip_req:uri(Req)),
    case route(Called) of
        {ok, Target, Opts0} ->
            {BSide, Opts1} = take(b_side, Opts0),
            Opts = Opts1#{
                media => policy(BSide),
                notify => Keeper,
                %% FreeSWITCH hands it back in CHANNEL_CREATE
                b_headers => [{<<"X-Chappe-Call">>, CallId}]
            },
            bridge(CallId, Called, Req, Res, Target, Opts);
        {error, Status} ->
            _ = chappe_sip_res:send(Res, Status),
            log("call ~s to ~s: ~b", [CallId, Called, Status])
    end.

take(Key, Map) ->
    {maps:get(Key, Map, undefined), maps:remove(Key, Map)}.

bridge(CallId, Called, Req, Res, Target, Opts) ->
    case chappe_sip:create_b2bua(Req, Res, Target, Opts) of
        {ok, #{b2b := B2b, media := M} = Legs} ->
            From = user(chappe_sip_req:get(<<"from">>, Req)),
            true = ets:insert(?CALLS, {CallId, B2b, From, Called}),
            log("call ~s ~s -> ~s up, media ~p", [
                CallId, From, Called, chappe_sip_b2b_media:mode(M)
            ]),
            Done = chappe_sip_b2b:relay(Legs),
            ets:delete(?CALLS, CallId),
            ets:delete(?FS, CallId),
            log("call ~s ended ~p", [CallId, Done]);
        {error, Why} ->
            log("call ~s to ~s failed: ~p", [CallId, Called, Why])
    end.

%% bypass/2 per call: the caller as its SDP and signalling address, the
%% callee as its registration's source (or a WebSocket or FreeSWITCH,
%% always anchored)
policy(ws) ->
    anchor;
policy(fs) ->
    anchor;
policy(BSide) ->
    Cfg = persistent_term:get({?MODULE, cfg}),
    fun(#{sdp := Sdp, source := Source}) ->
        B =
            case BSide of
                {Ip, _Uri} -> #{addr => Ip};
                undefined -> #{}
            end,
        chappe_sip_media:bypass(
            #{a => #{sdp => Sdp, source => Source}, b => B},
            #{networks => maps:get(networks, Cfg, [])}
        )
    end.

user(undefined) ->
    undefined;
user(Value) ->
    Uri =
        case chappe_sip_hdr:name_addr(Value) of
            {ok, #{uri := U}} -> U;
            _ -> Value
        end,
    case chappe_sip_uri:parse(Uri) of
        {ok, #{user := User}} -> User;
        _ -> undefined
    end.

%% ---- the shell ----

-spec calls() -> [#{call_id := binary(), from := binary(), to := binary(), media := atom()}].
calls() ->
    [maps:merge(#{call_id => C, from => F, to => T, media => mode(B2b)}, fs_of(C))
     || {C, B2b, F, T} <- ets:tab2list(?CALLS)].

fs_of(CallId) ->
    case ets:lookup(?FS, CallId) of
        [{_, Node, Uuid}] -> #{fs_node => Node, fs_uuid => Uuid};
        [] -> #{}
    end.

-spec anchor(binary() | string()) -> ok | {error, term()}.
anchor(CallId) -> switch(CallId, anchor).

-spec direct(binary() | string()) -> ok | {error, term()}.
direct(CallId) -> switch(CallId, direct).

switch(CallId, Mode) ->
    case ets:lookup(?CALLS, iolist_to_binary(CallId)) of
        [{_, B2b, _, _}] -> chappe_sip_b2b:set_media(B2b, Mode);
        [] -> {error, no_call}
    end.

%% The FreeSWITCH nodes: state, then sessions and idle CPU from their
%% HEARTBEAT.
-spec nodes() -> [{atom(), atom(), map()}].
nodes() ->
    [{N, St, load(N)} || {N, St} <- chappe_esl:nodes()].

load(Node) ->
    case chappe_esl:node_status(Node) of
        {ok, #{load := L}} -> maps:with([sessions, max_sessions, idle_cpu], L);
        _ -> #{}
    end.

-spec drain(atom()) -> ok | {error, not_found}.
drain(Node) -> chappe_esl:node_drain(Node).

-spec resume(atom()) -> ok | {error, not_found}.
resume(Node) -> chappe_esl:node_resume(Node).

-spec peers() -> [{term(), atom(), term()}].
peers() ->
    [{N, maps:get(state, I), maps:get(last_status, I)} || {N, I} <- chappe_sip:peers()].

mode(B2b) ->
    case chappe_sip_b2b:info(B2b) of
        #{media := M} -> M;
        _ -> unknown
    end.

%% the calls table, and the process that logs peer and hold events
keeper() ->
    Self = self(),
    Pid = spawn(fun() ->
        _ = ets:new(?CALLS, [named_table, public]),
        _ = ets:new(?FS, [named_table, public]),
        ok = chappe_esl:node_subscribe(all),
        ok = chappe_esl:node_events(all),
        Self ! {keeper, self()},
        keep()
    end),
    receive {keeper, Pid} -> Pid end.

keep() ->
    receive
        {chappe_sip_peer, Name, State} ->
            log("peer ~p is ~p", [Name, State]);
        {chappe_sip_qualify, Aor, Contact, unreachable} ->
            log("~s at ~s stopped answering, binding dropped", [Aor, Contact]);
        {chappe_esl_node, Name, {event, #{headers := H}}} ->
            channel(Name, H);
        {chappe_esl_node, Name, State} when is_atom(State) ->
            log("FreeSWITCH ~p is ~p", [Name, State]);
        {chappe_sip_b2b, Ref, Event} ->
            Calls = [C || {C, {_, R}, _, _} <- ets:tab2list(?CALLS), R =:= Ref],
            log("call ~s: ~p", [Calls, Event]);
        _ ->
            ok
    end,
    keep().

%% a CHANNEL_CREATE carrying our X-Chappe-Call: the call's channel there
channel(Node, #{<<"Event-Name">> := <<"CHANNEL_CREATE">>} = H) ->
    case maps:get(<<"variable_sip_h_X-Chappe-Call">>, H, undefined) of
        undefined ->
            ok;
        CallId ->
            Uuid = maps:get(<<"Unique-ID">>, H, undefined),
            true = ets:insert(?FS, {CallId, Node, Uuid}),
            log("call ~s is channel ~s on ~p", [CallId, Uuid, Node])
    end;
channel(_Node, _H) ->
    ok.

%% ---- the web page ----

%% A tiny HTTP server for web/index.html (the JsSIP softphone).
http(Port, Page) ->
    %% the listener lives in its own process, not the one that starts us
    Self = self(),
    _ = spawn(fun() ->
        {ok, L} = gen_tcp:listen(Port, [binary, {active, false}, {reuseaddr, true},
                                        {packet, http_bin}]),
        Self ! {http, self()},
        accept(L, Page)
    end),
    receive {http, _} -> ok after 5000 -> {error, http_listen} end.

accept(L, Page) ->
    {ok, S} = gen_tcp:accept(L),
    _ = spawn(fun() -> serve(S, Page) end),
    accept(L, Page).

serve(S, Page) ->
    _ = gen_tcp:recv(S, 0, 5000),
    {ok, Body} = file:read_file(Page),
    _ = gen_tcp:send(S, [<<"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n">>,
                         <<"Content-Length: ">>, integer_to_binary(byte_size(Body)),
                         <<"\r\nConnection: close\r\n\r\n">>, Body]),
    gen_tcp:close(S).

log(Fmt, Args) ->
    io:format("demo: " ++ Fmt ++ "~n", Args).
