%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The outbound registration client (chappe_sip_regc, RFC 3261 10.2) on the
%% wire: a raw UDP peer plays the registrar and answers each REGISTER as
%% the case needs (a digest challenge, 423, failures, 200).
-module(chappe_sip_regc_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-import(chappe_sip_core_peer, [
    open/0, port/1, send/3, recv/3, recv_none/3, response/3, tag/0,
    hdr/2, hdrs/2, cseq/1
]).

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([digest_and_refresh/1, digest_reuse_refused/1, min_expires_423/1, failure_backoff/1,
         expiry/1, unregister/1, from_app_env/1, not_found/1,
         stop_unregisters/1]).

-define(AOR, <<"sip:alice@example.com">>).

all() ->
    [digest_and_refresh, digest_reuse_refused, min_expires_423, failure_backoff, expiry, unregister,
     from_app_env, not_found, stop_unregisters].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(from_app_env, Config) ->
    Sock = open(),
    application:set_env(chappe_sip, registrations,
                        #{env_trunk => #{aor => ?AOR,
                                         registrar => registrar(Sock)}}),
    start(Sock, Config);
init_per_testcase(_Case, Config) ->
    start(open(), Config).

start(Sock, Config) ->
    EP = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => chappe_sip_core_peer:contact(EP)}),
    ok = chappe_sip:register_subscribe(self()),
    [{ep, EP}, {sock, Sock} | Config].

end_per_testcase(_Case, Config) ->
    application:unset_env(chappe_sip, registrations),
    [chappe_sip_regc_sup:delete_child(N)
     || {N, _} <- chappe_sip_regc_sup:children()],
    chappe_sip_core_peer:close(?config(sock, Config)),
    _ = chappe_sip:stop(),
    ok.

