%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% chappe_mrf against real FreeSWITCH and rtpengine (the lab of
%% apps/chappe_mrf/interop, `make interop-mrf'). The suite is the chappe
%% node; its callers and callees are chappe_mrf_live_ua softphones on the
%% host, whose audio goes through rtpengine. Prompts are wav files of one
%% marker tone each, written to the shared /media, so a caller tells which
%% prompt played by the tone it hears. It runs only with MRF=1.
-module(chappe_mrf_live_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("kernel/include/file.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    ivr_menu/1,
    bridge_sip_target/1,
    bridge_shows_caller/1,
    fork_same_flags_second_answers/1,
    fork_own_flags_second_answers/1,
    fork_own_flags_first_answers/1,
    fork_same_flags_failed_then_bridge/1,
    fork_own_flags_failed_then_bridge/1,
    fork_same_flags_failed_keeps_callee/1,
    fork_own_flags_failed_keeps_callee/1,
    failed_bridge_other_interface/1,
    fork_again_after_win/1,
    fork_fails_after_win/1,
    reinvite_after_win/1,
    fork_after_create_b2bua_fork/1,
    endpoint_bridge/1,
    record_playback/1,
    stored_recordings/1,
    native_conference/1,
    native_endpoint/1,
    fs_conference/1,
    endpoint_verbs/1,
    fs_conference_record_transfer/1,
    native_conference_transfer/1,
    owner_killed/1,
    node_down_failover/1
]).

-define(UA, chappe_mrf_live_ua).
-define(RTPE, chappe_mrf_live_rtpe).

%% marker tones of the prompts
-define(MENU, 440).
-define(ONE, 700).
-define(TWO, 1100).
-define(PIN, 520).

all() ->
    [
        ivr_menu,
        bridge_sip_target,
        bridge_shows_caller,
        fork_same_flags_second_answers,
        fork_own_flags_second_answers,
        fork_own_flags_first_answers,
        fork_same_flags_failed_then_bridge,
        fork_own_flags_failed_then_bridge,
        fork_same_flags_failed_keeps_callee,
        fork_own_flags_failed_keeps_callee,
        failed_bridge_other_interface,
        fork_again_after_win,
        fork_fails_after_win,
        reinvite_after_win,
        fork_after_create_b2bua_fork,
        endpoint_bridge,
        record_playback,
        stored_recordings,
        native_conference,
        native_endpoint,
        fs_conference,
        endpoint_verbs,
        fs_conference_record_transfer,
        native_conference_transfer,
        owner_killed,
        node_down_failover
    ].

init_per_suite(Config) ->
    case os:getenv("MRF") of
        "1" -> setup(Config);
        _ -> {skip, "MRF=1 not set (make interop-mrf)"}
    end.

setup(Config) ->
    Env = fun(K, D) -> os:getenv(K, D) end,
    Int = fun(K, D) -> list_to_integer(Env(K, D)) end,
    Media = Env("MRF_MEDIA_DIR", "/tmp/chappe-mrf-media"),
    write_prompts(Media),
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif, [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_mrf),
    SipPort = Int("MRF_SIP_PORT", "17060"),
    ok = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(SipPort))/binary>>
    }),
    ok = chappe_mrf:start(#{esl_port => Int("MRF_SOCKET_PORT", "17084")}),
    ok = chappe_sip_media:configure(#{
        rtpengine => #{
            nodes => [#{name => ?RTPE, host => "127.0.0.1", port => Int("MRF_NG_PORT", "17222")}]
        },
        mix => #{ip => {0, 0, 0, 0}, advertise => Env("MRF_MEDIA_IP", "127.0.0.1")}
    }),
    Nodes = [
        {fs1, Int("MRF_FS1_ESL", "17031"), Int("MRF_FS1_SIP", "17081")},
        {fs2, Int("MRF_FS2_ESL", "17032"), Int("MRF_FS2_SIP", "17082")}
    ],
    ok = chappe_esl:node_subscribe(all),
    [
        ok = chappe_esl:node_add(N, #{
            host => "127.0.0.1",
            port => Esl,
            sip_uri => <<"sip:127.0.0.1:", (integer_to_binary(Sip))/binary>>,
            heartbeat_interval_ms => 1000,
            probe_interval_ms => 2000,
            backoff_max_ms => 2000,
            %% a room's own events (stop-recording, bgdial-result) come
            %% from the node's connection
            events => [<<"CUSTOM">>, <<"conference::maintenance">>]
        })
     || {N, Esl, Sip} <- Nodes
    ],
    [wait_node(N, up, 20000) || {N, _, _} <- Nodes],
    %% the nodes record into /media, which is Media here; recordings
    %% asked with store => default are adopted into the store from there
    ok = application:set_env(chappe_mrf, shared_dir, #{freeswitch => "/media", local => Media}),
    ok = chappe_audio_store:configure(#{dir => filename:join(?config(priv_dir, Config), "recordings")}),
    [{sip_port, SipPort}, {media, Media}, {compose, Env("MRF_COMPOSE", "")} | Config].

end_per_suite(_Config) ->
    _ = chappe_sip:stop(),
    _ = application:stop(chappe_mrf),
    _ = application:stop(chappe_esl),
    _ = application:stop(chappe_sip),
    ok.

init_per_testcase(_Case, Config) ->
    flush(),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = [chappe_mrf_conf:stop(C) || {_, C} <- chappe_mrf:conferences()],
    ok.

write_prompts(Dir) ->
    ok = filelib:ensure_path(Dir),
    ?UA:write_wav(filename:join(Dir, "menu.wav"), ?MENU, 4000),
    ?UA:write_wav(filename:join(Dir, "one.wav"), ?ONE, 4000),
    ?UA:write_wav(filename:join(Dir, "two.wav"), ?TWO, 4000),
    ?UA:write_wav(filename:join(Dir, "pin.wav"), ?PIN, 3000),
    %% mod_say_en's number files, under the lab's sound_prefix
    Digits = filename:join([Dir, "sounds", "digits"]),
    ok = filelib:ensure_path(Digits),
    [
        ?UA:write_wav(filename:join(Digits, integer_to_list(N) ++ ".wav"), 300, 500)
     || N <- lists:seq(0, 19) ++ lists:seq(20, 90, 10)
    ],
    ok.

%% ---- helpers ----

%% rtpengine's interfaces: callers and chappe_mix on the host, FreeSWITCH
%% on the docker network
to_fs() ->
    #{a => #{direction => [<<"docker">>, <<"host">>]}, b => #{direction => [<<"host">>, <<"docker">>]}}.

to_host() ->
    #{b => #{direction => [<<"host">>, <<"host">>]}}.

%% Every INVITE goes to the IVR: connect_caller/3, then Script(Ep, B2b)
%% runs in the handler, which owns the endpoint.
ivr(Script) ->
    ivr(Script, #{}).

ivr(Script, Extra) ->
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Opts = maps:merge(#{anchor_params => to_fs(), notify => Test}, Extra),
        case chappe_mrf:connect_caller(Req, Res, Opts) of
            {ok, Ep, B2b} ->
                Test ! {connected, Ep, B2b, self()},
                Script(Ep, B2b);
            Err ->
                Test ! {connect_failed, Err}
        end
    end).

%% a script that waits, forwarding the endpoint's events and running
%% what it is sent
park(_Ep, _B2b) ->
    park_loop().

park_loop() ->
    receive
        {run, From, Fun} ->
            From ! {ran, Fun()},
            park_loop();
        stop ->
            ok;
        _ ->
            park_loop()
    end.

in_owner(Owner, Fun) ->
    Owner ! {run, self(), Fun},
    receive
        {ran, R} -> R
    after 30000 -> ct:fail(owner_run)
    end.

call_in(Config, Freq) ->
    Ua = ?UA:call(?config(sip_port, Config), #{freq => Freq}),
    receive
        {connected, Ep, B2b, Owner} ->
            receive
                {ua, Ua, {final, 200}} -> {Ua, Ep, B2b, Owner}
            after 10000 -> ct:fail(no_200)
            end;
        {connect_failed, Err} ->
            ct:fail({connect_failed, Err})
    after 15000 -> ct:fail(no_connect)
    end.

ua_got(Ua, Event, Ms) ->
    receive
        {ua, Ua, Event} -> ok
    after Ms -> ct:fail({ua_missing, Event})
    end.

no_reinvite(Ua) ->
    receive
        {ua, Ua, reinvite} -> ct:fail(reinvite_seen)
    after 0 -> ok
    end.

wait_node(Node, State, Ms) when Ms =< 0 ->
    ct:fail({node_not, Node, State});
wait_node(Node, State, Ms) ->
    case lists:keyfind(Node, 1, chappe_esl:nodes()) of
        {_, State} ->
            ok;
        _ ->
            timer:sleep(200),
            wait_node(Node, State, Ms - 200)
    end.

flush() ->
    receive
        _ -> flush()
    after 0 -> ok
    end.

media(Config, File) ->
    filename:join(?config(media, Config), File).

%% ---- cases ----

%% The IVR plays the menu (its tone reaches the caller), the caller
%% presses 2 (RFC 2833 through rtpengine), play_collect returns it, and
%% the branch's prompt plays.
ivr_menu(Config) ->
    Test = self(),
    ivr(fun(Ep, _B2b) ->
        {ok, D} = chappe_mrf:play_collect(Ep, #{
            file => <<"/media/menu.wav">>, max => 1, timeout => 10000
        }),
        Test ! {digits, D},
        Prompt =
            case D of
                <<"1">> -> <<"/media/one.wav">>;
                _ -> <<"/media/two.wav">>
            end,
        _ = chappe_mrf:play(Ep, Prompt),
        park_loop()
    end),
    {Ua, _Ep, _B2b, Owner} = call_in(Config, none),
    ?assert(?UA:hears(Ua, ?MENU, 6000)),
    ?UA:dtmf(Ua, <<"2">>),
    receive
        {digits, <<"2">>} -> ok;
        {digits, Other} -> ct:fail({digits, Other})
    after 10000 -> ct:fail(no_digits)
    end,
    ?UA:clear(Ua),
    ?assert(?UA:hears(Ua, ?TWO, 6000)),
    no_reinvite(Ua),
    ?UA:bye(Ua),
    Owner ! stop.

%% bridge/3 to a SIP callee: audio flows both ways and the caller sees no
%% re-INVITE; the endpoint's channel goes.
bridge_sip_target(Config) ->
    ivr(fun park/2),
    {Ua, Ep, B2b, Owner} = call_in(Config, 600),
    Callee = ?UA:callee(#{freq => 900}),
    Uri = <<"sip:bob@127.0.0.1:", (integer_to_binary(?UA:port(Callee)))/binary>>,
    ok = chappe_mrf:bridge(B2b, Uri, #{anchor_params => to_host()}),
    ua_got(Callee, invite, 5000),
    ?assert(?UA:hears(Ua, 900, 6000)),
    ?assert(?UA:hears(Callee, 600, 6000)),
    no_reinvite(Ua),
    ?assertMatch({error, _}, chappe_mrf:play(Ep, <<"/media/one.wav">>)),
    ?UA:bye(Ua),
    ua_got(Callee, bye, 5000),
    Owner ! stop.

%% A softphone rung after the menu sees the caller, not this node.
bridge_shows_caller(Config) ->
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test ! {caller, chappe_sip_b2b_hdr:b_from(Req, #{})},
        {ok, Ep, B2b} = chappe_mrf:connect_caller(
            Req, Res, #{anchor_params => to_fs(), notify => Test}
        ),
        Test ! {connected, Ep, B2b, self()},
        park_loop()
    end),
    {Ua, _Ep, B2b, Owner} = call_in(Config, 600),
    Caller =
        receive
            {caller, C} -> C
        after 0 -> ct:fail(no_caller)
        end,
    Callee = ?UA:callee(#{freq => 900}),
    ok = chappe_mrf:bridge(B2b, callee_uri(Callee), #{
        from => Caller, anchor_params => to_host()
    }),
    From =
        receive
            {ua, Callee, {invite_from, F}} -> F
        after 5000 -> ct:fail(no_invite_from)
        end,
    [Sent, _Tag] = binary:split(From, <<";tag=">>),
    ?assertEqual(Caller, Sent),
    ?UA:bye(Ua),
    ua_got(Callee, bye, 5000),
    Owner ! stop.

%% ---- bridge/3 with {parallel, Dests} ----

callee_uri(Ua) ->
    <<"sip:bob@127.0.0.1:", (integer_to_binary(?UA:port(Ua)))/binary>>.

%% the same call for every destination: one offer, leg B's tag
same_flags(Uris) -> {parallel, Uris}.

%% flags of their own: one offer each, each under its via-branch
own_flags([First | Rest]) ->
    {parallel, [First | [{U, #{anchor_params => #{b => #{ptime => 20}}}} || U <- Rest]]}.

%% After a menu, the caller rings two softphones at once. It keeps hearing
%% the endpoint while they ring, Winner answers: audio goes through both
%% ways, the other gets a CANCEL and no audio, and the caller sees no
%% re-INVITE.
fork_after_menu(Config, Target, Winner) ->
    Test = self(),
    ivr(fun(Ep, _B2b) ->
        {ok, D} = chappe_mrf:play_collect(Ep, #{
            file => <<"/media/menu.wav">>, max => 1, timeout => 10000
        }),
        Test ! {digits, D},
        park_loop()
    end),
    {Ua, Ep, B2b, Owner} = call_in(Config, 600),
    ?assert(?UA:hears(Ua, ?MENU, 6000)),
    ?UA:dtmf(Ua, <<"1">>),
    receive
        {digits, <<"1">>} -> ok
    after 10000 -> ct:fail(no_digits)
    end,
    Answering = #{freq => 900, answer => {after_ms, 2500}},
    Ringing = #{freq => 1300, answer => ring},
    {U1, U2, WinnerUa, Loser} =
        case Winner of
            1 ->
                W = ?UA:callee(Answering),
                L = ?UA:callee(Ringing),
                {W, L, W, L};
            2 ->
                L = ?UA:callee(Ringing),
                W = ?UA:callee(Answering),
                {L, W, W, L}
        end,
    _ = spawn(fun() -> chappe_mrf:play(Ep, <<"/media/one.wav">>) end),
    Self = self(),
    _ = spawn(fun() ->
        Self ! {forked, chappe_mrf:bridge(
            B2b, Target([callee_uri(U1), callee_uri(U2)]),
            #{anchor_params => to_host()}
        )}
    end),
    ua_got(U1, invite, 5000),
    ua_got(U2, invite, 5000),
    ?UA:clear(Ua),
    ?assert(?UA:hears(Ua, ?ONE, 2000)),
    receive
        {forked, {ok, #{winner := #{index := Winner}}}} -> ok;
        {forked, Other} -> ct:fail({fork, Other})
    after 15000 -> ct:fail(no_fork_result)
    end,
    ua_got(Loser, cancel, 5000),
    ?UA:clear(Ua),
    ?assert(?UA:hears(Ua, 900, 6000)),
    ?assert(?UA:hears(WinnerUa, 600, 6000)),
    ?assert(?UA:silent(Ua, 1300, 500)),
    ?assert(?UA:silent(Loser, 600, 500)),
    no_reinvite(Ua),
    ?assertMatch({error, _}, chappe_mrf:play(Ep, <<"/media/one.wav">>)),
    ?UA:bye(Ua),
    ua_got(WinnerUa, bye, 5000),
    Owner ! stop,
    ?UA:stop(Loser).

fork_same_flags_second_answers(Config) ->
    fork_after_menu(Config, fun same_flags/1, 2).

fork_own_flags_second_answers(Config) ->
    fork_after_menu(Config, fun own_flags/1, 2).

fork_own_flags_first_answers(Config) ->
    fork_after_menu(Config, fun own_flags/1, 1).

%% Every branch is busy: the caller stays on the endpoint and hears it.
%% The next bridge works, and it hears the new callee.
fork_failed_then_bridge(Config, Target) ->
    ivr(fun park/2),
    {Ua, Ep, B2b, Owner} = call_in(Config, 600),
    Busy = [?UA:callee(#{answer => {status, 486}}) || _ <- [1, 2]],
    ?assertMatch(
        {error, _},
        chappe_mrf:bridge(
            B2b, Target([callee_uri(U) || U <- Busy]),
            #{anchor_params => to_host()}
        )
    ),
    Test = self(),
    _ = spawn(fun() ->
        Test ! {played, chappe_mrf:play(Ep, <<"/media/two.wav">>)}
    end),
    ?UA:clear(Ua),
    ?assert(?UA:hears(Ua, ?TWO, 6000)),
    %% the other way as well, once the prompt is over: the endpoint hears
    %% the caller
    receive
        {played, ok} -> ok
    after 10000 -> ct:fail(no_played)
    end,
    Name = <<"rec-fail-", (integer_to_binary(erlang:unique_integer([positive])))/binary, ".wav">>,
    ok = chappe_mrf:record(Ep, <<"/media/", Name/binary>>, #{max_secs => 2}),
    Level = ?UA:wav_level(media(Config, binary_to_list(Name)), 600),
    ct:log("the endpoint recorded the caller at ~.1f dBFS", [Level]),
    ?assert(Level > -40.0),
    Callees = [?UA:callee(#{freq => F, answer => {after_ms, 200}}) || F <- [900, 1300]],
    ?assertMatch(
        {ok, #{winner := _}},
        chappe_mrf:bridge(
            B2b, Target([callee_uri(U) || U <- Callees]),
            #{anchor_params => to_host()}
        )
    ),
    ?UA:clear(Ua),
    ?assert(?UA:hears(Ua, 900, 6000) orelse ?UA:hears(Ua, 1300, 1000)),
    no_reinvite(Ua),
    ?UA:bye(Ua),
    Owner ! stop,
    [?UA:stop(U) || U <- Busy ++ Callees].

%% The old B is a softphone: after a failed fork it hears the caller, and
%% the caller it.
fork_failed_keeps_callee(Config, Target) ->
    ivr(fun park/2),
    {Ua, _Ep, B2b, Owner} = call_in(Config, 600),
    Old = ?UA:callee(#{freq => 900}),
    ok = chappe_mrf:bridge(B2b, callee_uri(Old), #{anchor_params => to_host()}),
    both_ways(Ua, 600, Old, 900),
    Busy = [?UA:callee(#{answer => {status, 486}}) || _ <- [1, 2]],
    ?assertMatch(
        {error, _},
        chappe_mrf:bridge(
            B2b, Target([callee_uri(U) || U <- Busy]),
            #{anchor_params => to_host()}
        )
    ),
    both_ways(Ua, 600, Old, 900),
    no_reinvite(Ua),
    ?UA:bye(Ua),
    ua_got(Old, bye, 5000),
    Owner ! stop,
    [?UA:stop(U) || U <- Busy].

fork_same_flags_failed_keeps_callee(Config) ->
    fork_failed_keeps_callee(Config, fun same_flags/1).

fork_own_flags_failed_keeps_callee(Config) ->
    fork_failed_keeps_callee(Config, fun own_flags/1).

%% A bridge to another rtpengine interface fails: the offer moved the
%% endpoint's media to it, and without taking it back the endpoint stops
%% hearing the caller, one run in three.
failed_bridge_other_interface(Config) ->
    ivr(fun park/2),
    {Ua, Ep, B2b, Owner} = call_in(Config, 600),
    Busy = ?UA:callee(#{answer => {status, 486}}),
    {error, _} = chappe_mrf:bridge(B2b, callee_uri(Busy), #{anchor_params => to_host()}),
    ok = chappe_mrf:play(Ep, <<"/media/two.wav">>),
    Name = <<"rec-iface-", (integer_to_binary(erlang:unique_integer([positive])))/binary, ".wav">>,
    ok = chappe_mrf:record(Ep, <<"/media/", Name/binary>>, #{max_secs => 2}),
    Level = ?UA:wav_level(media(Config, binary_to_list(Name)), 600),
    ct:log("the endpoint recorded the caller at ~.1f dBFS", [Level]),
    ?assert(Level > -40.0),
    ?UA:bye(Ua),
    Owner ! stop,
    ?UA:stop(Busy).

fork_same_flags_failed_then_bridge(Config) ->
    fork_failed_then_bridge(Config, fun same_flags/1).

fork_own_flags_failed_then_bridge(Config) ->
    fork_failed_then_bridge(Config, fun own_flags/1).

%% One fork of a running call: two softphones with flags of their own,
%% Win answers (its tone WinFreq), the other gets a CANCEL. Audio goes
%% both ways, and the winner's softphone comes back.
fork_round(B2b, Ua, Win, WinFreq) ->
    Answering = ?UA:callee(#{freq => WinFreq, answer => {after_ms, 300}}),
    Ringing = ?UA:callee(#{answer => ring}),
    Ordered =
        case Win of
            1 -> [Answering, Ringing];
            2 -> [Ringing, Answering]
        end,
    ?assertMatch(
        {ok, #{winner := #{index := Win}}},
        chappe_mrf:bridge(
            B2b, own_flags([callee_uri(U) || U <- Ordered]),
            #{anchor_params => to_host()}
        )
    ),
    ua_got(Ringing, cancel, 5000),
    both_ways(Ua, 600, Answering, WinFreq),
    ?UA:stop(Ringing),
    Answering.

both_ways(Ua, UaFreq, Other, OtherFreq) ->
    ?UA:clear(Ua),
    ?UA:clear(Other),
    ?assert(?UA:hears(Ua, OtherFreq, 6000)),
    ?assert(?UA:hears(Other, UaFreq, 6000)).

%% Fork after fork on one call, the via-branches of each landing on what
%% the one before left: each winner has audio both ways, the one before
%% gets a BYE, and the caller sees no re-INVITE.
fork_again_after_win(Config) ->
    ivr(fun park/2),
    {Ua, _Ep, B2b, Owner} = call_in(Config, 600),
    W1 = fork_round(B2b, Ua, 2, 900),
    W2 = fork_round(B2b, Ua, 2, 1300),
    ua_got(W1, bye, 5000),
    W3 = fork_round(B2b, Ua, 1, 1700),
    ua_got(W2, bye, 5000),
    W4 = fork_round(B2b, Ua, 1, 2100),
    ua_got(W3, bye, 5000),
    no_reinvite(Ua),
    ?UA:bye(Ua),
    ua_got(W4, bye, 5000),
    Owner ! stop.

%% A fork that fails after a win leaves the winner its audio, both ways,
%% and the next fork works.
fork_fails_after_win(Config) ->
    ivr(fun park/2),
    {Ua, _Ep, B2b, Owner} = call_in(Config, 600),
    lists:foreach(
        fun({Win, Freq}) ->
            W = fork_round(B2b, Ua, Win, Freq),
            Busy = [?UA:callee(#{answer => {status, 486}}) || _ <- [1, 2]],
            ?assertMatch(
                {error, _},
                chappe_mrf:bridge(
                    B2b, own_flags([callee_uri(U) || U <- Busy]),
                    #{anchor_params => to_host()}
                )
            ),
            both_ways(Ua, 600, W, Freq),
            [?UA:stop(U) || U <- Busy]
        end,
        [{1, 900}, {2, 1300}]
    ),
    no_reinvite(Ua),
    ?UA:bye(Ua),
    Owner ! stop.

%% After a win, a re-INVITE from either side reaches the other and leaves
%% audio both ways.
reinvite_after_win(Config) ->
    ivr(fun park/2),
    {Ua, _Ep, B2b, Owner} = call_in(Config, 600),
    lists:foreach(
        fun({Win, Freq}) ->
            W = fork_round(B2b, Ua, Win, Freq),
            ?UA:reinvite(Ua),
            ua_got(W, reinvite, 5000),
            ua_got(Ua, reinvited, 5000),
            both_ways(Ua, 600, W, Freq),
            ?UA:reinvite(W),
            ua_got(Ua, reinvite, 5000),
            ua_got(W, reinvited, 5000),
            both_ways(Ua, 600, W, Freq)
        end,
        [{2, 900}, {1, 1300}]
    ),
    ?UA:bye(Ua),
    Owner ! stop.

%% A call that began as an own-flags fork of create_b2bua/4: bridge/3 forks
%% again on it, under the same via-branch names.
fork_after_create_b2bua_fork(Config) ->
    Test = self(),
    Host = #{a => #{direction => [<<"host">>, <<"host">>]},
             b => #{direction => [<<"host">>, <<"host">>]}},
    First = ?UA:callee(#{freq => 900, answer => {after_ms, 300}}),
    Other = ?UA:callee(#{answer => ring}),
    Target = own_flags([callee_uri(Other), callee_uri(First)]),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(
            Req, Res, Target, #{media => anchor, anchor_params => Host}
        ),
        {ok, B2b} = chappe_sip_b2b:relay_async(Legs, #{notify => Test}),
        Test ! {up, B2b}
    end),
    Ua = ?UA:call(?config(sip_port, Config), #{freq => 600}),
    B2b =
        receive
            {up, H} -> H
        after 10000 -> ct:fail(no_call)
        end,
    ua_got(Ua, {final, 200}, 5000),
    ua_got(Other, cancel, 5000),
    both_ways(Ua, 600, First, 900),
    W1 = fork_round(B2b, Ua, 1, 1300),
    ua_got(First, bye, 5000),
    W2 = fork_round(B2b, Ua, 2, 1700),
    ua_got(W1, bye, 5000),
    no_reinvite(Ua),
    ?UA:bye(Ua),
    ua_got(W2, bye, 5000),
    [?UA:stop(U) || U <- [Other]].

%% create_endpoint/1, then bridge/3 moves the caller onto it: what the
%% new endpoint plays reaches the caller.
endpoint_bridge(Config) ->
    ivr(fun park/2),
    {Ua, _Ep1, B2b, Owner} = call_in(Config, none),
    {ok, Ep2} = chappe_mrf:create_endpoint(#{}),
    _ = spawn(fun() -> chappe_mrf:play(Ep2, <<"/media/one.wav">>) end),
    ok = chappe_mrf:bridge(B2b, Ep2, #{anchor_params => to_fs()}),
    ?assert(?UA:hears(Ua, ?ONE, 6000)),
    no_reinvite(Ua),
    ?UA:bye(Ua),
    receive
        {chappe_mrf, Ep2, {hangup, _}} -> ok
    after 5000 -> ct:fail(ep2_no_hangup)
    end,
    Owner ! stop.

%% record/3 writes the caller's audio to the shared volume, and playing
%% the file back brings the caller's tone back.
record_playback(Config) ->
    Name = <<"rec-", (integer_to_binary(erlang:unique_integer([positive])))/binary, ".wav">>,
    Test = self(),
    ivr(fun(Ep, _B2b) ->
        R = chappe_mrf:record(Ep, <<"/media/", Name/binary>>, #{max_secs => 3}),
        Test ! {recorded, R},
        park_loop()
    end),
    {Ua, Ep, _B2b, Owner} = call_in(Config, 600),
    receive
        {recorded, ok} -> ok;
        {recorded, Err} -> ct:fail({record, Err})
    after 15000 -> ct:fail(no_record)
    end,
    Path = media(Config, binary_to_list(Name)),
    {ok, #file_info{size = Size}} = file:read_file_info(Path),
    ct:log("recording ~s: ~b bytes", [Path, Size]),
    ?assert(Size > 8000),
    ?UA:tone(Ua, none),
    ?UA:clear(Ua),
    _ = in_owner(Owner, fun() -> spawn(fun() -> chappe_mrf:play(Ep, <<"/media/", Name/binary>>) end) end),
    ?assert(?UA:hears(Ua, 600, 6000)),
    ?UA:bye(Ua),
    Owner ! stop.

%% store => default: record/3 returns the id of the file adopted into the
%% store under the endpoint's call_ref; a session recording still going
%% at the hangup is adopted then, and the owner hears {recorded, Id};
%% one outside the shared folder is refused before FreeSWITCH sees it.
stored_recordings(Config) ->
    Name = fun(P) ->
        <<"/media/", P/binary, (integer_to_binary(erlang:unique_integer([positive])))/binary,
            ".wav">>
    end,
    Test = self(),
    ivr(fun(Ep, _B2b) ->
        %% the endpoint's call_ref, else its id: what the store files under
        Test ! {ref, store_ref(chappe_mrf_endpoint:info(Ep))},
        Test ! {recorded, chappe_mrf:record(Ep, Name(<<"store-">>), #{max_secs => 2, store => default})},
        Test ! {outside, chappe_mrf:record_session(Ep, <<"/tmp/x.wav">>, #{store => default})},
        Test ! {session, chappe_mrf:record_session(Ep, Name(<<"sess-">>), #{store => default})},
        fwd_loop(Test)
    end),
    {Ua, _Ep, _B2b, _Owner} = call_in(Config, 600),
    Ref = receive {ref, R} -> R after 10000 -> ct:fail(no_ref) end,
    {ok, Id} = receive {recorded, Rec} -> Rec after 15000 -> ct:fail(no_record) end,
    {ok, #{call_ref := Ref, source := <<"freeswitch">>, duration_ms := Ms, path := Path}} =
        chappe_audio_store:get(Id),
    ct:log("adopted ~s: ~p ms at ~s", [Id, Ms, Path]),
    ?assert(Ms > 1000),
    ?assertNot(filelib:is_regular(media(Config, filename:basename(Path)))),
    {error, not_shared} = receive {outside, O} -> O after 5000 -> ct:fail(no_outside) end,
    ok = receive {session, S} -> S after 5000 -> ct:fail(no_session) end,
    timer:sleep(1500),
    ?UA:bye(Ua),
    SessId = receive {fwd, {chappe_mrf, _, {recorded, SId}}} -> SId after 15000 -> ct:fail(no_recorded) end,
    Found = [I || #{id := I} <- chappe_audio_store:find(Ref)],
    ?assertEqual(lists:sort([Id, SessId]), lists:sort(Found)).

store_ref(#{call_ref := Ref}) when is_binary(Ref) -> Ref;
store_ref(#{id := Id}) -> Id.

fwd_loop(Test) ->
    receive
        stop ->
            ok;
        M ->
            Test ! {fwd, M},
            fwd_loop(Test)
    end.

%% Three callers in a native room (chappe_mix behind rtpengine): one talks
%% and the others hear it, a room prompt plays, mute and kick work, talker
%% events arrive, and the room outlives its first caller.
native_conference(Config) ->
    ivr(fun park/2),
    {ok, Conf} = chappe_mrf:conference(<<"live-native">>, #{anchor_params => to_host()}),
    Calls = [call_in(Config, F) || F <- [500, none, none]],
    [M1, M2, M3] = [
        begin
            {ok, M} = chappe_mrf_conf:join(Conf, B2b, #{}),
            M
        end
     || {_Ua, _Ep, B2b, _} <- Calls
    ],
    [{U1, _, _, _}, {U2, _, _, _}, {U3, _, _, _}] = Calls,
    ?assert(?UA:hears(U2, 500, 6000)),
    ?assert(?UA:hears(U3, 500, 6000)),
    receive
        {chappe_mrf_conf, Conf, {talking, M1, true}} -> ok
    after 5000 -> ct:fail(no_talking)
    end,
    %% a prompt for the room: rtpengine plays it on each caller's leg
    ok = chappe_mrf_conf:play(Conf, <<"/media/one.wav">>),
    ?assert(?UA:hears(U3, ?ONE, 5000)),
    ok = chappe_mrf_conf:mute(Conf, M1),
    timer:sleep(300),
    ?assert(?UA:silent(U2, 500, 1500)),
    ok = chappe_mrf_conf:unmute(Conf, M1),
    ?UA:clear(U2),
    ?assert(?UA:hears(U2, 500, 4000)),
    ok = chappe_mrf_conf:kick(Conf, M3),
    ua_got(U3, bye, 5000),
    [no_reinvite(U) || U <- [U1, U2]],
    %% the first caller leaves; the room stays and the next caller hears
    %% the second
    ?UA:bye(U1),
    receive
        {chappe_mrf_conf, Conf, {left, M1, departed}} -> ok
    after 5000 -> ct:fail(no_left)
    end,
    ?UA:tone(U2, 800),
    {U4, _, B4, _} = call_in(Config, none),
    {ok, _M4} = chappe_mrf_conf:join(Conf, B4, #{}),
    ?assert(?UA:hears(U4, 800, 6000)),
    ?assertMatch([_, _], chappe_mrf_conf:members(Conf)),
    _ = M2,
    [?UA:bye(U) || U <- [U2, U4]].

%% An endpoint of create_endpoint/1 in a native room: its dialog is
%% re-INVITEd to the mixer through rtpengine, so what it plays reaches a
%% caller in the room, and what the caller says reaches what it records.
native_endpoint(Config) ->
    ivr(fun park/2),
    {ok, Conf} = chappe_mrf:conference(<<"live-native-ep">>, #{
        anchor_params => to_host(),
        endpoint_params => #{
            offer => #{direction => [<<"host">>, <<"docker">>]},
            answer => #{direction => [<<"docker">>, <<"host">>]}
        }
    }),
    {Ua, _, B2b, _} = call_in(Config, 500),
    {ok, _} = chappe_mrf_conf:join(Conf, B2b, #{}),
    {ok, Ep} = chappe_mrf:create_endpoint(#{}),
    {ok, M} = chappe_mrf_conf:join(Conf, Ep, #{name => <<"ep">>}),
    _ = spawn(fun() -> chappe_mrf:play(Ep, <<"/media/one.wav">>) end),
    ?assert(?UA:hears(Ua, ?ONE, 6000)),
    Name = <<"rec-ep-", (integer_to_binary(erlang:unique_integer([positive])))/binary, ".wav">>,
    ok = chappe_mrf:record(Ep, <<"/media/", Name/binary>>, #{max_secs => 3}),
    Level = ?UA:wav_level(media(Config, binary_to_list(Name)), 500),
    ct:log("endpoint recorded 500 Hz at ~.1f dBFS", [Level]),
    ?assert(Level > -40.0),
    ok = chappe_mrf_conf:kick(Conf, M),
    ?assertMatch([_], chappe_mrf_conf:members(Conf)),
    ?assertMatch({ok, _}, chappe_mrf:uuid(Ep)),
    chappe_mrf:destroy(Ep),
    ?UA:bye(Ua).

%% Three callers in a mod_conference room: each enters the PIN after its
%% prompt, audio crosses the room, and the moderator kick drops one.
fs_conference(Config) ->
    ivr(fun park/2),
    {ok, Conf} = chappe_mrf:conference(<<"live-fs">>, #{
        backend => fs, node => fs1, bridge => #{anchor_params => to_fs()}
    }),
    Calls = [call_in(Config, F) || F <- [600, none, none]],
    Test = self(),
    Members = [
        begin
            _ = spawn(fun() ->
                Test ! {joined, Ua, chappe_mrf_conf:join(Conf, B2b, #{
                    pin => <<"1234">>, pin_prompt => <<"/media/pin.wav">>
                })}
            end),
            ?assert(?UA:hears(Ua, ?PIN, 8000)),
            ?UA:dtmf(Ua, <<"1234">>),
            receive
                {joined, Ua, {ok, M}} -> M;
                {joined, Ua, Err} -> ct:fail({join, Err})
            after 15000 -> ct:fail(no_join)
            end
        end
     || {Ua, _Ep, B2b, _} <- Calls
    ],
    [_M1, _M2, M3] = Members,
    [{U1, _, _, _}, {U2, _, _, _}, {U3, _, _, _}] = Calls,
    ?UA:clear(U2),
    ?assert(?UA:hears(U2, 600, 6000)),
    ?assertEqual(3, length(chappe_mrf_conf:members(Conf))),
    ok = chappe_mrf_conf:kick(Conf, M3),
    receive
        {chappe_mrf_conf, Conf, {left, M3, kicked}} -> ok
    after 5000 -> ct:fail(no_left)
    end,
    ua_got(U3, bye, 8000),
    [no_reinvite(U) || U <- [U1, U2]],
    [?UA:bye(U) || U <- [U1, U2]].

%% The endpoint verbs on a real node, the caller sending its 700 Hz
%% marker: a missing file, a playback's length and limit, playback events,
%% say (by the files it plays), speak, tone detection, variables and mute.
%% The handler owns the endpoint and relays its events here.
endpoint_verbs(Config) ->
    Test = self(),
    ivr(fun(_Ep, _B2b) -> relay_loop(Test) end, #{
        events => [playback_start, playback_stop]
    }),
    {Ua, Ep, _B2b, Owner} = call_in(Config, ?ONE),
    ?assertEqual({error, not_found}, chappe_mrf:play(Ep, <<"/media/missing.wav">>)),
    {ok, #{ms := Ms, response := <<"FILE PLAYED">>}} =
        chappe_mrf:play_info(Ep, <<"/media/pin.wav">>, #{}),
    ?assert(Ms > 2500 andalso Ms < 3500),
    ?assertEqual({playback_start, <<"/media/pin.wav">>}, ep_event()),
    ?assertEqual({playback_stop, <<"/media/pin.wav">>, <<"done">>}, ep_event()),
    {ok, #{ms := Limited}} =
        chappe_mrf:play_info(Ep, <<"/media/menu.wav">>, #{limit_secs => 2}),
    ct:pal("menu.wav limited to 2 s played ~p ms", [Limited]),
    ?assert(Limited < 3000),
    flush_ep_events(),
    S0 = erlang:monotonic_time(millisecond),
    ok = chappe_mrf:say(Ep, <<"42">>, #{}),
    %% mod_say_en picks forty and two and plays both half-second files
    ?assert(erlang:monotonic_time(millisecond) - S0 > 900),
    ?assertEqual([<<"file_string://digits/40.wav!digits/2.wav">>], started_files()),
    ok = chappe_mrf:speak(Ep, <<"Welcome to the chappe lab">>, #{
        engine => <<"flite">>, voice => <<"slt">>
    }),
    ok = chappe_mrf:detect_tones(Ep, <<"chappe_700">>),
    receive
        {ep_event, {tone, <<"TONE_700">>}} -> ok
    after 10000 -> ct:fail(no_tone)
    end,
    ok = chappe_mrf:stop_detect_tones(Ep),
    ok = chappe_mrf:set(Ep, #{<<"chappe_x">> => <<"1">>}),
    ?assertEqual({ok, <<"1">>}, chappe_mrf:var(Ep, <<"chappe_x">>)),
    {ok, #{<<"chappe_x">> := <<"1">>}} = chappe_mrf:vars(Ep),
    ok = chappe_mrf:mute(Ep, read),
    ok = chappe_mrf:unmute(Ep, read),
    ?UA:bye(Ua),
    Owner ! stop.

relay_loop(Test) ->
    receive
        {chappe_mrf, _Ep, Event} ->
            Test ! {ep_event, Event},
            relay_loop(Test);
        stop ->
            ok;
        _ ->
            relay_loop(Test)
    end.

ep_event() ->
    receive
        {ep_event, E} -> E
    after 10000 -> ct:fail(no_ep_event)
    end.

flush_ep_events() ->
    receive
        {ep_event, _} -> flush_ep_events()
    after 0 -> ok
    end.

started_files() ->
    receive
        {ep_event, {playback_start, F}} -> [F | started_files()];
        {ep_event, _} -> started_files()
    after 1500 -> []
    end.

%% Two FreeSWITCH rooms on fs1: a room is recorded to a file the node
%% writes, a member is muted (mod_conference's event) and moved to the
%% other room, where the caller is heard.
fs_conference_record_transfer(Config) ->
    ivr(fun park/2),
    Bridge = #{anchor_params => to_fs()},
    {ok, A} = chappe_mrf:conference(<<"live-fs-a">>, #{
        backend => fs, node => fs1, bridge => Bridge
    }),
    {ok, B} = chappe_mrf:conference(<<"live-fs-b">>, #{
        backend => fs, node => fs1, bridge => Bridge, max_members => 2
    }),
    ok = chappe_mrf_conf:events(B, self()),
    {U1, _, B1, _} = call_in(Config, 600),
    {U2, _, B2, _} = call_in(Config, none),
    {ok, M1} = chappe_mrf_conf:join(A, B1, #{name => <<"one">>}),
    {ok, _M2} = chappe_mrf_conf:join(B, B2, #{}),
    Rec = "conf-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".wav",
    ok = chappe_mrf_conf:record(A, <<"/media/", (list_to_binary(Rec))/binary>>),
    timer:sleep(2000),
    ok = chappe_mrf_conf:stop_record(A),
    ok = wait(fun() -> filelib:file_size(media(Config, Rec)) > 8000 end, 100),
    %% stored: stop_record/1 returns the id in the store, under the ref
    Stored = <<"/media/stored-", (list_to_binary(Rec))/binary>>,
    ok = chappe_mrf_conf:record(A, Stored, #{store => default, ref => <<"room-a">>}),
    timer:sleep(2000),
    ok = chappe_mrf_conf:stop_record(A),
    RoomRec =
        receive
            {chappe_mrf_conf, A, {recorded, _, {ok, RR}}} -> RR
        after 15000 -> ct:fail(no_room_recorded)
        end,
    {ok, #{call_ref := <<"room-a">>, source := <<"room">>, duration_ms := RoomMs}} =
        chappe_audio_store:get(RoomRec),
    ?assert(RoomMs > 1000),
    ok = chappe_mrf_conf:mute(A, M1),
    receive
        {chappe_mrf_conf, A, {muted, M1, true}} -> ok
    after 5000 -> ct:fail(no_muted)
    end,
    ok = chappe_mrf_conf:unmute(A, M1),
    {ok, N1} = chappe_mrf_conf:transfer(A, M1, B),
    receive
        {chappe_mrf_conf, A, {left, M1, transferred}} -> ok
    after 5000 -> ct:fail(no_left_transferred)
    end,
    receive
        {chappe_mrf_conf, B, {joined, N1, #{name := <<"one">>}}} -> ok
    after 5000 -> ct:fail(no_joined)
    end,
    ?UA:clear(U2),
    ?assert(?UA:hears(U2, 600, 6000)),
    {U3, _, B3, _} = call_in(Config, none),
    ?assertEqual({error, full}, chappe_mrf_conf:join(B, B3, #{})),
    [no_reinvite(U) || U <- [U1, U2]],
    [?UA:bye(U) || U <- [U1, U2, U3]].

%% Two native rooms: a member moved from one to the other is heard there,
%% without a re-INVITE.
native_conference_transfer(Config) ->
    ivr(fun park/2),
    {ok, A} = chappe_mrf:conference(<<"live-nat-a">>, #{anchor_params => to_host()}),
    {ok, B} = chappe_mrf:conference(<<"live-nat-b">>, #{anchor_params => to_host()}),
    {U1, _, B1, _} = call_in(Config, 500),
    {U2, _, B2, _} = call_in(Config, none),
    {ok, M1} = chappe_mrf_conf:join(A, B1, #{}),
    {ok, _} = chappe_mrf_conf:join(B, B2, #{}),
    ?assert(?UA:silent(U2, 500, 1500)),
    {ok, _N1} = chappe_mrf_conf:transfer(A, M1, B),
    receive
        {chappe_mrf_conf, A, {left, M1, transferred}} -> ok
    after 5000 -> ct:fail(no_left_transferred)
    end,
    ?UA:clear(U2),
    ?assert(?UA:hears(U2, 500, 6000)),
    no_reinvite(U1),
    [?UA:bye(U) || U <- [U1, U2]].

wait(_Fun, 0) ->
    ct:fail(wait_timeout);
wait(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(100),
            wait(Fun, N - 1)
    end.

%% The owner of an endpoint dies with an audio fork running: the fork is
%% stopped, the channel killed, and the caller gets a BYE.
owner_killed(Config) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, WsPort} = inet:port(L),
    Test = self(),
    ivr(fun(Ep, _B2b) ->
        R = chappe_mrf:fork_audio_start(
            Ep, <<"ws://host.docker.internal:", (integer_to_binary(WsPort))/binary>>, #{}
        ),
        Test ! {forked, R},
        park_loop()
    end),
    {Ua, Ep, _B2b, Owner} = call_in(Config, none),
    receive
        {forked, R} -> ct:log("fork: ~p", [R])
    after 10000 -> ct:fail(no_fork)
    end,
    {ok, Uuid} = chappe_mrf:uuid(Ep),
    {ok, Node} = chappe_mrf:node(Ep),
    exit(Owner, kill),
    ua_got(Ua, bye, 8000),
    timer:sleep(500),
    ?assertMatch({ok, <<"false", _/binary>>}, chappe_esl:node_api(Node, [<<"uuid_exists ">>, Uuid])),
    gen_tcp:close(L).

%% fs1 stops under a live endpoint: its owner hears node_down, and the
%% next caller lands on fs2.
node_down_failover(Config) ->
    case ?config(compose, Config) of
        "" -> {skip, "MRF_COMPOSE not set"};
        Compose -> node_down_failover(Config, Compose)
    end.

node_down_failover(Config, Compose) ->
    Test = self(),
    ivr(fun(_Ep, _B2b) -> relay_events(Test) end, #{node => fs1}),
    {Ua, Ep, _B2b, _Owner} = call_in(Config, none),
    ?assertEqual({ok, fs1}, chappe_mrf:node(Ep)),
    _ = os:cmd(Compose ++ " stop -t 2 fs1"),
    receive
        {relayed, {chappe_mrf, Ep, {node_down, fs1}}} -> ok
    after 20000 -> ct:fail(no_node_down)
    end,
    ?UA:stop(Ua),
    ivr(fun park/2),
    {Ua2, Ep2, _, Owner2} = call_in(Config, none),
    ?assertEqual({ok, fs2}, chappe_mrf:node(Ep2)),
    ?UA:bye(Ua2),
    Owner2 ! stop,
    _ = os:cmd(Compose ++ " start fs1"),
    wait_node(fs1, up, 60000).

relay_events(Test) ->
    receive
        {chappe_mrf, _, _} = M ->
            Test ! {relayed, M},
            relay_events(Test);
        stop ->
            ok
    end.
