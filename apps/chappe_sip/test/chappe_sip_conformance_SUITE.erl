%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Conformance against independent SIP stacks. A chappe node, SIPp and
%% pjsua run on one docker network with a dnsmasq server the node resolves
%% through (interop/conformance/lab.sh); each case
%% plays one flow and asserts the exact headers the RFCs require. The SIPp
%% scenarios are interop/sipp/scenarios/<case>.xml: a regexp action with
%% check_it fails the call on any mismatch, so a case passes only when the
%% whole flow went as the RFC says. The hep group checks the node's HEP
%% capture against heplify-server, the Homer capture server.
%%
%% Opt-in: runs only with CONFORMANCE=1 (make interop-conformance) and
%% skips when docker is absent. A case listed in
%% interop/conformance/expected-fail is a feature not built yet: its
%% failure is reported as a skip with the reason from the list, and a pass
%% fails the case so the list is kept honest. Never weaken a scenario to
%% make it pass; fix chappe and remove the line.
%%
%% CONFORMANCE_NOBUILD=1 skips the image and node builds (they are cached
%% anyway, this only saves the checks).
-module(chappe_sip_conformance_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([
    all/0,
    groups/0,
    suite/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    options/1,
    unknown_method/1,
    unknown_method_indialog/1,
    trying_100/1,
    rport_response/1,
    rport_received/1,
    rport_request/1,
    bye_reason/1,
    reinvite_offer/1,
    reinvite_offerless/1,
    update_offer/1,
    glare/1,
    replaces_nomatch/1,
    replaces_confirmed/1,
    replaces_early/1,
    refer_notify/1,
    refer_event_id/1,
    refer_norefersub/1,
    focus_refer_add/1,
    focus_refer_norefersub/1,
    focus_refer_tdialog/1,
    focus_refer_retrans/1,
    st_negotiate/1,
    st_422/1,
    st_refresh_uac/1,
    st_refresh_uas/1,
    st_expiry/1,
    subscribe/1,
    subscribe_489/1,
    presence/1,
    mwi/1,
    dns_srv/1,
    dns_sips_failover/1,
    pjsua_refer_blind/1,
    pjsua_refer_attended/1,
    b2b_refer_refused/1,
    pjsua_b2b_refer_blind/1,
    pjsua_b2b_refer_attended/1,
    pjsua_session_timer/1,
    hep_capture/1
]).

suite() -> [{timetrap, {minutes, 5}}].

all() ->
    case os:getenv("CONFORMANCE") of
        false -> {skip, "conformance suite disabled; set CONFORMANCE=1"};
        _ -> [{group, sipp}, {group, pjsua}, {group, hep}]
    end.

groups() ->
    [
        {sipp, [], [
            options,
            unknown_method,
            unknown_method_indialog,
            trying_100,
            rport_response,
            rport_received,
            rport_request,
            bye_reason,
            reinvite_offer,
            reinvite_offerless,
            update_offer,
            glare,
            replaces_nomatch,
            replaces_confirmed,
            replaces_early,
            refer_notify,
            refer_event_id,
            refer_norefersub,
            focus_refer_add,
            focus_refer_norefersub,
            focus_refer_tdialog,
            focus_refer_retrans,
            b2b_refer_refused,
            st_negotiate,
            st_422,
            st_refresh_uac,
            st_refresh_uas,
            st_expiry,
            subscribe,
            subscribe_489,
            presence,
            mwi,
            dns_srv,
            dns_sips_failover
        ]},
        {pjsua, [], [
            pjsua_refer_blind,
            pjsua_refer_attended,
            pjsua_b2b_refer_blind,
            pjsua_b2b_refer_attended,
            pjsua_session_timer
        ]},
        {hep, [], [hep_capture]}
    ].

init_per_suite(Config) ->
    %% building the lab images takes longer than a case may on a busy
    %% runner; the cases keep the suite's 5 minutes. Each build step has
    %% its own, shorter, timeout so a step that hangs is named in the log
    %% before this timetrap fires.
    ct:timetrap({minutes, 40}),
    case docker_ready() of
        ok ->
            Dir = interop_dir(),
            Lab = filename:join([Dir, "conformance", "lab.sh"]),
            ok = build(Lab),
            [
                {lab, Lab},
                {interop_dir, Dir},
                {xfail, expected_fail(Dir)}
                | Config
            ];
        {skip, _} = Skip ->
            Skip
    end.

end_per_suite(Config) ->
    _ = lab(Config, ["down"], 60000),
    ok.

init_per_testcase(_Case, Config) ->
    {0, _} = lab(Config, ["up"], 60000),
    Config.

end_per_testcase(Case, Config) ->
    {_, Log} = lab(Config, ["logs"], 30000),
    ct:log("node output for ~p:~n~s", [Case, Log]),
    ok.

%% ---- methods ----

%% RFC 3261 11.2: the 200 to OPTIONS carries Allow (listing every method
%% the UA takes, 20.5) and Supported.
%% req: R3261-O-001 R3261-O-006 R3261-O-007 R3261-426
options(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 3261 21.5.2: an unrecognized method gets 501, not 405.
%% req: R3261-21.5.2-1
unknown_method(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 3261 12.2.2 hands in-dialog requests to 8.2: an unknown method in a
%% dialog gets 501 too.
%% req: R3261-21.5.2-1
unknown_method_indialog(Config) -> sipp(?FUNCTION_NAME, Config).

%% ---- transport ----

%% RFC 3261 17.2.1: 100 Trying when the TU takes longer than 200 ms.
%% req: R3261-309
trying_100(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 3581 4: rport filled in on the response Via, and the response goes
%% back to the source.
%% req: R3581-009 R3581-011 R3581-012
rport_response(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 3581 4: received on the response Via even when it equals the sent-by
%% host (deviation R3581-010, listed in expected-fail).
%% req: R3581-010
rport_received(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 3581 3: our requests put a valueless rport in their Via.
%% req: R3581-001 R3581-002
rport_request(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 3326 2: our BYE says why the call ended.
%% req: R3326-01 R3326-05
bye_reason(Config) -> sipp(?FUNCTION_NAME, Config).

%% ---- re-INVITE, UPDATE, glare ----

%% RFC 3261 14.2 and RFC 3264 6: a re-INVITE offer is answered in the 2xx.
%% req: R3261-238 R3261-239 R3264-031
reinvite_offer(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 3261 14.2 and 13.3.1: an offerless re-INVITE gets an offer in the
%% 2xx.
%% req: R3261-210 R3261-244 R3261-246
reinvite_offerless(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 3311 5.2: an UPDATE offer is answered in the 2xx.
%% req: R3311-009 R3311-010 R3311-011
update_offer(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 3261 14.2: an INVITE received while ours is pending gets 491.
%% req: R3261-237
glare(Config) -> sipp(?FUNCTION_NAME, Config).

%% ---- Replaces ----

%% RFC 3891 3: no matching dialog gives 481.
%% req: R3891-04
replaces_nomatch(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 3891 3: a confirmed dialog is replaced; the old one gets a BYE.
%% req: R3891-23 R3891-10
replaces_confirmed(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 3891 3: an early dialog the UA did not initiate gives 481.
%% req: R3891-12
replaces_early(Config) -> sipp(?FUNCTION_NAME, Config).

%% ---- REFER ----

%% RFC 7647 5: 200, never 202. RFC 3515 2.4.4 to 2.4.7: NOTIFYs with
%% Event: refer, a sipfrag body starting with a status line, a
%% Subscription-State, the last one terminated.
%% req: R7647-04 R3515-05 R3515-10 R3515-11 R3515-13 R3515-14 R3515-18 R3515-29
refer_notify(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 3515 2.4.6: a second REFER in the dialog is reported under
%% Event: refer;id=<its CSeq>.
%% req: R3515-22
refer_event_id(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 4488 4: Refer-Sub: false in the 2xx and no NOTIFY.
%% req: R4488-01 R4488-03
refer_norefersub(Config) -> sipp(?FUNCTION_NAME, Config).

%% ---- REFER to a conference focus ----

%% RFC 4579 5.5: a REFER to the conference URI is answered 200 (RFC 7647
%% 5) with the conference URI and isfocus as Contact, and the focus
%% INVITEs the target with that Contact; NOTIFY 100, then the final 200.
%% req: R4579-12 R7647-04 R3515-05 R3515-10 R3515-23
focus_refer_add(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 4488 4: Refer-Sub: false to the focus: 200 with Refer-Sub: false,
%% no NOTIFY, and the target is still brought in.
%% req: R4488-01
focus_refer_norefersub(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 7647 4, RFC 4538 4: a REFER outside the dialog naming a
%% participant's dialog with Target-Dialog is authorized by it; one whose
%% Target-Dialog names no dialog proves nothing (here: 403).
%% req: R7647-03 R4538-010 R4538-013 R4538-014
focus_refer_tdialog(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 3261 17.2.2: a retransmitted REFER to the focus gets the same 200
%% and is carried out once: one subscription, one INVITE.
%% req: R3515-27
focus_refer_retrans(Config) -> sipp(?FUNCTION_NAME, Config).

%% A B2BUA call (transfer => auto) refuses what it must not carry out:
%% an off-net target (403), a REFER for a BYE (403), several targets
%% (Require: multiple-refer, 420 with Unsupported), and the call goes on.
%% req: R5589-06 R5368-01 R5368-02
b2b_refer_refused(Config) -> sipp(?FUNCTION_NAME, Config).

%% ---- session timers ----

%% RFC 4028 9: Session-Expires with the refresher in the 2xx, and
%% Require: timer when the refresher is the UAC.
%% req: R4028-31 R4028-33 R4028-34 R4028-35
st_negotiate(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 4028 6 and 9: 422 with a Min-SE of at least 90 s, and the retry at
%% that Min-SE is accepted.
%% req: R4028-05 R4028-28 R4028-29 R4028-30 R4028-32
st_422(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 4028 9 and 10: the refresh 2xx carries Session-Expires and the
%% refresh restarts the timer (no BYE at the first interval's end).
%% req: R4028-31 R4028-41
st_refresh_uac(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 4028 9: as refresher, chappe refreshes before the interval ends.
%% req: R4028-37 R4028-38 R4028-21
st_refresh_uas(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 4028 10: no refresh, so chappe sends a BYE before expiry.
%% req: R4028-41 R4028-42
st_expiry(Config) -> sipp(?FUNCTION_NAME, Config).

%% ---- SUBSCRIBE ----

%% RFC 6665: 200 with Expires, an immediate NOTIFY with
%% Subscription-State active;expires, the same after a refresh, and a
%% terminated NOTIFY after Expires: 0.
%% req: R6665-01 R6665-02 R6665-03 R6665-09 R6665-12 R6665-15 R6665-23 R6665-26
subscribe(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 6665 4.2.1.1: 489 for a package not served, with Allow-Events.
%% req: R6665-07 R6665-16
subscribe_489(Config) -> sipp(?FUNCTION_NAME, Config).

%% ---- PUBLISH, presence, message waiting ----

%% RFC 3903 and RFC 3856: SIPp publishes a tuple (200 with Expires and a
%% SIP-ETag), refreshes it (a new SIP-ETag), subscribes to the presentity
%% (a NOTIFY with the tuple as application/pidf+xml), modifies it (a NOTIFY
%% with the new state), gets 412 for the replaced entity-tag, and
%% unsubscribes.
%% req: R3903-29 R3903-31 R3903-40 R3903-41 R3903-42 R3856-03 R3856-10
%% req: R3856-12
presence(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 3842: a message-summary SUBSCRIBE without Accept gets the summary
%% at once as application/simple-message-summary with the account, and a
%% new one when the account's counts change.
%% req: R3842-01 R3842-03 R3842-15 R3842-17 R3842-18
mwi(Config) -> sipp(?FUNCTION_NAME, Config).

%% ---- DNS (RFC 3263) ----

%% RFC 3261 8.1.2: a request to sip:uas@svc.lab goes where DNS says. The
%% lab's NAPTR for svc.lab points at _sip._udp.svc.lab, whose SRV names
%% uas.svc.lab port 5080; the OPTIONS must arrive there, over UDP.
%% req: R3261-033
dns_srv(Config) -> sipp(?FUNCTION_NAME, Config).

%% RFC 3261 8.1.2: for sips:uas@svcs.lab the first SRV target refuses the
%% connection; the node moves on to the second, and still uses TLS.
%% req: R3261-033 R3261-037
dns_sips_failover(Config) -> sipp(?FUNCTION_NAME, Config).

%% ---- pjsua ----

%% A pjsua caller blind-transfers its call with chappe to a second pjsua
%% agent (pjsua console `x'). RFC 3515: the REFER is accepted, chappe
%% INVITEs the target, and pjsua reports the transfer done from the NOTIFY
%% sipfrag.
%% req: R7647-04 R3515-05 R3515-10 R3515-14 R3515-18 R3515-23
pjsua_refer_blind(Config) -> pjsua(refer_blind, Config).

%% Attended transfer (pjsua console `X'): pjsua has a call with chappe and
%% one with a second agent, and REFERs chappe to the second with Replaces.
%% req: R7647-04 R3515-05 R3515-10 R3891-23
pjsua_refer_attended(Config) -> pjsua(refer_attended, Config).

%% RFC 5589 6 through the B2BUA: pjsua a calls pjsua b through chappe
%% (transfer => auto, media anchored); b blind-transfers a to pjsua c.
%% chappe calls c on b's side, a gets no INVITE, b gets the final NOTIFY
%% 200 and then a BYE.
%% req: R5589-01 R5589-02 R5589-03 R5589-04 R7647-04 R3515-23
pjsua_b2b_refer_blind(Config) -> pjsua(b2b_refer_blind, Config).

%% RFC 5589 7.3 through the B2BUA: a calls b and b calls c, both through
%% chappe; b transfers with Replaces. Both calls are chappe's, so the
%% two remote parties are joined through the anchor with no new INVITE;
%% b sees the final 200 and loses both calls.
%% req: R5589-10 R5589-02
pjsua_b2b_refer_attended(Config) -> pjsua(b2b_refer_attended, Config).

%% pjsua calls chappe with session timers on (--timer=2, 90 s): the 2xx
%% must carry Session-Expires, and pjsua's refresh before 45 s is taken.
%% req: R4028-31 R4028-34 R4028-37
pjsua_session_timer(Config) -> pjsua(session_timer, Config).

%% ---- HEP ----

%% heplify-server, the Homer capture server, stores a call made to the
%% node over each of UDP, TCP, TLS and WebSocket: for every Call-ID it
%% decoded messages the node sent and messages it received. sofia captures
%% the native transports, chappe_sip_hep the WebSocket one.
hep_capture(Config) ->
    {0, _} = lab(Config, ["hep", "up"], 300000),
    {0, _} = lab(Config, ["up"], 60000, [{"CHAPPE_HEP", "10.253.7.40:9060"}]),
    {Status, Out} = lab(Config, ["hep", "calls"], 120000),
    ct:log("hep calls exit ~p:~n~s", [Status, Out]),
    Calls = [
        {binary_to_atom(P), Id}
     || [P, Id] <- matches(Out, "hep call (udp|tcp|tls|ws) (hep-\\S+)")
    ],
    Stored = [{P, Id, stored(Config, Id, 30)} || {P, Id} <- Calls],
    ct:log("stored (sent, received) per call: ~p", [Stored]),
    Missing =
        [udp, tcp, tls, ws] --
            [
                P
             || {P, _, {S, R}} <- Stored,
                S >= 2,
                R >= 2
            ],
    verdict(
        ?FUNCTION_NAME,
        Missing =:= [],
        {missing, Missing, Stored},
        Config
    ).

%% (sent, received) rows heplify-server stored for CallId; it writes in
%% batches, so ask again until both are there
stored(Config, CallId, 0) ->
    sent_received(Config, CallId);
stored(Config, CallId, N) ->
    case sent_received(Config, CallId) of
        {S, R} when S >= 2, R >= 2 ->
            {S, R};
        _ ->
            timer:sleep(1000),
            stored(Config, CallId, N - 1)
    end.

sent_received(Config, CallId) ->
    {_, Out} = lab(Config, ["hep", "stored", binary_to_list(CallId)], 30000),
    case matches(Out, "^([0-9]+) ([0-9]+)") of
        [[S, R] | _] -> {binary_to_integer(S), binary_to_integer(R)};
        [] -> {0, 0}
    end.

matches(Out, Re) ->
    case
        re:run(Out, Re, [global, multiline, {capture, all_but_first, binary}])
    of
        {match, Ms} -> Ms;
        nomatch -> []
    end.

%% ---- SIPp ----

sipp(Case, Config) ->
    {Status, Out} = lab(Config, ["sipp", atom_to_list(Case)], 240000),
    ct:log("sipp ~p exit ~p:~n~s", [Case, Status, Out]),
    Alive = alive(Config),
    verdict(Case, Status =:= 0 andalso Alive, {Status, Alive}, Config).

%% The case result against the expected-fail list.
verdict(Case, Passed, Detail, Config) ->
    case {Passed, lists:keyfind(Case, 1, ?config(xfail, Config))} of
        {true, false} ->
            ok;
        {true, {_, Why}} ->
            ct:fail(
                {unexpected_pass, Case,
                    "remove it from interop/conformance/expected-fail", Why}
            );
        {false, false} ->
            ct:fail({failed, Case, Detail});
        {false, {_, Why}} ->
            {skip, "expected fail: " ++ Why}
    end.

alive(Config) ->
    {Status, _} = lab(Config, ["alive"], 30000),
    Status =:= 0.

%% ---- pjsua ----

%% The agents sit next to the node: caller 10.253.7.20, target .21, and
%% transfer ones (target of the transfer) .22. See interop/pjsua/agent.sh.
pjsua(Kind, Config) ->
    Script = filename:join([
        ?config(interop_dir, Config),
        "pjsua",
        "scenario.sh"
    ]),
    {Status, Out} = cmd(Script, [atom_to_list(Kind)], 240000),
    ct:log("pjsua ~p exit ~p:~n~s", [Kind, Status, Out]),
    Alive = alive(Config),
    verdict(
        list_to_atom("pjsua_" ++ atom_to_list(Kind)),
        Status =:= 0 andalso Alive,
        {Status, Alive},
        Config
    ).

%% ---- lab ----

build(Lab) ->
    case os:getenv("CONFORMANCE_NOBUILD") of
        false ->
            {0, _} = run_logged(Lab, ["images"], 1080000),
            {0, _} = run_logged(Lab, ["build"], 1080000),
            ok;
        _ ->
            ok
    end.

%% ct:pal, not ct:log: the CI job keeps no CT logs, so the start, the
%% exit and the output of each step must be in the job output
run_logged(Lab, Args, Timeout) ->
    T0 = erlang:monotonic_time(second),
    ct:pal("lab ~p: start", [Args]),
    {Status, Out} = R = cmd(Lab, Args, Timeout),
    ct:pal("lab ~p: exit ~p after ~p s:~n~s", [
        Args, Status, erlang:monotonic_time(second) - T0, Out
    ]),
    R.

lab(Config, Args, Timeout) ->
    lab(Config, Args, Timeout, []).

lab(Config, Args, Timeout, Env) ->
    cmd(?config(lab, Config), Args, Timeout, Env).

%% Run a script, return its exit status and output.
cmd(Script, Args, Timeout) ->
    cmd(Script, Args, Timeout, []).

cmd(Script, Args, Timeout, Env) ->
    Port = open_port(
        {spawn_executable, "/bin/sh"},
        [
            {args, [Script | Args]},
            {env, Env},
            exit_status,
            binary,
            stderr_to_stdout,
            use_stdio
        ]
    ),
    collect(Port, [], erlang:monotonic_time(millisecond) + Timeout).

collect(Port, Acc, Deadline) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, D}} ->
            collect(Port, [D | Acc], Deadline);
        {Port, {exit_status, S}} ->
            {S, iolist_to_binary(lists:reverse(Acc))}
    after Left ->
        true = port_close(Port),
        {timeout, iolist_to_binary(lists:reverse(Acc))}
    end.

docker_ready() ->
    case os:find_executable("docker") of
        false ->
            {skip, "docker not found on PATH"};
        _ ->
            case
                string:trim(
                    os:cmd(
                        "docker info >/dev/null 2>&1 "
                        "&& echo ok"
                    )
                )
            of
                "ok" -> ok;
                _ -> {skip, "docker daemon not running"}
            end
    end.

%% interop/conformance/expected-fail: `case  reason' per line, # comments.
expected_fail(Dir) ->
    File = filename:join([Dir, "conformance", "expected-fail"]),
    {ok, Bin} = file:read_file(File),
    Lines = string:split(Bin, "\n", all),
    [entry(L) || L <- Lines, is_entry(L)].

is_entry(L) ->
    case string:trim(L) of
        <<>> -> false;
        <<"#", _/binary>> -> false;
        _ -> true
    end.

entry(L) ->
    [Name | Rest] = string:split(string:trim(L), " "),
    {binary_to_atom(Name), binary_to_list(string:trim(iolist_to_binary(Rest)))}.

%% The suite's own source sits in apps/chappe_sip/test; interop/ is next
%% to it. CHAPPE_SIP_INTEROP_DIR overrides.
interop_dir() ->
    case os:getenv("CHAPPE_SIP_INTEROP_DIR") of
        false ->
            Src = proplists:get_value(source, ?MODULE:module_info(compile)),
            filename:join(
                filename:dirname(filename:dirname(Src)),
                "interop"
            );
        D ->
            D
    end.
