%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Media session lifecycle: offer/answer/query/delete, owner crash
%% cleanup, timeout propagation, re-INVITE glare.
-module(chappe_rtpengine_session_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    full_lifecycle/1,
    owner_crash_sends_delete/1,
    offer_timeout_returns_error/1,
    reinvite_glare_rejected/1,
    stop_in_idle_sends_no_delete/1,
    callee_reinvite_swaps_tags/1,
    reoffer_with_via_branch/1,
    final_answer_deletes_losing_branches/1,
    media_commands/1,
    node_restart_notifies_owner/1,
    unknown_call_id_notifies_owner_once/1,
    media_subscription_flow/1,
    publish_one_sided/1,
    media_ducking/1,
    play_media_blob/1,
    stop_while_offer_pending/1,
    owner_dies_while_offering/1,
    failed_reanswer_keeps_to_tag/1,
    reoffer_rejected_rolls_back/1,
    competing_offers_are_glare/1,
    bad_param_keeps_session/1
]).

all() ->
    [
        full_lifecycle,
        owner_crash_sends_delete,
        offer_timeout_returns_error,
        reinvite_glare_rejected,
        stop_in_idle_sends_no_delete,
        callee_reinvite_swaps_tags,
        reoffer_with_via_branch,
        final_answer_deletes_losing_branches,
        media_commands,
        node_restart_notifies_owner,
        unknown_call_id_notifies_owner_once,
        media_subscription_flow,
        publish_one_sided,
        media_ducking,
        play_media_blob,
        stop_while_offer_pending,
        owner_dies_while_offering,
        failed_reanswer_keeps_to_tag,
        reoffer_rejected_rolls_back,
        competing_offers_are_glare,
        bad_param_keeps_session
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(chappe_rtpengine),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_rtpengine).

