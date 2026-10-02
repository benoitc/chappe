%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc chappe_sip_media facade tests.
%%
%% rtpengine: a minimal in-suite UDP server speaks the NG wire protocol
%% (cookie SP bencode) using chappe_rtpengine's own bencode codec, so the
%% whole path facade -> chappe_sip_media_rtpengine -> chappe_rtpengine_session
%% -> chappe_rtpengine_client -> wire is exercised without a real rtpengine.
%%
%% conference: real chappe_mix rooms on loopback, with G.711 RTP sent and
%% received over UDP by in-suite peers, so each case hears what the mixer
%% actually sends. The `rtpengine_live' group puts a real rtpengine in front
%% of one leg; it runs only when RTPENGINE_HOST and RTPENGINE_MEDIA_IP are
%% set (`make interop' brings one up).
-module(chappe_sip_media_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2,
         init_per_testcase/2, end_per_testcase/2]).
-export([offer_answer/1, play_and_dtmf/1, capability_routing/1,
         unknown_capability/1, owner_death_tears_down/1,
         subscribe_tap/1, duck_block/1, duck_silence/1,
         unsupported_on_mix/1, publish_anchor/1,
         dialog_identity_uas/1, dialog_identity_uac/1,
         media_env_config/1]).
-export([conference_two_legs/1, conference_leave/1, conference_mute/1,
         conference_owner_death/1, conference_leg_owner_death/1,
         conference_sdp/1, conference_ptime/1, conference_dtmf/1,
         conference_rtcp_port/1, conference_directions/1,
         conference_deaf_relate/1]).
-export([conference_behind_rtpengine/1]).

-define(LIVE_NODE, chappe_sip_media_live).

all() ->
    [offer_answer, publish_anchor, play_and_dtmf, capability_routing,
     unknown_capability, owner_death_tears_down, subscribe_tap, duck_block,
     duck_silence, unsupported_on_mix, dialog_identity_uas,
     dialog_identity_uac, media_env_config,
     {group, mix}, {group, rtpengine_live}].

groups() ->
    [{mix, [], [conference_two_legs, conference_leave, conference_mute,
                conference_owner_death, conference_leg_owner_death,
                conference_sdp, conference_ptime, conference_dtmf,
                conference_rtcp_port, conference_directions,
                conference_deaf_relate]},
     {rtpengine_live, [], [conference_behind_rtpengine]}].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_engine_fake,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    _ = application:stop(chappe_rtpengine),
    _ = application:stop(chappe_mix),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_group(mix, Config) ->
    ok = chappe_sip_media:configure(#{mix => #{ip => {127, 0, 0, 1}}}),
    Config;
init_per_group(rtpengine_live, Config) ->
    case {os:getenv("RTPENGINE_HOST"), os:getenv("RTPENGINE_MEDIA_IP")} of
        {false, _} ->
            {skip, "RTPENGINE_HOST not set"};
        {_, M} when M =:= false; M =:= "" ->
            {skip, "RTPENGINE_MEDIA_IP not set"};
        {Host, MediaIp} ->
            Port = list_to_integer(os:getenv("RTPENGINE_PORT", "2223")),
            {ok, RtpeIp} = inet:parse_address(Host),
            ok = chappe_sip_media:configure(
                   #{rtpengine => #{nodes => [#{name => ?LIVE_NODE,
                                                host => Host, port => Port}]},
                     mix => #{ip => {0, 0, 0, 0}, advertise => MediaIp}}),
            [{rtpe_ip, RtpeIp}, {media_ip, list_to_binary(MediaIp)} | Config]
    end.

end_per_group(rtpengine_live, _Config) ->
    _ = chappe_rtpengine:remove_node(?LIVE_NODE),
    ok;
end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    Port = start_fake(self()),
    ok = chappe_sip_media:configure(
        #{rtpengine =>
              #{nodes => [#{name => chappe_rtpengine_test, host => "127.0.0.1",
                            port => Port}]}}),
    [{fake_port, Port} | Config].

end_per_testcase(_Case, _Config) ->
    _ = chappe_rtpengine:remove_node(chappe_rtpengine_test),
    stop_fake(),
    ok.

%% ---- rtpengine ----

