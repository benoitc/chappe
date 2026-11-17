%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The event state compositor (RFC 3903): the soft state PUBLISH
%% sets, per resource and event package.
%%
%% handler/1 is the PUBLISH handler (chappe_sip:publish/1 registers it);
%% this process keeps the publications and is the only one to change them,
%% so the PUBLISHes of a resource apply one by one, in order, each one
%% completely or not at all (RFC 3903 6). Each 2xx carries the granted
%% Expires and a new SIP-ETag; SIP-If-Match refreshes (no body), modifies
%% (a body) or removes (Expires: 0) the publication it names, 412 when it
%% names none. A publication not refreshed in time is removed.
%%
%% Who may publish what (RFC 3903 14.1): by default an authenticated user
%% only its own address-of-record (the registrar's rule for REGISTER), and
%% nobody without credentials unless allow_unauthenticated is set; an
%% authorize fun replaces that rule. 403 otherwise. The store is bounded
%% (esc_max_publications, esc_max_publications_per_resource: 503 with
%% Retry-After; esc_max_body_size: 413).
%%
%% watch/2 subscribes a process to a package's changes:
%% {chappe_sip_esc, changed, Resource, Package} after every publication
%% that changed the state (a new one, a modify, a removal, an expiry).
-module(chappe_sip_esc).
-behaviour(gen_server).

-export([start_link/0]).
-export([handler/1, publications/2, watch/2, resource/1, authenticate/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export_type([publication/0]).

-type publication() :: #{
    etag := binary(),
    body := binary(),
    content_type := binary(),
    published_at := integer(),
    expires_at := integer()
}.

-record(state, {
    %% entity-tag => {Key, publication(), TRef}
    pubs = #{} :: #{
        binary() => {{binary(), binary()}, publication(), reference()}
    },
    %% resource => its live publications, every package
    counts = #{} :: #{binary() => pos_integer()},
    %% package => watching pids
    watchers = #{} :: #{binary() => [pid()]},
    %% one monitor per watching pid, whatever it watches
    monitors = #{} :: #{pid() => reference()}
}).
-type state() :: #state{}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% ---- the PUBLISH handler ----

%% Opts:
%%   packages => #{Package => [ContentType]}  the packages served and the
%%       body types each takes (default: presence with application/pidf+xml)
%%   resources => any | fun((Aor) -> boolean())  the resources we keep
%%       state for; another one gets 404 (default any)
%%   auth => #{realm := binary(), secret := fun(), domain => binary() |
%%       [binary()]}  digest: 401 until the PUBLISH carries credentials
%%   authorize => fun((#{user := binary() | undefined,
%%                       realm := binary() | undefined, resource := Aor,
%%                       event := Package, req := Req}) -> boolean())
%%       who may publish to Aor; false is 403. Default: the authenticated
%%       user publishes its own AOR only (user part, and host one of the
%%       auth domains, the realm by default: chappe_sip_registrar's rule),
%%       and a PUBLISH without auth is refused unless
%%   allow_unauthenticated => true  (a closed network only)
%%   default_expires (3600), min_expires (60, below it 423), max_expires
%%       (86400, above it the grant is capped)
-spec handler(map()) -> fun((chappe_sip_req:req(), chappe_sip_res:res()) -> ok).
handler(Opts) ->
    fun(Req, Res) -> handle(Req, Res, Opts) end.

handle(Req, Res, Opts) ->
    Steps = [
        fun auth_step/3,
        fun resource_step/3,
        fun event_step/3,
        fun authorize_step/3,
        fun if_match_step/3,
        fun expires_step/3,
        fun body_step/3
    ],
    case run(Steps, Req, Opts, #{}) of
        {ok, P} -> publish(P, Res, Opts);
        {reject, Status, Reason, Hdrs} -> reply(Res, Status, Reason, Hdrs)
    end.

run([], _Req, _Opts, Acc) ->
    {ok, Acc};
run([Step | Rest], Req, Opts, Acc) ->
    case Step(Req, Opts, Acc) of
        {ok, Acc1} -> run(Rest, Req, Opts, Acc1);
        Reject -> Reject
    end.

auth_step(Req, Opts, Acc) ->
    case authenticate(maps:get(auth, Opts, undefined), Req) of
        {ok, User} -> {ok, Acc#{user => User}};
        {reject, 401, Hdrs} -> {reject, 401, <<"Unauthorized">>, Hdrs};
        {reject, Status, Hdrs} -> {reject, Status, <<"Bad Request">>, Hdrs}
    end.

%% RFC 3903 6 step 1: a resource we do not keep state for
resource_step(Req, Opts, Acc) ->
    Aor = resource(chappe_sip_req:uri(Req)),
    Known =
        case maps:get(resources, Opts, any) of
            any -> true;
            F when is_function(F, 1) -> F(Aor)
        end,
    case Known of
        true -> {ok, Acc#{resource => Aor}};
        false -> {reject, 404, <<"Not Found">>, []}
    end.

%% step 2: the package
event_step(Req, Opts, Acc) ->
    Pkgs = packages(Opts),
    case chappe_sip_hdr:event(chappe_sip_req:get(<<"event">>, Req)) of
        {ok, #{type := T}} when is_map_key(T, Pkgs) ->
            {ok, Acc#{event => T, types => maps:get(T, Pkgs)}};
        _ ->
            Allow = iolist_to_binary(lists:join(<<", ">>, maps:keys(Pkgs))),
            {reject, 489, <<"Bad Event">>, [{<<"Allow-Events">>, Allow}]}
    end.

%% RFC 3903 14.1: the authorization policy, on the identity and the
%% resource together
authorize_step(Req, Opts, #{user := User, resource := Aor, event := E} = Acc) ->
    Auth = maps:get(auth, Opts, undefined),
    Allowed =
        case maps:get(authorize, Opts, undefined) of
            F when is_function(F, 1) ->
                F(#{
                    user => User,
                    realm => realm(Auth),
                    resource => Aor,
                    event => E,
                    req => Req
                });
            undefined ->
                owner(User, Auth, Aor, Opts)
        end,
    case Allowed of
        true -> {ok, Acc};
        _ -> {reject, 403, <<"Forbidden">>, []}
    end.

realm(#{realm := Realm}) -> Realm;
realm(_) -> undefined.

%% the default policy: an authenticated user its own AOR; no user only
%% when the application opted in
owner(undefined, _Auth, _Aor, #{allow_unauthenticated := true}) ->
    true;
owner(undefined, _Auth, _Aor, _Opts) ->
    false;
owner(User, #{} = Auth, Aor, _Opts) ->
    chappe_sip_registrar:aor_owned(User, Auth, Aor).

%% step 3: one entity-tag, or none
if_match_step(Req, _Opts, Acc) ->
    Tags = [
        string:trim(T)
     || V <- chappe_sip_req:get_all(<<"sip-if-match">>, Req),
        T <- binary:split(V, <<",">>, [global]),
        string:trim(T) =/= <<>>
    ],
    case Tags of
        [] -> {ok, Acc#{if_match => undefined}};
        [Tag] -> {ok, Acc#{if_match => Tag}};
        _ -> {reject, 400, <<"Invalid Request">>, []}
    end.

%% step 4: the Expires asked for, else the default; below the minimum
%% 423 with Min-Expires; above the maximum, capped
expires_step(Req, Opts, Acc) ->
    Default = maps:get(default_expires, Opts, 3600),
    Min = maps:get(min_expires, Opts, 60),
    Max = maps:get(max_expires, Opts, 86400),
    case chappe_sip_dialog_fsm:requested_expires(Req, Default) of
        N when N > 0, N < Min ->
            {reject, 423, <<"Interval Too Brief">>, [
                {<<"Min-Expires">>, integer_to_binary(Min)}
            ]};
        N ->
            {ok, Acc#{expires => min(N, Max)}}
    end.

%% step 5: a body the package takes, within esc_max_body_size (else 413,
%% RFC 3261 21.4.11); none needs an entity-tag
body_step(Req, _Opts, #{types := Types, if_match := IfMatch} = Acc) ->
    Max = chappe_sip_config:get(esc_max_body_size),
    case {chappe_sip_req:body(Req), IfMatch} of
        {<<>>, undefined} ->
            {reject, 400, <<"Invalid Request">>, []};
        {<<>>, _} ->
            {ok, Acc#{body => <<>>, content_type => undefined}};
        {Body, _} when byte_size(Body) > Max ->
            {reject, 413, <<"Request Entity Too Large">>, []};
        {Body, _} ->
            CT = base_type(chappe_sip_req:get(<<"content-type">>, Req)),
            case lists:member(CT, Types) of
                true ->
                    {ok, Acc#{body => Body, content_type => CT}};
                false ->
                    Accept = iolist_to_binary(lists:join(<<", ">>, Types)),
                    {reject, 415, <<"Unsupported Media Type">>, [
                        {<<"Accept">>, Accept}
                    ]}
            end
    end.

%% step 6: the 200 with the granted Expires and the new entity-tag; 503
%% when the store is full, to retry once the shortest grant could expire
publish(
    #{resource := R, event := E, if_match := IfMatch, expires := Exp} = P,
    Res,
    Opts
) ->
    Body = maps:get(body, P),
    CT = maps:get(content_type, P),
    case gen_server:call(?MODULE, {publish, {R, E}, IfMatch, Exp, Body, CT}) of
        {ok, ETag} ->
            reply(Res, 200, <<"OK">>, [
                {<<"Expires">>, integer_to_binary(Exp)},
                {<<"SIP-ETag">>, ETag}
            ]);
        {error, 412} ->
            reply(Res, 412, <<"Conditional Request Failed">>, []);
        {error, 503} ->
            After = integer_to_binary(maps:get(min_expires, Opts, 60)),
            reply(Res, 503, <<"Service Unavailable">>, [
                {<<"Retry-After">>, After}
            ])
    end.

reply(Res, Status, Reason, Hdrs) ->
    _ = chappe_sip_res:send(Res, Status, #{reason => Reason, headers => Hdrs}),
    ok.

packages(Opts) ->
    maps:get(packages, Opts, #{
        <<"presence">> => [chappe_sip_pidf:content_type()]
    }).

base_type(undefined) ->
    undefined;
base_type(CT) ->
    string:lowercase(string:trim(hd(binary:split(CT, <<";">>)))).

%% The key of a resource: its address-of-record (RFC 3261 10.3), else the
%% URI as written.
-spec resource(binary()) -> binary().
resource(Uri) ->
    case chappe_sip_uri:aor(Uri) of
        {ok, Aor} -> Aor;
        error -> Uri
    end.

%% Digest authentication of a request (RFC 3261 22): {ok, User}, or the
%% response to send. No auth: {ok, undefined}.
-spec authenticate(map() | undefined, chappe_sip_req:req()) ->
    {ok, binary() | undefined} | {reject, 400 | 401, [{binary(), binary()}]}.
authenticate(undefined, _Req) ->
    {ok, undefined};
authenticate(#{realm := Realm, secret := PwFun}, Req) ->
    Args = #{
        method => chappe_sip_req:method(Req),
        realm => Realm,
        secret => PwFun,
        authorization => chappe_sip_req:get(<<"authorization">>, Req),
        request_uri => chappe_sip_req:uri(Req)
    },
    case chappe_sip_digest:verify(Args) of
        {ok, User} ->
            {ok, User};
        stale ->
            {reject, 401, [challenge(Realm, true)]};
        {error, uri_mismatch} ->
            {reject, 400, []};
        {error, _} ->
            {reject, 401, [challenge(Realm, false)]}
    end.

challenge(Realm, Stale) ->
    {<<"WWW-Authenticate">>, chappe_sip_digest:challenge(Realm, Stale)}.

%% ---- the state ----

%% The live publications of Resource (an address-of-record, see
%% resource/1) for Package, the most recently changed first.
-spec publications(binary(), binary()) -> [publication()].
publications(Resource, Package) ->
    gen_server:call(?MODULE, {publications, {Resource, Package}}).

%% Pid gets {chappe_sip_esc, changed, Resource, Package} from now on.
-spec watch(binary(), pid()) -> ok.
watch(Package, Pid) ->
    gen_server:call(?MODULE, {watch, Package, Pid}).

%% ---- gen_server ----

-spec init([]) -> {ok, state()}.
init([]) ->
    {ok, #state{}}.

handle_call({publish, Key, IfMatch, Exp, Body, CT}, _From, S) ->
    {Reply, S1} = do_publish(Key, IfMatch, Exp, Body, CT, S),
    {reply, Reply, S1};
handle_call({publications, Key}, _From, S) ->
    Pubs = [P || {K, P, _} <- maps:values(S#state.pubs), K =:= Key],
    Sorted = lists:reverse(
        lists:keysort(1, [{maps:get(published_at, P), P} || P <- Pubs])
    ),
    {reply, [P || {_, P} <- Sorted], S};
handle_call({watch, Pkg, Pid}, _From, S) ->
    Ms = S#state.monitors,
    Ms1 =
        case is_map_key(Pid, Ms) of
            true -> Ms;
            false -> Ms#{Pid => erlang:monitor(process, Pid)}
        end,
    Ws = S#state.watchers,
    {reply, ok, S#state{
        watchers = Ws#{Pkg => [Pid | maps:get(Pkg, Ws, []) -- [Pid]]},
        monitors = Ms1
    }}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({expire, ETag}, S) ->
    case take(ETag, S) of
        {{Key, _P, _TRef}, S1} ->
            changed(Key, S1),
            {noreply, S1};
        error ->
            {noreply, S}
    end;
handle_info({'DOWN', _MRef, process, Pid, _}, S) ->
    Ws = maps:map(fun(_Pkg, Pids) -> Pids -- [Pid] end, S#state.watchers),
    {noreply, S#state{
        watchers = Ws, monitors = maps:remove(Pid, S#state.monitors)
    }};
handle_info(_Msg, S) ->
    {noreply, S}.

%% an initial publication: a new entity-tag and state, if the store has
%% room for it
do_publish({R, _} = Key, undefined, Exp, Body, CT, S) ->
    case room(R, S) of
        true ->
            ETag = new_etag(),
            S1 = store(Key, ETag, Body, CT, Exp, S),
            changed(Key, S1),
            {{ok, ETag}, S1};
        false ->
            {{error, 503}, S}
    end;
%% a refresh, a modify or a removal of the publication the tag names
do_publish(Key, IfMatch, Exp, Body, CT, S) ->
    case take(IfMatch, S) of
        {{Key, Old, TRef}, S0} ->
            _ = erlang:cancel_timer(TRef),
            ETag = new_etag(),
            case {Exp, Body} of
                {0, _} ->
                    %% removed at once, nothing stored (RFC 3903 6 step 5)
                    changed(Key, S0),
                    {{ok, ETag}, S0};
                {_, <<>>} ->
                    %% a refresh: the same state under a new entity-tag
                    #{body := B, content_type := C, published_at := At} = Old,
                    S1 = store(Key, ETag, B, C, Exp, S0),
                    {{ok, ETag}, keep_published_at(ETag, At, S1)};
                _ ->
                    S1 = store(Key, ETag, Body, CT, Exp, S0),
                    changed(Key, S1),
                    {{ok, ETag}, S1}
            end;
        _ ->
            {{error, 412}, S}
    end.

store(Key, ETag, Body, CT, Exp, S) ->
    Now = erlang:system_time(millisecond),
    TRef = erlang:send_after(Exp * 1000, self(), {expire, ETag}),
    P = #{
        etag => ETag,
        body => Body,
        content_type => CT,
        published_at => Now,
        expires_at => Now + Exp * 1000
    },
    {R, _} = Key,
    Counts = S#state.counts,
    S#state{
        pubs = (S#state.pubs)#{ETag => {Key, P, TRef}},
        counts = Counts#{R => maps:get(R, Counts, 0) + 1}
    }.

%% the publication ETag names, out of the store
take(ETag, S) ->
    case maps:take(ETag, S#state.pubs) of
        {{{R, _}, _, _} = Entry, Pubs} ->
            Counts =
                case S#state.counts of
                    #{R := 1} = C -> maps:remove(R, C);
                    #{R := N} = C -> C#{R := N - 1}
                end,
            {Entry, S#state{pubs = Pubs, counts = Counts}};
        error ->
            error
    end.

%% a new publication for resource R stays within esc_max_publications and
%% esc_max_publications_per_resource
room(R, S) ->
    map_size(S#state.pubs) < chappe_sip_config:get(esc_max_publications) andalso
        maps:get(R, S#state.counts, 0) <
            chappe_sip_config:get(esc_max_publications_per_resource).

keep_published_at(ETag, At, S) ->
    #{ETag := {Key, P, TRef}} = S#state.pubs,
    S#state{
        pubs = (S#state.pubs)#{ETag := {Key, P#{published_at := At}, TRef}}
    }.

changed({Resource, Pkg} = _Key, S) ->
    [
        W ! {?MODULE, changed, Resource, Pkg}
     || W <- maps:get(Pkg, S#state.watchers, [])
    ],
    ok.

%% RFC 3903 6 step 6: never one given before for any resource
new_etag() ->
    binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).
