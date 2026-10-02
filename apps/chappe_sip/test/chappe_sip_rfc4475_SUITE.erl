%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% RFC 4475 SIP torture-test corpus.
%%
%% Drives chappe_sip_msg:parse/1 (and, in later phases, the URI/header parsers and
%% the mandatory-header validator) against the 50 bit-exact messages from
%% RFC 4475 Appendix A, vendored under chappe_sip_rfc4475_SUITE_data/rfc4475/. Each
%% message is classified by the outcome expected of our deliberately lenient
%% parser (see the data-dir README): well-formed messages must parse, malformed
%% ones must never crash, and those with a bad start line are rejected.
-module(chappe_sip_rfc4475_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([corpus_present/1, parse_never_crashes/1, wellformed_accepted/1,
         malformed_startline_rejected/1, wellformed_fields/1,
         mandatory_headers_validated/1, deep_parse_defects/1,
         stack_udp_responses/1, semiuri_user/1, message_syntax/1,
         uri_comparison/1, uri_format_escaping/1]).

all() ->
    [corpus_present, parse_never_crashes, wellformed_accepted,
     malformed_startline_rejected, wellformed_fields,
     mandatory_headers_validated, deep_parse_defects,
     stack_udp_responses, semiuri_user, message_syntax, uri_comparison,
     uri_format_escaping].

init_per_suite(Config) ->
    [{corpus, filename:join(?config(data_dir, Config), "rfc4475")} | Config].

end_per_suite(_Config) ->
    ok.

%% ---- classification (RFC 4475 message basenames, without .dat) ----

%% Syntactically valid: parse/1 must return {ok, _}. Covers section 3.1.1
%% (well-formed), 3.2 / 3.3 (valid syntax, transaction/application semantics),
%% and 3.4 (RFC 2543 backward compatibility).
valid_syntax() ->
    [wsinv, intmeth, esc01, escnull, esc02, lwsdisp, longreq, dblreq,
     semiuri, transports, mpart01, unreason, noreason,
     badbranch,
     insuf, unkscm, novelsc, unksm2, bext01, invut, regaut01, multi01,
     mcl01, bcast, zeromf, cparam01, cparam02, regescrt, sdp01,
     inv2543].

%% Section 3.1.2 malformed with a broken start line: must reject {error, _}.
%% test.dat is an unnumbered archive artifact whose request line has no
%% SIP-Version, so it lands here too.
malformed_startline() ->
    [badvers, bigcode, lwsruri, lwsstart, trws, test].

%% Section 3.1.2 malformed that our lenient parser accepts (Postel): it must
%% not crash and returns {ok, _}; the header/URI-level defects are caught by
%% the deep parsers, exercised in the parser unit tests.
malformed_tolerated() ->
    [badinv01, clerr, ncl, scalar02, scalarlg, quotbal, ltgtruri, escruri,
     baddate, regbadct, badaspec, baddn, mismatch01, mismatch02].

all_names() ->
    valid_syntax() ++ malformed_startline() ++ malformed_tolerated().

read(Config, Name) ->
    F = filename:join(?config(corpus, Config), atom_to_list(Name) ++ ".dat"),
    {ok, Bin} = file:read_file(F),
    Bin.

%% ---- cases ----

%% every message is present and accounted for by the classification
corpus_present(Config) ->
    {ok, Fs} = file:list_dir(?config(corpus, Config)),
    Dats = [F || F <- Fs, lists:suffix(".dat", F)],
    ?assertEqual(50, length(Dats)),
    ?assertEqual(50, length(all_names())),
    ?assertEqual(lists:sort([list_to_atom(filename:rootname(F)) || F <- Dats]),
                 lists:sort(all_names())).

%% the core robustness property: no input in the corpus throws
parse_never_crashes(Config) ->
    lists:foreach(fun(N) ->
        try chappe_sip_msg:parse(read(Config, N)) of
            {ok, _} -> ok;
            {error, _} -> ok;
            Other -> ct:fail({not_a_result, N, Other})
        catch Cl:Rn:St -> ct:fail({crash, N, Cl, Rn, St})
        end
    end, all_names()).

%% well-formed (and Postel-tolerated) messages parse
wellformed_accepted(Config) ->
    lists:foreach(fun(N) ->
        case chappe_sip_msg:parse(read(Config, N)) of
            {ok, _} -> ok;
            Other -> ct:fail({expected_ok, N, Other})
        end
    end, valid_syntax() ++ malformed_tolerated()).

%% a malformed start line is rejected
malformed_startline_rejected(Config) ->
    lists:foreach(fun(N) ->
        case chappe_sip_msg:parse(read(Config, N)) of
            {error, _} -> ok;
            Other -> ct:fail({expected_error, N, Other})
        end
    end, malformed_startline()).

%% spot-check that fields extract correctly from a few well-formed messages
wellformed_fields(Config) ->
    {ok, Inv} = chappe_sip_msg:parse(read(Config, wsinv)),
    ?assertEqual(request, chappe_sip_msg:type(Inv)),
    ?assertEqual(<<"INVITE">>, chappe_sip_msg:method(Inv)),
    {ok, NoReason} = chappe_sip_msg:parse(read(Config, noreason)),
    ?assertEqual(response, chappe_sip_msg:type(NoReason)),
    ?assertEqual(100, chappe_sip_msg:status(NoReason)),
    ?assertEqual(<<>>, chappe_sip_msg:reason(NoReason)),
    {ok, UnReason} = chappe_sip_msg:parse(read(Config, unreason)),
    ?assertEqual(200, chappe_sip_msg:status(UnReason)).

%% RFC 4475 3.3.1 (insuf): a message missing mandatory headers parses but
%% fails validation; a well-formed one passes.
mandatory_headers_validated(Config) ->
    {ok, Insuf} = chappe_sip_msg:parse(read(Config, insuf)),
    ?assertEqual({error, missing_header}, chappe_sip_msg:validate(Insuf)),
    {ok, Ws} = chappe_sip_msg:parse(read(Config, wsinv)),
    ?assertEqual(ok, chappe_sip_msg:validate(Ws)).

%% header/URI-level defects the lenient parse tolerates are caught when the
%% offending header is deep-parsed: an unterminated quoted display name
%% (quotbal) and an overlarge CSeq scalar (scalarlg).
deep_parse_defects(Config) ->
    {ok, Qb} = chappe_sip_msg:parse(read(Config, quotbal)),
    ?assertMatch({error, _},
                 chappe_sip_hdr:name_addr(chappe_sip_msg:get(<<"to">>, Qb))),
    {ok, Sl} = chappe_sip_msg:parse(read(Config, scalarlg)),
    ?assertMatch({error, _},
                 chappe_sip_hdr:cseq(chappe_sip_msg:get(<<"cseq">>, Sl))).

%% RFC 4475 3.1.1.10 (semiuri): the Request-URI's user part carries a ';'
%% and an escaped '@'; the parameters begin after the host.
%% req: R3261-U-09
semiuri_user(Config) ->
    {ok, M} = chappe_sip_msg:parse(read(Config, semiuri)),
    {ok, U} = chappe_sip_uri:parse(chappe_sip_msg:uri(M)),
    ?assertEqual(<<"user;par=u%40example.net">>, maps:get(user, U)),
    ?assertEqual(<<"example.com">>, maps:get(host, U)),
    ?assertEqual(#{}, maps:get(params, U)),
    {ok, A} = chappe_sip_uri:parse(<<"sip:alice;day=tuesday@example.com">>),
    ?assertEqual({<<"alice;day=tuesday">>, <<"example.com">>},
                 {maps:get(user, A), maps:get(host, A)}).

%% Message syntax the parser enforces: a header name is a token, the
%% SIP-Version is case-insensitive, compact and long header names are the
%% same header, a request's CSeq names its own method, and a proxy adds
%% Max-Forwards: 70 to a request that has none.
%% req: R3261-U-01 R3261-U-02 R3261-U-03 R3261-U-04 R3261-U-06
message_syntax(_Config) ->
    Req = fun(Line, Extra) ->
        iolist_to_binary([Line, <<"\r\nVia: SIP/2.0/UDP h;branch=z9hG4bK1\r\n"
                                   "From: <sip:a@b>;tag=1\r\nTo: <sip:x@y>\r\n"
                                   "Call-ID: c@h\r\nCSeq: 1 OPTIONS\r\n">>,
                          Extra, <<"\r\n">>])
    end,
    ?assertEqual({error, malformed},
                 chappe_sip_msg:parse(Req(<<"OPTIONS sip:x@y SIP/2.0">>, <<"Bad Name: 1\r\n">>))),
    {ok, Lower} = chappe_sip_msg:parse(Req(<<"OPTIONS sip:x@y sip/2.0">>, <<>>)),
    ?assertEqual(ok, chappe_sip_msg:validate(Lower)),
    ?assertMatch({ok, _}, chappe_sip_msg:parse(<<"Sip/2.0 200 OK\r\n\r\n">>)),
    %% what we send is upper-case
    ?assertMatch(<<"OPTIONS sip:x@y SIP/2.0\r\n", _/binary>>,
                 iolist_to_binary(chappe_sip_msg:encode(Lower))),
    {ok, Compact} = chappe_sip_msg:parse(
                      Req(<<"OPTIONS sip:x@y SIP/2.0">>,
                          <<"a: *;audio\r\nj: *;video\r\nd: proxy\r\ny: abc\r\nn: <https://x>\r\n">>)),
    ?assertEqual(<<"*;audio">>, chappe_sip_msg:get(<<"Accept-Contact">>, Compact)),
    ?assertEqual(<<"*;video">>, chappe_sip_msg:get(<<"Reject-Contact">>, Compact)),
    ?assertEqual(<<"proxy">>, chappe_sip_msg:get(<<"Request-Disposition">>, Compact)),
    ?assertEqual(<<"abc">>, chappe_sip_msg:get(<<"Identity">>, Compact)),
    ?assertEqual(<<"<https://x>">>, chappe_sip_msg:get(<<"Identity-Info">>, Compact)),
    ?assertEqual({error, bad_cseq},
                 chappe_sip_msg:validate(
                   chappe_sip_msg:set(<<"CSeq">>, <<"1 INVITE">>, Lower))),
    {ok, Fwd} = chappe_sip_msg:decr_max_forwards(Lower),
    ?assertEqual(<<"70">>, chappe_sip_msg:get(<<"max-forwards">>, Fwd)).

%% RFC 3261 19.1.4 on its own examples: escaped and case variants match,
%% a header component, a port, a transport, a maddr or a different
%% security param do not. An escaped character in the host is not its
%% unescaped form (19.1.4).
%% req: R3261-U-10 R3261-397 R3261-396
uri_comparison(_Config) ->
    Eq = fun chappe_sip_uri:equal/2,
    ?assert(Eq(<<"sip:%61lice@atlanta.com;transport=TCP">>,
               <<"sip:alice@AtLanTa.CoM;Transport=tcp">>)),
    ?assert(Eq(<<"sip:carol@chicago.com">>, <<"sip:carol@chicago.com;newparam=5">>)),
    ?assert(Eq(<<"sip:alice@atlanta.com?subject=project%20x&priority=urgent">>,
               <<"sip:alice@atlanta.com?priority=urgent&subject=project%20x">>)),
    ?assertNot(Eq(<<"sip:carol@chicago.com">>,
                  <<"sip:carol@chicago.com?Subject=next%20meeting">>)),
    ?assertNot(Eq(<<"sip:bob@biloxi.com">>, <<"sip:bob@biloxi.com:5060">>)),
    ?assertNot(Eq(<<"sip:bob@biloxi.com">>, <<"sip:bob@biloxi.com;transport=udp">>)),
    ?assertNot(Eq(<<"SIP:ALICE@AtLanTa.CoM;Transport=udp">>,
                  <<"sip:alice@AtLanTa.CoM;Transport=UDP">>)),
    ?assertNot(Eq(<<"sip:carol@chicago.com;security=on">>,
                  <<"sip:carol@chicago.com;security=off">>)),
    ?assertNot(Eq(<<"sip:carol@chicago.com">>, <<"sip:carol@chicag%6F.com">>)).

%% ---- the corpus through the running stack ----

%% What RFC 4475 expects of a UA receiving each vector over UDP, as the
%% set of acceptable outcomes: a final status, `none' (no response: a
%% response message is discarded, 3.1.2.x allow a malformed datagram to be
%% dropped), or `any' (any final status, the vector only has to leave the
%% stack running). The node runs handlers for INVITE (486), OPTIONS and
%% MESSAGE (200) and a registrar, so a well-formed request meets a real
%% handler and the stack's own checks come first.
rfc4475_expect() ->
    Valid = [valid],
    #{
      %% 3.1.1 well-formed: a final response other than 400
      wsinv => Valid, esc01 => Valid, escnull => Valid, lwsdisp => Valid,
      dblreq => Valid, semiuri => Valid, transports => Valid,
      mpart01 => Valid, unreason => [none], noreason => [none],
      %% Via over TCP (or TLS): the response goes over a connection we do
      %% not hold, so only the node's survival is checked
      intmeth => [any, none], esc02 => [any, none], longreq => [any, none],
      trws => [any, none], scalar02 => [any, none], unkscm => [any, none],
      novelsc => [any, none], regaut01 => [any, none],
      bext01 => [any, none], scalarlg => [none],
      %% 3.1.2 malformed requests: 400, except where the RFC allows
      %% another answer or a drop
      badinv01 => [400], clerr => [400], ncl => [400, none],
      quotbal => [400], ltgtruri => [400, none], lwsruri => [400],
      lwsstart => [400, none, valid], escruri => [400, valid],
      baddate => [400, valid], regbadct => [400, valid],
      badaspec => [400, valid], baddn => [400], badvers => [505],
      mismatch01 => [400], mismatch02 => [501, 400], bigcode => [none],
      %% 3.3 transaction and application layer semantics
      badbranch => [any], insuf => [400], unksm2 => [400, 404, 416],
      invut => [415], multi01 => [400], mcl01 => [400, none],
      bcast => [none], zeromf => Valid, cparam01 => Valid,
      cparam02 => Valid, regescrt => Valid, sdp01 => [400, 406, valid],
      %% 3.4 RFC 2543 backward compatibility
      inv2543 => Valid,
      test => [400, none]
    }.