init_per_testcase(Case, Config) ->
    {ok, Server, Port} = chappe_rtpengine_fake_server:start(handler(Case)),
    Node = list_to_atom("chappe_rtpengine_sess_" ++ atom_to_list(Case)),
    Opts = maps:merge(#{host => {127, 0, 0, 1}, port => Port}, opts(Case)),
    ok = chappe_rtpengine:add_node(Node, Opts),
    [{node, Node}, {server, Server} | Config].

end_per_testcase(_Case, Config) ->
    _ = chappe_rtpengine:remove_node(?config(node, Config)),
    chappe_rtpengine_fake_server:stop(?config(server, Config)),
    ok.

handler(offer_timeout_returns_error) ->
    fun
        (_N, #{<<"command">> := <<"offer">>}) -> drop;
        (N, Cmd) -> chappe_rtpengine_fake_server:default_handler(N, Cmd)
    end;
handler(unknown_call_id_notifies_owner_once) ->
    fun
        (_N, #{<<"command">> := <<"query">>}) ->
            {reply, #{
                <<"result">> => <<"error">>,
                <<"error-reason">> => <<"Unknown call-ID">>
            }};
        (N, Cmd) ->
            chappe_rtpengine_fake_server:default_handler(N, Cmd)
    end;
handler(Case) when
    Case =:= stop_while_offer_pending; Case =:= owner_dies_while_offering
->
    %% the offer reply lands while the delete is still in flight
    fun
        (_N, #{<<"command">> := <<"offer">>}) ->
            {reply_after, 150, #{<<"result">> => <<"ok">>, <<"sdp">> => sdp()}};
        (_N, #{<<"command">> := <<"delete">>}) ->
            {reply_after, 400, #{<<"result">> => <<"ok">>}};
        (N, Cmd) ->
            chappe_rtpengine_fake_server:default_handler(N, Cmd)
    end;
handler(_Case) ->
    fun chappe_rtpengine_fake_server:default_handler/2.

opts(offer_timeout_returns_error) ->
    #{timeout => 50, attempts => 2};
opts(node_restart_notifies_owner) ->
    #{timeout => 50, attempts => 1, down_after => 2, health_interval => 100};
opts(_Case) ->
    #{}.

sdp() ->
    <<
        "v=0\r\n"
        "o=- 1545997027 1 IN IP4 198.51.100.1\r\n"
        "s=call\r\n"
        "c=IN IP4 198.51.100.1\r\n"
        "t=0 0\r\n"
        "m=audio 30000 RTP/AVP 0 8 101\r\n"
        "a=rtpmap:0 PCMU/8000\r\n"
        "a=sendrecv\r\n"
    >>.

wait_dead(Pid) ->
    Mon = erlang:monitor(process, Pid),
    receive
        {'DOWN', Mon, process, Pid, _} -> ok
    after 5000 -> error({still_alive, Pid})
    end.

commands(Server) ->
    [
        maps:get(<<"command">>, Cmd)
     || {_Cookie, Cmd} <- chappe_rtpengine_fake_server:received(Server)
    ].

%% cases

%% req: RNG-11
full_lifecycle(Config) ->
    Server = ?config(server, Config),
    CallId = <<"sess-lifecycle">>,
    {ok, Sess} = chappe_rtpengine:start_session(#{call_id => CallId}),
    %% pinned to the only node
    {ok, _, _} = chappe_rtpengine_pool:pinned(CallId),

    {ok, OfferReply} = chappe_rtpengine_session:offer(Sess, #{
        from_tag => <<"ft-1">>, sdp => sdp()
    }),
    ?assertNotEqual(
        nomatch,
        binary:match(chappe_rtpengine_ng:sdp(OfferReply), <<"a=rtpengine:fake">>)
    ),
    #{state := offered} = chappe_rtpengine_session:info(Sess),

    {ok, _} = chappe_rtpengine_session:answer(Sess, #{
        to_tag => <<"tt-1">>, sdp => sdp()
    }),
    #{state := established} = chappe_rtpengine_session:info(Sess),

    {ok, QueryReply} = chappe_rtpengine_session:query(Sess),
    ?assertEqual(1700000000, maps:get(<<"created">>, QueryReply)),

    ok = chappe_rtpengine_session:stop(Sess),
    wait_dead(Sess),
    ?assertEqual(
        [<<"offer">>, <<"answer">>, <<"query">>, <<"delete">>],
        commands(Server)
    ),
    %% delete carried the session's tags, and the pin is released
    {_, Delete} = lists:last(chappe_rtpengine_fake_server:received(Server)),
    ?assertEqual(<<"ft-1">>, maps:get(<<"from-tag">>, Delete)),
    ?assertEqual(CallId, maps:get(<<"call-id">>, Delete)),
    error = chappe_rtpengine_pool:pinned(CallId),
    ok.

%% req: RNG-11
owner_crash_sends_delete(Config) ->
    Server = ?config(server, Config),
    Test = self(),
    _Owner = spawn(fun() ->
        {ok, Sess} = chappe_rtpengine:start_session(#{
            call_id => <<"sess-crash">>
        }),
        {ok, _} = chappe_rtpengine_session:offer(Sess, #{
            from_tag => <<"ft-2">>, sdp => sdp()
        }),
        Test ! {sess, Sess},
        exit(simulated_owner_crash)
    end),
    Sess =
        receive
            {sess, S} -> S
        after 5000 -> error(no_session)
        end,
    wait_dead(Sess),
    ?assertEqual([<<"offer">>, <<"delete">>], commands(Server)),
    error = chappe_rtpengine_pool:pinned(<<"sess-crash">>),
    ok.

offer_timeout_returns_error(Config) ->
    Server = ?config(server, Config),
    {ok, Sess} = chappe_rtpengine:start_session(#{
        call_id => <<"sess-timeout">>
    }),
    {error, timeout} = chappe_rtpengine_session:offer(Sess, #{
        from_tag => <<"ft-3">>, sdp => sdp()
    }),
    %% failed offer falls back to idle; the session stays usable
    #{state := idle} = chappe_rtpengine_session:info(Sess),
    %% both attempts reached the wire with the same cookie
    Received = chappe_rtpengine_fake_server:received(Server),
    ?assertEqual(2, length(Received)),
    ?assertEqual(1, length(lists:usort([C || {C, _} <- Received]))),
    ok = chappe_rtpengine_session:stop(Sess),
    wait_dead(Sess),
    ok.

%% req: RNG-12
reinvite_glare_rejected(Config) ->
    Server = ?config(server, Config),
    {ok, Sess} = chappe_rtpengine:start_session(#{
        call_id => <<"sess-glare">>
    }),
    {ok, _} = chappe_rtpengine_session:offer(Sess, #{
        from_tag => <<"ft-4">>, sdp => sdp()
    }),
    {ok, _} = chappe_rtpengine_session:answer(Sess, #{
        to_tag => <<"tt-4">>, sdp => sdp()
    }),

    %% slow down reoffer replies, then race two re-INVITEs
    chappe_rtpengine_fake_server:set_handler(Server, fun
        (_N, #{<<"command">> := <<"offer">>}) ->
            {reply_after, 300, #{
                <<"result">> => <<"ok">>, <<"sdp">> => sdp()
            }};
        (N, Cmd) ->
            chappe_rtpengine_fake_server:default_handler(N, Cmd)
    end),
    Test = self(),
    spawn_link(fun() ->
        Test ! {reoffer, chappe_rtpengine_session:offer(Sess, #{sdp => sdp()})}
    end),
    timer:sleep(100),
    #{state := reoffering} = chappe_rtpengine_session:info(Sess),
    {error, glare} = chappe_rtpengine_session:offer(Sess, #{sdp => sdp()}),
    receive
        {reoffer, {ok, _}} -> ok
    after 5000 -> error(reoffer_lost)
    end,
    %% the winning re-INVITE completes normally
    #{state := offered} = chappe_rtpengine_session:info(Sess),
    {ok, _} = chappe_rtpengine_session:answer(Sess, #{sdp => sdp()}),
    #{state := established} = chappe_rtpengine_session:info(Sess),
    ok = chappe_rtpengine_session:stop(Sess),
    wait_dead(Sess),
    ok.

establish(CallId, FromTag, ToTag) ->
    {ok, Sess} = chappe_rtpengine:start_session(#{call_id => CallId}),
    {ok, _} = chappe_rtpengine_session:offer(Sess, #{from_tag => FromTag, sdp => sdp()}),
    {ok, _} = chappe_rtpengine_session:answer(Sess, #{to_tag => ToTag, sdp => sdp()}),
    #{state := established} = chappe_rtpengine_session:info(Sess),
    Sess.

%% req: RNG-11
callee_reinvite_swaps_tags(Config) ->
    Server = ?config(server, Config),
    Sess = establish(<<"sess-callee">>, <<"ft-c">>, <<"tt-c">>),
    %% callee-initiated re-INVITE: from-tag must be the callee's tag
    {ok, _} = chappe_rtpengine_session:offer(Sess, #{
        sdp => sdp(), initiator => callee
    }),
    {ok, _} = chappe_rtpengine_session:answer(Sess, #{sdp => sdp()}),
    #{state := established} = chappe_rtpengine_session:info(Sess),
    [_, _, Reoffer, Reanswer] = [
        Cmd
     || {_, Cmd} <- chappe_rtpengine_fake_server:received(Server)
    ],
    ?assertEqual(<<"offer">>, maps:get(<<"command">>, Reoffer)),
    ?assertEqual(<<"tt-c">>, maps:get(<<"from-tag">>, Reoffer)),
    ?assertEqual(<<"ft-c">>, maps:get(<<"to-tag">>, Reoffer)),
    ?assertEqual(<<"answer">>, maps:get(<<"command">>, Reanswer)),
    ?assertEqual(<<"tt-c">>, maps:get(<<"from-tag">>, Reanswer)),
    ?assertEqual(<<"ft-c">>, maps:get(<<"to-tag">>, Reanswer)),
    %% a caller-initiated re-INVITE afterwards uses the canonical tags
    {ok, _} = chappe_rtpengine_session:offer(Sess, #{sdp => sdp()}),
    {_, Reoffer2} = lists:last(chappe_rtpengine_fake_server:received(Server)),
    ?assertEqual(<<"ft-c">>, maps:get(<<"from-tag">>, Reoffer2)),
    ok = chappe_rtpengine_session:stop(Sess),
    wait_dead(Sess),
    ok.

%% A re-offer naming a via-branch opens a branch: no to-tag goes with it,
%% and the answer's to-tag becomes the session's.
reoffer_with_via_branch(Config) ->
    Server = ?config(server, Config),
    Sess = establish(<<"sess-via">>, <<"ft-v">>, <<"tt-v">>),
    {ok, _} = chappe_rtpengine_session:offer(Sess, #{
        sdp => sdp(), via_branch => <<"v1">>
    }),
    {_, Offer} = lists:last(chappe_rtpengine_fake_server:received(Server)),
    ?assertEqual(<<"v1">>, maps:get(<<"via-branch">>, Offer)),
    ?assertEqual(<<"ft-v">>, maps:get(<<"from-tag">>, Offer)),
    ?assertNot(maps:is_key(<<"to-tag">>, Offer)),
    {ok, _} = chappe_rtpengine_session:answer(Sess, #{
        sdp => sdp(), to_tag => <<"tt-new">>, via_branch => <<"v1">>
    }),
    {ok, _} = chappe_rtpengine_session:offer(Sess, #{sdp => sdp()}),
    {_, Later} = lists:last(chappe_rtpengine_fake_server:received(Server)),
    ?assertEqual(<<"tt-new">>, maps:get(<<"to-tag">>, Later)),
    ok = chappe_rtpengine_session:stop(Sess),
    wait_dead(Sess),
    ok.

final_answer_deletes_losing_branches(Config) ->
    Server = ?config(server, Config),
    {ok, Sess} = chappe_rtpengine:start_session(#{
        call_id => <<"sess-fork">>
    }),
    {ok, _} = chappe_rtpengine_session:offer(Sess, #{
        from_tag => <<"ft-f">>, sdp => sdp()
    }),
    %% two forked branches answer with distinct to-tags
    {ok, _} = chappe_rtpengine_session:answer(Sess, #{to_tag => <<"tt-1">>, sdp => sdp()}),
    {ok, _} = chappe_rtpengine_session:answer(Sess, #{to_tag => <<"tt-2">>, sdp => sdp()}),
    #{branches := [<<"tt-1">>, <<"tt-2">>]} = chappe_rtpengine_session:info(Sess),
    %% branch tt-2 wins; the session prunes tt-1 with a targeted delete
    {ok, _} = chappe_rtpengine_session:answer(Sess, #{
        to_tag => <<"tt-2">>, sdp => sdp(), final => true
    }),
    ok = wait_until(fun() ->
        lists:any(
            fun({_, Cmd}) ->
                maps:get(<<"command">>, Cmd) =:= <<"delete">> andalso
                    maps:get(<<"to-tag">>, Cmd, undefined) =:= <<"tt-1">>
            end,
            chappe_rtpengine_fake_server:received(Server)
        )
    end),
    #{state := established, branches := [<<"tt-2">>], to_tag := <<"tt-2">>} =
        chappe_rtpengine_session:info(Sess),
    ok = chappe_rtpengine_session:stop(Sess),
    wait_dead(Sess),
    ok.

media_commands(Config) ->
    Server = ?config(server, Config),
    {ok, Idle} = chappe_rtpengine:start_session(#{
        call_id => <<"sess-media-idle">>
    }),
    {error, not_started} = chappe_rtpengine_session:play_media(Idle, #{
        file => <<"/prompts/hello.wav">>
    }),
    ok = chappe_rtpengine_session:stop(Idle),
    wait_dead(Idle),

    Sess = establish(<<"sess-media">>, <<"ft-m">>, <<"tt-m">>),
    {ok, _} = chappe_rtpengine_session:play_media(Sess, #{
        file => <<"/prompts/hello.wav">>
    }),
    {ok, _} = chappe_rtpengine_session:play_dtmf(Sess, #{code => 5, duration => 100}),
    {ok, _} = chappe_rtpengine_session:block_dtmf(Sess),
    {ok, _} = chappe_rtpengine_session:start_recording(Sess),
    {ok, _} = chappe_rtpengine_session:stop_media(Sess),
    Commands = commands(Server),
    ?assertEqual(
        [
            <<"offer">>,
            <<"answer">>,
            <<"play media">>,
            <<"play DTMF">>,
            <<"block DTMF">>,
            <<"start recording">>,
            <<"stop media">>
        ],
        Commands
    ),
    %% media commands carry the session's identity
    {_, Play} = lists:nth(3, chappe_rtpengine_fake_server:received(Server)),
    ?assertEqual(<<"sess-media">>, maps:get(<<"call-id">>, Play)),
    ?assertEqual(<<"ft-m">>, maps:get(<<"from-tag">>, Play)),
    ?assertEqual(<<"/prompts/hello.wav">>, maps:get(<<"file">>, Play)),
    ok = chappe_rtpengine_session:stop(Sess),
    wait_dead(Sess),
    ok.

%% req: RNG-11
node_restart_notifies_owner(Config) ->
    Server = ?config(server, Config),
    Node = ?config(node, Config),
    Sess = establish(<<"sess-restart">>, <<"ft-r">>, <<"tt-r">>),
    #{generation := 1} = chappe_rtpengine_session:info(Sess),
    %% node stops answering: health pings take it down
    chappe_rtpengine_fake_server:set_handler(Server, fun(_N, _Cmd) -> drop end),
    receive
        {chappe_rtpengine_session, Sess, {node_down, Node}} -> ok
    after 5000 -> error(no_node_down_notice)
    end,
    %% node recovers: generation bump means the media session is gone
    chappe_rtpengine_fake_server:set_handler(
        Server, fun chappe_rtpengine_fake_server:default_handler/2
    ),
    receive
        {chappe_rtpengine_session, Sess, {node_restarted, Node}} -> ok
    after 5000 -> error(no_node_restarted_notice)
    end,
    #{generation := 2, media_lost := true} = chappe_rtpengine_session:info(Sess),
    %% owner decides: teardown
    ok = chappe_rtpengine_session:stop(Sess),
    wait_dead(Sess),
    ok.

unknown_call_id_notifies_owner_once(Config) ->
    Node = ?config(node, Config),
    Sess = establish(<<"sess-unknown">>, <<"ft-u">>, <<"tt-u">>),
    {error, <<"Unknown call-ID">>, _} = chappe_rtpengine_session:query(Sess),
    receive
        {chappe_rtpengine_session, Sess, {node_restarted, Node}} -> ok
    after 5000 -> error(no_restart_notice)
    end,
    %% the notification fires once, not per failing command
    {error, <<"Unknown call-ID">>, _} = chappe_rtpengine_session:query(Sess),
    receive
        {chappe_rtpengine_session, Sess, _} = Extra -> error({unexpected, Extra})
    after 200 -> ok
    end,
    #{media_lost := true} = chappe_rtpengine_session:info(Sess),
    ok = chappe_rtpengine_session:stop(Sess),
    wait_dead(Sess),
    ok.

%% A one-sided call: publish establishes the session on its own, an
%% answer never follows, and the tap and the delete both work from
%% there with only a from-tag.
%% req: RNG-11
publish_one_sided(Config) ->
    Server = ?config(server, Config),
    CallId = <<"sess-publish">>,
    {ok, Sess} = chappe_rtpengine:start_session(#{call_id => CallId}),
    {error, {missing_params, [sdp]}} =
        chappe_rtpengine_session:publish(Sess, #{from_tag => <<"ft-p">>}),
    {ok, Reply} = chappe_rtpengine_session:publish(Sess, #{
        from_tag => <<"ft-p">>, sdp => sdp()
    }),
    ?assertNotEqual(
        nomatch,
        binary:match(
            chappe_rtpengine_ng:sdp(Reply), <<"a=rtpengine:fake-publish">>
        )
    ),
    #{state := established, to_tag := undefined} =
        chappe_rtpengine_session:info(Sess),
    %% a second offer on an established session is a re-INVITE, and a
    %% second publish is refused rather than silently re-anchoring
    {error, busy} = chappe_rtpengine_session:publish(Sess, #{
        from_tag => <<"ft-p">>, sdp => sdp()
    }),
    {ok, _} = chappe_rtpengine_session:subscribe_request(Sess, #{
        from_tags => [<<"ft-p">>]
    }),
    ok = chappe_rtpengine_session:stop(Sess),
    wait_dead(Sess),
    %% the refused second publish never reached the wire
    ?assertEqual(
        [<<"publish">>, <<"subscribe request">>, <<"delete">>],
        commands(Server)
    ),
    {_, Delete} = lists:last(chappe_rtpengine_fake_server:received(Server)),
    ?assertEqual(<<"ft-p">>, maps:get(<<"from-tag">>, Delete)),
    ok.

media_subscription_flow(Config) ->
    Server = ?config(server, Config),
    Sess = establish(<<"sess-sub">>, <<"ft-s">>, <<"tt-s">>),
    {ok, SubReply} = chappe_rtpengine_session:subscribe_request(Sess, #{
        flags => [all]
    }),
    SubTag = maps:get(<<"to-tag">>, SubReply),
    ?assertNotEqual(undefined, chappe_rtpengine_ng:sdp(SubReply)),
    {ok, _} = chappe_rtpengine_session:subscribe_answer(Sess, #{
        to_tag => SubTag, sdp => sdp()
    }),
    {ok, _} = chappe_rtpengine_session:unsubscribe(Sess, #{to_tag => SubTag}),

    Received = chappe_rtpengine_fake_server:received(Server),
    {_, SubReq} = lists:nth(3, Received),
    ?assertEqual(<<"subscribe request">>, maps:get(<<"command">>, SubReq)),
    ?assertEqual(<<"sess-sub">>, maps:get(<<"call-id">>, SubReq)),
    ?assertEqual([<<"all">>], maps:get(<<"flags">>, SubReq)),
    %% no automatic from-tag injection on subscription commands
    ?assertEqual(undefined, maps:get(<<"from-tag">>, SubReq, undefined)),
    {_, SubAns} = lists:nth(4, Received),
    ?assertEqual(<<"subscribe answer">>, maps:get(<<"command">>, SubAns)),
    ?assertEqual(SubTag, maps:get(<<"to-tag">>, SubAns)),
    {_, Unsub} = lists:nth(5, Received),
    ?assertEqual(<<"unsubscribe">>, maps:get(<<"command">>, Unsub)),
    ?assertEqual(SubTag, maps:get(<<"to-tag">>, Unsub)),

    {error, {missing_params, [to_tag]}} =
        chappe_rtpengine_session:subscribe_answer(Sess, #{sdp => sdp()}),
    ok = chappe_rtpengine_session:stop(Sess),
    wait_dead(Sess),
    ok.

media_ducking(Config) ->
    Server = ?config(server, Config),
    Sess = establish(<<"sess-duck">>, <<"ft-d">>, <<"tt-d">>),

    %% one direction: the party's tag plus the directional flag
    {ok, _} = chappe_rtpengine_session:silence_media(Sess, #{party => caller}),
    {ok, _} = chappe_rtpengine_session:silence_media(Sess, #{party => callee}),
    %% whole call by default
    {ok, _} = chappe_rtpengine_session:block_media(Sess),
    {ok, _} = chappe_rtpengine_session:unblock_media(Sess),
    {ok, _} = chappe_rtpengine_session:unsilence_media(Sess, #{party => caller}),

    [_, _, SilCaller, SilCallee, BlockAll, UnblockAll, UnsilCaller] = [
        Cmd
     || {_, Cmd} <- chappe_rtpengine_fake_server:received(Server)
    ],
    ?assertEqual(<<"silence media">>, maps:get(<<"command">>, SilCaller)),
    ?assertEqual(<<"ft-d">>, maps:get(<<"from-tag">>, SilCaller)),
    ?assertEqual([<<"directional">>], maps:get(<<"flags">>, SilCaller)),
    ?assertEqual(<<"tt-d">>, maps:get(<<"from-tag">>, SilCallee)),
    ?assertEqual(<<"block media">>, maps:get(<<"command">>, BlockAll)),
    ?assertEqual([<<"all">>], maps:get(<<"flags">>, BlockAll)),
    ?assertEqual(<<"unblock media">>, maps:get(<<"command">>, UnblockAll)),
    ?assertEqual([<<"all">>], maps:get(<<"flags">>, UnblockAll)),
    ?assertEqual(
        <<"unsilence media">>, maps:get(<<"command">>, UnsilCaller)
    ),
    ?assertEqual([<<"directional">>], maps:get(<<"flags">>, UnsilCaller)),
    ok = chappe_rtpengine_session:stop(Sess),
    wait_dead(Sess),

    %% callee cannot be targeted before an answer set the to-tag
    {ok, Sess2} = chappe_rtpengine:start_session(#{
        call_id => <<"sess-duck-early">>
    }),
    {ok, _} = chappe_rtpengine_session:offer(Sess2, #{
        from_tag => <<"ft-d2">>, sdp => sdp()
    }),
    {error, no_to_tag} =
        chappe_rtpengine_session:silence_media(Sess2, #{party => callee}),
    ok = chappe_rtpengine_session:stop(Sess2),
    wait_dead(Sess2),
    ok.

play_media_blob(Config) ->
    Server = ?config(server, Config),
    Sess = establish(<<"sess-blob">>, <<"ft-b">>, <<"tt-b">>),
    Blob = <<"RIFF", 0, 1, 2, 255, 254, "fake-wav">>,
    {ok, _} = chappe_rtpengine_session:play_media(Sess, #{
        blob => Blob,
        party => callee,
        repeat_times => 2
    }),
    {_, Play} = lists:nth(3, chappe_rtpengine_fake_server:received(Server)),
    ?assertEqual(<<"play media">>, maps:get(<<"command">>, Play)),
    %% raw blob bytes survive bencode framing untouched
    ?assertEqual(Blob, maps:get(<<"blob">>, Play)),
    %% party => callee targets the callee's tag, not the session's
    ?assertEqual(<<"tt-b">>, maps:get(<<"from-tag">>, Play)),
    ?assertEqual(2, maps:get(<<"repeat-times">>, Play)),
    ok = chappe_rtpengine_session:stop(Sess),
    wait_dead(Sess),
    ok.

%% stop/1 while the offer is on the wire: the offer reply arrives in
%% the deleting state, the offer caller is told the session stopped,
%% and stop/1 still gets its ok once the delete is answered.
%% req: RNG-11
stop_while_offer_pending(Config) ->
    Server = ?config(server, Config),
    {ok, Sess} = chappe_rtpengine:start_session(#{call_id => <<"sess-sp">>}),
    Mon = erlang:monitor(process, Sess),
    Test = self(),
    spawn_link(fun() ->
        Test ! {offer, chappe_rtpengine_session:offer(Sess, #{
            from_tag => <<"ft-sp">>, sdp => sdp()
        })}
    end),
    ok = wait_until(fun() ->
        maps:get(state, chappe_rtpengine_session:info(Sess)) =:= offering
    end),
    ok = chappe_rtpengine_session:stop(Sess),
    receive
        {offer, {error, stopped}} -> ok;
        {offer, Other} -> error({offer_result, Other})
    after 5000 -> error(no_offer_result)
    end,
    receive
        {'DOWN', Mon, process, Sess, Reason} -> ?assertEqual(normal, Reason)
    after 5000 -> error(session_alive)
    end,
    ?assertEqual([<<"offer">>, <<"delete">>], commands(Server)),
    ok.

%% The owner dies while its offer is in flight: the session deletes
%% and exits normally even though the offer reply arrives first.
%% req: RNG-11
owner_dies_while_offering(Config) ->
    Server = ?config(server, Config),
    Test = self(),
    Owner = spawn(fun() ->
        {ok, Sess} = chappe_rtpengine:start_session(#{
            call_id => <<"sess-od">>
        }),
        Test ! {sess, Sess},
        _ = chappe_rtpengine_session:offer(Sess, #{
            from_tag => <<"ft-od">>, sdp => sdp()
        }),
        receive
            never -> ok
        end
    end),
    Sess =
        receive
            {sess, S} -> S
        after 5000 -> error(no_session)
        end,
    Mon = erlang:monitor(process, Sess),
    ok = wait_until(fun() ->
        maps:get(state, chappe_rtpengine_session:info(Sess)) =:= offering
    end),
    exit(Owner, kill),
    receive
        {'DOWN', Mon, process, Sess, Reason} -> ?assertEqual(normal, Reason)
    after 5000 -> error(session_alive)
    end,
    ?assertEqual([<<"offer">>, <<"delete">>], commands(Server)),
    error = chappe_rtpengine_pool:pinned(<<"sess-od">>),
    ok.

%% A failed answer to a re-INVITE leaves the dialog's to-tag alone.
failed_reanswer_keeps_to_tag(Config) ->
    Server = ?config(server, Config),
    Sess = establish(<<"sess-fra">>, <<"ft-fra">>, <<"tt-fra">>),
    {ok, _} = chappe_rtpengine_session:offer(Sess, #{sdp => sdp()}),
    chappe_rtpengine_fake_server:set_handler(Server, fun
        (_N, #{<<"command">> := <<"answer">>}) ->
            {reply, #{
                <<"result">> => <<"error">>,
                <<"error-reason">> => <<"Incomplete SDP">>
            }};
        (N, Cmd) ->
            chappe_rtpengine_fake_server:default_handler(N, Cmd)
    end),
    {error, <<"Incomplete SDP">>, _} =
        chappe_rtpengine_session:answer(Sess, #{sdp => sdp()}),
    #{state := offered, to_tag := <<"tt-fra">>} =
        chappe_rtpengine_session:info(Sess),
    ok = chappe_rtpengine_session:stop(Sess),
    wait_dead(Sess),
    ok.

%% The peer refused the re-INVITE (488): the owner rolls the session
%% back to established and the call carries on with its old tags.
%% req: RNG-12
reoffer_rejected_rolls_back(Config) ->
    {ok, Fresh} = chappe_rtpengine:start_session(#{call_id => <<"sess-rr0">>}),
    {ok, _} = chappe_rtpengine_session:offer(Fresh, #{
        from_tag => <<"ft-rr0">>, sdp => sdp()
    }),
    %% an initial offer is not a re-offer: nothing to roll back to
    {error, no_reoffer} = chappe_rtpengine_session:reoffer_rejected(Fresh),
    ok = chappe_rtpengine_session:stop(Fresh),
    wait_dead(Fresh),

    Server = ?config(server, Config),
    Sess = establish(<<"sess-rr">>, <<"ft-rr">>, <<"tt-rr">>),
    {ok, _} = chappe_rtpengine_session:offer(Sess, #{
        sdp => sdp(), initiator => callee
    }),
    #{state := offered} = chappe_rtpengine_session:info(Sess),
    ok = chappe_rtpengine_session:reoffer_rejected(Sess),
    #{state := established, from_tag := <<"ft-rr">>, to_tag := <<"tt-rr">>} =
        chappe_rtpengine_session:info(Sess),
    {error, no_reoffer} = chappe_rtpengine_session:reoffer_rejected(Sess),
    %% the next re-INVITE uses the canonical direction again
    {ok, _} = chappe_rtpengine_session:offer(Sess, #{sdp => sdp()}),
    {_, Reoffer} = lists:last(chappe_rtpengine_fake_server:received(Server)),
    ?assertEqual(<<"ft-rr">>, maps:get(<<"from-tag">>, Reoffer)),
    ok = chappe_rtpengine_session:stop(Sess),
    wait_dead(Sess),
    ok.

%% Any offer while another offer/answer exchange is open is glare.
%% req: RNG-12
competing_offers_are_glare(Config) ->
    Server = ?config(server, Config),
    chappe_rtpengine_fake_server:set_handler(Server, fun
        (_N, #{<<"command">> := C}) when C =:= <<"offer">>; C =:= <<"answer">> ->
            {reply_after, 200, #{<<"result">> => <<"ok">>, <<"sdp">> => sdp()}};
        (N, Cmd) ->
            chappe_rtpengine_fake_server:default_handler(N, Cmd)
    end),
    {ok, Sess} = chappe_rtpengine:start_session(#{call_id => <<"sess-gl">>}),
    Test = self(),
    Async = fun(Fun) -> spawn_link(fun() -> Test ! {async, Fun()} end) end,
    State = fun() -> maps:get(state, chappe_rtpengine_session:info(Sess)) end,
    Offer = fun() -> chappe_rtpengine_session:offer(Sess, #{sdp => sdp()}) end,
    Async(fun() ->
        chappe_rtpengine_session:offer(Sess, #{
            from_tag => <<"ft-gl">>, sdp => sdp()
        })
    end),
    ok = wait_until(fun() -> State() =:= offering end),
    {error, glare} = Offer(),
    receive
        {async, {ok, _}} -> ok
    after 5000 -> error(no_offer_reply)
    end,
    offered = State(),
    {error, glare} = Offer(),
    Async(fun() ->
        chappe_rtpengine_session:answer(Sess, #{
            to_tag => <<"tt-gl">>, sdp => sdp()
        })
    end),
    ok = wait_until(fun() -> State() =:= answering end),
    {error, glare} = Offer(),
    receive
        {async, {ok, _}} -> ok
    after 5000 -> error(no_answer_reply)
    end,
    established = State(),
    ok = chappe_rtpengine_session:stop(Sess),
    wait_dead(Sess),
    ok.

%% A parameter bencode cannot carry fails the call, not the session.
bad_param_keeps_session(Config) ->
    _ = Config,
    Sess = establish(<<"sess-bp">>, <<"ft-bp">>, <<"tt-bp">>),
    {error, {bad_param, volume, 0.5}} =
        chappe_rtpengine_session:play_dtmf(Sess, #{code => 1, volume => 0.5}),
    #{state := established} = chappe_rtpengine_session:info(Sess),
    ok = chappe_rtpengine_session:stop(Sess),
    wait_dead(Sess),
    ok.

wait_until(Fun) ->
    wait_until(Fun, 100).

wait_until(_Fun, 0) ->
    error(wait_until_timeout);
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_until(Fun, N - 1)
    end.

stop_in_idle_sends_no_delete(Config) ->
    Server = ?config(server, Config),
    {ok, Sess} = chappe_rtpengine:start_session(#{
        call_id => <<"sess-idle-stop">>
    }),
    ok = chappe_rtpengine_session:stop(Sess),
    wait_dead(Sess),
    ?assertEqual([], commands(Server)),
    error = chappe_rtpengine_pool:pinned(<<"sess-idle-stop">>),
    ok.
