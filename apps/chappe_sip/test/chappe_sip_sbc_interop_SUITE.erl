%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The B2BUA as an SBC against real peers: SIPp calls through a chappe SBC
%% node to two FreeSWITCH nodes (a peer group kept alive with OPTIONS),
%% with rtpengine anchoring the calls that ask for it and Kamailio pinging
%% the node and pinged by it. The lab is apps/chappe_sip/interop/sbc
%% (lab.sh, docker-compose.yml, the node module chappe_sbc_node); the
%% suite brings it up, runs one SIPp call per case and asks the node what
%% it saw with erl_call.
%%
%% Opt-in: INTEROP=1 and docker. SBC_LAB names the compose project
%% (default chappe-sbc); SBC_KEEP=1 leaves the lab up afterwards.
-module(chappe_sip_sbc_interop_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, suite/0, init_per_suite/1, end_per_suite/1]).
-export([direct_call/1, anchored_call/1, hold_from_sipp/1, hold_from_fs/1,
         offerless_reinvite/1, update_offer/1, glare/1,
         set_media_both_ways/1, session_timer_refresh/1,
         options_failover/1, kamailio_pings/1, replace_b/1,
         fork_webrtc_and_plain/1]).

all() ->
    case os:getenv("INTEROP") of
        "1" ->
            [kamailio_pings, direct_call, anchored_call, hold_from_sipp,
             hold_from_fs, offerless_reinvite, update_offer, glare,
             set_media_both_ways, session_timer_refresh, replace_b,
             fork_webrtc_and_plain,
             options_failover];
        _ ->
            {skip, "set INTEROP=1 (needs docker) to run the SBC lab"}
    end.

suite() ->
    [{timetrap, {minutes, 20}}].

init_per_suite(Config) ->
    case os:find_executable("docker") of
        false ->
            {skip, "docker not found"};
        _ ->
            Lab = lab(Config),
            [ok = run(Lab, Step, 1200000) || Step <- ["images", "build", "up"]],
            [{lab, Lab} | Config]
    end.

end_per_suite(Config) ->
    _ = case os:getenv("SBC_KEEP") of
            "1" -> ok;
            _ -> run(?config(lab, Config), "down", 120000)
        end,
    ok.

lab(Config) ->
    Data = ?config(data_dir, Config),
    %% the suite's data dir is a copy; the lab is in the source tree
    Root = filename:join(lists:takewhile(fun(P) -> P =/= "_build" end,
                                         filename:split(Data))),
    filename:join([Root, "apps", "chappe_sip", "interop", "sbc", "lab.sh"]).

%% ---- cases ----

%% Kamailio's dispatcher pings the node, and the node pings Kamailio (a
%% peer of group kam): both see the other up.
kamailio_pings(Config) ->
    Lab = ?config(lab, Config),
    ok = until(fun() -> has(cmd(Lab, "logs"), "options from 10.253.9.40") end, 30),
    ok = until(fun() -> lists:member({kam, up}, ctl(Lab, "peers", "[]")) end, 30),
    ok = until(fun() -> has(cmd(Lab, "kam"), "FLAGS: AP") orelse
                            has(cmd(Lab, "kam"), "FLAGS: A") end, 30).

%% A direct call: the SDP SIPp gets names FreeSWITCH.
direct_call(Config) ->
    Lab = ?config(lab, Config),
    Cid = "direct-1@lab",
    Pid = sipp(Lab, "sbc_call", "direct", 3000, Cid),
    ok = until(fun() -> mode(Lab, Cid) =:= direct end, 20),
    Out = done(Pid),
    ?assert(has(answer(Out), "c=IN IP4 10.253.9.3")).

%% An anchored call: the SDP SIPp gets names rtpengine, and rtpengine
%% relays FreeSWITCH's tone.
anchored_call(Config) ->
    Lab = ?config(lab, Config),
    Cid = "anchor-1@lab",
    Pid = sipp(Lab, "sbc_call", "anchor", 4000, Cid),
    ok = until(fun() -> mode(Lab, Cid) =:= anchor end, 20),
    ok = until(fun() -> packets(Lab, Cid) > 0 end, 10),
    Out = done(Pid),
    ?assert(has(answer(Out), "c=IN IP4 10.253.9.20")).

%% SIPp's re-INVITE with a=sendonly, then a=sendrecv: the SBC relays both
%% and reports hold and unhold of leg a.
hold_from_sipp(Config) ->
    Lab = ?config(lab, Config),
    Cid = "hold-a-1@lab",
    _ = done(sipp(Lab, "sbc_hold", "anchor", 1000, Cid)),
    Events = ctl(Lab, "events", "[\"" ++ Cid ++ "\"]"),
    ?assert(lists:member({hold, a}, Events)),
    ?assert(lists:member({unhold, a}, Events)).