%% Where the stack does not meet rfc4475_expect/0 today: the outcome it
%% gives and why. A vector here that starts to conform fails the case, so
%% the list only shrinks.
rfc4475_known() ->
    #{
      %% sofia cannot parse the Via (empty parameters), so it has nowhere
      %% to send the 400 and drops the request (3.1.2.1 wants a 400)
      badinv01 => none,
      %% SIP/7.0 in the start line and the Via: dropped, no 505 (3.1.2.16)
      badvers => none,
      %% LWS inside the Request-URI: dropped, no 400 (3.1.2.8)
      lwsruri => none
    }.

%% Every vector of the corpus sent over UDP to a running stack
%% (sofia's nta through the NIF), from a socket on the vector's Via
%% sent-by port so the response comes back to it. The stack must answer
%% as RFC 4475 describes and stay up; an OPTIONS round trip at the end
%% proves it is still serving.
%% req: R3261-373 R3261-360 R3261-361 R3261-368
stack_udp_responses(Config) ->
    Socks = listen_sockets([5050, 5060, 5070]),
    case Socks of
        {error, Port} ->
            {skip, io_lib:format("UDP 127.0.0.1:~b is busy", [Port])};
        _ ->
            try stack_udp_responses(Config, Socks)
            after
                [gen_udp:close(S) || S <- maps:values(Socks)],
                _ = chappe_sip:stop(),
                _ = chappe_sip_engine:reset_routes(),
                _ = application:stop(chappe_sip),
                application:unset_env(chappe_sip, engine_mod,
                                      [{persistent, true}])
            end
    end.

stack_udp_responses(Config, Socks) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Port = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => iolist_to_binary(
                                         ["sip:127.0.0.1:",
                                          integer_to_list(Port)])}),
    ok = chappe_sip:invite(reply(486)),
    ok = chappe_sip:options(reply(200)),
    ok = chappe_sip:message(reply(200)),
    ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})),
    Expect = rfc4475_expect(),
    Known = rfc4475_known(),
    Seen = [{N, send_vector(read(Config, N), Socks, Port)}
            || N <- lists:sort(all_names())],
    ct:log("outcomes: ~p", [Seen]),
    Bad = [{N, Got, maps:get(N, Expect)}
           || {N, Got} <- Seen,
              not conforms(Got, maps:get(N, Expect)),
              maps:get(N, Known, undefined) =/= Got],
    Fixed = [{N, Got} || {N, Got} <- Seen,
                         maps:is_key(N, Known),
                         conforms(Got, maps:get(N, Expect))],
    ?assertEqual([], Bad),
    ?assertEqual([], Fixed),
    %% still serving
    ?assertEqual(200, send_vector(options_probe(Port), Socks, Port)).

