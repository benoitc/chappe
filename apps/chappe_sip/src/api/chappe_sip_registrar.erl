%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The ready-made REGISTER handler behind chappe_sip:registrar/1.
%%
%% It authenticates the REGISTER (digest or a callback; running without one
%% is an explicit opt-out), applies it to the location store
%% (chappe_sip_registry, RFC 3261 10.3) and answers: 200 with every binding
%% (expires, q), a Date, the request's Path (RFC 3327) and, for an RFC 5626
%% flow, Require: outbound and a Flow-Timer; or the store's refusal (400,
%% 403, 404, 420 with Unsupported: path, 423 with Min-Expires, 439, 503;
%% on a cluster without a quorum, 503 with Retry-After).
-module(chappe_sip_registrar).

-export([handler/1, aor_owned/3]).

%% A ready-made REGISTER handler backed by the location store: it records
%% the request's contacts and answers 200 echoing the live bindings (with
%% q, Date, the Path of RFC 3327, and Require: outbound and Flow-Timer for
%% an RFC 5626 flow). Opts:
%%   auth => #{realm := binary(),
%%             secret := fun((User) -> {ok, Pass} | {ha1, HA1} | error),
%%             domain => binary() | [binary()]}
%%         | fun((Req) -> ok | {reject, Status} | {reject, Status, Headers})
%%     Authentication before any binding is written. The map form runs
%%     built-in digest (challenges 401, verifies the response, and binds the
%%     authenticated user to the AOR: its user part, and its host one of
%%     domain, the realm by default). The fun form is a custom policy; a
%%     6xx it rejects with is sent as 403 (RFC 3261 10.3).
%%   allow_unauthenticated => true
%%     Required to run without auth (a closed test network): a registrar
%%     with neither raises error({registrar, auth_required}).
%%   domains => any | [binary()]  the domains bindings are kept for
%%     (default: the registrar_domains setting); another one gets 404.
%%   default_expires => pos_integer()
%%   qualify_interval_ms => pos_integer()  send an OPTIONS to each contact
%%     registered over UDP this often (NAT keepalive); qualify_down_after
%%     (default 2) unanswered in a row drop the binding (chappe_sip_qualify)
-spec handler(map()) ->
    fun((chappe_sip_req:req(), chappe_sip_res:res()) -> ok).
handler(#{auth := _} = Opts0) ->
    registrar_fun(Opts0);
handler(#{allow_unauthenticated := true} = Opts0) ->
    registrar_fun(Opts0);
handler(_Opts) ->
    erlang:error({registrar, auth_required}).

registrar_fun(Opts0) ->
    ok = qualify(Opts0),
    fun(Req, Res) ->
        case registrar_auth(maps:get(auth, Opts0, undefined), Req) of
            ok ->
                do_register(
                    maps:without(
                        [auth, allow_unauthenticated | qualify_keys()], Opts0
                    ),
                    Req,
                    Res
                );
            {reject, Status} ->
                _ = chappe_sip_res:send(Res, no_6xx(Status)),
                ok;
            {reject, Status, Headers} ->
                _ = chappe_sip_res:send(Res, no_6xx(Status), #{
                    headers => Headers
                }),
                ok
        end
    end.

qualify(#{qualify_interval_ms := Ms} = Opts) when is_integer(Ms), Ms > 0 ->
    chappe_sip_qualify:configure(#{
        interval_ms => Ms,
        down_after => maps:get(qualify_down_after, Opts, 2),
        timeout_ms => maps:get(qualify_timeout_ms, Opts, 2000)
    });
qualify(_Opts) ->
    ok.

qualify_keys() ->
    [qualify_interval_ms, qualify_down_after, qualify_timeout_ms].

%% RFC 3261 10.3: a registrar never answers 6xx; a policy that declines
%% with one gets 403 on the wire
no_6xx(Status) when Status >= 600 -> 403;
no_6xx(Status) -> Status.

do_register(Opts0, Req, Res) ->
    %% a WS-originated REGISTER carries its flow in the request meta; over
    %% TCP/TLS and UDP the flow it came on is kept for outbound bindings
    %% (RFC 5626 6)
    Meta = chappe_sip_req:meta(Req),
    Received = chappe_sip_route:received_flow(Meta),
    Opts1 = Opts0#{transport => maps:get(transport, Meta, undefined)},
    Opts =
        case maps:get(flow, Meta, undefined) of
            undefined ->
                with_direct_flow(Received, Opts1#{received => Received});
            Flow ->
                Opts1#{flow => Flow}
        end,
    case chappe_sip_registry:register_request(Req, Opts) of
        {ok, Bindings, Info} ->
            _ = chappe_sip_res:send(
                Res,
                200,
                #{
                    reason => <<"OK">>,
                    headers => register_ok_headers(Bindings, Info)
                }
            ),
            ok;
        {error, 420} ->
            %% RFC 3327 5.3: a Path the UA did not say it supports
            _ = chappe_sip_res:send(
                Res,
                420,
                #{
                    reason => <<"Bad Extension">>,
                    headers => [{<<"Unsupported">>, <<"path">>}]
                }
            ),
            ok;
        {error, no_quorum} ->
            no_quorum(Res);
        {error, 439} ->
            _ = chappe_sip_res:send(
                Res, 439, #{reason => <<"First Hop Lacks Outbound Support">>}
            ),
            ok;
        {error, 423} ->
            %% RFC 3261 10.3 step 7: 423 MUST carry Min-Expires
            Min = chappe_sip_config:get(registrar_min_expires),
            _ = chappe_sip_res:send(
                Res,
                423,
                #{
                    reason => <<"Interval Too Brief">>,
                    headers => [{<<"Min-Expires">>, integer_to_binary(Min)}]
                }
            ),
            ok;
        {error, Status} ->
            _ = chappe_sip_res:send(Res, Status),
            ok
    end.

