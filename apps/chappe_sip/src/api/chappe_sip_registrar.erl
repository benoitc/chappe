%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The ready-made REGISTER handler behind chappe_sip:registrar/1.
%%
%% It authenticates the REGISTER (digest or a callback; running without one
%% is an explicit opt-out), applies it to the location store
%% (chappe_sip_registry, RFC 3261 10.3) and answers: 200 with every binding
%% (expires, q), a Date, the request's Path (RFC 3327) and, for an RFC 5626
%% flow, Require: outbound and a Flow-Timer; or the store's refusal (400,
%% 403, 404, 420 with Unsupported: path, 423 with Min-Expires, 439, 503).
-module(chappe_sip_registrar).

-export([handler/1]).

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
-spec handler(map()) ->
    fun((chappe_sip_req:req(), chappe_sip_res:res()) -> ok).
handler(#{auth := _} = Opts0) ->
    registrar_fun(Opts0);
handler(#{allow_unauthenticated := true} = Opts0) ->
    registrar_fun(Opts0);
handler(_Opts) ->
    erlang:error({registrar, auth_required}).

registrar_fun(Opts0) ->
    fun(Req, Res) ->
        case registrar_auth(maps:get(auth, Opts0, undefined), Req) of
            ok ->
                do_register(
                    maps:without([auth, allow_unauthenticated], Opts0), Req, Res
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

%% RFC 3261 10.3: a registrar never answers 6xx; a policy that declines
%% with one gets 403 on the wire
no_6xx(Status) when Status >= 600 -> 403;
no_6xx(Status) -> Status.

do_register(Opts0, Req, Res) ->
    %% a WS-originated REGISTER carries its flow in the request meta; over
    %% TCP/TLS and UDP the flow it came on is kept for outbound bindings
    %% (RFC 5626 6)
    Meta = chappe_sip_req:meta(Req),
    Opts =
        case maps:get(flow, Meta, undefined) of
            undefined -> with_direct_flow(direct_flow(Meta), Opts0);
            Flow -> Opts0#{flow => Flow}
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

%% the flow a request arrived on: its TCP/TLS connection, or the address
%% and port a UDP request came from (RFC 5626 3.3), with the listen address
%% it reached when there are several, so a request to the binding leaves
%% from that same socket
direct_flow(#{conn := Id}) when is_integer(Id) ->
    {conn, Id};
direct_flow(
    #{transport := <<"udp">>, source_ip := Ip, source_port := Port} = Meta
) when
    Ip =/= <<>>, Port > 0
->
    case chappe_sip_binds:local(Meta) of
        undefined -> {udp, Ip, Port};
        Local -> {udp, Ip, Port, Local}
    end;
direct_flow(_Meta) ->
    undefined.

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
            case aor_owned(User, auth_domains(Auth), Req) of
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

%% the To AOR being registered is User's, in one of Domains
aor_owned(User, Domains, Req) ->
    case chappe_sip_uri:parse(aor_uri(chappe_sip_req:get(<<"to">>, Req))) of
        {ok, #{user := User, host := Host}} ->
            lists:member(chappe_sip_lib:lower(Host), Domains);
        _ ->
            false
    end.

aor_uri(NameAddr) ->
    case chappe_sip_hdr:name_addr(NameAddr) of
        {ok, #{uri := Uri}} -> Uri;
        _ -> NameAddr
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