%% A 401 is answered with credentials on the same Call-ID and the next
%% CSeq; the 2xx's expires for our Contact is kept, and the binding is
%% refreshed before it runs out, without a second registered event.
%% req: R3261-RC-01 R3261-RC-02 R3261-RC-05 R3261-RC-06
digest_and_refresh(Config) ->
    Sock = ?config(sock, Config),
    ok = chappe_sip:register_client(trunk, #{
        aor => ?AOR, registrar => registrar(Sock), expires => 3,
        auth => #{user => <<"alice">>, pass => <<"secret">>}}),
    R1 = register(Sock),
    ?assertEqual(<<"3">>, hdr(<<"expires">>, R1)),
    ?assertEqual(<<"<", ?AOR/binary, ">">>, hdr(<<"to">>, R1)),
    ?assertMatch(<<"<sip:alice@127.0.0.1:", _/binary>>, hdr(<<"contact">>, R1)),
    challenge(Sock, R1),
    R2 = register(Sock),
    {ok, <<"alice">>} = verify(R2),
    ?assertEqual(hdr(<<"call-id">>, R1), hdr(<<"call-id">>, R2)),
    ?assertEqual(seq(R1) + 1, seq(R2)),
    ok(Sock, R2, 3),
    registered = event(trunk),
    {ok, #{status := registered, granted := 3}} =
        chappe_sip:register_status(trunk),
    %% the refresh, a third early (about 2 s in), answers the same
    %% challenge at once: same nonce, the next nc, a new cnonce
    R3 = register(Sock),
    ?assertEqual(hdr(<<"call-id">>, R1), hdr(<<"call-id">>, R3)),
    ?assertEqual(seq(R2) + 1, seq(R3)),
    #{<<"nonce">> := N, <<"nc">> := <<"00000001">>, <<"cnonce">> := C2} =
        auth_params(R2),
    #{<<"nonce">> := N, <<"nc">> := <<"00000002">>, <<"cnonce">> := C3} =
        auth_params(R3),
    ?assertNotEqual(C2, C3),
    {ok, <<"alice">>} = verify(R3),
    ok(Sock, R3, 60),
    no_event(trunk, 500),
    {ok, #{status := registered, granted := 60}} =
        chappe_sip:register_status(trunk).

%% A refresh whose reused nonce is refused (a plain 401, no stale) starts
%% over: a REGISTER without credentials, its challenge answered; one told
%% stale=true answers the new nonce straight away.
digest_reuse_refused(Config) ->
    Sock = ?config(sock, Config),
    ok = chappe_sip:register_client(tre, #{
        aor => ?AOR, registrar => registrar(Sock), expires => 2,
        auth => #{user => <<"alice">>, pass => <<"secret">>}}),
    R1 = register(Sock),
    challenge(Sock, R1),
    R2 = register(Sock),
    ok(Sock, R2, 2),
    registered = event(tre),
    R3 = register(Sock),
    ?assertNotEqual(undefined, hdr(<<"authorization">>, R3)),
    challenge(Sock, R3),
    R4 = register(Sock),
    ?assertEqual(undefined, hdr(<<"authorization">>, R4)),
    challenge(Sock, R4),
    R5 = register(Sock),
    {ok, <<"alice">>} = verify(R5),
    ok(Sock, R5, 2),
    R6 = register(Sock),
    reply(Sock, R6, 401, [{<<"WWW-Authenticate">>,
                           chappe_sip_digest:challenge(<<"lab">>, true)}]),
    R7 = register(Sock),
    ?assertNotEqual(maps:get(<<"nonce">>, auth_params(R6)),
                    maps:get(<<"nonce">>, auth_params(R7))),
    {ok, <<"alice">>} = verify(R7),
    ok(Sock, R7, 3600),
    no_event(tre, 300).

%% A 423 is retried with the Min-Expires it names.
%% req: R3261-RC-08
min_expires_423(Config) ->
    Sock = ?config(sock, Config),
    ok = chappe_sip:register_client(t423, #{
        aor => ?AOR, registrar => registrar(Sock), expires => 30}),
    R1 = register(Sock),
    reply(Sock, R1, 423, [{<<"Min-Expires">>, <<"120">>}]),
    R2 = register(Sock),
    ?assertEqual(<<"120">>, hdr(<<"expires">>, R2)),
    ok(Sock, R2, 120),
    registered = event(t423).

%% A failure is reported once and retried with a doubling backoff, after
%% the Retry-After of a 503.
%% req: R3261-RC-07
failure_backoff(Config) ->
    Sock = ?config(sock, Config),
    ok = chappe_sip:register_client(tfail, #{
        aor => ?AOR, registrar => registrar(Sock), retry_min_ms => 300}),
    R1 = register(Sock),
    reply(Sock, R1, 403, []),
    failed = event(tfail),
    T1 = now_ms(),
    R2 = register(Sock),
    ?assert(now_ms() - T1 >= 250),
    reply(Sock, R2, 500, []),
    T2 = now_ms(),
    R3 = register(Sock),
    ?assert(now_ms() - T2 >= 550),
    reply(Sock, R3, 503, [{<<"Retry-After">>, <<"2">>}]),
    T3 = now_ms(),
    recv_none(Sock, {method, <<"REGISTER">>}, 1500),
    R4 = register(Sock),
    ?assert(now_ms() - T3 >= 1900),
    no_event(tfail, 0),
    {ok, #{status := failed, failures := 3, last_status := 503}} =
        chappe_sip:register_status(tfail),
    ok(Sock, R4, 3600),
    registered = event(tfail).

%% A refresh that fails reports failed; when the granted expiry then
%% passes, expired.
expiry(Config) ->
    Sock = ?config(sock, Config),
    ok = chappe_sip:register_client(texp, #{
        aor => ?AOR, registrar => registrar(Sock), expires => 2,
        retry_min_ms => 5000}),
    R1 = register(Sock),
    ok(Sock, R1, 2),
    registered = event(texp),
    R2 = register(Sock),
    reply(Sock, R2, 500, []),
    failed = event(texp),
    expired = event(texp),
    {ok, #{status := expired, expires_in := 0}} =
        chappe_sip:register_status(texp).

%% unregister_client sends Expires: 0 for the same Contact and returns
%% once the registrar answers; the registration is then gone.
%% req: R3261-RC-04
unregister(Config) ->
    Sock = ?config(sock, Config),
    ok = chappe_sip:register_client(tun, #{
        aor => ?AOR, registrar => registrar(Sock)}),
    R1 = register(Sock),
    ok(Sock, R1, 3600),
    registered = event(tun),
    Self = self(),
    spawn_link(fun() -> Self ! {unregistered, chappe_sip:unregister_client(tun)} end),
    R2 = register(Sock),
    ?assertEqual(<<"0">>, hdr(<<"expires">>, R2)),
    ?assertEqual(hdr(<<"contact">>, R1), hdr(<<"contact">>, R2)),
    ?assertEqual(hdr(<<"call-id">>, R1), hdr(<<"call-id">>, R2)),
    ok(Sock, R2, 0),
    receive {unregistered, ok} -> ok after 5000 -> ct:fail(no_unregister) end,
    {error, not_found} = chappe_sip:register_status(tun),
    {error, not_found} = chappe_sip:unregister_client(tun),
    %% the name can be used again
    ok = chappe_sip:register_client(tun, #{
        aor => ?AOR, registrar => registrar(Sock)}),
    _ = register(Sock).

%% The registrations setting is started with the stack.
from_app_env(Config) ->
    Sock = ?config(sock, Config),
    R1 = register(Sock),
    ok(Sock, R1, 3600),
    registered = event(env_trunk),
    {error, already_started} = chappe_sip:register_client(env_trunk,
                                                          #{aor => ?AOR}).

not_found(_Config) ->
    {error, not_found} = chappe_sip:register_status(nobody),
    {error, not_found} = chappe_sip:unregister_client(nobody),
    {error, bad_aor} = chappe_sip:register_client(bad, #{aor => <<"nope">>}).

%% A registration stopped by its supervisor removes its binding on the
%% way out.
%% req: R3261-RC-04
stop_unregisters(Config) ->
    Sock = ?config(sock, Config),
    ok = chappe_sip:register_client(tstop, #{
        aor => ?AOR, registrar => registrar(Sock)}),
    R1 = register(Sock),
    ok(Sock, R1, 3600),
    registered = event(tstop),
    ok = supervisor:terminate_child(chappe_sip_regc_sup, {regc, tstop}),
    R2 = register(Sock),
    ?assertEqual(<<"0">>, hdr(<<"expires">>, R2)).

%% ---- helpers ----

registrar(Sock) ->
    <<"sip:127.0.0.1:", (integer_to_binary(port(Sock)))/binary>>.

register(Sock) ->
    {Bin, _} = recv(Sock, {method, <<"REGISTER">>}, 6000),
    Bin.

verify(Req) ->
    M = chappe_sip_core_peer:parse(Req),
    chappe_sip_digest:verify(#{
        method => <<"REGISTER">>, realm => <<"lab">>,
        secret => fun(<<"alice">>) -> {ok, <<"secret">>}; (_) -> error end,
        authorization => chappe_sip_msg:get(<<"authorization">>, M),
        request_uri => chappe_sip_msg:uri(M)}).

auth_params(Req) ->
    {ok, #{params := P}} = chappe_sip_hdr:auth(hdr(<<"authorization">>, Req)),
    P.

seq(Bin) ->
    {N, <<"REGISTER">>} = cseq(Bin),
    N.

challenge(Sock, Req) ->
    reply(Sock, Req, 401,
          [{<<"WWW-Authenticate">>, chappe_sip_digest:challenge(<<"lab">>)}]).

ok(Sock, Req, Expires) ->
    [Contact] = hdrs(<<"contact">>, Req),
    reply(Sock, Req, 200,
          [{<<"Contact">>,
            <<Contact/binary, ";expires=", (integer_to_binary(Expires))/binary>>}]).

reply(Sock, Req, Status, Hdrs) ->
    send(Sock, src_port(Req), response(Req, Status, #{to_tag => tag(), headers => Hdrs})).

%% the engine's port, from the top Via of its request
src_port(Req) ->
    Via = hdr(<<"via">>, Req),
    {match, [P]} = re:run(Via, ":([0-9]+)", [{capture, all_but_first, binary}]),
    binary_to_integer(P).

event(Name) ->
    receive {chappe_sip_regc, Name, E} -> E
    after 6000 -> ct:fail({no_regc_event, Name})
    end.

no_event(Name, T) ->
    receive {chappe_sip_regc, Name, E} -> ct:fail({unexpected, E})
    after T -> ok
    end.

now_ms() -> erlang:monotonic_time(millisecond).