%% FreeSWITCH holds the call (uuid_hold) and takes it off: its re-INVITEs
%% reach SIPp through the SBC, which reports hold and unhold of leg b.
hold_from_fs(Config) ->
    Lab = ?config(lab, Config),
    Cid = "hold-b-1@lab",
    Pid = sipp(Lab, "sbc_wait_reinvite", "direct", 1000, Cid),
    ok = until(fun() -> mode(Lab, Cid) =:= direct end, 20),
    {N, Uuid} = fs_channel(Lab),
    _ = cmd(Lab, "fs " ++ N ++ " 'uuid_hold " ++ Uuid ++ "'"),
    ok = until(fun() -> lists:member({hold, b}, events(Lab, Cid)) end, 15),
    _ = cmd(Lab, "fs " ++ N ++ " 'uuid_hold off " ++ Uuid ++ "'"),
    ok = until(fun() -> lists:member({unhold, b}, events(Lab, Cid)) end, 15),
    _ = done(Pid).

%% SIPp's re-INVITE without an offer: FreeSWITCH's offer comes back
%% through the SBC in the 2xx, SIPp's answer goes on in the ACK.
offerless_reinvite(Config) ->
    _ = done(sipp(?config(lab, Config), "reinvite_offerless", "uas", 1000,
                  "offerless-1@lab")).

%% An UPDATE with an offer in the confirmed call, answered by FreeSWITCH.
update_offer(Config) ->
    _ = done(sipp(?config(lab, Config), "update_offer", "uas", 1000,
                  "update-1@lab")).

%% The SBC re-INVITEs SIPp right after the ACK (set_media), SIPp's own
%% re-INVITE crosses it: each side gets 491 (RFC 3261 14.2).
glare(Config) ->
    _ = done(sipp(?config(lab, Config), "glare", "glare", 1000, "glare-1@lab")).

%% A direct call goes anchored mid-call and back: SIPp takes the SBC's
%% offerless re-INVITEs, rtpengine relays packets while anchored.
set_media_both_ways(Config) ->
    Lab = ?config(lab, Config),
    Cid = "switch-1@lab",
    Pid = sipp(Lab, "sbc_wait_reinvite", "direct", 1000, Cid),
    ok = until(fun() -> mode(Lab, Cid) =:= direct end, 20),
    ?assertEqual(ok, ctl(Lab, "set_media", "[\"" ++ Cid ++ "\", anchor]")),
    ?assertEqual(anchor, mode(Lab, Cid)),
    ok = until(fun() -> packets(Lab, Cid) > 0 end, 10),
    ?assertEqual(ok, ctl(Lab, "set_media", "[\"" ++ Cid ++ "\", direct]")),
    ?assertEqual(direct, mode(Lab, Cid)),
    _ = done(Pid).

%% SIPp refreshes its session timer (RFC 4028) through the SBC; the A leg
%% answers it and no BYE comes before the refreshed expiry.
session_timer_refresh(Config) ->
    _ = done(sipp(?config(lab, Config), "st_refresh_uac", "uas", 1000,
                  "st-1@lab"), 150000).

%% An anchored call on fs1 moves to fs2 (replace_b/3): SIPp sees no
%% re-INVITE (its scenario takes none), fs2 gets the call and fs1 its BYE,
%% rtpengine keeps relaying, and SIPp's BYE ends the call on fs2.
replace_b(Config) ->
    Lab = ?config(lab, Config),
    Cid = "replace-1@lab",
    Pid = sipp(Lab, "sbc_call", "anchor", 8000, Cid),
    ok = until(fun() -> mode(Lab, Cid) =:= anchor end, 20),
    ok = until(fun() -> channels(Lab, "1") =:= 1 end, 10),
    ?assertEqual(ok, ctl(Lab, "replace_b", "[\"" ++ Cid ++ "\", fs2]")),
    ?assert(lists:member({replaced, b}, events(Lab, Cid))),
    ok = until(fun() -> channels(Lab, "2") =:= 1 end, 10),
    ok = until(fun() -> channels(Lab, "1") =:= 0 end, 10),
    Before = packets(Lab, Cid),
    ok = until(fun() -> packets(Lab, Cid) > Before end, 10),
    _ = done(Pid),
    ok = until(fun() -> channels(Lab, "2") =:= 0 end, 10).

%% An anchored fork with a WebRTC-flagged branch and a plain one against
%% the real rtpengine: each branch has its own offer (via-branch), the
%% plain branch (FreeSWITCH) answers under its via-branch, SIPp gets
%% rtpengine's address and rtpengine relays the tone.
fork_webrtc_and_plain(Config) ->
    Lab = ?config(lab, Config),
    Cid = "fork-1@lab",
    Pid = sipp(Lab, "sbc_call", "fork", 4000, Cid),
    ok = until(fun() -> mode(Lab, Cid) =:= anchor end, 20),
    ?assert(lists:member({winner, 2}, events(Lab, Cid))),
    ok = until(fun() -> packets(Lab, Cid) > 0 end, 10),
    Out = done(Pid),
    ?assert(has(answer(Out), "c=IN IP4 10.253.9.20")).