%% on a cluster the region could not take the write: no 200 for a binding
%% that is not stored (RFC 3261 10.3 step 8); the UA keeps its current
%% binding and retries after Retry-After (21.5.4)
no_quorum(Res) ->
    After = integer_to_binary(chappe_sip_config:get(registrar_retry_after)),
    _ = chappe_sip_res:send(Res, 503, #{
        reason => <<"Service Unavailable">>,
        headers => [{<<"Retry-After">>, After}]
    }),
    ok.

with_direct_flow(undefined, Opts) -> Opts;
with_direct_flow(Flow, Opts) -> Opts#{outbound_flow => Flow}.

%% allow_unauthenticated: accept (a closed network only)
registrar_auth(undefined, _Req) ->
    ok;
registrar_auth(Fun, Req) when is_function(Fun, 1) ->
    Fun(Req);
registrar_auth(#{realm := Realm, secret := PwFun} = Auth, Req) ->
    Args = #{
        method => chappe_sip_req:method(Req),
        realm => Realm,
        secret => PwFun,
        authorization => chappe_sip_req:get(<<"authorization">>, Req),
        request_uri => chappe_sip_req:uri(Req)
    },
    case chappe_sip_digest:verify(Args) of
        {ok, User} ->
            To = chappe_sip_hdr:name_addr_uri(
                chappe_sip_req:get(<<"to">>, Req)
            ),
            case aor_owned(User, Auth, To) of
                % identity and domain match the AOR
                true -> ok;
                % authenticated as someone else, or for another domain
                false -> {reject, 403}
            end;
        stale ->
            {reject, 401, [www_authenticate(Realm, true)]};
        {error, uri_mismatch} ->
            %% RFC 7616 3.4: the digest names another resource
            {reject, 400};
        {error, _} ->
            {reject, 401, [www_authenticate(Realm, false)]}
    end.

www_authenticate(Realm, Stale) ->
    {<<"WWW-Authenticate">>, chappe_sip_digest:challenge(Realm, Stale)}.

%% the domains the credentials of this realm register in: the auth map's
%% domain (one or a list), else the realm itself
auth_domains(#{domain := D}) when is_binary(D) -> [chappe_sip_lib:lower(D)];
auth_domains(#{domain := Ds}) when is_list(Ds) ->
    [chappe_sip_lib:lower(D) || D <- Ds];
auth_domains(#{realm := Realm}) ->
    [chappe_sip_lib:lower(Realm)].

%% The address-of-record Uri is User's under the digest map Auth: its
%% user part is User and its host one of the auth domains (the auth map's
%% domain, one or a list, else the realm). The registrar checks the To of
%% a REGISTER with it; the ESC the Request-URI of a PUBLISH.
-spec aor_owned(binary(), #{realm := binary(), _ => _}, binary()) ->
    boolean().
aor_owned(User, Auth, Uri) ->
    case chappe_sip_uri:parse(Uri) of
        {ok, #{user := User, host := Host}} ->
            lists:member(chappe_sip_lib:lower(Host), auth_domains(Auth));
        _ ->
            false
    end.

%% RFC 3261 10.3 step 8: every binding with its expires (and q), and a
%% Date; RFC 3327 5.3: the request's Path; RFC 5626 6: Require: outbound
%% (and a Flow-Timer on a direct flow) when a flow was registered
register_ok_headers(Bindings, #{
    path := Path, outbound := Ob, first_hop := First
}) ->
    [{<<"Contact">>, binding_value(B)} || B <- Bindings] ++
        [
            {<<"Path">>, iolist_to_binary(lists:join(<<", ">>, Path))}
         || Path =/= []
        ] ++
        [{<<"Require">>, <<"outbound">>} || Ob] ++
        [
            {<<"Flow-Timer">>,
                integer_to_binary(chappe_sip_config:get(registrar_flow_timer))}
         || Ob, First
        ] ++
        [{<<"Date">>, httpd_date()}].

binding_value(B) ->
    iolist_to_binary([
        $<,
        maps:get(contact, B),
        $>,
        [[<<";q=">>, Q] || Q <- [maps:get(q, B, undefined)], Q =/= undefined],
        [
            [<<";+sip.instance=">>, I]
         || I <- [maps:get(instance, B, undefined)], I =/= undefined
        ],
        [
            [<<";reg-id=">>, R]
         || R <- [maps:get(reg_id, B, undefined)], R =/= undefined
        ],
        <<";expires=">>,
        integer_to_binary(maps:get(expires, B))
    ]).

%% RFC 3261 20.17: an RFC 1123 date, always GMT
httpd_date() ->
    {{Y, Mo, D} = Date, {H, Mi, S}} = calendar:universal_time(),
    Day = element(calendar:day_of_the_week(Date), {
        "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"
    }),
    Mon = element(Mo, {
        "Jan",
        "Feb",
        "Mar",
        "Apr",
        "May",
        "Jun",
        "Jul",
        "Aug",
        "Sep",
        "Oct",
        "Nov",
        "Dec"
    }),
    iolist_to_binary(
        io_lib:format(
            "~s, ~2..0B ~s ~4..0B ~2..0B:~2..0B:~2..0B GMT",
            [Day, D, Mon, Y, H, Mi, S]
        )
    ).
