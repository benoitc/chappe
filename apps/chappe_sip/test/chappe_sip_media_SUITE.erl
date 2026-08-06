%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc chappe_sip_media facade tests against a fake rtpengine NG node.
%%
%% A minimal in-suite UDP server speaks the NG wire protocol (cookie SP
%% bencode) using chappe_rtpengine's own bencode codec, so the whole path
%% facade -> chappe_sip_media_rtpengine -> chappe_rtpengine_session -> chappe_rtpengine_client -> wire is
%% exercised without a real rtpengine. Live coverage against a real node is in
%% chappe_rtpengine's own interop track.
-module(chappe_sip_media_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([offer_answer/1, play_and_dtmf/1, capability_routing/1,
         unknown_capability/1, owner_death_tears_down/1,
         subscribe_tap/1, duck_block/1, duck_silence/1,
         unsupported_on_freeswitch/1]).

all() ->
    [offer_answer, play_and_dtmf, capability_routing, unknown_capability,
     owner_death_tears_down, subscribe_tap, duck_block, duck_silence,
     unsupported_on_freeswitch].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_engine_fake,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    _ = application:stop(chappe_rtpengine),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
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

%% ---- tests ----

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

play_and_dtmf(_Config) ->
    {ok, S} = chappe_sip_media:session(identity(), #{capability => anchor}),
    {ok, _} = chappe_sip_media:offer(S, <<"v=0 caller-offer">>),
    ?assertEqual(ok, chappe_sip_media:play(S, #{file => <<"/tmp/x.wav">>})),
    ?assertEqual(ok, chappe_sip_media:dtmf(S, #{code => 1})),
    ?assertEqual(ok, chappe_sip_media:stop(S)).

capability_routing(_Config) ->
    %% conference routes to the FreeSWITCH backend, which rejects for the
    %% missing channel (no_node only comes from that adapter, proving routing)
    ?assertEqual({error, no_node},
                 chappe_sip_media:session(identity(), #{capability => conference})),
    %% explicit backend override to freeswitch, same result
    ?assertEqual({error, no_node},
                 chappe_sip_media:session(identity(),
                                    #{capability => anchor,
                                      backend => freeswitch})).

unknown_capability(_Config) ->
    ?assertEqual({error, {no_backend, bogus}},
                 chappe_sip_media:session(identity(), #{capability => bogus})).

subscribe_tap(_Config) ->
    {ok, S} = chappe_sip_media:session(identity(), #{capability => anchor}),
    {ok, _} = chappe_sip_media:offer(S, <<"v=0 caller-offer">>),
    {ok, _} = chappe_sip_media:answer(S, <<"v=0 callee-answer">>),
    _ = drain_cmds(),
    {ok, Sub} = chappe_sip_media:subscribe(S, #{party => caller}),
    ?assertEqual(<<"v=0 fake-sub">>, maps:get(sdp, Sub)),
    ?assertEqual(<<"sub-1">>, maps:get(to_tag, Sub)),
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

unsupported_on_freeswitch(_Config) ->
    {ok, S} = chappe_sip_media:session(#{call_id => <<"c">>},
                                 #{capability => conference, node => fs1,
                                   uuid => <<"chan">>}),
    ?assertEqual({error, {unsupported, subscribe}},
                 chappe_sip_media:subscribe(S, #{})),
    ?assertEqual({error, {unsupported, subscribe}},
                 chappe_sip_media:subscribe_answer(
                   S, #{to_tag => <<"x">>, sdp => <<"s">>})),
    ?assertEqual({error, {unsupported, subscribe}},
                 chappe_sip_media:unsubscribe(S, #{to_tag => <<"x">>})),
    ?assertEqual({error, {unsupported, duck}}, chappe_sip_media:duck(S, #{})),
    ?assertEqual({error, {unsupported, duck}}, chappe_sip_media:unduck(S, #{})).

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

%% ---- helpers ----

identity() ->
    #{call_id => <<"call-1">>, from_tag => <<"ft-1">>, to_tag => <<"tt-1">>}.

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
fake_reply(<<"subscribe request">>) ->
    #{<<"result">> => <<"ok">>, <<"sdp">> => <<"v=0 fake-sub">>,
      <<"to-tag">> => <<"sub-1">>};
fake_reply(_Other) ->
    #{<<"result">> => <<"ok">>}.