reply(Status) ->
    fun(_Req, Res) -> chappe_sip_res:send(Res, Status) end.

conforms(Got, Accept) ->
    lists:any(fun(A) -> accepts(A, Got) end, Accept).

accepts(any, S) -> is_integer(S);
accepts(valid, S) -> is_integer(S) andalso S =/= 400;
accepts(A, S) -> A =:= S.

listen_sockets(Ports) ->
    lists:foldl(
      fun(_, {error, _} = E) -> E;
         (P, Acc) ->
              case gen_udp:open(P, [binary, {ip, {127, 0, 0, 1}},
                                    {active, false}]) of
                  {ok, S} -> Acc#{P => S};
                  {error, _} ->
                      [gen_udp:close(S) || S <- maps:values(Acc)],
                      {error, P}
              end
      end, #{}, Ports).

%% Send one datagram from the socket of its Via port and return the first
%% final status for it that comes back within a second, or none. The
%% Call-ID tells its responses from the retransmitted finals of earlier
%% INVITEs, which nobody ACKs.
send_vector(Bin, Socks, Port) ->
    S = maps:get(via_port(Bin), Socks, maps:get(5060, Socks)),
    [flush(X) || X <- maps:values(Socks)],
    ok = gen_udp:send(S, {127, 0, 0, 1}, Port, Bin),
    first_final(S, call_id(Bin), erlang:monotonic_time(millisecond) + 1000).

first_final(S, CallId, Deadline) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    case Left > 0 andalso gen_udp:recv(S, 0, Left) of
        {ok, {_, _, Data}} ->
            Ours = CallId =:= any orelse CallId =:= call_id(Data),
            case {status(Data), Ours} of
                {N, true} when is_integer(N), N >= 200 -> N;
                _ -> first_final(S, CallId, Deadline)
            end;
        _ ->
            none
    end.

status(Data) ->
    case re:run(Data, "^SIP/2\\.0 ([0-9]{3}) ",
                [{capture, all_but_first, binary}]) of
        {match, [St]} -> binary_to_integer(St);
        nomatch -> undefined
    end.

call_id(Bin) ->
    case re:run(Bin, "\\n(?:Call-ID|i)[ \\t]*:[ \\t]*([^\\r\\n]+)",
                [caseless, {capture, all_but_first, binary}]) of
        {match, [C]} -> string:trim(C);
        nomatch -> any
    end.

flush(S) ->
    case gen_udp:recv(S, 0, 0) of
        {ok, _} -> flush(S);
        {error, _} -> ok
    end.

%% the port of the top Via's sent-by, 5060 when it has none
via_port(Bin) ->
    case re:run(Bin, "\\n(?:Via|v)[ \\t]*:[^\\n]*?/[ \\t]*(?:UDP|udp)"
                     "[ \\t]+[^ \\t;:\\r\\n]+:([0-9]+)",
                [{capture, all_but_first, binary}]) of
        {match, [P]} -> binary_to_integer(P);
        nomatch -> 5060
    end.

options_probe(Port) ->
    P = integer_to_binary(Port),
    <<"OPTIONS sip:probe@127.0.0.1:", P/binary, " SIP/2.0\r\n",
      "Via: SIP/2.0/UDP 127.0.0.1:5060;branch=z9hG4bK-4475-probe\r\n",
      "From: <sip:probe@127.0.0.1:5060>;tag=4475\r\n",
      "To: <sip:probe@127.0.0.1:", P/binary, ">\r\n",
      "Call-ID: rfc4475-probe@127.0.0.1\r\n",
      "CSeq: 1 OPTIONS\r\n",
      "Max-Forwards: 70\r\n",
      "Content-Length: 0\r\n\r\n">>.

%% A URI built from raw components is written with every character outside
%% each component's set (RFC 3261 25.1: user, password, paramchar,
%% hnv-unreserved) percent-escaped and existing escapes kept; a URI that
%% parses is written back as it came, and a parameter named twice is
%% written once.
%% req: R3261-393 R3261-394 R3261-395
uri_format_escaping(_Config) ->
    F = fun chappe_sip_uri:format/1,
    Sip = fun(M) -> maps:merge(#{scheme => sip, host => <<"h">>,
                                 params => #{}}, M) end,
    ?assertEqual(<<"sip:a%20b%40c%3A@h">>, F(Sip(#{user => <<"a b@c:">>}))),
    ?assertEqual(<<"sip:a&=+$,;/x-_.!~*'()@h">>,
                 F(Sip(#{user => <<"a&=+$,;/x-_.!~*'()">>}))),
    ?assertEqual(<<"sip:a%20b%3F100%25@h">>, F(Sip(#{user => <<"a%20b?100%">>}))),
    ?assertEqual(<<"sip:u:p%40ss%3Aw&=+$,@h">>,
                 F(Sip(#{user => <<"u">>, password => <<"p@ss:w&=+$,">>}))),
    ?assertEqual(<<"sip:h;x=a%20b%3Bc%3Dd;f%3Fg;y=[::1]/a:b&c+$">>,
                 F(Sip(#{params => #{<<"x">> => <<"a b;c=d">>,
                                     <<"f?g">> => true,
                                     <<"y">> => <<"[::1]/a:b&c+$">>},
                         '_porder' => [<<"x">>, <<"f?g">>, <<"y">>]}))),
    ?assertEqual(<<"sip:h?Subject=hi%20there%26%3D&Route=%3Csip:x%3E&e=&n">>,
                 F(Sip(#{headers => <<"Subject=hi there%26%3D&Route=<sip:x>&e=&n">>}))),
    ?assertEqual(<<"sip:h?a%3Bb=%40[]/?:+$">>,
                 F(Sip(#{headers => <<"a;b=@[]/?:+$">>}))),
    ?assertEqual(<<"tel:+1%20555-0100%3C">>,
                 F(#{scheme => tel, host => <<>>, user => <<"+1 555-0100<">>,
                     params => #{}})),
    %% what parses is written back byte for byte, and parses the same
    [begin
         {ok, U} = chappe_sip_uri:parse(B),
         ?assertEqual(B, F(U)),
         ?assertEqual({ok, U}, chappe_sip_uri:parse(F(U)))
     end || B <- [<<"sip:user;par=u%40example.net@example.com">>,
                  <<"sip:user@example.com?Route=%3Csip:example.com%3E">>,
                  <<"sips:alice:se%23cret@[::1]:5061;transport=tcp;lr"
                    "?Subject=a%20b&h=">>,
                  <<"sip:%61lice@atlanta.com;maddr=239.255.255.1;ttl=15">>,
                  <<"tel:+358-555-1234567;postd=pp22">>]],
    %% raw components: the escaped form parses, and is a fixed point
    [begin
         Out = F(U),
         {ok, P} = chappe_sip_uri:parse(Out),
         ?assertEqual(Out, F(P)),
         ?assertEqual({ok, P}, chappe_sip_uri:parse(F(P)))
     end || U <- [Sip(#{user => <<"a b@c">>, password => <<"x:y">>}),
                  Sip(#{params => #{<<"k">> => <<"v;w">>}}),
                  Sip(#{headers => <<"S=a b">>})]],
    %% a repeated parameter is written once
    {ok, Dup} = chappe_sip_uri:parse(<<"sip:h;a=1;b;a=2">>),
    ?assertEqual([<<"a">>, <<"b">>], maps:get('_porder', Dup)),
    ?assertEqual(<<"sip:h;a=2;b">>, F(Dup)),
    ?assertEqual(<<"sip:h;a=1">>,
                 F(Sip(#{params => #{<<"a">> => <<"1">>},
                         '_porder' => [<<"a">>, <<"a">>]}))).