offer_answer(_Config) ->
    {ok, S} = chappe_sip_media:session(identity(), #{capability => anchor}),
    {ok, OfferOut} = chappe_sip_media:offer(S, <<"v=0 caller-offer">>),
    ?assertEqual(<<"v=0 fake-offer">>, OfferOut),
    {ok, AnswerOut} = chappe_sip_media:answer(S, <<"v=0 callee-answer">>),
    ?assertEqual(<<"v=0 fake-answer">>, AnswerOut),
    ok = chappe_sip_media:stop(S),
    %% one drain, then inspect: the offer carried the from-tag, the answer
    %% the to-tag, and stop issued a delete
    Cmds = drain_cmds(),
    ?assertEqual(<<"ft-1">>, tag_of(<<"offer">>, <<"from-tag">>, Cmds)),
    ?assertEqual(<<"tt-1">>, tag_of(<<"answer">>, <<"to-tag">>, Cmds)),
    ?assertEqual(<<"call-1">>, tag_of(<<"offer">>, <<"call-id">>, Cmds)).

%% A call with no second leg: publish anchors the offer and the engine
%% answers it, so there is no answer/2 to follow and the tap works straight
%% away.
publish_anchor(_Config) ->
    {ok, S} = chappe_sip_media:session(identity(), #{capability => anchor}),
    {ok, AnswerOut} = chappe_sip_media:publish(S, <<"v=0 recorder-offer">>),
    ?assertEqual(<<"v=0 fake-publish">>, AnswerOut),
    {ok, Sub} = chappe_sip_media:subscribe(S, #{party => caller}),
    ?assertEqual(<<"sub-1">>, maps:get(to_tag, Sub)),
    ok = chappe_sip_media:stop(S),
    Cmds = drain_cmds(),
    ?assertEqual(<<"ft-1">>, tag_of(<<"publish">>, <<"from-tag">>, Cmds)),
    ?assertEqual(<<"call-1">>, tag_of(<<"publish">>, <<"call-id">>, Cmds)),
    ?assertEqual(<<"v=0 recorder-offer">>, tag_of(<<"publish">>, <<"sdp">>, Cmds)),
    %% the tap follows the publish with no answer in between
    ?assertEqual([<<"ft-1">>],
                 tag_of(<<"subscribe request">>, <<"from-tags">>, Cmds)).

play_and_dtmf(_Config) ->
    {ok, S} = chappe_sip_media:session(identity(), #{capability => anchor}),
    {ok, _} = chappe_sip_media:offer(S, <<"v=0 caller-offer">>),
    ?assertEqual(ok, chappe_sip_media:play(S, #{file => <<"/tmp/x.wav">>})),
    ?assertEqual(ok, chappe_sip_media:dtmf(S, #{code => 1})),
    ?assertEqual(ok, chappe_sip_media:stop(S)).

%% conference routes to chappe_mix: refused while mix is not configured,
%% a session once it is. The FreeSWITCH backend is gone and its config is
%% refused rather than ignored.
capability_routing(_Config) ->
    ok = chappe_sip_media_sup:stop_child(chappe_sip_media_mix),
    ?assertEqual({error, {not_configured, mix}},
                 chappe_sip_media:session(identity(), #{capability => conference})),
    ok = chappe_sip_media:configure(#{mix => #{ip => {127, 0, 0, 1}}}),
    ?assertMatch({ok, _},
                 chappe_sip_media:session(identity(), #{capability => conference})),
    ?assertMatch({ok, _},
                 chappe_sip_media:session(identity(), #{capability => anchor,
                                                        backend => mix})),
    ?assertEqual({error, {unsupported_backend, freeswitch}},
                 chappe_sip_media:configure(#{freeswitch => #{nodes => []}})),
    ?assertEqual({error, {no_backend, ivr}},
                 chappe_sip_media:session(identity(), #{capability => ivr})).

unknown_capability(_Config) ->
    ?assertEqual({error, {no_backend, bogus}},
                 chappe_sip_media:session(identity(), #{capability => bogus})).

subscribe_tap(_Config) ->
    {ok, S} = chappe_sip_media:session(identity(), #{capability => anchor}),
    {ok, _} = chappe_sip_media:offer(S, <<"v=0 caller-offer">>),
    {ok, _} = chappe_sip_media:answer(S, <<"v=0 callee-answer">>),
    _ = drain_cmds(),
    {ok, Sub} = chappe_sip_media:subscribe(S, #{party => caller}),
    ?assertEqual(fake_sub_sdp(), maps:get(sdp, Sub)),
    ?assertEqual(<<"sub-1">>, maps:get(to_tag, Sub)),
    %% the tapped streams, in m-line order, keyed by their SDP label: what a
    %% per-stream fork selects on
    ?assertEqual([{0, <<"1">>}, {1, <<"2">>}],
                 [{I, L} || #{index := I, label := L} <- maps:get(streams, Sub)]),
    ?assertEqual(ok, chappe_sip_media:subscribe_answer(
                       S, #{to_tag => <<"sub-1">>, sdp => <<"v=0 consumer">>})),
    ?assertEqual(ok, chappe_sip_media:unsubscribe(S, #{to_tag => <<"sub-1">>})),
    Cmds = drain_cmds(),
    %% caller tap: the stored from-tag goes out as from-tags
    ?assertEqual([<<"ft-1">>],
                 tag_of(<<"subscribe request">>, <<"from-tags">>, Cmds)),
    ?assertEqual(<<"sub-1">>,
                 tag_of(<<"subscribe answer">>, <<"to-tag">>, Cmds)),
    ?assertEqual(<<"v=0 consumer">>,
                 tag_of(<<"subscribe answer">>, <<"sdp">>, Cmds)),
    ?assertEqual(<<"sub-1">>, tag_of(<<"unsubscribe">>, <<"to-tag">>, Cmds)).

duck_block(_Config) ->
    {ok, S} = chappe_sip_media:session(identity(), #{capability => anchor}),
    {ok, _} = chappe_sip_media:offer(S, <<"v=0 caller-offer">>),
    _ = drain_cmds(),
    ?assertEqual(ok, chappe_sip_media:duck(S, #{party => caller})),
    ?assertEqual(ok, chappe_sip_media:unduck(S, #{party => caller})),
    Cmds = drain_cmds(),
    %% caller duck: from-tag plus the directional flag rtpengine requires
    ?assertEqual(<<"ft-1">>, tag_of(<<"block media">>, <<"from-tag">>, Cmds)),
    ?assert(has_flag(<<"block media">>, <<"directional">>, Cmds)),
    ?assertEqual(<<"ft-1">>, tag_of(<<"unblock media">>, <<"from-tag">>, Cmds)).

duck_silence(_Config) ->
    {ok, S} = chappe_sip_media:session(identity(), #{capability => anchor}),
    {ok, _} = chappe_sip_media:offer(S, <<"v=0 caller-offer">>),
    _ = drain_cmds(),
    ?assertEqual(ok, chappe_sip_media:duck(S, #{party => caller, mode => silence})),
    ?assertEqual(ok, chappe_sip_media:unduck(S, #{party => caller, mode => silence})),
    Cmds = drain_cmds(),
    ?assertEqual(<<"ft-1">>, tag_of(<<"silence media">>, <<"from-tag">>, Cmds)),
    ?assertEqual(<<"ft-1">>,
                 tag_of(<<"unsilence media">>, <<"from-tag">>, Cmds)).

%% The mixer has no SDP to rewrite and no anchored RTP: every rtpengine
%% operation is refused on a conference session, and the conference
%% operations on an rtpengine one.
unsupported_on_mix(_Config) ->
    ok = chappe_sip_media:configure(#{mix => #{ip => {127, 0, 0, 1}}}),
    {ok, S} = chappe_sip_media:session(#{call_id => <<"c">>},
                                       #{capability => conference}),
    ?assertEqual({error, {unsupported, offer}},
                 chappe_sip_media:offer(S, <<"v=0">>)),
    ?assertEqual({error, {unsupported, answer}},
                 chappe_sip_media:answer(S, <<"v=0">>)),
    ?assertEqual({error, {unsupported, play}},
                 chappe_sip_media:play(S, #{file => <<"x">>})),
    ?assertEqual({error, {unsupported, record}},
                 chappe_sip_media:record(S, #{})),
    ?assertEqual({error, {unsupported, dtmf}},
                 chappe_sip_media:dtmf(S, #{code => 1})),
    ?assertEqual({error, {unsupported, subscribe}},
                 chappe_sip_media:subscribe(S, #{})),
    ?assertEqual({error, {unsupported, duck}}, chappe_sip_media:duck(S, #{})),
    ?assertEqual({error, {missing, room}}, chappe_sip_media:conference(S, #{})),
    ?assertEqual({error, not_joined}, chappe_sip_media:mute(S)),
    {ok, R} = chappe_sip_media:session(identity(), #{capability => anchor}),
    ?assertEqual({error, {unsupported, conference}},
                 chappe_sip_media:conference(R, <<"room">>, #{})),
    ?assertEqual({error, {unsupported, conference}}, chappe_sip_media:leave(R)),
    ?assertEqual({error, {unsupported, conference}}, chappe_sip_media:mute(R)).

%% A UAS dialog: the From tag is the peer's, so it is what rtpengine gets as
%% from-tag, and our tag goes out as to-tag.
dialog_identity_uas(_Config) ->
    {Dialog, Fake} = fake_dialog(uas),
    {ok, S} = chappe_sip_media:session(Dialog, #{capability => anchor}),
    {ok, _} = chappe_sip_media:offer(S, <<"v=0 caller-offer">>),
    {ok, _} = chappe_sip_media:answer(S, <<"v=0 callee-answer">>),
    ok = chappe_sip_media:stop(S),
    exit(Fake, kill),
    Cmds = drain_cmds(),
    ?assertEqual(<<"remote-tag">>, tag_of(<<"offer">>, <<"from-tag">>, Cmds)),
    ?assertEqual(<<"local-tag">>, tag_of(<<"answer">>, <<"to-tag">>, Cmds)),
    ?assertEqual(<<"dlg-call">>, tag_of(<<"offer">>, <<"call-id">>, Cmds)).

%% A UAC dialog: we sent the INVITE, so the From tag is ours.
dialog_identity_uac(_Config) ->
    {Dialog, Fake} = fake_dialog(uac),
    {ok, S} = chappe_sip_media:session(Dialog, #{capability => anchor}),
    {ok, _} = chappe_sip_media:offer(S, <<"v=0 caller-offer">>),
    {ok, _} = chappe_sip_media:answer(S, <<"v=0 callee-answer">>),
    ok = chappe_sip_media:stop(S),
    exit(Fake, kill),
    Cmds = drain_cmds(),
    ?assertEqual(<<"local-tag">>, tag_of(<<"offer">>, <<"from-tag">>, Cmds)),
    ?assertEqual(<<"remote-tag">>, tag_of(<<"answer">>, <<"to-tag">>, Cmds)).

%% With no `media' option, configure reads the application env; an
%% explicit config wins over it.
media_env_config(_Config) ->
    ok = chappe_sip_media_sup:stop_child(chappe_sip_media_mix),
    application:set_env(chappe_sip, media, #{mix => #{ip => {127, 0, 0, 1}}}),
    try
        ok = chappe_sip_media:configure(undefined),
        ?assert(is_pid(whereis(chappe_sip_media_mix))),
        ok = chappe_sip_media_sup:stop_child(chappe_sip_media_mix),
        %% the option overrides the env: a bad address in the option fails
        %% although the env is fine
        ?assertMatch({error, {bad_address, _}},
                     chappe_sip_media:configure(#{mix => #{ip => "nope"}})),
        ?assertEqual(undefined, whereis(chappe_sip_media_mix))
    after
        application:unset_env(chappe_sip, media)
    end,
    %% no env, no option: nothing starts
    ok = chappe_sip_media:configure(undefined),
    ?assertEqual(undefined, whereis(chappe_sip_media_mix)).

owner_death_tears_down(_Config) ->
    Collector = self(),
    Owner = spawn(fun() ->
        {ok, S} = chappe_sip_media:session(identity(), #{capability => anchor}),
        %% offer moves the session out of idle, so owner death forces a
        %% delete (an idle session has nothing to tear down)
        {ok, _} = chappe_sip_media:offer(S, <<"v=0 caller-offer">>),
        Collector ! owner_ready,
        receive stop -> ok end
    end),
    receive owner_ready -> ok after 2000 -> ct:fail(no_owner_ready) end,
    %% drain the offer seen so far, then kill the owner
    _ = drain_cmds(),
    exit(Owner, kill),
    %% chappe_rtpengine_session monitors its owner and issues a delete on its death
    ?assert(wait_for_cmd(<<"delete">>, 3000)).

%% ---- conference (chappe_mix) ----

%% Two calls in one room, one per SDP direction: A offers PCMA without
%% rtcp-mux and the mixer answers; the mixer offers PCMU to B, which
%% answers through set_remote/2. Each hears the other and not itself.
conference_two_legs(_Config) ->
    Room = room(),
    {A, APort} = peer_start(alaw),
    {ok, SA} = conf_session(),
    {ok, AnswerA} = chappe_sip_media:conference(
                      SA, Room, #{sdp => peer_sdp(APort, alaw, false)}),
    ?assertNotEqual(nomatch, binary:match(AnswerA, <<"a=rtpmap:8 PCMA/8000">>)),
    ?assertEqual(nomatch, binary:match(AnswerA, <<"a=rtcp-mux">>)),
    ?assertNotEqual(nomatch, binary:match(AnswerA, <<"a=sendrecv">>)),
    peer_dst(A, audio_port(AnswerA)),

    {B, BPort} = peer_start(ulaw),
    {ok, SB} = conf_session(),
    {ok, OfferB} = chappe_sip_media:conference(SB, Room, #{}),
    ?assertNotEqual(nomatch, binary:match(OfferB, <<"a=rtpmap:0 PCMU/8000">>)),
    ?assertNotEqual(nomatch, binary:match(OfferB, <<"a=rtcp-mux">>)),
    ok = chappe_sip_media:set_remote(SB, peer_sdp(BPort, ulaw, true)),
    peer_dst(B, audio_port(OfferB)),

    #{conf := Conf} = chappe_sip_media:info(SA),
    ?assertMatch(#{conf := Conf, room := Room}, chappe_sip_media:info(SB)),

    %% only A talks: B hears it, A hears silence
    peer_talk(A, true),
    ?assert(hears(B, 2000)),
    ?assertNot(hears(A, 300)),
    %% both talk: A hears B too
    peer_talk(B, true),
    ?assert(hears(A, 2000)),
    ok = chappe_sip_media:leave(SA),
    ok = chappe_sip_media:leave(SB),
    peer_stop(A),
    peer_stop(B).

%% Leaving takes the leg out; the room stops with its last leg.
conference_leave(_Config) ->
    Room = room(),
    {ok, SA} = conf_session(),
    {ok, SB} = conf_session(),
    {ok, _} = chappe_sip_media:conference(SA, Room, #{}),
    {ok, _} = chappe_sip_media:conference(SB, Room, #{}),
    ?assertEqual({error, already_joined},
                 chappe_sip_media:conference(SA, Room, #{})),
    #{conf := Conf} = chappe_sip_media:info(SA),
    MRef = monitor(process, Conf),
    ok = chappe_sip_media:leave(SA),
    ?assertEqual({error, not_joined}, chappe_sip_media:info(SA)),
    ?assertEqual(1, length(chappe_mix:legs(Conf))),
    ok = chappe_sip_media:stop(SB),
    receive {'DOWN', MRef, process, Conf, _} -> ok
    after 2000 -> ct:fail(room_not_stopped)
    end,
    ?assertEqual({error, not_joined}, chappe_sip_media:leave(SB)),
    %% the name is free again: a new join makes a new room
    {ok, SC} = conf_session(),
    {ok, _} = chappe_sip_media:conference(SC, Room, #{}),
    #{conf := Conf2} = chappe_sip_media:info(SC),
    ?assertNotEqual(Conf, Conf2),
    ok = chappe_sip_media:leave(SC).

%% A muted leg still hears the room but nobody hears it.
conference_mute(_Config) ->
    Room = room(),
    {A, SA} = joined_peer(Room),
    {B, SB} = joined_peer(Room),
    ok = chappe_sip_media:mute(SA),
    ?assertMatch(#{muted := true}, chappe_sip_media:info(SA)),
    peer_talk(A, true),
    peer_talk(B, true),
    ?assert(hears(A, 2000)),
    timer:sleep(200),
    peer_clear(B),
    ?assertNot(hears(B, 400)),
    ok = chappe_sip_media:unmute(SA),
    ?assert(hears(B, 2000)),
    ok = chappe_sip_media:leave(SA),
    ok = chappe_sip_media:leave(SB),
    peer_stop(A),
    peer_stop(B).

%% The room owner going away stops the room under every leg in it.
conference_owner_death(_Config) ->
    Room = room(),
    Owner = spawn(fun() -> receive stop -> ok end end),
    {ok, SA} = conf_session(),
    {ok, SB} = conf_session(),
    {ok, _} = chappe_sip_media:conference(SA, Room, #{owner => Owner}),
    {ok, _} = chappe_sip_media:conference(SB, Room, #{}),
    #{conf := Conf} = chappe_sip_media:info(SA),
    MRef = monitor(process, Conf),
    exit(Owner, kill),
    receive {'DOWN', MRef, process, Conf, _} -> ok
    after 2000 -> ct:fail(room_not_stopped)
    end,
    ?assertEqual({error, not_joined}, chappe_sip_media:info(SA)),
    ?assertEqual({error, not_joined}, chappe_sip_media:info(SB)).

%% A call process going away takes its leg out of the room.
conference_leg_owner_death(_Config) ->
    Room = room(),
    {ok, SA} = conf_session(),
    {ok, _} = chappe_sip_media:conference(SA, Room, #{}),
    #{conf := Conf} = chappe_sip_media:info(SA),
    Self = self(),
    Call = spawn(fun() ->
        {ok, S} = conf_session(),
        {ok, _} = chappe_sip_media:conference(S, Room, #{}),
        Self ! {joined, self()},
        receive stop -> ok end
    end),
    receive {joined, Call} -> ok after 2000 -> ct:fail(not_joined) end,
    ?assertEqual(2, length(chappe_mix:legs(Conf))),
    exit(Call, kill),
    ?assert(wait_until(fun() -> length(chappe_mix:legs(Conf)) =:= 1 end, 2000)),
    ok = chappe_sip_media:leave(SA).

%% What the mixer answers and what it refuses.
conference_sdp(_Config) ->
    Room = room(),
    {ok, S} = conf_session(),
    Opus = <<"v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
             "t=0 0\r\nm=audio 4000 RTP/AVP 96\r\n"
             "a=rtpmap:96 opus/48000/2\r\n">>,
    ?assertEqual({error, no_common_codec},
                 chappe_sip_media:conference(S, Room, #{sdp => Opus})),
    Srtp = <<"v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
             "t=0 0\r\nm=audio 4000 RTP/SAVP 0\r\n">>,
    ?assertEqual({error, {unsupported_proto, <<"RTP/SAVP">>}},
                 chappe_sip_media:conference(S, Room, #{sdp => Srtp})),
    %% video is rejected in place, audio answered with the offer's
    %% preferred law, the muxed RTCP kept
    Offer = <<"v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
              "t=0 0\r\nm=video 5000 RTP/AVP 97\r\na=rtpmap:97 VP8/90000\r\n"
              "m=audio 4000 RTP/AVP 96 8 0\r\na=rtpmap:96 opus/48000/2\r\n"
              "a=rtcp-mux\r\n">>,
    {ok, Answer} = chappe_sip_media:conference(S, Room, #{sdp => Offer}),
    ?assertNotEqual(nomatch, binary:match(Answer, <<"m=video 0 RTP/AVP 97">>)),
    ?assertNotEqual(nomatch, binary:match(Answer, <<" RTP/AVP 8\r\n">>)),
    ?assertNotEqual(nomatch, binary:match(Answer, <<"a=rtcp-mux">>)),
    ?assertNotEqual(nomatch, binary:match(Answer, <<"c=IN IP4 127.0.0.1">>)),
    ?assertMatch(#{law := alaw}, chappe_sip_media:info(S)),
    %% an answer in another law than the leg's is refused
    ?assertEqual({error, {law_mismatch, ulaw}},
                 chappe_sip_media:set_remote(S, peer_sdp(4000, ulaw, true))),
    ok = chappe_sip_media:leave(S).

%% The far end's packet time reaches the leg (the mixer takes any size
%% and always sends 20 ms, so the answer still says 20); a far end that
%% takes no more than 10 ms per packet cannot be served and is refused.
conference_ptime(_Config) ->
    Room = room(),
    {ok, S} = conf_session(),
    Sdp = fun(Attrs) ->
        <<"v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
          "t=0 0\r\nm=audio 4000 RTP/AVP 0\r\n", Attrs/binary>>
    end,
    ?assertEqual({error, {maxptime, 10}},
                 chappe_sip_media:conference(
                   S, Room, #{sdp => Sdp(<<"a=maxptime:10\r\n">>)})),
    {ok, Answer} = chappe_sip_media:conference(
                     S, Room,
                     #{sdp => Sdp(<<"a=ptime:30\r\na=maxptime:60\r\n">>)}),
    ?assertNotEqual(nomatch, binary:match(Answer, <<"a=ptime:20">>)),
    #{conf := Conf, leg := Leg} = chappe_sip_media:info(S),
    ?assertMatch([#{ptime := 30}],
                 [L || #{id := Id} = L <- chappe_mix:legs(Conf), Id =:= Leg]),
    ok = chappe_sip_media:leave(S).

%% RFC 4733 events: an offer with telephone-event is answered with it,
%% on the offer's payload type, listing events 0 to 16; the leg sends
%% the far end only the events its fmtp lists. An offer without it gets
%% none. The mixer's own offer carries telephone-event, and an answer
%% that takes it gives the leg its payload type.
conference_dtmf(_Config) ->
    Room = room(),
    Sdp = fun(Fmts, Attrs) ->
        <<"v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
          "t=0 0\r\nm=audio 4000 RTP/AVP ", Fmts/binary, "\r\n",
          Attrs/binary>>
    end,
    Leg = fun(S) ->
        #{conf := Conf, leg := L} = chappe_sip_media:info(S),
        [Info] = [I || #{id := Id} = I <- chappe_mix:legs(Conf), Id =:= L],
        Info
    end,
    {ok, S1} = conf_session(),
    {ok, A1} = chappe_sip_media:conference(
                 S1, Room,
                 #{sdp => Sdp(<<"0 101">>,
                              <<"a=rtpmap:101 telephone-event/8000\r\n"
                                "a=fmtp:101 0-11\r\n">>)}),
    ?assertNotEqual(nomatch, binary:match(A1, <<" RTP/AVP 0 101\r\n">>)),
    ?assertNotEqual(nomatch,
                    binary:match(A1, <<"a=rtpmap:101 telephone-event/8000">>)),
    ?assertNotEqual(nomatch, binary:match(A1, <<"a=fmtp:101 0-16">>)),
    ?assertMatch(#{dtmf_pt := 101, dtmf_events := [0, 1, 2, 3, 4, 5, 6, 7, 8,
                                                   9, 10, 11]}, Leg(S1)),
    {ok, S2} = conf_session(),
    {ok, A2} = chappe_sip_media:conference(
                 S2, Room, #{sdp => Sdp(<<"0">>, <<>>)}),
    ?assertEqual(nomatch, binary:match(A2, <<"telephone-event">>)),
    ?assertMatch(#{dtmf_pt := undefined}, Leg(S2)),
    {ok, S3} = conf_session(),
    {ok, O3} = chappe_sip_media:conference(S3, Room, #{}),
    ?assertNotEqual(nomatch,
                    binary:match(O3, <<"a=rtpmap:101 telephone-event/8000">>)),
    ?assertNotEqual(nomatch, binary:match(O3, <<"a=fmtp:101 0-16">>)),
    ?assertMatch(#{dtmf_pt := undefined}, Leg(S3)),
    ok = chappe_sip_media:set_remote(
           S3, Sdp(<<"0 100">>, <<"a=rtpmap:100 telephone-event/8000\r\n">>)),
    %% no fmtp: the DTMF digits only (RFC 4733 2.5.1.1)
    ?assertMatch(#{dtmf_pt := 100, dtmf_events := [0, 1, 2, 3, 4, 5, 6, 7, 8,
                                                   9, 10, 11, 12, 13, 14, 15]},
                 Leg(S3)),
    [ok = chappe_sip_media:leave(S) || S <- [S1, S2, S3]].

%% RFC 3605: a media-level a=rtcp names the RTCP port, and maybe the
%% address, the leg reports to; a session-level one is not an a=rtcp at
%% all, and with rtcp-mux RTCP stays on the RTP port.
conference_rtcp_port(_Config) ->
    Room = room(),
    Sdp = fun(Sess, Media) ->
        <<"v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n",
          Sess/binary, "t=0 0\r\nm=audio 4000 RTP/AVP 0\r\n", Media/binary>>
    end,
    Leg = fun(S) ->
        #{conf := Conf, leg := L} = chappe_sip_media:info(S),
        [Info] = [I || #{id := Id} = I <- chappe_mix:legs(Conf), Id =:= L],
        Info
    end,
    Join = fun(Offer) ->
        {ok, S} = conf_session(),
        {ok, _} = chappe_sip_media:conference(S, Room, #{sdp => Offer}),
        S
    end,
    S1 = Join(Sdp(<<>>, <<"a=rtcp:5011\r\n">>)),
    ?assertMatch(#{rtcp_remote := {{127, 0, 0, 1}, 5011}}, Leg(S1)),
    S2 = Join(Sdp(<<>>, <<"a=rtcp:5013 IN IP4 10.1.2.3\r\n">>)),
    ?assertMatch(#{rtcp_remote := {{10, 1, 2, 3}, 5013}}, Leg(S2)),
    S3 = Join(Sdp(<<"a=rtcp:5015\r\n">>, <<>>)),
    ?assertMatch(#{rtcp_remote := undefined}, Leg(S3)),
    S4 = Join(Sdp(<<>>, <<"a=rtcp-mux\r\na=rtcp:4000\r\n">>)),
    ?assertMatch(#{rtcp_remote := undefined}, Leg(S4)),
    %% the answer to the mixer's offer can carry one too
    {ok, S5} = conf_session(),
    {ok, _} = chappe_sip_media:conference(S5, Room, #{}),
    ok = chappe_sip_media:set_remote(
           S5, Sdp(<<>>, <<"a=rtcp:5017 IN IP4 10.1.2.4\r\n">>)),
    ?assertMatch(#{rtcp_remote := {{10, 1, 2, 4}, 5017}}, Leg(S5)),
    [ok = chappe_sip_media:leave(S) || S <- [S1, S2, S3, S4, S5]].

%% SDP directions: the leg does what the far end asked, seen from the
%% room (an offer that only sends gets a leg the room only takes from,
%% and a=recvonly back), at media or session level; the mixer's own offer
%% says the direction the join asked for.
conference_directions(_Config) ->
    Room = room(),
    Sdp = fun(Sess, Media) ->
        <<"v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n",
          Sess/binary, "t=0 0\r\nm=audio 4000 RTP/AVP 0\r\n", Media/binary>>
    end,
    Dir = fun(S) ->
        #{conf := Conf, leg := L} = chappe_sip_media:info(S),
        [D] = [D || #{id := Id, direction := D} <- chappe_mix:legs(Conf),
                    Id =:= L],
        D
    end,
    Join = fun(Opts) ->
        {ok, S} = conf_session(),
        {ok, Sdp1} = chappe_sip_media:conference(S, Room, Opts),
        {S, Sdp1}
    end,
    Cases = [
        {Sdp(<<>>, <<"a=sendonly\r\n">>), recvonly, <<"a=recvonly">>},
        {Sdp(<<>>, <<"a=recvonly\r\n">>), sendonly, <<"a=sendonly">>},
        {Sdp(<<>>, <<"a=inactive\r\n">>), inactive, <<"a=inactive">>},
        {Sdp(<<"a=sendonly\r\n">>, <<>>), recvonly, <<"a=recvonly">>},
        {Sdp(<<"a=sendonly\r\n">>, <<"a=sendrecv\r\n">>), sendrecv,
         <<"a=sendrecv">>}
    ],
    Ss = [
        begin
            {S, Answer} = Join(#{sdp => Offer}),
            ?assertNotEqual(nomatch, binary:match(Answer, Attr), {Offer, Answer}),
            ?assertEqual(Want, Dir(S)),
            S
        end
     || {Offer, Want, Attr} <- Cases
    ],
    {S6, Offer6} = Join(#{direction => recvonly}),
    ?assertNotEqual(nomatch, binary:match(Offer6, <<"a=recvonly">>)),
    ?assertEqual(recvonly, Dir(S6)),
    %% the answer to the mixer's offer can narrow it
    {S7, _} = Join(#{}),
    ok = chappe_sip_media:set_remote(S7, Sdp(<<>>, <<"a=recvonly\r\n">>)),
    ?assertEqual(sendonly, Dir(S7)),
    [ok = chappe_sip_media:leave(S) || S <- Ss ++ [S6, S7]].

%% deaf: the leg keeps talking to the room and hears nothing of it (the
%% room sends it nothing); undeaf gives it back. relate/3: one leg stops
%% hearing another, then hears it again.
conference_deaf_relate(_Config) ->
    Room = room(),
    {ok, S1} = conf_session(),
    {ok, S2} = conf_session(),
    {ok, _} = chappe_sip_media:conference(S1, Room, #{}),
    {ok, _} = chappe_sip_media:conference(S2, Room, #{}),
    #{conf := Conf, leg := L1} = chappe_sip_media:info(S1),
    #{leg := L2} = chappe_sip_media:info(S2),
    Leg = fun(L) ->
        [I] = [I || #{id := Id} = I <- chappe_mix:legs(Conf), Id =:= L],
        I
    end,
    ok = chappe_sip_media:deaf(S1),
    ?assertMatch(#{direction := recvonly}, Leg(L1)),
    ?assertMatch(#{deaf := true}, chappe_sip_media:info(S1)),
    ok = chappe_sip_media:mute(S1),
    ?assertMatch(#{direction := inactive}, Leg(L1)),
    ok = chappe_sip_media:undeaf(S1),
    ?assertMatch(#{direction := sendonly}, Leg(L1)),
    ok = chappe_sip_media:unmute(S1),
    ?assertMatch(#{direction := sendrecv}, Leg(L1)),
    ok = chappe_sip_media:relate(S1, S2, nohear),
    ?assertMatch(#{nohear := [L2]}, Leg(L1)),
    ok = chappe_sip_media:relate(S1, S2, hear),
    ?assertMatch(#{nohear := []}, Leg(L1)),
    %% legs of two rooms have no relation
    {ok, S3} = conf_session(),
    {ok, _} = chappe_sip_media:conference(S3, room(), #{}),
    ?assertEqual({error, not_same_room}, chappe_sip_media:relate(S1, S3, nohear)),
    [ok = chappe_sip_media:leave(S) || S <- [S1, S2, S3]].

%% ---- conference behind rtpengine ----

%% The deployed shape: the caller is anchored on rtpengine, which offers
%% toward the mixer leg; the mixer answers, and rtpengine's answer goes
%% back to the caller. A second leg joins the room directly. Both hear the
%% other.
conference_behind_rtpengine(Config) ->
    RtpeIp = ?config(rtpe_ip, Config),
    MediaIp = ?config(media_ip, Config),
    Room = room(),
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    CallId = <<"chappe-sip-media-live-", Suffix/binary>>,
    {Caller, CallerPort} = peer_start(ulaw, {0, 0, 0, 0}),
    {ok, Anchor} = chappe_sip_media:session(
                     #{call_id => CallId, from_tag => <<"caller-", Suffix/binary>>},
                     #{capability => anchor, node => ?LIVE_NODE}),
    {ok, ToMixer} = chappe_sip_media:offer(
                      Anchor, peer_sdp(CallerPort, ulaw, false, MediaIp),
                      #{params => #{ice => remove}}),
    {ok, SM} = chappe_sip_media:session(#{call_id => CallId},
                                        #{capability => conference}),
    {ok, MixAnswer} = chappe_sip_media:conference(SM, Room, #{sdp => ToMixer}),
    %% rtpengine advertises the address it is published on; reach it where
    %% the test does
    ok = chappe_sip_media:set_remote(SM, {RtpeIp, audio_port(ToMixer)}),
    {ok, ToCaller} = chappe_sip_media:answer(
                       Anchor, MixAnswer,
                       #{to_tag => <<"mix-", Suffix/binary>>,
                         params => #{ice => remove}}),
    ct:log("to mixer:~n~s~nmixer answer:~n~s~nto caller:~n~s",
           [ToMixer, MixAnswer, ToCaller]),
    peer_dst(Caller, {RtpeIp, audio_port(ToCaller)}),

    {Direct, DirectPort} = peer_start(ulaw),
    {ok, SD} = conf_session(),
    {ok, DAnswer} = chappe_sip_media:conference(
                      SD, Room, #{sdp => peer_sdp(DirectPort, ulaw, true)}),
    peer_dst(Direct, audio_port(DAnswer)),

    peer_talk(Caller, true),
    ?assert(hears(Direct, 4000)),
    peer_talk(Direct, true),
    ?assert(hears(Caller, 4000)),
    ok = chappe_sip_media:leave(SD),
    ok = chappe_sip_media:leave(SM),
    ok = chappe_sip_media:stop(Anchor),
    peer_stop(Caller),
    peer_stop(Direct).

%% ---- helpers ----

identity() ->
    #{call_id => <<"call-1">>, from_tag => <<"ft-1">>, to_tag => <<"tt-1">>}.

room() ->
    <<"room-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

conf_session() ->
    chappe_sip_media:session(#{call_id => room()}, #{capability => conference}).

%% A peer joined to Room by answering its offer.
joined_peer(Room) ->
    {P, Port} = peer_start(ulaw),
    {ok, S} = conf_session(),
    {ok, Answer} = chappe_sip_media:conference(
                     S, Room, #{sdp => peer_sdp(Port, ulaw, true)}),
    peer_dst(P, audio_port(Answer)),
    {P, S}.

%% A dialog handle backed by a stand-in for the dialog fsm (it answers the
%% tag and Call-ID queries) and indexed under Role, as a confirmed dialog
%% is.
fake_dialog(Role) ->
    Pid = spawn(fun fake_dialog_loop/0),
    Key = {<<"dlg-call">>, <<"local-tag">>, <<"remote-tag">>},
    ok = chappe_sip_dialog_index:insert(Key, 1, confirmed, Role, Pid),
    {chappe_sip_dialog:make(Pid, 1), Pid}.

fake_dialog_loop() ->
    receive
        {'$gen_call', From, Query} ->
            gen_statem:reply(From, fake_dialog_reply(Query)),
            fake_dialog_loop()
    end.

fake_dialog_reply(call_id) -> <<"dlg-call">>;
fake_dialog_reply(local_tag) -> <<"local-tag">>;
fake_dialog_reply(remote_tag) -> <<"remote-tag">>.

wait_until(Fun, Timeout) when Timeout =< 0 ->
    Fun();
wait_until(Fun, Timeout) ->
    case Fun() of
        true -> true;
        false -> timer:sleep(20), wait_until(Fun, Timeout - 20)
    end.

audio_port(Sdp) ->
    {match, [Port]} = re:run(Sdp, <<"m=audio ([0-9]+)">>,
                             [{capture, all_but_first, binary}]),
    binary_to_integer(Port).

peer_sdp(Port, Law, Mux) ->
    peer_sdp(Port, Law, Mux, <<"127.0.0.1">>).

peer_sdp(Port, Law, Mux, Ip) ->
    {Pt, Map} = case Law of
                    ulaw -> {<<"0">>, <<"a=rtpmap:0 PCMU/8000\r\n">>};
                    alaw -> {<<"8">>, <<"a=rtpmap:8 PCMA/8000\r\n">>}
                end,
    iolist_to_binary(
      [<<"v=0\r\no=- 1 1 IN IP4 ">>, Ip, <<"\r\ns=peer\r\nc=IN IP4 ">>, Ip,
       <<"\r\nt=0 0\r\nm=audio ">>, integer_to_binary(Port), <<" RTP/AVP ">>,
       Pt, <<"\r\n">>, Map, <<"a=ptime:20\r\na=sendrecv\r\n">>,
       case Mux of
           true -> <<"a=rtcp-mux\r\n">>;
           false -> <<>>
       end]).

%% ---- G.711 RTP peer ----
%%
%% One UDP socket. While talking it sends a loud constant frame every 20 ms
%% to its destination; it keeps whether any audio frame (not the law's
%% silence code) came back.

peer_start(Law) ->
    peer_start(Law, {127, 0, 0, 1}).

peer_start(Law, Ip) ->
    Self = self(),
    Pid = spawn_link(fun() ->
        {ok, Sock} = gen_udp:open(0, [binary, {ip, Ip}, {active, true}]),
        {ok, Port} = inet:port(Sock),
        Self ! {self(), port, Port},
        peer_loop(#{sock => Sock, law => Law, dst => undefined, talk => false,
                    seq => 0, heard => false})
    end),
    receive {Pid, port, Port} -> {Pid, Port}
    after 2000 -> ct:fail(peer_start)
    end.

peer_stop(Pid) ->
    unlink(Pid),
    exit(Pid, kill).

peer_dst(Pid, Port) when is_integer(Port) ->
    peer_dst(Pid, {{127, 0, 0, 1}, Port});
peer_dst(Pid, Dst) ->
    Pid ! {dst, Dst},
    ok.

peer_talk(Pid, Talk) ->
    Pid ! {talk, Talk},
    ok.

peer_clear(Pid) ->
    Pid ! clear,
    ok.

%% Whether the peer hears audio within Timeout ms.
hears(Pid, Timeout) ->
    wait_until(fun() -> peer_heard(Pid) end, Timeout).

peer_heard(Pid) ->
    Ref = make_ref(),
    Pid ! {heard, self(), Ref},
    receive {Ref, Heard} -> Heard
    after 1000 -> false
    end.

peer_loop(#{sock := Sock, law := Law} = P) ->
    receive
        {dst, Dst} ->
            erlang:send_after(20, self(), tick),
            peer_loop(P#{dst => Dst});
        {talk, Talk} ->
            peer_loop(P#{talk => Talk});
        clear ->
            peer_loop(P#{heard => false});
        {heard, From, Ref} ->
            From ! {Ref, maps:get(heard, P)},
            peer_loop(P);
        tick ->
            erlang:send_after(20, self(), tick),
            peer_loop(peer_send(P));
        {udp, Sock, _Ip, _Port, <<2:2, _:7, Pt:7, _:16, _:32, _:32,
                                  Payload/binary>>} when Pt =:= 0; Pt =:= 8 ->
            Heard = maps:get(heard, P) orelse
                        Payload =/= binary:copy(<<(silence(Law))>>,
                                                byte_size(Payload)),
            peer_loop(P#{heard => Heard});
        {udp, Sock, _, _, _} ->
            peer_loop(P)
    end.

peer_send(#{talk := false} = P) ->
    P;
peer_send(#{sock := Sock, law := Law, dst := {Ip, Port}, seq := Seq} = P) ->
    Pt = case Law of ulaw -> 0; alaw -> 8 end,
    Hdr = <<2:2, 0:1, 0:1, 0:4, 0:1, Pt:7, (Seq band 16#FFFF):16,
            (Seq * 160 band 16#FFFFFFFF):32, 16#5EED:32>>,
    %% a loud constant: 0x80 is near full scale in mu-law, 0xAA in A-law
    Loud = case Law of ulaw -> 16#80; alaw -> 16#AA end,
    _ = gen_udp:send(Sock, Ip, Port, <<Hdr/binary, (binary:copy(<<Loud>>, 160))/binary>>),
    P#{seq => Seq + 1}.

silence(ulaw) -> 16#FF;
silence(alaw) -> 16#D5.

%% Value of Key in the last command named Name, out of an already-drained list.
tag_of(Name, Key, Cmds) ->
    case [C || C <- Cmds, maps:get(<<"command">>, C, undefined) =:= Name] of
        [] -> undefined;
        Matches -> maps:get(Key, lists:last(Matches), undefined)
    end.

%% Whether command Name carried Flag in its flags list.
has_flag(Name, Flag, Cmds) ->
    case tag_of(Name, <<"flags">>, Cmds) of
        Flags when is_list(Flags) -> lists:member(Flag, Flags);
        _ -> false
    end.

%% Collect every {fake_cmd, Cmd} currently in the mailbox.
drain_cmds() ->
    drain_cmds([]).

drain_cmds(Acc) ->
    receive
        {fake_cmd, Cmd} -> drain_cmds([Cmd | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

wait_for_cmd(_Name, Timeout) when Timeout =< 0 ->
    false;
wait_for_cmd(Name, Timeout) ->
    receive
        {fake_cmd, Cmd} ->
            case maps:get(<<"command">>, Cmd, undefined) of
                Name -> true;
                _ -> wait_for_cmd(Name, Timeout)
            end
    after Timeout ->
        false
    end.

%% ---- fake rtpengine NG node (UDP) ----

start_fake(Collector) ->
    Self = self(),
    Pid = spawn(fun() -> fake_init(Self, Collector) end),
    put(fake_pid, Pid),
    receive
        {fake_port, Pid, Port} -> Port
    after 2000 -> exit(fake_start_timeout)
    end.

stop_fake() ->
    case get(fake_pid) of
        undefined -> ok;
        Pid -> Pid ! stop, ok
    end.

fake_init(Starter, Collector) ->
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}]),
    {ok, Port} = inet:port(Sock),
    Starter ! {fake_port, self(), Port},
    fake_loop(Sock, Collector).

fake_loop(Sock, Collector) ->
    receive
        {udp, Sock, IP, PPort, Packet} ->
            [Cookie, Body] = binary:split(Packet, <<" ">>),
            {ok, Cmd} = chappe_rtpengine_bencode:decode(Body),
            Collector ! {fake_cmd, Cmd},
            Reply = fake_reply(maps:get(<<"command">>, Cmd, <<>>)),
            RBin = chappe_rtpengine_bencode:encode_to_binary(Reply),
            ok = gen_udp:send(Sock, IP, PPort,
                              <<Cookie/binary, " ", RBin/binary>>),
            fake_loop(Sock, Collector);
        stop ->
            gen_udp:close(Sock)
    end.

fake_reply(<<"offer">>) ->
    #{<<"result">> => <<"ok">>, <<"sdp">> => <<"v=0 fake-offer">>};
fake_reply(<<"answer">>) ->
    #{<<"result">> => <<"ok">>, <<"sdp">> => <<"v=0 fake-answer">>};
fake_reply(<<"publish">>) ->
    #{<<"result">> => <<"ok">>, <<"sdp">> => <<"v=0 fake-publish">>};
fake_reply(<<"subscribe request">>) ->
    %% a two-stream tap, as a multi-stream (SIPREC) recording offer taps
    #{<<"result">> => <<"ok">>, <<"sdp">> => fake_sub_sdp(),
      <<"to-tag">> => <<"sub-1">>};
fake_reply(_Other) ->
    #{<<"result">> => <<"ok">>}.

fake_sub_sdp() ->
    <<"v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
      "t=0 0\r\n"
      "m=audio 30010 RTP/AVP 0\r\na=label:1\r\na=rtpmap:0 PCMU/8000\r\n"
      "m=audio 30012 RTP/AVP 0\r\na=label:2\r\na=rtpmap:0 PCMU/8000\r\n">>.