%% fs1 stops: its peer goes down, and the next call lands on fs2; fs1
%% comes back up.
options_failover(Config) ->
    Lab = ?config(lab, Config),
    _ = cmd(Lab, "stop fs1"),
    ok = until(fun() -> lists:member({fs1, down}, ctl(Lab, "peers", "[]")) end, 30),
    Out = done(sipp(Lab, "sbc_call", "direct", 1000, "failover-1@lab")),
    ?assert(has(answer(Out), "c=IN IP4 10.253.9.32")),
    _ = cmd(Lab, "start fs1"),
    ok = until(fun() -> lists:member({fs1, up}, ctl(Lab, "peers", "[]")) end, 60).

%% ---- helpers ----

run(Lab, Args, Timeout) ->
    Self = self(),
    Pid = spawn(fun() -> Self ! {self(), sh(Lab ++ " " ++ Args)} end),
    receive
        {Pid, {0, _}} -> ok;
        {Pid, {Rc, Out}} -> ct:log("~s ~s: rc=~p~n~s", [Lab, Args, Rc, Out]),
                            {error, Rc}
    after Timeout -> ct:fail({timeout, Args})
    end.

cmd(Lab, Args) ->
    {_, Out} = sh(Lab ++ " " ++ Args),
    Out.

sh(Cmd) ->
    Env = case os:getenv("SBC_LAB") of
              false -> "";
              Name -> "SBC_LAB=" ++ Name ++ " "
          end,
    Out = os:cmd(Env ++ Cmd ++ " 2>&1; echo \"\nrc=$?\""),
    [Rc | Rev] = lists:reverse(string:split(string:trim(Out), "\n", all)),
    {list_to_integer(string:prefix(Rc, "rc=")), lists:join("\n", lists:reverse(Rev))}.

%% an erl_call on the node, its result read back as a term
ctl(Lab, Fun, Args) ->
    Out = string:trim(lists:flatten(cmd(Lab, "ctl " ++ Fun ++ " '" ++ Args ++ "'"))),
    case erl_scan:string(Out ++ ".") of
        {ok, Toks, _} ->
            case erl_parse:parse_term(Toks) of
                {ok, T} -> T;
                _ -> {unparsed, Out}
            end;
        _ -> {unparsed, Out}
    end.

mode(Lab, Cid) ->
    case ctl(Lab, "calls", "[]") of
        L when is_list(L) -> proplists:get_value(Cid, L);
        _ -> undefined
    end.

packets(Lab, Cid) ->
    case ctl(Lab, "query", "[\"" ++ Cid ++ "\"]") of
        N when is_integer(N) -> N;
        _ -> 0
    end.

events(Lab, Cid) ->
    case ctl(Lab, "events", "[\"" ++ Cid ++ "\"]") of
        L when is_list(L) -> L;
        _ -> []
    end.

%% how many channels fsN has (fs_cli's "N total.")
channels(Lab, N) ->
    Out = lists:flatten(cmd(Lab, "fs " ++ N ++ " 'show channels count'")),
    case re:run(Out, "([0-9]+) total", [{capture, all_but_first, list}]) of
        {match, [C]} -> list_to_integer(C);
        nomatch -> -1
    end.

%% the FreeSWITCH node with a channel, and that channel's uuid
fs_channel(Lab) ->
    Found = [{N, Uuid} || N <- ["1", "2"],
                          Line <- [lists:nth(2, string:split(
                                                  cmd(Lab, "fs " ++ N ++ " 'show channels'")
                                                  ++ "\n\n", "\n", all))],
                          [Uuid | _] <- [string:split(Line, ",")],
                          length(Uuid) =:= 36],
    case Found of
        [F | _] -> F;
        [] -> ct:fail(no_fs_channel)
    end.

sipp(Lab, Scen, User, Pause, Cid) ->
    Self = self(),
    Args = lists:flatten(io_lib:format("sipp ~s ~s ~b ~s", [Scen, User, Pause, Cid])),
    spawn(fun() -> Self ! {sipp, self(), sh(Lab ++ " " ++ Args)} end).

done(Pid) -> done(Pid, 90000).

done(Pid, Timeout) ->
    receive
        {sipp, Pid, {Rc, Out}} ->
            ct:log("~s", [Out]),
            ?assertEqual(0, Rc),
            lists:flatten(Out)
    after Timeout -> ct:fail(sipp_timeout)
    end.

%% the first 200 SIPp received, where the answer's c= line is
answer(Out) ->
    case string:find(Out, "SIP/2.0 200") of
        nomatch -> "";
        Rest -> string:slice(Rest, 0, 1500)
    end.

has(Text, Part) -> string:find(lists:flatten(Text), Part) =/= nomatch.

until(_Fun, 0) -> {error, timeout};
until(Fun, N) ->
    case try Fun() catch _:_ -> false end of
        true -> ok;
        _ -> timer:sleep(1000), until(Fun, N - 1)
    end.
