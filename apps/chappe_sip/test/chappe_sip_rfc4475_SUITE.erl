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
         mandatory_headers_validated/1, deep_parse_defects/1]).

all() ->
    [corpus_present, parse_never_crashes, wellformed_accepted,
     malformed_startline_rejected, wellformed_fields,
     mandatory_headers_validated, deep_parse_defects].

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
