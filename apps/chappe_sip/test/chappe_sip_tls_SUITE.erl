%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% TLS contact.
%%
%% Start the engine with a secondary TLS listener (its own port), then drive
%% an OPTIONS over a real TLS client socket and confirm it is answered.
%% Skipped if openssl is not on PATH to generate a throwaway cert.
-module(chappe_sip_tls_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([tls_options/1, udp_still_works/1, tls_bad_verify/1]).

all() ->
    [tls_options, udp_still_works, tls_bad_verify].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    {ok, _} = application:ensure_all_started(ssl),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

end_per_testcase(_Case, _Config) ->
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% OPTIONS over TLS is answered on the same connection.
tls_options(Config) ->
    CertDir = filename:join(?config(priv_dir, Config), "tlscerts"),
    ok = filelib:ensure_dir(filename:join(CertDir, "x")),
    case gen_certs(CertDir) of
        {error, no_openssl} ->
            {skip, "openssl not available"};
        ok ->
            EP = pick(),
            TP = pick(),
            ok = chappe_sip:start(#{
                contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>,
                tls => #{contact => <<"sips:127.0.0.1:",
                                      (integer_to_binary(TP))/binary,
                                      ";transport=tls">>,
                         cert_dir => list_to_binary(CertDir),
                         verify => none}}),
            ok = chappe_sip:options(fun(_Req, Res) ->
                chappe_sip_res:send(Res, 200, #{reason => <<"OK">>})
            end),
            {ok, S} = ssl:connect("127.0.0.1", TP,
                                  [{verify, verify_none}, binary,
                                   {active, false}, {versions, ['tlsv1.2']}],
                                  5000),
            ok = ssl:send(S, options_req()),
            {ok, Data} = ssl:recv(S, 0, 5000),
            ?assertMatch(<<"SIP/2.0 200", _/binary>>, Data),
            ok = ssl:close(S)
    end.

%% F11: an unrecognised TLS verify value is rejected, not silently treated as
%% no verification.
tls_bad_verify(_Config) ->
    EP = pick(),
    TP = pick(),
    R = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>,
        tls => #{contact => <<"sips:127.0.0.1:", (integer_to_binary(TP))/binary,
                              ";transport=tls">>,
                 verify => banana}}),
    ?assertMatch({error, {tls, {bad_verify, banana}}}, R).

%% the primary UDP transport still works alongside the TLS listener.
udp_still_works(Config) ->
    CertDir = filename:join(?config(priv_dir, Config), "tlscerts2"),
    ok = filelib:ensure_dir(filename:join(CertDir, "x")),
    case gen_certs(CertDir) of
        {error, no_openssl} ->
            {skip, "openssl not available"};
        ok ->
            EP = pick(),
            TP = pick(),
            ok = chappe_sip:start(#{
                contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>,
                tls => #{contact => <<"sips:127.0.0.1:",
                                      (integer_to_binary(TP))/binary,
                                      ";transport=tls">>,
                         cert_dir => list_to_binary(CertDir)}}),
            ok = chappe_sip:options(fun(_Req, Res) ->
                chappe_sip_res:send(Res, 200, #{reason => <<"OK">>})
            end),
            {ok, Sock} = gen_udp:open(0, [binary, {active, true},
                                          {ip, {127,0,0,1}}]),
            P = integer_to_binary(lport(Sock)),
            gen_udp:send(Sock, {127,0,0,1}, EP, options_udp(P)),
            receive
                {udp, Sock, _, _, <<"SIP/2.0 200", _/binary>>} -> ok
            after 5000 -> ct:fail(no_udp_answer)
            end,
            gen_udp:close(Sock)
    end.

%% ---- helpers ----

gen_certs(Dir) ->
    Key = filename:join(Dir, "key.pem"),
    Cert = filename:join(Dir, "cert.pem"),
    Cmd = lists:flatten(io_lib:format(
        "openssl req -x509 -newkey rsa:2048 -keyout ~ts -out ~ts -days 2 "
        "-nodes -subj '/CN=127.0.0.1' 2>/dev/null", [Key, Cert])),
    _ = os:cmd(Cmd),
    case filelib:is_file(Cert) andalso filelib:is_file(Key) of
        false ->
            {error, no_openssl};
        true ->
            {ok, CertBin} = file:read_file(Cert),
            {ok, KeyBin} = file:read_file(Key),
            ok = file:write_file(filename:join(Dir, "agent.pem"),
                                 [CertBin, KeyBin]),
            ok = file:write_file(filename:join(Dir, "cafile.pem"), CertBin),
            ok
    end.

pick() -> 40000 + rand:uniform(20000).
lport(Sock) -> {ok, P} = inet:port(Sock), P.

options_req() ->
    <<"OPTIONS sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/TLS 127.0.0.1:12345;branch=z9hG4bKtls1\r\n"
      "Max-Forwards: 70\r\n"
      "From: <sip:p@127.0.0.1>;tag=t1\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Call-ID: tls-test@ct\r\n"
      "CSeq: 1 OPTIONS\r\nContent-Length: 0\r\n\r\n">>.

options_udp(P) ->
    <<"OPTIONS sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=z9hG4bKu1\r\n"
      "Max-Forwards: 70\r\n"
      "From: <sip:p@127.0.0.1:", P/binary, ">;tag=t2\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Call-ID: udp-test-", P/binary, "@ct\r\n"
      "CSeq: 1 OPTIONS\r\nContent-Length: 0\r\n\r\n">>.
