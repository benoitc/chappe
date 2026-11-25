%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% chappe_mrf end to end on loopback: the real SIP engine, chappe_mix
%% for native rooms, and fakes for FreeSWITCH (SIP plus its outbound
%% event socket), rtpengine and the callers (chappe_mrf_fake). The same
%% flows run against real FreeSWITCH and rtpengine in
%% chappe_mrf_live_SUITE.
-module(chappe_mrf_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    connect_caller_ivr/1,
    fs_refer_transfers_caller/1,
    refer_removes_member/1,
    refer_native_joined_on_answer/1,
    refer_outcomes/1,
    refer_lock_max_both_backends/1,
    refer_idempotent/1,
    refer_ood_replaces/1,
    refer_bye_roster_uri/1,
    refer_bye_ambiguous_485/1,
    refer_bye_cross_room/1,
    refer_bye_unauthorized/1,
    refer_room_end_487/1,
    refer_norefersub/1,
    ood_target_dialog_member/1,
    refer_nested_refer/1,
    referred_invite_joins/1,
    member_transfer_attended/1,
    invite_replaces_member/1,
    refer_policy_crash/1,
    refer_admission_probe/1,
    refer_worker_dies/1,
    refer_bye_two_members_one_origin/1,
    refer_two_origins_one_dial/1,
    refer_dial_fun_once/1,
    refer_dial_fun_crash/1,
    refer_abort_other_origin/1,
    refer_dial_own_uri_no_focus/1,
    refer_replaces_callid_chars/1,
    invite_replaces_policy/1,
    invite_replaces_default/1,
    invite_replaces_anonymous/1,
    invite_replaces_race/1,
    invite_replaces_caller_dies/1,
    transferred_drops_privacy/1,
    refer_adds_fs/1,
    refer_hostile_target/1,
    refer_bgdial/1,
    dialed_party_leaves/1,
    dialed_party_flags/1,
    member_transferred/1,
    focus_member_refer_adds/1,
    member_refer_transfers/1,
    focus_member_refer_removes/1,
    bye_refused_without_focus/1,
    fs_focus_member_isfocus/1,
    session_recording_waits_for_close/1,
    room_recording_waits_for_close/1,
    caller_hangup/1,
    unknown_channel_refused/1,
    owner_death_kills_channel/1,
    no_node/1,
    create_endpoint_bridge/1,
    bridge_to_uri/1,
    endpoint_commands/1,
    play_results/1,
    owner_events/1,
    call_ref/1,
    endpoint_more_commands/1,
    endpoint_call_notices/1,
    node_down/1,
    native_conference/1,
    native_record_to_store/1,
    native_room_outlives_caller/1,
    native_join_unanswered/1,
    native_talking/1,
    fs_conference_pin/1,
    fs_conference_bad_pin/1,
    fs_conference_room/1,
    fs_conference_transfer/1,
    fs_mover_dies/1,
    native_conference_transfer/1,
    conference_focus/1,
    attach_timeout/1,
    failover/1,
    connect_failure/1,
    endpoint_errors/1,
    endpoint_socket/1,
    endpoint_socket_errors/1,
    endpoint_dialog_ends/1,
    setup_edges/1,
    listener_ip_allow/1,
    listener_options_differ/1,
    registry_edges/1,
    registry_restart/1,
    registry_put_restart/1,
    registry_dead_entry/1,
    native_loop_fails/1,
    native_call_loop_fails/1,
    native_endpoint_fails/1,
    native_join_worker_dies/1,
    native_join_bad_handle/1,
    join_timeout_refused/1,
    invite_replaces_stale_hold/1,
    invite_replaces_after_transfer/1,
    invite_replaces_member_left/1,
    sip_edges/1,
    conf_edges/1,
    native_endpoint/1,
    native_hd_room/1,
    dial_codecs_refused/1,
    fs_conference_edges/1
]).

-define(F, chappe_mrf_fake).
-define(FAULTS, chappe_mrf_faults).

all() ->
    [
        connect_caller_ivr,
        fs_refer_transfers_caller,
        refer_removes_member,
        refer_native_joined_on_answer,
        refer_outcomes,
        refer_lock_max_both_backends,
        refer_idempotent,
        refer_ood_replaces,
        refer_bye_roster_uri,
        refer_bye_ambiguous_485,
        refer_bye_cross_room,
        refer_bye_unauthorized,
        refer_room_end_487,
        refer_norefersub,
        ood_target_dialog_member,
        refer_nested_refer,
        referred_invite_joins,
        member_transfer_attended,
        invite_replaces_member,
        refer_policy_crash,
        refer_admission_probe,
        refer_worker_dies,
        refer_bye_two_members_one_origin,
        refer_two_origins_one_dial,
        refer_dial_fun_once,
        refer_dial_fun_crash,
        refer_abort_other_origin,
        refer_dial_own_uri_no_focus,
        refer_replaces_callid_chars,
        invite_replaces_policy,
        invite_replaces_default,
        invite_replaces_anonymous,
        invite_replaces_race,
        invite_replaces_caller_dies,
        transferred_drops_privacy,
        refer_adds_fs,
        refer_hostile_target,
        refer_bgdial,
        dialed_party_leaves,
        dialed_party_flags,
        member_transferred,
        focus_member_refer_adds,
        member_refer_transfers,
        focus_member_refer_removes,
        bye_refused_without_focus,
        fs_focus_member_isfocus,
        session_recording_waits_for_close,
        room_recording_waits_for_close,
        caller_hangup,
        unknown_channel_refused,
        owner_death_kills_channel,
        no_node,
        create_endpoint_bridge,
        bridge_to_uri,
        endpoint_commands,
        play_results,
        owner_events,
        call_ref,
        endpoint_more_commands,
        endpoint_call_notices,
        node_down,
        native_conference,
        native_record_to_store,
        native_room_outlives_caller,
        native_join_unanswered,
        native_talking,
        fs_conference_pin,
        fs_conference_bad_pin,
        fs_conference_room,
        fs_conference_transfer,
        fs_mover_dies,
        native_conference_transfer,
        conference_focus,
        attach_timeout,
        failover,
        connect_failure,
        endpoint_errors,
        endpoint_socket,
        endpoint_socket_errors,
        endpoint_dialog_ends,
        setup_edges,
        listener_ip_allow,
        listener_options_differ,
        registry_edges,
        registry_restart,
        registry_put_restart,
        registry_dead_entry,
        native_loop_fails,
        native_call_loop_fails,
        native_endpoint_fails,
        native_join_worker_dies,
        native_join_bad_handle,
        join_timeout_refused,
        invite_replaces_stale_hold,
        invite_replaces_after_transfer,
        invite_replaces_member_left,
        sip_edges,
        conf_edges,
        native_endpoint,
        native_hd_room,
        dial_codecs_refused,
        fs_conference_edges
    ].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif, [
        {persistent, true}
    ]),
    {ok, _} = application:ensure_all_started(chappe_mrf),
    Config.

end_per_suite(_Config) ->
    _ = application:stop(chappe_mrf),
    _ = application:stop(chappe_esl),
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(_Case, Config) ->
    EP = ?F:pick(),
    ok = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>
    }),
    LP = ?F:pick(),
    ok = chappe_mrf:start(#{esl_port => LP}),
    Rtpe = ?F:rtpe_start(self()),
    Fs = ?F:fs_start(<<"fs1">>, #{esl_port => LP}),
    [{ep, EP}, {lp, LP}, {rtpe, Rtpe}, {fs, Fs} | Config].

end_per_testcase(_Case, Config) ->
    _ = [chappe_mrf_conf:stop(C) || {_, C} <- chappe_mrf:conferences()],
    ?F:fs_stop(?config(fs, Config)),
    ?F:rtpe_stop(?config(rtpe, Config)),
    _ = chappe_mrf:stop_listener(),
    _ = [chappe_esl:node_remove(N) || {N, _} <- chappe_esl:nodes()],
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% ---- helpers ----

fs_uri(Config) ->
    <<"sip:127.0.0.1:",
        (integer_to_binary(?F:fs_port(?config(fs, Config))))/binary>>.

%% Every INVITE goes to connect_caller/3 on the fake node; the handler
%% hands {Ep, B2b} to the test and stays the endpoint's owner until told.
ivr(Config) ->
    ivr(Config, #{}).

ivr(Config, Extra) ->
    Test = self(),
    Targets = [{fs1, fs_uri(Config)}],
    ok = chappe_sip:invite(fun(Req, Res) ->
        Opts = maps:merge(#{targets => Targets, notify => Test}, Extra),
        case chappe_mrf:connect_caller(Req, Res, Opts) of
            {ok, Ep, B2b} ->
                Test ! {connected, Ep, B2b, self()},
                owner_loop(Test);
            Err ->
                Test ! {connect_failed, Err}
        end
    end).

owner_loop(Test) ->
    receive
        {chappe_mrf, _, _} = M ->
            Test ! {owner, M},
            owner_loop(Test);
        {run, From, Fun} ->
            From ! {ran, Fun()},
            owner_loop(Test);
        stop ->
            ok
    end.

%% run Fun in the endpoint's owner (the handler)
in_owner(Owner, Fun) ->
    Owner ! {run, self(), Fun},
    receive
        {ran, R} -> R
    after 10000 -> ct:fail(owner_run)
    end.

call_in(Config) ->
    Ua = ?F:ua_call(?config(ep, Config), #{}),
    {Ep, B2b, Owner} =
        receive
            {connected, E, B, O} -> {E, B, O}
        after 10000 -> ct:fail(no_connect)
        end,
    {ok, 200} = ua_final(Ua),
    {Ua, Ep, B2b, Owner}.

ua_final(Ua) ->
    receive
        {ua, Ua, {final, S, _}} -> {ok, S}
    after 10000 -> ct:fail(no_final)
    end.

ua_event(Ua, What) ->
    receive
        {ua, Ua, {What, Bin}} -> Bin
    after 10000 -> ct:fail({no_ua_event, What})
    end.

no_ua_event(Ua, What, Ms) ->
    receive
        {ua, Ua, {What, Bin}} -> ct:fail({unexpected, What, Bin})
    after Ms -> ok
    end.

fs_cmd(Pattern) ->
    fs_cmd(Pattern, 5000).

fs_cmd(Pattern, Ms) ->
    receive
        {fake_fs, _, _, {cmd, Block}} = M ->
            case binary:match(Block, Pattern) of
                nomatch -> fs_cmd(Pattern, Ms);
                _ -> M
            end
    after Ms -> ct:fail({no_fs_cmd, Pattern})
    end.

fs_what(What) ->
    receive
        {fake_fs, _, _, {What, Bin}} -> Bin
    after 5000 -> ct:fail({no_fs, What})
    end.

owner_msg(Pattern) ->
    receive
        {owner, {chappe_mrf, _, Pattern} = M} -> M
    after 5000 -> ct:fail({no_owner_msg, Pattern})
    end.

has(Bin, Part) -> binary:match(Bin, Part) =/= nomatch.

%% ---- cases ----

%% A caller reaches the IVR: the node gets the INVITE with X-Chappe-Call,
%% the outbound socket comes back and is answered, the caller gets the
%% 200; play, play_collect and DTMF events work on the endpoint.
%% req: MRF-01 MRF-03
connect_caller_ivr(Config) ->
    ivr(Config),
    {Ua, Ep, {_, _}, Owner} = call_in(Config),
    {ok, Uuid} = chappe_mrf:uuid(Ep),
    ?assertMatch(<<"uuid-", _/binary>>, Uuid),
    ?assertEqual({ok, fs1}, chappe_mrf:node(Ep)),
    ok = in_owner(Owner, fun() -> chappe_mrf:play(Ep, <<"/media/menu.wav">>) end),
    {fake_fs, _, _, {cmd, Play}} = fs_cmd(<<"execute-app-name: playback">>),
    ?assert(has(Play, <<"/media/menu.wav">>)),
    ?assertEqual(
        {ok, <<"1">>},
        in_owner(Owner, fun() ->
            chappe_mrf:play_collect(Ep, #{
                file => <<"/media/menu.wav">>, max => 1
            })
        end)
    ),
    ok = ?F:fs_dtmf(?config(fs, Config), <<"5">>),
    _ = owner_msg({dtmf, <<"5">>}),
    ?F:ua_bye(Ua),
    _ = owner_msg({hangup, <<"NORMAL_CLEARING">>}),
    Owner ! stop.

%% The channel REFERs the caller elsewhere (a deflect) on a call made with
%% transfer => auto: chappe carries it out. The target is called with the
%% caller's media through rtpengine, the channel gets the final NOTIFY,
%% then a BYE, and the caller sees neither a REFER nor a re-INVITE.
fs_refer_transfers_caller(Config) ->
    {_Callee, CP} = ?F:callee_start(<<"carol">>),
    %% the target listens on a port of its own on loopback
    ivr(Config, #{
        transfer => auto, transfer_opts => #{domains => [<<"127.0.0.1">>]}
    }),
    {Ua, _Ep, {_, Ref}, Owner} = call_in(Config),
    ReferTo = <<"<sip:carol@127.0.0.1:", (integer_to_binary(CP))/binary, ">">>,
    ok = ?F:fs_refer(?config(fs, Config), ReferTo),
    Answer = fs_what(response),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, Answer),
    receive
        {callee, invite, _Inv} -> ok
    after 5000 -> ct:fail(no_target_invite)
    end,
    ?assert(has(fs_what(notify), <<"SIP/2.0 100">>)),
    ?assert(has(fs_what(notify), <<"SIP/2.0 200">>)),
    _ = fs_what(bye),
    receive
        {chappe_sip_b2b, Ref, {transferred, b, _}} -> ok
    after 5000 -> ct:fail(no_transferred)
    end,
    no_ua_event(Ua, reinvite, 500),
    no_ua_event(Ua, request, 0),
    Owner ! stop.

%% A REFER to the room's URI with method=BYE (RFC 4579 5.11) removes the
%% member with that URI, when the room's policy lets the referrer: 200,
%% NOTIFY 100 then 200, the member leaves kicked. Someone the policy does
%% not let is refused 403 and the member stays; an unknown URI is refused
%% 404.
refer_removes_member(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    ivr(Config),
    Policy = fun(#{referrer := R}) -> has(R, <<"boss@">>) end,
    {ok, Conf} = chappe_mrf:conference(<<"rroom">>, #{
        focus => true, refer_policy => Policy
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    {Ua, _Ep, B2b, _Owner} = call_in(Config),
    {ok, M} = chappe_mrf_conf:join(Conf, B2b, #{
        uri => <<"sip:caller@127.0.0.1">>
    }),
    {joined, M, _} = joined(Conf),
    Bye = <<"<sip:caller@127.0.0.1;method=BYE>">>,
    {Sock, _} = refer(Config, Entity, <<"intruder">>, Bye),
    ?assertMatch(<<"SIP/2.0 403", _/binary>>, sip_response(Sock)),
    ?assertMatch([_], chappe_mrf_conf:members(Conf)),
    {Sock2, _} = refer(Config, Entity, <<"boss">>, Bye),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(Sock2)),
    ?assertEqual([<<"SIP/2.0 100">>, <<"SIP/2.0 200">>], frags(Sock2, 2)),
    _ = ua_event(Ua, bye),
    conf_event(Conf, {left, M, kicked}),
    {Sock3, _} = refer(
        Config, Entity, <<"boss">>, <<"<sip:nobody@127.0.0.1;method=BYE>">>
    ),
    ?assertMatch(<<"SIP/2.0 404", _/binary>>, sip_response(Sock3)).

%% fs: mod_conference dials the party into the room under our uuid; its
%% add-member makes it a member and the referrer gets NOTIFY 200; a
%% method=BYE then kicks it by its URI. The bgdial INVITE has the
%% conference's user and isfocus in its Contact (5.5), and leaves the
%% party's codecs to FreeSWITCH (the profile's).
refer_adds_fs(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {ok, Conf} = chappe_mrf:conference(<<"fsadd">>, #{
        backend => fs,
        node => fs1,
        focus => true,
        refer_policy => fun(_) -> true end
    }),
    {ok, Ep} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    {ok, First} = chappe_mrf_conf:join(Conf, Ep, #{}),
    {joined, First, _} = joined(Conf),
    Entity =
        <<"sip:fsadd@127.0.0.1:",
            (integer_to_binary(?config(ep, Config)))/binary>>,
    {Sock, _} = refer(Config, Entity, <<"boss">>, <<"<sip:dave@10.0.0.8>">>),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(Sock)),
    {fake_fs, _, _, {cmd, Dial}} = fs_cmd(<<"conference fsadd bgdial">>),
    ?assert(has(Dial, <<"}sofia/external/dave@10.0.0.8">>)),
    ?assertNot(has(Dial, <<"absolute_codec_string">>)),
    ?assert(has(Dial, <<"sip_contact_user=fsadd">>)),
    ?assert(has(Dial, <<"sip_invite_contact_params=~isfocus">>)),
    {match, [Uuid]} = re:run(Dial, <<"origination_uuid=([^,}]+)">>, [
        {capture, all_but_first, binary}
    ]),
    ?assertEqual([<<"SIP/2.0 100">>], frags(Sock, 1)),
    Conf !
        {chappe_esl_node, fs1,
            {event, #{
                body => <<>>,
                headers => #{
                    <<"Event-Name">> => <<"CUSTOM">>,
                    <<"Event-Subclass">> => <<"conference::maintenance">>,
                    <<"Conference-Name">> => <<"fsadd">>,
                    <<"Action">> => <<"add-member">>,
                    <<"Member-ID">> => <<"77">>,
                    <<"Unique-ID">> => Uuid
                }
            }}},
    ?assertEqual(<<"SIP/2.0 200">>, final_frag(Sock)),
    {joined, <<"77">>, #{uri := <<"sip:dave@10.0.0.8">>}} = joined(Conf),
    {Sock2, _} = refer(
        Config, Entity, <<"boss">>, <<"<sip:dave@10.0.0.8;method=BYE>">>
    ),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(Sock2)),
    _ = fs_cmd(<<"conference fsadd kick 77">>),
    conf_event(Conf, {left, <<"77">>, kicked}),
    ?assertMatch([#{id := First}], chappe_mrf_conf:members(Conf)),
    ok = chappe_mrf:destroy(Ep).

%% Toll fraud: a Refer-To whose URI carries FreeSWITCH dial-string syntax
%% (a parallel dial through a gateway, per-leg variables, an expansion)
%% is refused 403 before anything is dialed, and the policy of an allowed
%% one sees the dial string it would run.
refer_hostile_target(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    Test = self(),
    {ok, Conf} = chappe_mrf:conference(<<"tollroom">>, #{
        focus => true,
        refer_policy => fun(Info) ->
            Test ! {policy, Info},
            true
        end,
        dial_endpoint => #{targets => [{fs1, fs_uri(Config)}]}
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    Hostile = [
        <<"<sip:a,sofia/gateway/gw/19005551234@h>">>,
        <<"<sip:a|sofia/gateway/gw/1900@h>">>,
        <<"<sip:[leg_timeout=1]a@h>">>,
        <<"<sip:a@h;x=${system(id)}>">>,
        <<"<sip:a:_:sofia/gateway/gw/1900@h>">>,
        <<"<sip:{x=1}a@h>">>
    ],
    lists:foreach(
        fun(T) ->
            {Sock, _} = refer(Config, Entity, <<"boss">>, T),
            ?assertMatch(<<"SIP/2.0 403", _/binary>>, sip_response(Sock)),
            gen_udp:close(Sock)
        end,
        Hostile
    ),
    receive
        {fake_fs, _, _, {invite, _}} = M -> ct:fail({dialed, M})
    after 300 -> ok
    end,
    {Sock2, _} = refer(Config, Entity, <<"boss">>, <<"<sip:carol@10.0.0.9>">>),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(Sock2)),
    receive
        {policy, #{
            action := add,
            dial :=
                <<"[^^:absolute_codec_string=PCMU,PCMA,G722,OPUS]",
                    "sofia/external/carol@10.0.0.9">>
        }} ->
            ok
    after 2000 -> ct:fail(no_dial_in_policy)
    end.

%% fs: the party is dialed with bgdial, so neither the room nor the
%% member whose socket carries the command waits for the target to
%% answer (dial would, for as long as it rings); the job's failure
%% (bgdial-result) is the referrer's final status.
refer_bgdial(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    Slow = ?F:fs_start(<<"slow">>, #{
        esl_port => ?config(lp, Config), dial_delay => 4000
    }),
    {ok, Conf} = chappe_mrf:conference(<<"bgroom">>, #{
        backend => fs, node => slow, refer_policy => fun(_) -> true end
    }),
    {ok, Ep} = chappe_mrf:create_endpoint(#{
        targets => [{slow, uri_of(?F:fs_port(Slow))}]
    }),
    {ok, _First} = chappe_mrf_conf:join(Conf, Ep, #{}),
    {joined, _, _} = joined(Conf),
    Entity =
        <<"sip:bgroom@127.0.0.1:",
            (integer_to_binary(?config(ep, Config)))/binary>>,
    {Sock, _} = refer(Config, Entity, <<"boss">>, <<"<sip:busy@10.0.0.8>">>),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(Sock)),
    {fake_fs, _, _, {cmd, Dial}} = fs_cmd(<<"conference bgroom bgdial">>),
    %% a room without focus => true does not say it is a focus (4.2)
    ?assertNot(has(Dial, <<"isfocus">>)),
    {match, [Uuid]} = re:run(Dial, <<"origination_uuid=([^,}]+)">>, [
        {capture, all_but_first, binary}
    ]),
    T0 = erlang:monotonic_time(millisecond),
    #{members := 1} = chappe_mrf_conf:info(Conf),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 1000),
    Conf !
        {chappe_esl_node, slow,
            {event, #{
                body => <<>>,
                headers => #{
                    <<"Event-Name">> => <<"CUSTOM">>,
                    <<"Event-Subclass">> => <<"conference::maintenance">>,
                    <<"Conference-Name">> => <<"bgroom">>,
                    <<"Action">> => <<"bgdial-result">>,
                    <<"Result">> => <<"USER_BUSY">>,
                    <<"Job-UUID">> => <<"job-1">>,
                    <<"Peer-UUID">> => Uuid
                }
            }}},
    ?assertEqual(<<"SIP/2.0 486">>, final_frag(Sock)),
    ?assertMatch(#{members := 1}, chappe_mrf_conf:info(Conf)),
    ok = chappe_mrf:destroy(Ep),
    ?F:fs_stop(Slow).

%% A party the room dialed for a REFER hangs up: its del-member (on the
%% node's events, as it has no endpoint) takes it off the roster and out
%% of the max_members count.
dialed_party_leaves(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {ok, Conf} = chappe_mrf:conference(<<"leaveroom">>, #{
        backend => fs,
        node => fs1,
        max_members => 2,
        refer_policy => fun(_) -> true end
    }),
    {ok, Ep} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    {ok, _} = chappe_mrf_conf:join(Conf, Ep, #{}),
    {joined, _, _} = joined(Conf),
    Entity =
        <<"sip:leaveroom@127.0.0.1:",
            (integer_to_binary(?config(ep, Config)))/binary>>,
    {Sock, _} = refer(Config, Entity, <<"boss">>, <<"<sip:dave@10.0.0.8>">>),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(Sock)),
    {fake_fs, _, _, {cmd, Dial}} = fs_cmd(<<"conference leaveroom bgdial">>),
    {match, [Uuid]} = re:run(Dial, <<"origination_uuid=([^,}]+)">>, [
        {capture, all_but_first, binary}
    ]),
    Maint = fun(Action) ->
        Conf !
            {chappe_esl_node, fs1,
                {event, #{
                    body => <<>>,
                    headers => #{
                        <<"Event-Name">> => <<"CUSTOM">>,
                        <<"Event-Subclass">> => <<"conference::maintenance">>,
                        <<"Conference-Name">> => <<"leaveroom">>,
                        <<"Action">> => Action,
                        <<"Member-ID">> => <<"88">>,
                        <<"Unique-ID">> => Uuid
                    }
                }}}
    end,
    Maint(<<"add-member">>),
    {joined, <<"88">>, _} = joined(Conf),
    ?assertMatch(#{members := 2}, chappe_mrf_conf:info(Conf)),
    Maint(<<"del-member">>),
    conf_event(Conf, {left, <<"88">>, departed}),
    ?assertMatch(#{members := 1}, chappe_mrf_conf:info(Conf)),
    ok = chappe_mrf:destroy(Ep).

%% A party mod_conference dialed in for a REFER has no endpoint: mute and
%% deaf go to the room's node as conference commands.
dialed_party_flags(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {ok, Conf} = chappe_mrf:conference(<<"flagroom">>, #{
        backend => fs, node => fs1, refer_policy => fun(_) -> true end
    }),
    {ok, Ep} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    {ok, _} = chappe_mrf_conf:join(Conf, Ep, #{}),
    {joined, _, _} = joined(Conf),
    Entity =
        <<"sip:flagroom@127.0.0.1:",
            (integer_to_binary(?config(ep, Config)))/binary>>,
    {Sock, _} = refer(Config, Entity, <<"boss">>, <<"<sip:dave@10.0.0.8>">>),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(Sock)),
    {fake_fs, _, _, {cmd, Dial}} = fs_cmd(<<"conference flagroom bgdial">>),
    {match, [Uuid]} = re:run(Dial, <<"origination_uuid=([^,}]+)">>, [
        {capture, all_but_first, binary}
    ]),
    Conf !
        {chappe_esl_node, fs1,
            {event, #{
                body => <<>>,
                headers => #{
                    <<"Event-Name">> => <<"CUSTOM">>,
                    <<"Event-Subclass">> => <<"conference::maintenance">>,
                    <<"Conference-Name">> => <<"flagroom">>,
                    <<"Action">> => <<"add-member">>,
                    <<"Member-ID">> => <<"66">>,
                    <<"Unique-ID">> => Uuid
                }
            }}},
    {joined, <<"66">>, _} = joined(Conf),
    ok = chappe_mrf_conf:mute(Conf, <<"66">>),
    _ = fs_cmd(<<"conference flagroom mute 66">>),
    ok = chappe_mrf_conf:deaf(Conf, <<"66">>),
    _ = fs_cmd(<<"conference flagroom deaf 66">>),
    ?assertMatch([#{mute := true, deaf := true}], [
        M
     || #{id := <<"66">>} = M <- chappe_mrf_conf:members(Conf)
    ]),
    ok = chappe_mrf:destroy(Ep).

%% A session recording is adopted only once FreeSWITCH says it closed
%% the file (RECORD_STOP, which comes after the media bug goes), never
%% when record_session_stop/2 returns: until then the file stays where
%% FreeSWITCH writes it.
session_recording_waits_for_close(Config) ->
    ivr(Config),
    ok = chappe_audio_store:configure(#{
        dir => filename:join(?config(priv_dir, Config), "store")
    }),
    Path = iolist_to_binary(
        filename:join(?config(priv_dir, Config), "sess.wav")
    ),
    ok = file:write_file(Path, chappe_audio_wav:header(8000, 1, 0)),
    {_Ua, Ep, _B2b, Owner} = call_in(Config),
    ok = in_owner(Owner, fun() ->
        chappe_mrf:record_session(Ep, Path, #{store => default})
    end),
    _ = fs_cmd(<<"RECORD_STOP">>),
    ok = in_owner(Owner, fun() -> chappe_mrf:record_session_stop(Ep, Path) end),
    timer:sleep(800),
    ?assert(filelib:is_regular(Path)),
    ok = ?F:fs_event(?config(fs, Config), <<"RECORD_STOP">>, [
        {<<"Record-File-Path">>, Path}
    ]),
    Id =
        receive
            {owner, {chappe_mrf, Ep, {recorded, R}}} -> R
        after 5000 -> ct:fail(no_recorded)
        end,
    ?assertMatch({ok, _}, chappe_audio_store:get(Id)),
    ?assertNot(filelib:is_regular(Path)),
    Owner ! stop.

%% A room recording is adopted on mod_conference's stop-recording (the
%% file closed), not when `recording stop all' returns.
room_recording_waits_for_close(Config) ->
    ok = chappe_audio_store:configure(#{
        dir => filename:join(?config(priv_dir, Config), "store")
    }),
    Path = iolist_to_binary(
        filename:join(?config(priv_dir, Config), "room.wav")
    ),
    ok = file:write_file(Path, chappe_audio_wav:header(8000, 1, 0)),
    {ok, Conf} = chappe_mrf:conference(<<"recroom">>, #{
        backend => fs, node => fs1
    }),
    {ok, Ep} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    {ok, _} = chappe_mrf_conf:join(Conf, Ep, #{}),
    {joined, _, _} = joined(Conf),
    ok = chappe_mrf_conf:record(Conf, Path, #{
        store => default, ref => <<"room-r">>
    }),
    ok = chappe_mrf_conf:stop_record(Conf),
    receive
        {chappe_mrf_conf, Conf, {recorded, _, _}} = M -> ct:fail({too_early, M})
    after 800 -> ok
    end,
    ?assert(filelib:is_regular(Path)),
    Conf !
        {chappe_esl_node, fs1,
            {event, #{
                body => <<>>,
                headers => #{
                    <<"Event-Name">> => <<"CUSTOM">>,
                    <<"Event-Subclass">> => <<"conference::maintenance">>,
                    <<"Conference-Name">> => <<"recroom">>,
                    <<"Action">> => <<"stop-recording">>,
                    <<"Path">> => Path
                }
            }}},
    receive
        {chappe_mrf_conf, Conf, {recorded, _, {ok, Id}}} ->
            ?assertMatch(
                {ok, #{call_ref := <<"room-r">>}}, chappe_audio_store:get(Id)
            )
    after 5000 -> ct:fail(no_recorded)
    end,
    ok = chappe_mrf:destroy(Ep).

%% RFC 4579 4.2: a member of a focus room is answered with the conference
%% URI and isfocus as its Contact. A REFER in that dialog is a REFER to the
%% focus (5.5): its Refer-To party is dialed into the room, with the
%% Replaces the Refer-To carries on that INVITE (5.10).
%% req: MRF-17
focus_member_refer_adds(Config) ->
    {ok, Conf} = chappe_mrf:conference(<<"froom">>, #{
        focus => true,
        refer_policy => fun(_) -> true end,
        dial_endpoint => #{targets => [{fs1, fs_uri(Config)}]}
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    {Ua, M} = room_caller(Config, Conf),
    {ua, Ua, {final, 200, Ok}} = ua_answer(Ua),
    Contact = ?F:hdr(Ok, <<"contact">>),
    ?assert(has(Contact, Entity)),
    ?assert(has(Contact, <<";isfocus">>)),
    _ = M,
    ok = ?F:ua_refer(
        Ua,
        <<"<sip:carol@10.0.0.9?Replaces=c1%40h%3Bto-tag%3Dt1%3Bfrom-tag%3Df1>">>
    ),
    {ua, Ua, {response, R}} = ua_msg(Ua, response),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, R),
    {fake_fs, _, _, {cmd, Bridge}} = fs_cmd(<<"execute-app-name: bridge">>),
    ?assert(has(Bridge, <<"sofia/external/carol@10.0.0.9">>)),
    ?assert(has(Bridge, <<"_sofia_replaces_=c1@h;to-tag=t1;from-tag=f1">>)),
    %% 5.5: the INVITE to the party has the conference's user and isfocus
    %% in its Contact (sofia's sip_contact_user, sip_invite_contact_params)
    ?assert(has(Bridge, <<"sip_contact_user=froom">>)),
    ?assert(has(Bridge, <<"sip_invite_contact_params=~isfocus">>)),
    ok = chappe_mrf_conf:stop(Conf).

%% A room with focus => false does not advertise isfocus: a member's REFER
%% is an RFC 3515 transfer of that member; the target takes its place in
%% the room.
member_refer_transfers(Config) ->
    {_Callee, CP} = ?F:callee_start(<<"dave">>),
    {ok, Conf} = chappe_mrf:conference(<<"xfroom">>, #{
        focus => false, refer_policy => fun(_) -> true end
    }),
    {Ua, M} = room_caller(Config, Conf),
    {ua, Ua, {final, 200, Ok}} = ua_answer(Ua),
    ?assertNot(has(?F:hdr(Ok, <<"contact">>), <<"isfocus">>)),
    Target = <<"sip:dave@127.0.0.1:", (integer_to_binary(CP))/binary>>,
    ok = ?F:ua_refer(Ua, <<"<", Target/binary, ">">>),
    {ua, Ua, {response, R}} = ua_msg(Ua, response),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, R),
    receive
        {callee, invite, _} -> ok
    after 5000 -> ct:fail(no_target_invite)
    end,
    conf_event(Conf, {left, M, transferred}),
    {joined, M, #{uri := Target}} = joined(Conf),
    ok = chappe_mrf_conf:stop(Conf).

%% In a focus room a member's REFER with method=BYE removes the member it
%% names (5.11), by the URI it called from.
focus_member_refer_removes(Config) ->
    {ok, Conf} = chappe_mrf:conference(<<"rmroom">>, #{
        focus => true, refer_policy => fun(_) -> true end
    }),
    {Ua1, M1} = room_caller(Config, Conf),
    {ua, Ua1, {final, 200, _}} = ua_answer(Ua1),
    {Ua2, M2} = room_caller(Config, Conf),
    {ua, Ua2, {final, 200, _}} = ua_answer(Ua2),
    [#{uri := U2}] = [
        Mb
     || #{id := Id} = Mb <- chappe_mrf_conf:members(Conf), Id =:= M2
    ],
    ok = ?F:ua_refer(Ua1, <<"<", U2/binary, ";method=BYE>">>),
    {ua, Ua1, {response, R}} = ua_msg(Ua1, response),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, R),
    conf_event(Conf, {left, M2, kicked}),
    %% the focus sends the BYE to the member it removes (5.11, F5) and
    %% tells the referrer the outcome
    _ = ua_event(Ua2, bye),
    ?assert(final_notify(Ua1, <<"SIP/2.0 200">>)),
    ?assertMatch([#{id := M1}], chappe_mrf_conf:members(Conf)),
    ok = chappe_mrf_conf:stop(Conf).

%% Removal is a focus's (RFC 4579 5.11): a room without focus => true
%% refuses a REFER with method=BYE 403, in a member's dialog or to its
%% URI, whatever its policy says, and every member stays.
bye_refused_without_focus(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {ok, Conf} = chappe_mrf:conference(<<"nobye">>, #{
        focus => false, refer_policy => fun(_) -> true end
    }),
    {Ua1, _M1} = room_caller(Config, Conf),
    {ua, Ua1, {final, 200, _}} = ua_answer(Ua1),
    {Ua2, M2} = room_caller(Config, Conf),
    {ua, Ua2, {final, 200, _}} = ua_answer(Ua2),
    [#{uri := U2}] = [
        Mb
     || #{id := Id} = Mb <- chappe_mrf_conf:members(Conf), Id =:= M2
    ],
    Bye = <<"<", U2/binary, ";method=BYE>">>,
    ok = ?F:ua_refer(Ua1, Bye),
    {ua, Ua1, {response, R}} = ua_msg(Ua1, response),
    ?assertMatch(<<"SIP/2.0 403", _/binary>>, R),
    Uri =
        <<"sip:nobye@127.0.0.1:",
            (integer_to_binary(?config(ep, Config)))/binary>>,
    {Sock, _} = refer(Config, Uri, <<"boss">>, Bye),
    ?assertMatch(<<"SIP/2.0 403", _/binary>>, sip_response(Sock)),
    no_ua_event(Ua2, bye, 500),
    ?assertEqual(2, length(chappe_mrf_conf:members(Conf))),
    ok = chappe_mrf_conf:stop(Conf).

%% An fs focus room answers a caller it joins itself (join/3 with {call,
%% Req, Res}) with the conference URI and isfocus as its Contact (RFC
%% 4579 4.2), as a native room does, and the member's REFER is to the
%% focus: its party is dialed into the room (5.5).
fs_focus_member_isfocus(Config) ->
    meck_targets(Config),
    {ok, Conf} = chappe_mrf:conference(<<"fsfocus">>, #{
        backend => fs,
        node => fs1,
        focus => true,
        refer_policy => fun(_) -> true end
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    {Ua, _M} = room_caller(Config, Conf),
    {ua, Ua, {final, 200, Ok}} = ua_answer(Ua),
    Contact = ?F:hdr(Ok, <<"contact">>),
    ?assert(has(Contact, Entity)),
    ?assert(has(Contact, <<";isfocus">>)),
    ok = ?F:ua_refer(Ua, <<"<sip:carol@10.0.0.9>">>),
    {ua, Ua, {response, R}} = ua_msg(Ua, response),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, R),
    %% over the node's connection, or a member's once that one is down
    Dial =
        receive
            {fake_esl, _,
                {api, <<"api conference fsfocus bgdial", _/binary>> = D}} ->
                D;
            {fake_fs, _, _,
                {cmd, <<"api conference fsfocus bgdial", _/binary>> = D}} ->
                D
        after 5000 -> ct:fail(no_bgdial)
        end,
    ?assert(has(Dial, <<"carol@10.0.0.9">>)),
    ?assert(has(Dial, <<"sip_invite_contact_params=~isfocus">>)),
    ok = chappe_mrf_conf:stop(Conf).

%% ---- REFER to a room: the decision and the dial-outs ----

%% native: the party a REFER to the room brings in is dialed by an
%% endpoint of the pool, in the mixer out of sight first, and is no
%% member until it answers: no member, no roster entry, and a bridge that
%% waits for the answer (ignore_early_media) while it rings. Its 180 reaches the referrer (the node's
%% CHANNEL_PROGRESS, marked by the dial's chappe_dial variables); once it
%% answers (CHANNEL_BRIDGE) the endpoint joins the mixer and the referrer
%% hears 200. The REFER's 200 has the conference URI and isfocus as
%% Contact; the roster shows the party dialed out.
%% req: MRF-11 MRF-12 MRF-19
refer_native_joined_on_answer(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    ok = chappe_sip:event_package(
        <<"conference">>, fun chappe_mrf:focus_subscribe/2
    ),
    {ok, Conf} = chappe_mrf:conference(<<"ansroom">>, #{
        focus => true,
        refer_policy => fun(#{action := add}) -> true end,
        dial_endpoint => #{targets => [{fs1, fs_uri(Config)}]},
        dial_profile => <<"carrier">>
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    W = watch(Config, Entity),
    _ = roster(W),
    {Sock, _} = refer(Config, Entity, <<"boss">>, <<"<sip:carol@10.0.0.9>">>),
    R = sip_response(Sock),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, R),
    ?assert(has(?F:hdr(R, <<"contact">>), <<Entity/binary, ">;isfocus">>)),
    ?assertEqual([<<"SIP/2.0 100">>], frags(Sock, 1)),
    %% in the mixer first, out of sight, then the bridge, which waits for
    %% the answer: nothing it plays before reaches the room
    _ = fs_what(reinvite),
    {fake_fs, _, _, {cmd, Bridge}} = fs_cmd(<<"execute-app-name: bridge">>),
    ?assert(has(Bridge, <<"sofia/carrier/carol@10.0.0.9">>)),
    %% bridged from the room's endpoint, the party would be offered only
    %% the endpoint's codec: the default offers it every codec of the lab,
    %% G.711 first in this 8 kHz room
    ?assert(
        has(
            Bridge,
            <<"[^^:absolute_codec_string=PCMU,PCMA,G722,OPUS]sofia/carrier/">>
        )
    ),
    ?assert(has(Bridge, <<"sip_contact_user=ansroom">>)),
    ?assert(has(Bridge, <<"sip_invite_contact_params=~isfocus">>)),
    ?assert(has(Bridge, <<"ignore_early_media=true">>)),
    ?assertEqual([], chappe_mrf_conf:members(Conf)),
    no_joined(Conf),
    {Tag, Op} = dial_marks(Bridge),
    Conf ! progress_event(fs1, <<"CHANNEL_PROGRESS">>, Tag, Op),
    ?assertEqual([<<"SIP/2.0 180">>], frags(Sock, 1)),
    %% another room's mark is not this room's
    Conf ! progress_event(fs1, <<"CHANNEL_PROGRESS_MEDIA">>, <<"x">>, Op),
    ok = ?F:fs_bridge(?config(fs, Config), answered),
    {joined, M, #{uri := <<"sip:carol@10.0.0.9">>}} = joined(Conf),
    ?assertEqual(<<"SIP/2.0 200">>, final_frag(Sock)),
    ?assertMatch([#{id := M}], chappe_mrf_conf:members(Conf)),
    %% the roster shows it dialed out, referred by nobody (no Referred-By)
    ?assert(roster_until(W, <<"<joining-method>dialed-out</joining-method>">>)),
    gen_udp:close(W).

%% A dial-out that fails tells the referrer how (busy 486, declined 603,
%% no answer 480, no answer in dial_timeout 408), and the room is left as
%% it was: no member, no joined or left event.
%% req: MRF-13
refer_outcomes(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {ok, Conf} = chappe_mrf:conference(<<"failroom">>, #{
        focus => true,
        refer_policy => fun(_) -> true end,
        dial_timeout => 800,
        dial_endpoint => #{targets => [{fs1, fs_uri(Config)}]}
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    Fs = ?config(fs, Config),
    lists:foreach(
        fun({Outcome, Want}) ->
            {Sock, _} = refer(
                Config, Entity, <<"boss">>, <<"<sip:dave@10.0.0.9>">>
            ),
            ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(Sock)),
            ?assertEqual([<<"SIP/2.0 100">>], frags(Sock, 1)),
            _ = fs_cmd(<<"execute-app-name: bridge">>),
            _ =
                case Outcome of
                    timeout -> ok;
                    Cause -> ?F:fs_bridge(Fs, {failed, Cause})
                end,
            ?assertEqual(Want, final_frag(Sock)),
            ?assertEqual([], chappe_mrf_conf:members(Conf)),
            gen_udp:close(Sock)
        end,
        [
            {<<"USER_BUSY">>, <<"SIP/2.0 486">>},
            {<<"CALL_REJECTED">>, <<"SIP/2.0 603">>},
            {<<"NO_ANSWER">>, <<"SIP/2.0 480">>},
            {timeout, <<"SIP/2.0 408">>}
        ]
    ),
    no_joined(Conf),
    receive
        {chappe_mrf_conf, Conf, {left, _, _} = L} -> ct:fail({left, L})
    after 0 -> ok
    end.

%% Admission before anything is dialed, on both backends: a locked room
%% refuses a REFER that adds a party 403 and a full one 486, a party being
%% dialed counting as a member; nothing is dialed then.
%% req: MRF-14 MRF-11
refer_lock_max_both_backends(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    Targets = [{fs1, fs_uri(Config)}],
    {ok, N} = chappe_mrf:conference(<<"maxnative">>, #{
        focus => true,
        max_members => 1,
        refer_policy => fun(_) -> true end,
        dial_endpoint => #{targets => Targets}
    }),
    #{entity := NE} = chappe_mrf_conf:info(N),
    %% one being dialed fills the room
    {S1, _} = refer(Config, NE, <<"boss">>, <<"<sip:a@10.0.0.9>">>),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(S1)),
    _ = fs_cmd(<<"execute-app-name: bridge">>),
    {S2, _} = refer(Config, NE, <<"boss">>, <<"<sip:b@10.0.0.9>">>),
    ?assertMatch(<<"SIP/2.0 486", _/binary>>, sip_response(S2)),
    ok = ?F:fs_bridge(?config(fs, Config), {failed, <<"USER_BUSY">>}),
    ?assertEqual(<<"SIP/2.0 486">>, final_frag(S1)),
    ok = chappe_mrf_conf:lock(N),
    {S3, _} = refer(Config, NE, <<"boss">>, <<"<sip:c@10.0.0.9>">>),
    ?assertMatch(<<"SIP/2.0 403", _/binary>>, sip_response(S3)),
    no_fs_cmd(<<"execute-app-name: bridge">>, 300),
    %% fs: the same before bgdial
    {ok, F} = chappe_mrf:conference(<<"maxfs">>, #{
        backend => fs,
        node => fs1,
        focus => true,
        max_members => 1,
        refer_policy => fun(_) -> true end
    }),
    {ok, Ep} = chappe_mrf:create_endpoint(#{targets => Targets}),
    {ok, _} = chappe_mrf_conf:join(F, Ep, #{}),
    {joined, _, _} = joined(F),
    FE =
        <<"sip:maxfs@127.0.0.1:",
            (integer_to_binary(?config(ep, Config)))/binary>>,
    {S4, _} = refer(Config, FE, <<"boss">>, <<"<sip:d@10.0.0.8>">>),
    ?assertMatch(<<"SIP/2.0 486", _/binary>>, sip_response(S4)),
    ok = chappe_mrf_conf:lock(F),
    {S5, _} = refer(Config, FE, <<"boss">>, <<"<sip:d@10.0.0.8>">>),
    ?assertMatch(<<"SIP/2.0 403", _/binary>>, sip_response(S5)),
    no_fs_cmd(<<"bgdial">>, 300),
    ok = chappe_mrf:destroy(Ep).

%% A REFER repeated from the same origin (Call-ID and From tag) for the
%% same target is the same request: it is answered (200, NOTIFY 100) but
%% nobody is dialed again, and both hear the outcome; one after the
%% outcome hears it at once. Adding a member already in is 200 at once.
%% req: MRF-15
refer_idempotent(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {ok, Conf} = chappe_mrf:conference(<<"idemroom">>, #{
        focus => true,
        refer_policy => fun(_) -> true end,
        dial_endpoint => #{targets => [{fs1, fs_uri(Config)}]}
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    Carol = <<"<sip:carol@10.0.0.9>">>,
    Same = #{call_id => <<"idem-1">>, from_tag => <<"same">>},
    {S1, _} = refer(Config, Entity, <<"boss">>, Carol, Same#{cseq => 1}),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(S1)),
    _ = fs_cmd(<<"execute-app-name: bridge">>),
    {S2, _} = refer(Config, Entity, <<"boss">>, Carol, Same#{cseq => 2}),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(S2)),
    ?assertEqual([<<"SIP/2.0 100">>], frags(S2, 1)),
    no_fs_cmd(<<"execute-app-name: bridge">>, 500),
    ok = ?F:fs_bridge(?config(fs, Config), answered),
    {joined, _, _} = joined(Conf),
    ?assertEqual(<<"SIP/2.0 200">>, final_frag(S1)),
    ?assertEqual(<<"SIP/2.0 200">>, final_frag(S2)),
    {S3, _} = refer(Config, Entity, <<"boss">>, Carol, Same#{cseq => 3}),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(S3)),
    ?assertEqual(<<"SIP/2.0 200">>, final_frag(S3)),
    %% another origin asking for carol, now a member
    {S4, _} = refer(Config, Entity, <<"boss">>, Carol),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(S4)),
    ?assertEqual(<<"SIP/2.0 200">>, final_frag(S4)),
    no_fs_cmd(<<"execute-app-name: bridge">>, 300),
    ?assertMatch([_], chappe_mrf_conf:members(Conf)).

%% RFC 4579 5.10, outside any dialog: the Replaces of the Refer-To goes on
%% the INVITE to the party, and so does the REFER's Referred-By (RFC 3892
%% 2.2), as a bare URI.
%% req: MRF-17
refer_ood_replaces(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {ok, Conf} = chappe_mrf:conference(<<"reproom">>, #{
        focus => true,
        refer_policy => fun(_) -> true end,
        dial_endpoint => #{targets => [{fs1, fs_uri(Config)}]}
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    RT =
        <<"<sip:carol@10.0.0.9?Replaces=c1%40h%3Bto-tag%3Dt1%3Bfrom-tag%3Df1>">>,
    {Sock, _} = refer(Config, Entity, <<"boss">>, RT, #{
        headers => [{<<"Referred-By">>, <<"\"Boss\" <sip:boss@127.0.0.1>">>}]
    }),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(Sock)),
    {fake_fs, _, _, {cmd, Bridge}} = fs_cmd(<<"execute-app-name: bridge">>),
    ?assert(has(Bridge, <<"_sofia_replaces_=c1@h;to-tag=t1;from-tag=f1">>)),
    ?assert(has(Bridge, <<"sip_h_Referred-By=<sip:boss@127.0.0.1>">>)).

%% RFC 4579 5.11: a REFER with method=BYE whose Refer-To is a member's
%% endpoint entity (<conference URI>;member=Id) removes that member. The
%% roster has each participant as a user by its address-of-record with an
%% endpoint per member; the removed one shows disconnected, booted, then
%% is deleted.
%% req: MRF-16 MRF-19
refer_bye_roster_uri(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    ok = chappe_sip:event_package(
        <<"conference">>, fun chappe_mrf:focus_subscribe/2
    ),
    {ok, Conf} = chappe_mrf:conference(<<"rosroom">>, #{
        focus => true, refer_policy => fun(_) -> true end
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    {Ua1, M1} = room_caller(Config, Conf),
    {ua, Ua1, {final, 200, _}} = ua_answer(Ua1),
    {Ua2, M2} = room_caller(Config, Conf),
    {ua, Ua2, {final, 200, _}} = ua_answer(Ua2),
    [#{uri := U2}] = [
        Mb
     || #{id := Id} = Mb <- chappe_mrf_conf:members(Conf), Id =:= M2
    ],
    W = watch(Config, Entity),
    Full = roster(W),
    Aor2 = chappe_mrf_conf_refer_op:aor(U2),
    ?assert(has(Full, <<"<user entity=\"", Aor2/binary, "\"">>)),
    ?assert(
        has(
            Full,
            <<"<endpoint entity=\"", Entity/binary, ";member=", M2/binary,
                "\"">>
        )
    ),
    ?assert(has(Full, <<"<joining-method>dialed-in</joining-method>">>)),
    Bye = <<"<", Entity/binary, ";member=", M2/binary, ";method=BYE>">>,
    {Sock, _} = refer(Config, Entity, <<"boss">>, Bye),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(Sock)),
    conf_event(Conf, {left, M2, kicked}),
    _ = ua_event(Ua2, bye),
    ?assertEqual(<<"SIP/2.0 200">>, final_frag(Sock)),
    ?assert(
        roster_until(
            W, <<"<disconnection-method>booted</disconnection-method>">>
        )
    ),
    ?assert(roster_until(W, <<"state=\"deleted\"">>)),
    ?assertMatch([#{id := M1}], chappe_mrf_conf:members(Conf)),
    gen_udp:close(W).

%% Two members with the same address-of-record: a removal by that URI is
%% ambiguous (485) and both stay.
%% req: MRF-16
refer_bye_ambiguous_485(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {ok, Conf} = chappe_mrf:conference(<<"dupl">>, #{
        focus => true, refer_policy => fun(_) -> true end
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    Dup = #{from => <<"sip:twin@127.0.0.1">>},
    {Ua1, _} = room_caller(Config, Conf, Dup),
    {ua, Ua1, {final, 200, _}} = ua_answer(Ua1),
    {Ua2, _} = room_caller(Config, Conf, Dup),
    {ua, Ua2, {final, 200, _}} = ua_answer(Ua2),
    {Sock, _} = refer(
        Config, Entity, <<"boss">>, <<"<sip:twin@127.0.0.1;method=BYE>">>
    ),
    ?assertMatch(<<"SIP/2.0 485", _/binary>>, sip_response(Sock)),
    no_ua_event(Ua1, bye, 300),
    ?assertEqual(2, length(chappe_mrf_conf:members(Conf))).

%% A removal only looks at the room it was sent to: a member of another
%% room, by its URI or its endpoint entity there, is not found (404) and
%% stays.
%% req: MRF-16
refer_bye_cross_room(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    Policy = #{focus => true, refer_policy => fun(_) -> true end},
    {ok, A} = chappe_mrf:conference(<<"rooma">>, Policy),
    {ok, B} = chappe_mrf:conference(<<"roomb">>, Policy),
    #{entity := EA} = chappe_mrf_conf:info(A),
    #{entity := EB} = chappe_mrf_conf:info(B),
    {Ua, M} = room_caller(Config, B),
    {ua, Ua, {final, 200, _}} = ua_answer(Ua),
    [#{uri := U}] = chappe_mrf_conf:members(B),
    lists:foreach(
        fun(RT) ->
            {Sock, _} = refer(Config, EA, <<"boss">>, RT),
            ?assertMatch(<<"SIP/2.0 404", _/binary>>, sip_response(Sock))
        end,
        [
            <<"<", U/binary, ";method=BYE>">>,
            <<"<", EB/binary, ";member=", M/binary, ";method=BYE>">>
        ]
    ),
    no_ua_event(Ua, bye, 300),
    ?assertMatch([#{id := M}], chappe_mrf_conf:members(B)).

%% A referrer the policy refuses gets 403 for a removal, whether the
%% member it names is in or not: it learns nothing of the roster.
%% req: MRF-16 MRF-11
refer_bye_unauthorized(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    Policy = fun(#{referrer := R}) -> has(R, <<"boss@">>) end,
    {ok, Conf} = chappe_mrf:conference(<<"authroom">>, #{
        focus => true, refer_policy => Policy
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    {Ua, M} = room_caller(Config, Conf),
    {ua, Ua, {final, 200, _}} = ua_answer(Ua),
    [#{uri := U}] = chappe_mrf_conf:members(Conf),
    lists:foreach(
        fun(RT) ->
            {Sock, _} = refer(Config, Entity, <<"intruder">>, RT),
            ?assertMatch(<<"SIP/2.0 403", _/binary>>, sip_response(Sock))
        end,
        [
            <<"<", U/binary, ";method=BYE>">>,
            <<"<sip:nobody@127.0.0.1;method=BYE>">>
        ]
    ),
    no_ua_event(Ua, bye, 300),
    ?assertMatch([#{id := M}], chappe_mrf_conf:members(Conf)).

%% The room ends while a party it dials rings: the referrer hears 487 and
%% the dial is given up, on both backends (native: the dialing endpoint
%% is hung up; fs: the dialed uuid is killed).
%% req: MRF-20
refer_room_end_487(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {ok, N} = chappe_mrf:conference(<<"endnative">>, #{
        focus => true,
        refer_policy => fun(_) -> true end,
        dial_endpoint => #{targets => [{fs1, fs_uri(Config)}]}
    }),
    #{entity := NE} = chappe_mrf_conf:info(N),
    {S1, _} = refer(Config, NE, <<"boss">>, <<"<sip:carol@10.0.0.9>">>),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(S1)),
    ?assertEqual([<<"SIP/2.0 100">>], frags(S1, 1)),
    _ = fs_cmd(<<"execute-app-name: bridge">>),
    ok = chappe_mrf_conf:stop(N),
    _ = fs_cmd(<<"uuid_kill ">>),
    ?assertEqual(<<"SIP/2.0 487">>, final_frag(S1)),
    {ok, F} = chappe_mrf:conference(<<"endfs">>, #{
        backend => fs,
        node => fs1,
        focus => true,
        refer_policy => fun(_) -> true end
    }),
    {ok, Ep} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    {ok, _} = chappe_mrf_conf:join(F, Ep, #{}),
    {joined, _, _} = joined(F),
    FE =
        <<"sip:endfs@127.0.0.1:",
            (integer_to_binary(?config(ep, Config)))/binary>>,
    {S2, _} = refer(Config, FE, <<"boss">>, <<"<sip:dave@10.0.0.8>">>),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(S2)),
    {fake_fs, _, _, {cmd, Dial}} = fs_cmd(<<"conference endfs bgdial">>),
    {match, [Uuid]} = re:run(Dial, <<"origination_uuid=([^,}]+)">>, [
        {capture, all_but_first, binary}
    ]),
    ok = chappe_mrf_conf:stop(F),
    _ = fs_cmd(<<"uuid_kill ", Uuid/binary>>),
    ?assertEqual(<<"SIP/2.0 487">>, final_frag(S2)),
    ok = chappe_mrf:destroy(Ep).

%% RFC 4488 4 on a room: Refer-Sub: false with norefersub gets 200 with
%% Refer-Sub: false and the conference's Contact, no NOTIFY, and the
%% party is still brought in.
%% req: MRF-11
refer_norefersub(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {ok, Conf} = chappe_mrf:conference(<<"nosubroom">>, #{
        focus => true,
        refer_policy => fun(_) -> true end,
        dial_endpoint => #{targets => [{fs1, fs_uri(Config)}]}
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    {Sock, _} = refer(
        Config, Entity, <<"boss">>, <<"<sip:carol@10.0.0.9>">>, #{
            headers => [
                {<<"Refer-Sub">>, <<"false">>},
                {<<"Supported">>, <<"norefersub">>}
            ]
        }
    ),
    R = sip_response(Sock),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, R),
    ?assertEqual(<<"false">>, ?F:hdr(R, <<"refer-sub">>)),
    ?assert(has(?F:hdr(R, <<"contact">>), <<";isfocus">>)),
    _ = fs_cmd(<<"execute-app-name: bridge">>),
    ok = ?F:fs_bridge(?config(fs, Config), answered),
    {joined, _, _} = joined(Conf),
    receive
        {udp, Sock, _, _, <<"NOTIFY", _/binary>> = N} -> ct:fail({notify, N})
    after 1500 -> ok
    end.

%% RFC 4538 4: a REFER to the room's URI whose Target-Dialog names a
%% member's dialog with the room comes from that member (the policy sees
%% member => Id); one naming no dialog of the room comes from nobody.
%% req: MRF-21
ood_target_dialog_member(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    Test = self(),
    {ok, Conf} = chappe_mrf:conference(<<"tdroom">>, #{
        focus => true,
        refer_policy => fun(Info) ->
            Test ! {policy, Info},
            maps:get(member, Info) =/= undefined
        end,
        dial_endpoint => #{targets => [{fs1, fs_uri(Config)}]}
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    {Ua, M} = room_caller(Config, Conf),
    {ua, Ua, {final, 200, Ok}} = ua_answer(Ua),
    Call = ?F:hdr(Ok, <<"call-id">>),
    {ok, Msg} = chappe_sip_msg:parse(Ok),
    TD =
        <<Call/binary, ";local-tag=", (chappe_sip_msg:to_tag(Msg))/binary,
            ";remote-tag=", (chappe_sip_msg:from_tag(Msg))/binary>>,
    {S1, _} = refer(Config, Entity, <<"boss">>, <<"<sip:carol@10.0.0.9>">>, #{
        headers => [{<<"Target-Dialog">>, TD}, {<<"Require">>, <<"tdialog">>}]
    }),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(S1)),
    ?assertMatch({policy, #{member := M}}, policy_info()),
    Bogus = <<Call/binary, ";local-tag=nope;remote-tag=nope">>,
    {S2, _} = refer(Config, Entity, <<"boss">>, <<"<sip:dave@10.0.0.9>">>, #{
        headers => [{<<"Target-Dialog">>, Bogus}]
    }),
    ?assertMatch(<<"SIP/2.0 403", _/binary>>, sip_response(S2)),
    ?assertMatch({policy, #{member := undefined}}, policy_info()).

%% RFC 4579 5.7: a REFER with method=REFER whose Refer-To carries this
%% room's URI makes the focus REFER the party to the conference, as the
%% focus (its URI, isfocus in its Contact, the REFER's Referred-By); the
%% referrer's final status is the party's answer to that REFER. One
%% naming another conference is refused 403.
%% req: MRF-18
refer_nested_refer(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {ok, Conf} = chappe_mrf:conference(<<"nestroom">>, #{
        focus => true, refer_policy => fun(_) -> true end
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    {ok, Bob} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    {ok, BP} = inet:port(Bob),
    BobUri = <<"sip:bob@127.0.0.1:", (integer_to_binary(BP))/binary>>,
    Nested = fun(To, Rt) ->
        chappe_sip_hdr:refer_to_value(#{
            uri => To, method => <<"REFER">>, headers => [{<<"Refer-To">>, Rt}]
        })
    end,
    RB = <<"\"Boss\" <sip:boss@127.0.0.1>;cid=x1">>,
    lists:foreach(
        fun({Rt, Answer}) ->
            {Sock, _} = refer(
                Config, Entity, <<"boss">>, Nested(BobUri, Rt), #{
                    headers => [{<<"Referred-By">>, RB}]
                }
            ),
            ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(Sock)),
            {Refer, Src} = udp_request(Bob, <<"REFER">>),
            {ok, #{uri := RT}} = chappe_sip_hdr:name_addr(
                ?F:hdr(Refer, <<"refer-to">>)
            ),
            ?assertEqual(Entity, RT),
            ?assert(has(?F:hdr(Refer, <<"contact">>), <<";isfocus">>)),
            ?assert(has(?F:hdr(Refer, <<"from">>), Entity)),
            %% RFC 3892 2.2: as the REFER had it
            ?assertEqual(RB, ?F:hdr(Refer, <<"referred-by">>)),
            ok = gen_udp:send(
                Bob, {127, 0, 0, 1}, Src, answer(Refer, Answer, BobUri)
            ),
            ?assertEqual(
                <<"SIP/2.0 ", (integer_to_binary(Answer))/binary>>,
                final_frag(Sock)
            ),
            gen_udp:close(Sock)
        end,
        %% a Refer-To to the room with parameters (maddr) still refers
        %% the party to the conference URI itself
        [{Entity, 200}, {<<Entity/binary, ";maddr=10.9.9.9">>, 603}]
    ),
    Other =
        <<"sip:otherroom@127.0.0.1:",
            (integer_to_binary(?config(ep, Config)))/binary>>,
    %% nothing that could make the focus REFER, or dial, itself in a loop:
    %% another conference, a Refer-To that is no plain INVITE to the room,
    %% the room as the party
    Loop = chappe_sip_hdr:refer_to_value(#{uri => Entity, method => <<"REFER">>}),
    lists:foreach(
        fun(RT) ->
            {S2, _} = refer(Config, Entity, <<"boss">>, RT),
            ?assertMatch(<<"SIP/2.0 403", _/binary>>, sip_response(S2))
        end,
        [
            Nested(BobUri, Other),
            Nested(BobUri, Loop),
            Nested(Entity, Entity),
            <<"<", Entity/binary, ">">>
        ]
    ),
    no_udp(Bob, 300),
    gen_udp:close(Bob).

no_udp(Sock, Ms) ->
    receive
        {udp, Sock, _, _, Bin} -> ct:fail({unexpected, Bin})
    after Ms -> ok
    end.

%% A caller referred to the room (its INVITE carries Referred-By, RFC 4579
%% 5.6) joins as any caller, and the roster shows who referred it (RFC
%% 4575 5.7.2); one that asked for privacy is anonymous there.
%% req: MRF-19
referred_invite_joins(Config) ->
    ok = chappe_sip:event_package(
        <<"conference">>, fun chappe_mrf:focus_subscribe/2
    ),
    {ok, Conf} = chappe_mrf:conference(<<"refdroom">>, #{focus => true}),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    W = watch(Config, Entity),
    _ = roster(W),
    {Ua, _M} = room_caller(Config, Conf, #{
        headers => [{<<"Referred-By">>, <<"\"Alice\" <sip:alice@127.0.0.1>">>}]
    }),
    {ua, Ua, {final, 200, _}} = ua_answer(Ua),
    ?assert(roster_until(W, <<"<by>sip:alice@127.0.0.1</by>">>)),
    {Ua2, _} = room_caller(Config, Conf, #{
        from => <<"sip:shy@127.0.0.1">>,
        headers => [{<<"Privacy">>, <<"id">>}]
    }),
    {ua, Ua2, {final, 200, _}} = ua_answer(Ua2),
    ?assert(roster_until(W, <<"anonymous.invalid">>)),
    ?assertNot(has(roster_now(W), <<"shy@">>)),
    gen_udp:close(W).

%% A member of a room without focus transfers itself, attended (its
%% Refer-To carries Replaces, RFC 5589 7): the room's policy decides
%% (action transfer, kind attended), the member's call carries it out with
%% an INVITE with Replaces to the target, and the target takes the
%% member's place.
%% req: MRF-17
member_transfer_attended(Config) ->
    {_Callee, CP} = ?F:callee_start(<<"erin">>),
    Test = self(),
    {ok, Conf} = chappe_mrf:conference(<<"attroom">>, #{
        focus => false,
        refer_policy => fun(Info) ->
            Test ! {policy, Info},
            true
        end
    }),
    {Ua, M} = room_caller(Config, Conf),
    {ua, Ua, {final, 200, _}} = ua_answer(Ua),
    Target = <<"sip:erin@127.0.0.1:", (integer_to_binary(CP))/binary>>,
    RT = chappe_sip_hdr:refer_to_value(#{
        uri => Target,
        replaces => #{
            call_id => <<"x1@h">>, to_tag => <<"t1">>, from_tag => <<"f1">>
        }
    }),
    ok = ?F:ua_refer(Ua, RT),
    {ua, Ua, {response, R}} = ua_msg(Ua, response),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, R),
    ?assertMatch(
        {policy, #{action := transfer, kind := attended, member := M}},
        policy_info()
    ),
    Inv =
        receive
            {callee, invite, I} -> I
        after 5000 -> ct:fail(no_target_invite)
        end,
    ?assertEqual(<<"x1@h;to-tag=t1;from-tag=f1">>, ?F:hdr(Inv, <<"replaces">>)),
    conf_event(Conf, {left, M, transferred}),
    {joined, M, #{uri := Target}} = joined(Conf),
    ok = chappe_mrf_conf:stop(Conf).

%% RFC 3891 and RFC 4579 5.9: an INVITE to the room with Replaces naming a
%% member's call, from that member, takes its place: the new caller joins, then
%% the member it replaces gets a BYE and leaves (replaced). A Replaces
%% naming no call is 481 and changes nothing.
%% req: MRF-22
invite_replaces_member(Config) ->
    {ok, Conf} = chappe_mrf:conference(<<"reproom2">>, #{focus => true}),
    {Ua1, M1} = room_caller(Config, Conf),
    {ua, Ua1, {final, 200, Ok}} = ua_answer(Ua1),
    [#{uri := U1}] = chappe_mrf_conf:members(Conf),
    Rep = replaces_of(Ok),
    %% the member itself, from another device (its address-of-record)
    {Ua2, M2} = room_caller(Config, Conf, #{
        from => U1, headers => [{<<"Replaces">>, Rep}]
    }),
    {ua, Ua2, {final, 200, _}} = ua_answer(Ua2),
    _ = ua_event(Ua1, bye),
    conf_event(Conf, {left, M1, replaced}),
    ?assertMatch([#{id := M2}], chappe_mrf_conf:members(Conf)),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test ! {join, chappe_mrf_conf:join(Conf, {call, Req, Res}, #{})}
    end),
    Ua3 = ?F:ua_call(?config(ep, Config), #{
        headers => [{<<"Replaces">>, <<"nobody@h;to-tag=a;from-tag=b">>}]
    }),
    {ua, Ua3, {final, 481, _}} = ua_answer(Ua3),
    ?assertMatch([#{id := M2}], chappe_mrf_conf:members(Conf)).

%% a request to a raw socket: {Bin, Src}
udp_request(Sock, Method) ->
    receive
        {udp, Sock, _, Src,
            <<Method:(byte_size(Method))/binary, " ", _/binary>> = Bin} ->
            {Bin, Src};
        {udp, Sock, _, _, _} ->
            udp_request(Sock, Method)
    after 5000 -> ct:fail({no_request, Method})
    end.

%% a final answer to a request, with a To tag and a Contact
answer(Req, Status, Contact) ->
    {ok, M} = chappe_sip_msg:parse(Req),
    iolist_to_binary([
        <<"SIP/2.0 ">>,
        integer_to_binary(Status),
        <<" Answer\r\n">>,
        [
            [<<"Via: ">>, V, <<"\r\n">>]
         || V <- chappe_sip_msg:get_all(<<"via">>, M)
        ],
        <<"From: ">>,
        chappe_sip_msg:get(<<"from">>, M),
        <<"\r\nTo: ">>,
        chappe_sip_msg:get(<<"to">>, M),
        <<";tag=bob1\r\nCall-ID: ">>,
        chappe_sip_msg:call_id(M),
        <<"\r\nCSeq: ">>,
        chappe_sip_msg:get(<<"cseq">>, M),
        <<"\r\nContact: <">>,
        Contact,
        <<">\r\nContent-Length: 0\r\n\r\n">>
    ]).

%% the conference-info bodies the watcher has now
roster_now(Sock) ->
    receive
        {udp, Sock, _, Src, <<"NOTIFY ", _/binary>> = Bin} ->
            _ = gen_udp:send(Sock, {127, 0, 0, 1}, Src, ok_for(Bin)),
            <<(?F:body(Bin))/binary, (roster_now(Sock))/binary>>
    after 300 -> <<>>
    end.

%% ---- review: the decision cannot be crashed, probed or flooded ----

%% A policy is code of the app run in the room: one that does not match
%% what it is given (a clause for adds only, given a removal) refuses the
%% REFER 403, and the room and its members carry on. Every action gives
%% the policy the same keys, undefined when they do not apply.
%% req: MRF-11
refer_policy_crash(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    Test = self(),
    {ok, Conf} = chappe_mrf:conference(<<"crashroom">>, #{
        focus => true,
        refer_policy => fun(#{action := add} = Info) ->
            Test ! {policy, Info},
            true
        end,
        dial_endpoint => #{targets => [{fs1, fs_uri(Config)}]}
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    {Ua, M} = room_caller(Config, Conf),
    {ua, Ua, {final, 200, _}} = ua_answer(Ua),
    [#{uri := U}] = chappe_mrf_conf:members(Conf),
    {S1, _} = refer(
        Config, Entity, <<"boss">>, <<"<", U/binary, ";method=BYE>">>
    ),
    ?assertMatch(<<"SIP/2.0 403", _/binary>>, sip_response(S1)),
    ?assert(is_process_alive(Conf)),
    no_ua_event(Ua, bye, 300),
    ?assertMatch([#{id := M}], chappe_mrf_conf:members(Conf)),
    {S2, _} = refer(Config, Entity, <<"boss">>, <<"<sip:carol@10.0.0.9>">>),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(S2)),
    {policy, Info} = policy_info(),
    [
        ?assert(is_map_key(K, Info))
     || K <- [
            action,
            target,
            method,
            replaces,
            refer_to,
            nested,
            referrer,
            referred_by,
            target_dialog,
            origin,
            member,
            dial,
            removes
        ]
    ],
    ?assertMatch(#{nested := undefined, removes := undefined}, Info).

%% A referrer the policy refuses learns nothing of the room: a full room
%% answers it 403, as any room does, not 486.
%% req: MRF-11 MRF-14
refer_admission_probe(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {ok, Conf} = chappe_mrf:conference(<<"proberoom">>, #{
        focus => true,
        max_members => 1,
        refer_policy => fun(#{referrer := R}) -> has(R, <<"boss@">>) end,
        dial_endpoint => #{targets => [{fs1, fs_uri(Config)}]}
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    {Ua, _} = room_caller(Config, Conf),
    {ua, Ua, {final, 200, _}} = ua_answer(Ua),
    {S1, _} = refer(Config, Entity, <<"intruder">>, <<"<sip:carol@10.0.0.9>">>),
    ?assertMatch(<<"SIP/2.0 403", _/binary>>, sip_response(S1)),
    {S2, _} = refer(Config, Entity, <<"boss">>, <<"<sip:carol@10.0.0.9>">>),
    ?assertMatch(<<"SIP/2.0 486", _/binary>>, sip_response(S2)).

%% The process that asked the room to decide a REFER dies before it
%% answered it: the op it reserved goes with it, and stops counting as a
%% dial under way.
%% req: MRF-15
refer_worker_dies(Config) ->
    {ok, Conf} = chappe_mrf:conference(<<"leakroom">>, #{
        focus => true,
        max_members => 1,
        refer_policy => fun(_) -> true end,
        dial_endpoint => #{targets => [{fs1, fs_uri(Config)}]}
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    Info = #{
        action => add,
        target => <<"sip:carol@10.0.0.9">>,
        method => <<"INVITE">>,
        replaces => undefined,
        referrer => <<"<sip:boss@127.0.0.1>">>,
        referred_by => undefined,
        target_dialog => undefined,
        origin => {request, <<"leak-1">>, <<"t">>},
        room_uri => Entity
    },
    {Pid, Mon} = spawn_monitor(fun() ->
        exit(chappe_mrf_conf:call(Conf, {refer, {decide, Info, self()}}, 5000))
    end),
    receive
        {'DOWN', Mon, process, Pid, {accept, _, _}} -> ok
    after 5000 -> ct:fail(no_decision)
    end,
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {S1, _} = refer(Config, Entity, <<"boss">>, <<"<sip:dave@10.0.0.9>">>),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(S1)).

%% Two removals from one origin, of two members by their endpoint
%% entities (which share the room's address-of-record), are two ops: both
%% members go.
%% req: MRF-15 MRF-16
refer_bye_two_members_one_origin(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {ok, Conf} = chappe_mrf:conference(<<"twobye">>, #{
        focus => true, refer_policy => fun(_) -> true end
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    {Ua1, M1} = room_caller(Config, Conf),
    {ua, Ua1, {final, 200, _}} = ua_answer(Ua1),
    {Ua2, M2} = room_caller(Config, Conf),
    {ua, Ua2, {final, 200, _}} = ua_answer(Ua2),
    Same = #{call_id => <<"twobye-1">>, from_tag => <<"same">>},
    lists:foreach(
        fun({M, N}) ->
            Bye = <<"<", Entity/binary, ";member=", M/binary, ";method=BYE>">>,
            {Sock, _} = refer(Config, Entity, <<"boss">>, Bye, Same#{cseq => N}),
            ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(Sock)),
            conf_event(Conf, {left, M, kicked})
        end,
        [{M1, 1}, {M2, 2}]
    ),
    ?assertEqual([], chappe_mrf_conf:members(Conf)).

%% Two origins asking for the same party while it is being dialed: it is
%% dialed once, and both hear the outcome.
%% req: MRF-15
refer_two_origins_one_dial(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {ok, Conf} = chappe_mrf:conference(<<"tworigin">>, #{
        focus => true,
        refer_policy => fun(_) -> true end,
        dial_endpoint => #{targets => [{fs1, fs_uri(Config)}]}
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    Carol = <<"<sip:carol@10.0.0.9>">>,
    {S1, _} = refer(Config, Entity, <<"boss">>, Carol),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(S1)),
    _ = fs_cmd(<<"execute-app-name: bridge">>),
    {S2, _} = refer(Config, Entity, <<"other">>, Carol),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(S2)),
    no_fs_cmd(<<"execute-app-name: bridge">>, 500),
    ok = ?F:fs_bridge(?config(fs, Config), answered),
    {joined, _, _} = joined(Conf),
    ?assertEqual(<<"SIP/2.0 200">>, final_frag(S1)),
    ?assertEqual(<<"SIP/2.0 200">>, final_frag(S2)).

%% The room's dial fun makes the dial string once: the policy sees it and
%% the backend dials it.
%% req: MRF-11
refer_dial_fun_once(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    Test = self(),
    {ok, Conf} = chappe_mrf:conference(<<"dialfun">>, #{
        focus => true,
        refer_policy => fun(_) -> true end,
        dial => fun(T) ->
            Test ! {dial_fun, T},
            [<<"sofia/once/">>, binary:part(T, 4, byte_size(T) - 4)]
        end,
        dial_endpoint => #{targets => [{fs1, fs_uri(Config)}]}
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    {Sock, _} = refer(Config, Entity, <<"boss">>, <<"<sip:carol@10.0.0.9>">>),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(Sock)),
    {fake_fs, _, _, {cmd, Bridge}} = fs_cmd(<<"execute-app-name: bridge">>),
    ?assert(has(Bridge, <<"sofia/once/carol@10.0.0.9">>)),
    ?assertEqual(1, length(dial_funs())).

dial_funs() ->
    receive
        {dial_fun, T} -> [T | dial_funs()]
    after 300 -> []
    end.

%% The room's dial fun is code of the app run in the room, like its
%% policy: one that crashes on a target (or makes no iodata) refuses the
%% REFER 403, dials nothing, and the room and its members carry on.
%% req: MRF-11
refer_dial_fun_crash(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {ok, Conf} = chappe_mrf:conference(<<"dialcrash">>, #{
        focus => true,
        refer_policy => fun(_) -> true end,
        dial => fun
            (<<"sip:carol@", R/binary>>) -> [<<"sofia/ok/carol@">>, R];
            (<<"sip:erin@", _/binary>>) -> not_iodata
        end,
        dial_endpoint => #{targets => [{fs1, fs_uri(Config)}]}
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    {Ua, M} = room_caller(Config, Conf),
    {ua, Ua, {final, 200, _}} = ua_answer(Ua),
    lists:foreach(
        fun(Target) ->
            {S, _} = refer(Config, Entity, <<"boss">>, Target),
            ?assertMatch(<<"SIP/2.0 403", _/binary>>, sip_response(S))
        end,
        [<<"<sip:dave@10.0.0.9>">>, <<"<sip:erin@10.0.0.9>">>]
    ),
    ?assert(is_process_alive(Conf)),
    no_fs_cmd(<<"execute-app-name: bridge">>, 300),
    ?assertMatch([#{id := M}], chappe_mrf_conf:members(Conf)),
    {S1, _} = refer(Config, Entity, <<"boss">>, <<"<sip:carol@10.0.0.9>">>),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(S1)),
    {fake_fs, _, _, {cmd, Bridge}} = fs_cmd(<<"execute-app-name: bridge">>),
    ?assert(has(Bridge, <<"sofia/ok/carol@10.0.0.9">>)).

%% A second origin attached to the op the first one reserved, whose own
%% REFER then could not be accepted, gives up its own part only: the
%% first one's op still holds its place (and will carry the REFER the
%% first one answered), until its worker gives it up too.
%% req: MRF-15
refer_abort_other_origin(Config) ->
    {ok, Conf} = chappe_mrf:conference(<<"abortroom">>, #{
        focus => true,
        max_members => 1,
        refer_policy => fun(_) -> true end,
        dial_endpoint => #{targets => [{fs1, fs_uri(Config)}]}
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    Info = fun(Origin) ->
        #{
            action => add,
            target => <<"sip:carol@10.0.0.9">>,
            method => <<"INVITE">>,
            replaces => undefined,
            referrer => <<"<sip:boss@127.0.0.1>">>,
            referred_by => undefined,
            target_dialog => undefined,
            origin => {request, Origin, <<"t">>},
            room_uri => Entity
        }
    end,
    [W1, W2] = [
        spawn(fun() ->
            receive
                stop -> ok
            end
        end)
     || _ <- [1, 2]
    ],
    Decide = fun(Origin, W) ->
        chappe_mrf_conf:call(Conf, {refer, {decide, Info(Origin), W}}, 5000)
    end,
    {accept, K1, _} = Decide(<<"abort-1">>, W1),
    %% another origin asking for the same party joins that op
    {accept, K1, _} = Decide(<<"abort-2">>, W2),
    ok = chappe_mrf_conf:call(Conf, {refer, {abort, K1, W2}}, 5000),
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {S1, _} = refer(Config, Entity, <<"boss">>, <<"<sip:dave@10.0.0.9>">>),
    ?assertMatch(<<"SIP/2.0 486", _/binary>>, sip_response(S1)),
    exit(W1, kill),
    {S2, _} = refer(Config, Entity, <<"boss">>, <<"<sip:dave@10.0.0.9>">>),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(S2)).

%% A room without focus has no conference URI, but the URI a REFER is
%% sent to is its own: a REFER asking it to dial that URI is a loop and is
%% refused 403, nothing dialed.
%% req: MRF-11
refer_dial_own_uri_no_focus(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {ok, _Conf} = chappe_mrf:conference(<<"selfroom">>, #{
        focus => false,
        refer_policy => fun(_) -> true end,
        dial_endpoint => #{targets => [{fs1, fs_uri(Config)}]}
    }),
    Uri =
        <<"sip:selfroom@127.0.0.1:",
            (integer_to_binary(?config(ep, Config)))/binary>>,
    {Sock, _} = refer(Config, Uri, <<"boss">>, <<"<", Uri/binary, ">">>),
    ?assertMatch(<<"SIP/2.0 403", _/binary>>, sip_response(Sock)),
    no_fs_cmd(<<"execute-app-name: bridge">>, 300).

%% RFC 4579 5.10: a Replaces whose Call-ID has characters a Call-ID may
%% have (/ and parentheses) goes on the INVITE as it is; one FreeSWITCH
%% could not carry as it is (braces, legal in a Call-ID) is refused 403,
%% never dropped.
%% req: MRF-17
refer_replaces_callid_chars(Config) ->
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {ok, Conf} = chappe_mrf:conference(<<"callidroom">>, #{
        focus => true,
        refer_policy => fun(_) -> true end,
        dial_endpoint => #{targets => [{fs1, fs_uri(Config)}]}
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    RT = fun(CallId) ->
        chappe_sip_hdr:refer_to_value(#{
            uri => <<"sip:carol@10.0.0.9">>,
            replaces => #{
                call_id => CallId, to_tag => <<"t1">>, from_tag => <<"f1">>
            }
        })
    end,
    {S1, _} = refer(Config, Entity, <<"boss">>, RT(<<"a/b(c)@h">>)),
    ?assertMatch(<<"SIP/2.0 200", _/binary>>, sip_response(S1)),
    {fake_fs, _, _, {cmd, Bridge}} = fs_cmd(<<"execute-app-name: bridge">>),
    ?assert(has(Bridge, <<"_sofia_replaces_=a/b(c)@h;to-tag=t1;from-tag=f1">>)),
    {S2, _} = refer(Config, Entity, <<"other">>, RT(<<"a{b}@h">>)),
    ?assertMatch(<<"SIP/2.0 403", _/binary>>, sip_response(S2)).

%% RFC 4579 5.9 and RFC 3891 8: who may replace a member is the room's
%% replaces_policy, given its own keys (the caller, the member it would
%% replace, the Referred-By, the INVITE); the refer_policy is never asked.
%% A caller it refuses, or one it crashes on, is 403 and the member stays.
%% req: MRF-22
invite_replaces_policy(Config) ->
    Test = self(),
    {ok, Conf} = chappe_mrf:conference(<<"reppol">>, #{
        focus => true,
        refer_policy => fun(Info) ->
            Test ! {refer_policy, Info},
            true
        end,
        replaces_policy => fun(#{caller := C} = Info) ->
            Test ! {policy, Info},
            case has(C, <<"crash@">>) of
                true -> error(boom);
                false -> has(C, <<"boss@">>)
            end
        end
    }),
    {Ua1, M1} = room_caller(Config, Conf),
    {ua, Ua1, {final, 200, Ok}} = ua_answer(Ua1),
    [#{uri := U1}] = chappe_mrf_conf:members(Conf),
    Rep = replaces_of(Ok),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test ! {join, chappe_mrf_conf:join(Conf, {call, Req, Res}, #{})}
    end),
    lists:foreach(
        fun(From) ->
            Ua = ?F:ua_call(?config(ep, Config), #{
                from => From, headers => [{<<"Replaces">>, Rep}]
            }),
            {ua, Ua, {final, 403, _}} = ua_answer(Ua),
            {error, _} = join_result()
        end,
        [<<"sip:stranger@127.0.0.1">>, <<"sip:crash@127.0.0.1">>]
    ),
    {policy, Info} = policy_info(),
    ?assertMatch(
        #{
            caller := <<"sip:stranger@127.0.0.1">>,
            replaced := M1,
            referred_by := undefined
        },
        Info
    ),
    ?assertEqual(
        chappe_mrf_conf_refer_op:aor(U1), maps:get(replaced_aor, Info)
    ),
    ?assert(is_map_key(request, Info)),
    {policy, _} = policy_info(),
    ?assert(is_process_alive(Conf)),
    ?assertMatch([#{id := M1}], chappe_mrf_conf:members(Conf)),
    no_ua_event(Ua1, bye, 300),
    %% the policy widens it: boss may
    {Boss, M2} = room_caller(Config, Conf, #{
        from => <<"sip:boss@127.0.0.1">>, headers => [{<<"Replaces">>, Rep}]
    }),
    {ua, Boss, {final, 200, _}} = ua_answer(Boss),
    _ = ua_event(Ua1, bye),
    conf_event(Conf, {left, M1, replaced}),
    ?assertMatch([#{id := M2}], chappe_mrf_conf:members(Conf)),
    receive
        {refer_policy, P} -> ct:fail({refer_policy_asked, P})
    after 0 -> ok
    end.

%% A refer_policy that lets every REFER in says nothing about Replaces:
%% without a replaces_policy the room allows the member itself and a
%% caller whose Referred-By names it, and refuses anyone else 403.
%% req: MRF-22
invite_replaces_default(Config) ->
    {ok, Conf} = chappe_mrf:conference(<<"repdef">>, #{
        focus => true, refer_policy => fun(_) -> true end
    }),
    {Ua1, M1} = room_caller(Config, Conf),
    {ua, Ua1, {final, 200, Ok}} = ua_answer(Ua1),
    [#{uri := U1}] = chappe_mrf_conf:members(Conf),
    Rep = replaces_of(Ok),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test ! {join, chappe_mrf_conf:join(Conf, {call, Req, Res}, #{})}
    end),
    Stranger = ?F:ua_call(?config(ep, Config), #{
        from => <<"sip:stranger@127.0.0.1">>, headers => [{<<"Replaces">>, Rep}]
    }),
    {ua, Stranger, {final, 403, _}} = ua_answer(Stranger),
    {error, _} = join_result(),
    ?assertMatch([#{id := M1}], chappe_mrf_conf:members(Conf)),
    no_ua_event(Ua1, bye, 300),
    %% a caller the member referred
    {Referred, M2} = room_caller(Config, Conf, #{
        from => <<"sip:carol@127.0.0.1">>,
        headers => [
            {<<"Replaces">>, Rep},
            {<<"Referred-By">>, <<"<", U1/binary, ">">>}
        ]
    }),
    {ua, Referred, {final, 200, _}} = ua_answer(Referred),
    _ = ua_event(Ua1, bye),
    conf_event(Conf, {left, M1, replaced}),
    ?assertMatch([#{id := M2}], chappe_mrf_conf:members(Conf)).

%% Anonymous callers share one address-of-record: one never replaces an
%% anonymous member by the room's default, only through its
%% replaces_policy.
%% req: MRF-22
invite_replaces_anonymous(Config) ->
    Anon = <<"sip:anonymous@anonymous.invalid">>,
    Test = self(),
    Rooms = [
        {<<"repanon">>, #{focus => true}, 403},
        {<<"repanon2">>,
            #{
                focus => true,
                replaces_policy => fun(#{caller := C}) -> C =:= Anon end
            },
            200}
    ],
    lists:foreach(
        fun({Name, Opts, Status}) ->
            {ok, Conf} = chappe_mrf:conference(Name, Opts),
            {Ua1, M1} = room_caller(Config, Conf, #{from => Anon}),
            {ua, Ua1, {final, 200, Ok}} = ua_answer(Ua1),
            ok = chappe_sip:invite(fun(Req, Res) ->
                Test ! {join, chappe_mrf_conf:join(Conf, {call, Req, Res}, #{})}
            end),
            Ua = ?F:ua_call(?config(ep, Config), #{
                from => Anon, headers => [{<<"Replaces">>, replaces_of(Ok)}]
            }),
            {ua, Ua, {final, Status, _}} = ua_answer(Ua),
            _ = join_result(),
            case Status of
                403 ->
                    no_ua_event(Ua1, bye, 300),
                    ?assertMatch([#{id := M1}], chappe_mrf_conf:members(Conf));
                200 ->
                    _ = ua_event(Ua1, bye),
                    conf_event(Conf, {left, M1, replaced})
            end,
            ok = chappe_mrf_conf:stop(Conf)
        end,
        Rooms
    ).

%% Two calls replacing the same member at once: the first, held inside
%% its join until the second came, takes its place; the second is refused
%% 603 (RFC 3891 3, as for a dialog already being replaced).
%% req: MRF-22
invite_replaces_race(Config) ->
    {ok, Conf} = chappe_mrf:conference(<<"reprace">>, #{
        focus => true, backend => chappe_mrf_conf_gate_backend
    }),
    {Ua1, M1} = room_caller(Config, Conf),
    {ua, Ua1, {final, 200, Ok}} = ua_answer(Ua1),
    [#{uri := U1}] = chappe_mrf_conf:members(Conf),
    gated(Conf),
    Opts = #{from => U1, headers => [{<<"Replaces">>, replaces_of(Ok)}]},
    A = ?F:ua_call(?config(ep, Config), Opts),
    Held = gate(),
    B = ?F:ua_call(?config(ep, Config), Opts),
    {ua, B, {final, 603, _}} = ua_answer(B),
    Held ! {gate, go},
    {ua, A, {final, 200, _}} = ua_answer(A),
    _ = ua_event(Ua1, bye),
    conf_event(Conf, {left, M1, replaced}),
    ?assertMatch([_], chappe_mrf_conf:members(Conf)).

%% A member held for a caller replacing it is released when that caller
%% dies inside its join, or its join raises: a later caller replaces it.
%% req: MRF-22
invite_replaces_caller_dies(Config) ->
    {ok, Conf} = chappe_mrf:conference(<<"repdies">>, #{
        focus => true, backend => chappe_mrf_conf_gate_backend
    }),
    {Ua1, M1} = room_caller(Config, Conf),
    {ua, Ua1, {final, 200, Ok}} = ua_answer(Ua1),
    [#{uri := U1}] = chappe_mrf_conf:members(Conf),
    gated(Conf),
    Opts = #{from => U1, headers => [{<<"Replaces">>, replaces_of(Ok)}]},
    _A = ?F:ua_call(?config(ep, Config), Opts),
    Dies = gate(),
    Mon = monitor(process, Dies),
    exit(Dies, kill),
    receive
        {'DOWN', Mon, process, Dies, _} -> ok
    after 5000 -> ct:fail(no_down)
    end,
    B = ?F:ua_call(?config(ep, Config), Opts),
    gate() ! {gate, raise},
    {ua, B, {final, _, _}} = ua_answer(B),
    ?assertMatch([#{id := M1}], chappe_mrf_conf:members(Conf)),
    C = ?F:ua_call(?config(ep, Config), Opts),
    gate() ! {gate, go},
    {ua, C, {final, 200, _}} = ua_answer(C),
    _ = ua_event(Ua1, bye),
    conf_event(Conf, {left, M1, replaced}).

%% A caller whose hold on a member ran out is too late: a second caller
%% holds the member now, so the first one's join, completing, gets
%% {error, expired} and its call is hung up, not the member (the roster
%% shows it booted); the second caller then replaces it.
%% req: MRF-27
invite_replaces_stale_hold(Config) ->
    ok = chappe_sip:event_package(
        <<"conference">>, fun chappe_mrf:focus_subscribe/2
    ),
    {ok, Conf} = chappe_mrf:conference(<<"repstale">>, #{
        focus => true, backend => chappe_mrf_conf_gate_backend
    }),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    {Ua1, M1} = room_caller(Config, Conf),
    {ua, Ua1, {final, 200, Ok}} = ua_answer(Ua1),
    [#{uri := U1}] = chappe_mrf_conf:members(Conf),
    W = watch(Config, Entity),
    _ = roster(W),
    gated(Conf),
    Opts = #{from => U1, headers => [{<<"Replaces">>, replaces_of(Ok)}]},
    A = ?F:ua_call(?config(ep, Config), Opts),
    GateA = gate(),
    expire_hold(Conf, M1),
    B = ?F:ua_call(?config(ep, Config), Opts),
    GateB = gate(),
    GateA ! {gate, go},
    {ua, A, {final, 200, _}} = ua_answer(A),
    ?assertEqual({error, expired}, join_result()),
    _ = ua_event(A, bye),
    ?assertMatch([#{id := M1}], chappe_mrf_conf:members(Conf)),
    no_ua_event(Ua1, bye, 200),
    ?assert(
        roster_until(
            W, <<"<disconnection-method>booted</disconnection-method>">>
        )
    ),
    gen_udp:close(W),
    GateB ! {gate, go},
    {ua, B, {final, 200, _}} = ua_answer(B),
    {ok, MB} = join_result(),
    _ = ua_event(Ua1, bye),
    conf_event(Conf, {left, M1, replaced}),
    ?assertMatch([#{id := MB}], chappe_mrf_conf:members(Conf)).

%% A member whose call was transferred while a caller was replacing it
%% keeps the target in its place when that caller's join completes, and
%% that caller is hung up.
%% req: MRF-27
invite_replaces_after_transfer(Config) ->
    {ok, Conf} = chappe_mrf:conference(<<"repxfer">>, #{
        focus => true, backend => chappe_mrf_conf_gate_backend
    }),
    {Ua1, M1} = room_caller(Config, Conf),
    {ua, Ua1, {final, 200, Ok}} = ua_answer(Ua1),
    [#{uri := U1}] = chappe_mrf_conf:members(Conf),
    gated(Conf),
    A = ?F:ua_call(?config(ep, Config), #{
        from => U1, headers => [{<<"Replaces">>, replaces_of(Ok)}]
    }),
    GateA = gate(),
    #{M1 := #{b2b := {_, Ref}, replacing := _}} = element(
        9, sys:get_state(Conf)
    ),
    Erin = <<"sip:erin@10.0.0.7">>,
    ok = chappe_mrf_conf:b2b_event(
        Conf, {chappe_sip_b2b, Ref, {transferred, a, #{target => Erin}}}
    ),
    conf_event(Conf, {left, M1, transferred}),
    GateA ! {gate, go},
    {ua, A, {final, 200, _}} = ua_answer(A),
    ?assertEqual({error, expired}, join_result()),
    _ = ua_event(A, bye),
    ?assertMatch([#{id := M1, uri := Erin}], chappe_mrf_conf:members(Conf)),
    no_ua_event(Ua1, bye, 200).

%% A member that leaves while a caller replacing it is on its way leaves
%% its place to that caller: the caller's join completes, its call is not
%% hung up, and it stays in the room.
%% req: MRF-27
invite_replaces_member_left(Config) ->
    {ok, Conf} = chappe_mrf:conference(<<"repleft">>, #{
        focus => true, backend => chappe_mrf_conf_gate_backend
    }),
    {Ua1, M1} = room_caller(Config, Conf),
    {ua, Ua1, {final, 200, Ok}} = ua_answer(Ua1),
    [#{uri := U1}] = chappe_mrf_conf:members(Conf),
    gated(Conf),
    A = ?F:ua_call(?config(ep, Config), #{
        from => U1, headers => [{<<"Replaces">>, replaces_of(Ok)}]
    }),
    GateA = gate(),
    ok = ?F:ua_bye(Ua1),
    conf_event(Conf, {left, M1, departed}),
    GateA ! {gate, go},
    {ua, A, {final, 200, _}} = ua_answer(A),
    {ok, MA} = join_result(),
    no_ua_event(A, bye, 300),
    ?assertMatch([#{id := MA}], chappe_mrf_conf:members(Conf)).

%% the timer of member Id's hold fires now
expire_hold(Conf, Id) ->
    #{Id := #{replacing := {Hold, T}}} = element(9, sys:get_state(Conf)),
    Conf ! {timeout, T, {refer_replace, Id, Hold}},
    until(fun() ->
        #{Id := Mb} = element(9, sys:get_state(Conf)),
        not is_map_key(replacing, Mb)
    end).

%% what the next join/3 of the INVITE handler returned
join_result() ->
    receive
        {join, J} -> J
    after 10000 -> ct:fail(no_join)
    end.

%% every call joins through the gate of chappe_mrf_conf_gate_backend
gated(Conf) ->
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test !
            {join,
                chappe_mrf_conf:join(Conf, {call, Req, Res}, #{gate => Test})}
    end).

%% the next join held at the gate
gate() ->
    receive
        {gate, Pid} -> Pid
    after 10000 -> ct:fail(no_gate)
    end.

%% the Replaces naming a caller's dialog with the room, from its 200
replaces_of(Ok) ->
    {ok, Msg} = chappe_sip_msg:parse(Ok),
    <<
        (chappe_sip_msg:call_id(Msg))/binary,
        ";to-tag=",
        (chappe_sip_msg:to_tag(Msg))/binary,
        ";from-tag=",
        (chappe_sip_msg:from_tag(Msg))/binary
    >>.

%% A member's call transferred to someone else: the roster shows the
%% target as itself, not under the privacy the old caller asked for.
%% req: MRF-19
transferred_drops_privacy(Config) ->
    ivr(Config),
    ok = chappe_sip:event_package(
        <<"conference">>, fun chappe_mrf:focus_subscribe/2
    ),
    {ok, Conf} = chappe_mrf:conference(<<"privroom">>, #{focus => true}),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    {_Ua, _Ep, {_, Ref} = B2b, _Owner} = call_in(Config),
    {ok, M} = chappe_mrf_conf:join(Conf, B2b, #{
        uri => <<"sip:shy@127.0.0.1">>, private => true
    }),
    {joined, M, _} = joined(Conf),
    W = watch(Config, Entity),
    ?assert(roster_until(W, <<"anonymous.invalid">>)),
    ok = chappe_mrf_conf:b2b_event(
        Conf,
        {chappe_sip_b2b, Ref,
            {transferred, a, #{target => <<"sip:erin@10.0.0.7">>}}}
    ),
    ?assert(roster_until(W, <<"user entity=\"sip:erin@10.0.0.7\"">>)),
    gen_udp:close(W).

policy_info() ->
    receive
        {policy, _} = P -> P
    after 5000 -> ct:fail(no_policy)
    end.

%% the chappe_dial marks of a dial command
dial_marks(Cmd) ->
    {match, [Tag]} = re:run(Cmd, <<"chappe_dial=([^,}]+)">>, [
        {capture, all_but_first, binary}
    ]),
    {match, [Op]} = re:run(Cmd, <<"chappe_dial_op=([^,}]+)">>, [
        {capture, all_but_first, binary}
    ]),
    {Tag, Op}.

%% a node event of the dialed leg, as chappe_esl:node_events/2 delivers it
progress_event(Node, Name, Tag, Op) ->
    {chappe_esl_node, Node,
        {event, #{
            body => <<>>,
            headers => #{
                <<"Event-Name">> => Name,
                <<"variable_chappe_dial">> => Tag,
                <<"variable_chappe_dial_op">> => Op
            }
        }}}.

no_joined(Conf) ->
    receive
        {chappe_mrf_conf, Conf, {joined, _, _} = J} -> ct:fail({joined, J})
    after 0 -> ok
    end.

no_fs_cmd(Pattern, Ms) ->
    receive
        {fake_fs, _, _, {cmd, Block}} = M ->
            case has(Block, Pattern) of
                true -> ct:fail({unexpected, M});
                false -> no_fs_cmd(Pattern, Ms)
            end;
        {fake_esl, _, {api, Block}} = M ->
            case has(Block, Pattern) of
                true -> ct:fail({unexpected, M});
                false -> no_fs_cmd(Pattern, Ms)
            end
    after Ms -> ok
    end.

%% a watcher of the room's conference package: its socket
watch(Config, Entity) ->
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    {ok, P} = inet:port(Sock),
    Pb = integer_to_binary(P),
    Sub = iolist_to_binary([
        <<"SUBSCRIBE ">>,
        Entity,
        <<" SIP/2.0\r\n">>,
        <<"Via: SIP/2.0/UDP 127.0.0.1:", Pb/binary,
            ";rport;branch=z9hG4bKros1\r\n">>,
        <<"Max-Forwards: 70\r\nFrom: <sip:w@127.0.0.1>;tag=w1\r\n">>,
        <<"To: <", Entity/binary,
            ">\r\nCall-ID: ros-1\r\nCSeq: 1 SUBSCRIBE\r\n">>,
        <<"Contact: <sip:w@127.0.0.1:", Pb/binary,
            ">\r\nEvent: conference\r\n">>,
        <<"Accept: application/conference-info+xml\r\nExpires: 60\r\n">>,
        <<"Content-Length: 0\r\n\r\n">>
    ]),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, ?config(ep, Config), Sub),
    Sock.

%% the next conference-info body the watcher gets
roster(Sock) ->
    receive
        {udp, Sock, _, Src, <<"NOTIFY ", _/binary>> = Bin} ->
            _ = gen_udp:send(Sock, {127, 0, 0, 1}, Src, ok_for(Bin)),
            ?F:body(Bin);
        {udp, Sock, _, _, _} ->
            roster(Sock)
    after 5000 -> ct:fail(no_roster)
    end.

%% whether a conference-info body with Part comes
roster_until(Sock, Part) ->
    receive
        {udp, Sock, _, Src, <<"NOTIFY ", _/binary>> = Bin} ->
            _ = gen_udp:send(Sock, {127, 0, 0, 1}, Src, ok_for(Bin)),
            has(?F:body(Bin), Part) orelse roster_until(Sock, Part);
        {udp, Sock, _, _, _} ->
            roster_until(Sock, Part)
    after 5000 -> false
    end.

%% A caller answered straight into Conf (join/3 with {call, Req, Res}).
room_caller(Config, Conf) ->
    room_caller(Config, Conf, #{}).

%% UaOpts: ?F:ua_call/2's (from, headers)
room_caller(Config, Conf, UaOpts) ->
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test ! {join, chappe_mrf_conf:join(Conf, {call, Req, Res}, #{})}
    end),
    Ua = ?F:ua_call(?config(ep, Config), UaOpts),
    {ok, M} =
        receive
            {join, J} -> J
        after 10000 -> ct:fail(no_join)
        end,
    {joined, M, _} = joined(Conf),
    {Ua, M}.

ua_answer(Ua) ->
    receive
        {ua, Ua, {final, _, _}} = F -> F
    after 10000 -> ct:fail(no_final)
    end.

%% whether the REFER's NOTIFYs to Ua end with a sipfrag starting Frag
final_notify(Ua, Frag) ->
    receive
        {ua, Ua, {request, <<"NOTIFY", _/binary>> = N}} ->
            case has(N, <<"terminated">>) of
                true -> has(N, Frag);
                false -> final_notify(Ua, Frag)
            end
    after 10000 -> ct:fail(no_final_notify)
    end.

ua_msg(Ua, Kind) ->
    receive
        {ua, Ua, {Kind, _}} = M -> M
    after 10000 -> ct:fail({no_ua, Kind})
    end.

%% A member's call is transferred by REFER (its B2BUA carries it out,
%% transfer => auto): handed the call's transferred event, the room shows
%% the member leaving (transferred) and the target in its place.
member_transferred(Config) ->
    ivr(Config),
    {ok, Conf} = chappe_mrf:conference(<<"xroom">>, #{}),
    {_Ua, _Ep, {_, Ref} = B2b, _Owner} = call_in(Config),
    {ok, M} = chappe_mrf_conf:join(Conf, B2b, #{
        uri => <<"sip:caller@127.0.0.1">>
    }),
    {joined, M, _} = joined(Conf),
    ok = chappe_mrf_conf:b2b_event(
        Conf, {chappe_sip_b2b, make_ref(), {transferred, a, #{}}}
    ),
    ok = chappe_mrf_conf:b2b_event(
        Conf,
        {chappe_sip_b2b, Ref,
            {transferred, a, #{
                target => <<"sip:erin@10.0.0.7">>, kind => blind
            }}}
    ),
    conf_event(Conf, {left, M, transferred}),
    {joined, M, #{uri := <<"sip:erin@10.0.0.7">>}} =
        {joined, M, _} = joined(Conf),
    ?assertMatch(
        [#{id := M, uri := <<"sip:erin@10.0.0.7">>}],
        chappe_mrf_conf:members(Conf)
    ).

joined(Conf) ->
    receive
        {chappe_mrf_conf, Conf, {joined, _, _} = E} -> E
    after 5000 -> ct:fail(no_joined)
    end.

%% A REFER out of dialog to Uri from User, Refer-To ReferTo, over UDP.
refer(Config, Uri, User, ReferTo) ->
    refer(Config, Uri, User, ReferTo, #{}).

%% Opts: call_id and from_tag (a REFER from the same origin as another),
%% cseq, headers
refer(Config, Uri, User, ReferTo, Opts) ->
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    {ok, P} = inet:port(Sock),
    Pb = integer_to_binary(P),
    N = integer_to_binary(erlang:unique_integer([positive])),
    CallId = maps:get(call_id, Opts, <<"refer-", N/binary>>),
    FromTag = maps:get(from_tag, Opts, <<"r1">>),
    CSeq = integer_to_binary(maps:get(cseq, Opts, 1)),
    Req = iolist_to_binary([
        <<"REFER ">>,
        Uri,
        <<" SIP/2.0\r\n">>,
        <<"Via: SIP/2.0/UDP 127.0.0.1:", Pb/binary, ";rport;branch=z9hG4bK",
            CallId/binary, "-", N/binary, "\r\n">>,
        <<"Max-Forwards: 70\r\nFrom: <sip:", User/binary, "@127.0.0.1>;tag=",
            FromTag/binary, "\r\n">>,
        <<"To: <", Uri/binary, ">\r\nCall-ID: ", CallId/binary, "\r\nCSeq: ",
            CSeq/binary, " REFER\r\n">>,
        <<"Contact: <sip:", User/binary, "@127.0.0.1:", Pb/binary, ">\r\n">>,
        [[K, <<": ">>, V, <<"\r\n">>] || {K, V} <- maps:get(headers, Opts, [])],
        <<"Refer-To: ", ReferTo/binary, "\r\nContent-Length: 0\r\n\r\n">>
    ]),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, ?config(ep, Config), Req),
    {Sock, CallId}.

%% The final response to the REFER (provisionals skipped).
sip_response(Sock) ->
    receive
        {udp, Sock, _, _, <<"SIP/2.0 1", _/binary>>} -> sip_response(Sock);
        {udp, Sock, _, _, <<"SIP/2.0 ", _/binary>> = R} -> R
    after 5000 -> ct:fail(no_refer_response)
    end.

%% The status lines of the next N NOTIFYs' sipfrags, each answered 200
%% (a retransmission, by its CSeq, is answered and skipped).
frags(Sock, N) ->
    frags(Sock, N, get_seen(Sock)).

frags(_Sock, 0, _Seen) ->
    [];
frags(Sock, N, Seen) ->
    receive
        {udp, Sock, _, Src, <<"NOTIFY ", _/binary>> = Bin} ->
            _ = gen_udp:send(Sock, {127, 0, 0, 1}, Src, ok_for(Bin)),
            {ok, Msg} = chappe_sip_msg:parse(Bin),
            CSeq = chappe_sip_msg:get(<<"cseq">>, Msg),
            case lists:member(CSeq, Seen) of
                true ->
                    frags(Sock, N, Seen);
                false ->
                    put({seen, Sock}, [CSeq | Seen]),
                    <<Line:11/binary, _/binary>> = chappe_sip_msg:body(Msg),
                    [Line | frags(Sock, N - 1, [CSeq | Seen])]
            end
    after 10000 -> ct:fail(no_notify)
    end.

%% The next final sipfrag status line (progress 1xx skipped).
final_frag(Sock) ->
    case frags(Sock, 1) of
        [<<"SIP/2.0 1", _/binary>>] -> final_frag(Sock);
        [Line] -> Line
    end.

get_seen(Sock) ->
    case get({seen, Sock}) of
        undefined -> [];
        L -> L
    end.

%% The caller hangs up: the channel gets a BYE, the owner the hangup, and
%% the call's notify process how the call ended.
caller_hangup(Config) ->
    ivr(Config),
    {Ua, _Ep, {_, Ref}, Owner} = call_in(Config),
    ?F:ua_bye(Ua),
    _ = fs_what(bye),
    _ = owner_msg({hangup, <<"NORMAL_CLEARING">>}),
    receive
        {chappe_sip_b2b, Ref, {done, {done, a_bye}}} -> ok
    after 5000 -> ct:fail(no_done)
    end,
    Owner ! stop.

%% A channel whose X-Chappe-Call nobody waits for is hung up.
%% req: MRF-02
unknown_channel_refused(Config) ->
    {ok, Tcp} = gen_tcp:connect({127, 0, 0, 1}, ?config(lp, Config), [
        binary, {active, false}
    ]),
    ok = gen_tcp:send(Tcp, <<>>),
    {ok, <<"connect\n\n">>} = gen_tcp:recv(Tcp, 0, 5000),
    ok = gen_tcp:send(
        Tcp,
        <<
            "Content-Type: command/reply\nReply-Text: +OK\nUnique-ID: u1\n"
            "variable_sip_h_X-Chappe-Call: nobody\n\n"
        >>
    ),
    {ok, Next} = recv_until(Tcp, <<"hangup">>, <<>>),
    ?assert(has(Next, <<"execute-app-name: hangup">>)),
    gen_tcp:close(Tcp).

recv_until(Tcp, Part, Acc) ->
    case binary:match(Acc, Part) of
        nomatch ->
            case gen_tcp:recv(Tcp, 0, 5000) of
                {ok, B} -> recv_until(Tcp, Part, <<Acc/binary, B/binary>>);
                Err -> Err
            end;
        _ ->
            {ok, Acc}
    end.

%% The endpoint's owner dies: the channel is killed (uuid_kill), and the
%% caller gets a BYE.
%% req: MRF-04
owner_death_kills_channel(Config) ->
    ivr(Config),
    {Ua, Ep, _B2b, Owner} = call_in(Config),
    {ok, Uuid} = chappe_mrf:uuid(Ep),
    ok = in_owner(Owner, fun() ->
        chappe_mrf:fork_audio_start(Ep, <<"ws://127.0.0.1:1/x">>, #{})
    end),
    exit(Owner, kill),
    _ = fs_cmd(<<"uuid_audio_fork ", Uuid/binary, " stop">>),
    _ = fs_cmd(<<"uuid_kill ", Uuid/binary>>),
    _ = ua_event(Ua, bye).

%% No node to send the caller to: 503.
no_node(Config) ->
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test ! {result, chappe_mrf:connect_caller(Req, Res, #{})}
    end),
    Ua = ?F:ua_call(?config(ep, Config), #{}),
    {ok, 503} = ua_final(Ua),
    receive
        {result, {error, no_node}} -> ok
    after 5000 -> ct:fail(no_result)
    end,
    ?assertEqual({error, no_node}, chappe_mrf:create_endpoint(#{})).

%% create_endpoint/1, then bridge/2 moves the caller onto it: the new
%% channel's dialog gets rtpengine's offer for the caller, the old
%% channel a BYE, and the caller no re-INVITE.
%% req: MRF-01 MRF-05
create_endpoint_bridge(Config) ->
    ivr(Config),
    {Ua, Ep1, B2b, Owner} = call_in(Config),
    {ok, Ep2} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    ?assertNotEqual(chappe_mrf:uuid(Ep1), chappe_mrf:uuid(Ep2)),
    ok = chappe_mrf:bridge(B2b, Ep2),
    ReInvite = fs_what(reinvite),
    ?assert(has(ReInvite, <<"a=rtpe-offer:">>)),
    _ = fs_what(bye),
    _ = owner_msg({hangup, <<"NORMAL_CLEARING">>}),
    no_ua_event(Ua, reinvite, 500),
    ?assertEqual({error, already_bridged}, chappe_mrf:bridge(B2b, Ep2)),
    ?assertMatch(#{bridged := true}, chappe_mrf:info(Ep2)),
    ?F:ua_bye(Ua),
    receive
        {chappe_mrf, Ep2, {hangup, _}} -> ok
    after 5000 -> ct:fail(ep2_no_hangup)
    end,
    Owner ! stop.

%% bridge/2 to a SIP URI: the callee gets the INVITE, the endpoint's
%% channel a BYE.
%% req: MRF-05
bridge_to_uri(Config) ->
    ivr(Config),
    {Ua, _Ep, B2b, Owner} = call_in(Config),
    {_Callee, CP} = ?F:callee_start(<<"calleetag">>),
    ok = chappe_mrf:bridge(
        B2b, <<"sip:bob@127.0.0.1:", (integer_to_binary(CP))/binary>>
    ),
    receive
        {callee, invite, _} -> ok
    after 5000 -> ct:fail(no_callee)
    end,
    _ = fs_what(bye),
    no_ua_event(Ua, reinvite, 300),
    ?F:ua_bye(Ua),
    receive
        {callee, bye, _} -> ok
    after 5000 -> ct:fail(no_callee_bye)
    end,
    Owner ! stop.

%% The other endpoint commands reach the channel as their application.
endpoint_commands(Config) ->
    {ok, Ep} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    ok = chappe_mrf:record(Ep, <<"/media/rec.wav">>, #{max_secs => 3}),
    _ = fs_cmd(<<"execute-app-name: record">>),
    ok = chappe_mrf:record_session(Ep, <<"/media/s.wav">>),
    _ = fs_cmd(<<"execute-app-name: record_session">>),
    ok = chappe_mrf:record_session_stop(Ep, <<"/media/s.wav">>),
    _ = fs_cmd(<<"execute-app-name: stop_record_session">>),
    ok = chappe_mrf:send_dtmf(Ep, <<"12">>),
    _ = fs_cmd(<<"execute-app-name: send_dtmf">>),
    ok = chappe_mrf:set(Ep, <<"x">>, <<"1">>),
    _ = fs_cmd(<<"execute-app-arg: x=1">>),
    {ok, _} = chappe_mrf:execute(Ep, <<"echo">>, <<>>),
    {ok, <<"+OK">>} = chappe_mrf:api(Ep, <<"status">>),
    ok = chappe_mrf:play(Ep, [<<"/a.wav">>, <<"/b.wav">>]),
    _ = fs_cmd(<<"/b.wav">>),
    ok = chappe_mrf:modify(Ep, hold),
    _ = fs_cmd(<<"uuid_hold ">>),
    ok = chappe_mrf:modify(Ep, unhold),
    _ = fs_cmd(<<"uuid_hold off">>),
    {ok, Answer} = chappe_mrf:modify(Ep, chappe_mrf:inactive_sdp()),
    ?assert(has(Answer, <<"m=audio">>)),
    _ = fs_what(reinvite),
    ok = chappe_mrf:fork_audio_stop(Ep),
    {ok, Uuid} = chappe_mrf:uuid(Ep),
    ok = chappe_mrf:destroy(Ep),
    _ = fs_cmd(<<"uuid_kill ", Uuid/binary>>),
    ?assertEqual({error, gone}, chappe_mrf:play(Ep, <<"/a.wav">>)).

%% A missing file is an error, play_info/3 reports how long the file
%% played, and play_collect/2 can return the whole result.
play_results(Config) ->
    {ok, Ep} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    ?assertEqual(
        {error, not_found}, chappe_mrf:play(Ep, <<"/media/missing.wav">>)
    ),
    ?assertEqual(
        {error, not_found},
        chappe_mrf:play(Ep, [<<"/a.wav">>, <<"/missing.wav">>, <<"/b.wav">>])
    ),
    ?assertEqual(
        {ok, #{ms => 1234, response => <<"FILE PLAYED">>}},
        chappe_mrf:play_info(Ep, <<"/a.wav">>, #{offset => 800})
    ),
    _ = fs_cmd(<<"/a.wav@@800">>),
    ?assertEqual(
        {ok, #{digits => <<"1">>, terminator => <<>>, invalid => <<>>}},
        chappe_mrf:play_collect(Ep, #{file => <<"/p.wav">>, result => full})
    ),
    ok = chappe_mrf:destroy(Ep).

%% Variables, mute, export and an application run without waiting: each
%% reaches the node as the command FreeSWITCH expects, and the
%% application's end reaches the owner.
endpoint_more_commands(Config) ->
    {ok, Ep} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    {ok, Uuid} = chappe_mrf:uuid(Ep),
    ok = chappe_mrf:mute(Ep, read),
    _ = fs_cmd(<<"uuid_audio ", Uuid/binary, " start read mute 1">>),
    ok = chappe_mrf:unmute(Ep, read),
    _ = fs_cmd(<<"uuid_audio ", Uuid/binary, " start read mute 0">>),
    ok = chappe_mrf:set(Ep, #{<<"a">> => <<"1">>, <<"b">> => <<"2">>}),
    _ = fs_cmd(<<"execute-app-arg: ^^|a=1|b=2">>),
    ok = chappe_mrf:export(Ep, <<"c">>, <<"3">>),
    _ = fs_cmd(<<"execute-app-arg: c=3">>),
    {ok, _} = chappe_mrf:var(Ep, <<"a">>),
    _ = fs_cmd(<<"uuid_getvar ", Uuid/binary, " a">>),
    ok = chappe_mrf:say(Ep, <<"7">>, #{type => number}),
    _ = fs_cmd(<<"execute-app-arg: en number pronounced 7">>),
    ok = chappe_mrf:speak(Ep, <<"hello">>, #{
        engine => <<"flite">>, voice => <<"kal">>
    }),
    _ = fs_cmd(<<"execute-app-arg: flite|kal|hello">>),
    ok = chappe_mrf:detect_tones(Ep, <<"chappe">>),
    _ = fs_cmd(<<"event plain DETECTED_TONE">>),
    ok = chappe_mrf:detect_fax(Ep),
    _ = fs_cmd(<<"execute-app-arg: set chappe_fax_detected=true 0 cng">>),
    Fs = ?config(fs, Config),
    ?F:fs_event(Fs, <<"DETECTED_TONE">>, [{<<"Detected-Tone">>, <<"T1">>}]),
    ?F:fs_event(Fs, <<"DETECTED_TONE">>, [{<<"Detected-Fax-Tone">>, <<"true">>}]),
    ?assertEqual({tone, <<"T1">>}, ep_msg(Ep)),
    ?assertEqual({fax, detected}, ep_msg(Ep)),
    ok = chappe_mrf:stop_detect_tones(Ep),
    ok = chappe_mrf:stop_detect_fax(Ep),
    ?assertEqual({error, not_forking}, chappe_mrf:fork_audio_pause(Ep)),
    ok = chappe_mrf:fork_audio_start(Ep, <<"ws://x">>, #{bugname => <<"b1">>}),
    _ = fs_cmd(<<"start ws://x mono 16000 b1">>),
    ok = chappe_mrf:fork_audio_pause(Ep),
    _ = fs_cmd(<<"uuid_audio_fork ", Uuid/binary, " pause b1">>),
    ok = chappe_mrf:fork_audio_resume(Ep, #{bugname => <<"b1">>}),
    _ = fs_cmd(<<"uuid_audio_fork ", Uuid/binary, " resume b1">>),
    ok = chappe_mrf:fork_audio_send_text(Ep, <<"{\"x\":1}">>),
    _ = fs_cmd(<<"send_text b1 {\"x\":1}">>),
    {ok, AppUuid} = chappe_mrf:execute(Ep, <<"echo">>, <<>>, #{wait => false}),
    receive
        {chappe_mrf, Ep, {complete, <<"echo">>, Ev}} ->
            ?assertEqual(
                AppUuid, chappe_esl_event:header(<<"Application-UUID">>, Ev)
            )
    after 5000 -> ct:fail(no_completion)
    end,
    ok = chappe_mrf:destroy(Ep).

%% Two endpoints of one call, given its call_ref: each INVITE carries the
%% ref as X-Chappe-Call and its own id as X-Chappe-Endpoint, each channel
%% finds its own endpoint, and info/1 returns the ref. A bad ref is
%% refused before anything is sent.
call_ref(Config) ->
    Opts = #{targets => [{fs1, fs_uri(Config)}], call_ref => <<"call-42">>},
    {ok, Ep1} = chappe_mrf:create_endpoint(Opts),
    {ok, Ep2} = chappe_mrf:create_endpoint(Opts),
    #{call_ref := <<"call-42">>, id := Id1, uuid := U1} = chappe_mrf:info(Ep1),
    #{call_ref := <<"call-42">>, id := Id2, uuid := U2} = chappe_mrf:info(Ep2),
    ?assertNotEqual(Id1, Id2),
    ?assertNotEqual(U1, U2),
    {ok, Plain} = chappe_mrf:create_endpoint(maps:remove(call_ref, Opts)),
    ?assertMatch(#{call_ref := undefined}, chappe_mrf:info(Plain)),
    [
        ?assertEqual(
            {error, {bad_option, call_ref}},
            chappe_mrf:create_endpoint(Opts#{call_ref => Bad})
        )
     || Bad <- [42, <<>>, <<"a\r\nX-Evil: 1">>]
    ],
    [ok = chappe_mrf:destroy(E) || E <- [Ep1, Ep2, Plain]].

%% The owner asked for playback, CUSTOM and channel events: the endpoint
%% subscribes to them (CUSTOM last) and hands them over; what it did not
%% ask for stays away.
owner_events(Config) ->
    Events = [
        playback_start,
        playback_stop,
        {custom, <<"chappe::x">>},
        {channel, <<"CHANNEL_BRIDGE">>}
    ],
    {ok, Ep} = chappe_mrf:create_endpoint(#{
        targets => [{fs1, fs_uri(Config)}], events => Events
    }),
    _ = fs_cmd(
        <<"event plain CHANNEL_BRIDGE PLAYBACK_START PLAYBACK_STOP CUSTOM chappe::x">>
    ),
    Fs = ?config(fs, Config),
    File = [{<<"Playback-File-Path">>, <<"/a.wav">>}],
    ?F:fs_event(Fs, <<"PLAYBACK_START">>, File),
    ?F:fs_event(Fs, <<"PLAYBACK_STOP">>, [
        {<<"Playback-Status">>, <<"break">>} | File
    ]),
    ?F:fs_event(Fs, <<"CUSTOM">>, [{<<"Event-Subclass">>, <<"other::y">>}]),
    ?F:fs_event(Fs, <<"CUSTOM">>, [{<<"Event-Subclass">>, <<"chappe::x">>}]),
    ?F:fs_event(Fs, <<"CHANNEL_PARK">>, []),
    ?F:fs_event(Fs, <<"CHANNEL_BRIDGE">>, []),
    ?assertEqual({playback_start, <<"/a.wav">>}, ep_msg(Ep)),
    ?assertEqual({playback_stop, <<"/a.wav">>, <<"break">>}, ep_msg(Ep)),
    ?assertMatch({custom, <<"chappe::x">>, _}, ep_msg(Ep)),
    ?assertMatch({channel, <<"CHANNEL_BRIDGE">>, _}, ep_msg(Ep)),
    ok = chappe_mrf:destroy(Ep),
    [
        ?assertEqual(
            {error, {bad_option, events}},
            chappe_mrf:create_endpoint(#{
                targets => [{fs1, fs_uri(Config)}], events => Bad
            })
        )
     || Bad <- [
            nope,
            [speak],
            [{custom, <<"two words">>}],
            [{channel, <<"CUSTOM">>}],
            [{channel, <<"A\nB">>}]
        ]
    ].

ep_msg(Ep) ->
    receive
        {chappe_mrf, Ep, Msg} -> Msg
    after 5000 -> ct:fail(no_endpoint_msg)
    end.

%% The call's linger and disconnect notices leave a live endpoint as it is:
%% closed and the hangup are what end it.
endpoint_call_notices(Config) ->
    {ok, Ep} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    {ok, Call} = chappe_mrf_endpoint:call(Ep),
    Ep ! {chappe_esl_call, Call, linger},
    Ep ! {chappe_esl_call, Call, disconnect},
    ?assertMatch({ok, _}, chappe_mrf:uuid(Ep)),
    ok = chappe_mrf:destroy(Ep).

%% The node of a live endpoint goes down: its owner hears node_down.
%% req: MRF-03
node_down(Config) ->
    {Esl, Port} = ?F:esl_start(),
    ok = chappe_esl:node_add(fs1, #{
        host => "127.0.0.1",
        port => Port,
        sip_uri => fs_uri(Config),
        heartbeat_interval_ms => 60000,
        probe_interval_ms => 60000
    }),
    ok = chappe_esl:node_subscribe(fs1),
    receive
        {chappe_esl_node, fs1, up} -> ok
    after 5000 -> ct:fail(node_not_up)
    end,
    {ok, Ep} = chappe_mrf:create_endpoint(#{}),
    ?assertEqual({ok, fs1}, chappe_mrf:node(Ep)),
    ?F:esl_stop({Esl, Port}),
    receive
        {chappe_mrf, Ep, {node_down, fs1}} -> ok
    after 10000 -> ct:fail(no_node_down)
    end,
    chappe_mrf:destroy(Ep).

%% A native room recorded through SIPREC to chappe_sip's recording server
%% on this node, store => default: the mix lands in chappe_audio's store
%% under the ref given to record/3.
native_record_to_store(Config) ->
    Test = self(),
    Dir = filename:join(?config(priv_dir, Config), "native-rec"),
    ok = chappe_audio_store:configure(#{dir => Dir}),
    Targets = [{fs1, fs_uri(Config)}],
    ok = chappe_sip:handle(
        <<"INVITE">>,
        fun(Req, Res) ->
            case chappe_sip_req:uri(Req) of
                <<"sip:srs@", _/binary>> ->
                    {ok, Srs} = chappe_sip_siprec_srs:serve(Req, Res, #{
                        store => default
                    }),
                    chappe_sip_siprec_srs:run(Srs);
                _ ->
                    {ok, Ep, B2b} = chappe_mrf:connect_caller(
                        Req, Res, #{targets => Targets, notify => Test}
                    ),
                    Test ! {connected, Ep, B2b, self()},
                    owner_loop(Test)
            end
        end,
        #{option_tags => [<<"siprec">>]}
    ),
    {ok, Conf} = chappe_mrf:conference(<<"natrec">>, #{backend => native}),
    {Ua, _Ep, B2b, _Owner} = call_in(Config),
    {ok, _M} = chappe_mrf_conf:join(Conf, B2b, #{}),
    _ = fs_what(bye),
    Srs =
        <<"sip:srs@127.0.0.1:",
            (integer_to_binary(?config(ep, Config)))/binary>>,
    ok = chappe_mrf_conf:record(Conf, Srs, #{ref => <<"natrec-ref">>}),
    timer:sleep(500),
    ok = chappe_mrf_conf:stop_record(Conf),
    [R] = stored(<<"natrec-ref">>, 50),
    ?assertMatch(
        #{
            source := <<"siprec">>,
            parties := [<<"sip:mrf-natrec@chappe.invalid">>]
        },
        R
    ),
    ?F:ua_bye(Ua).

stored(Ref, 0) ->
    ct:fail({not_stored, Ref, chappe_audio_store:find(Ref)});
stored(Ref, N) ->
    case chappe_audio_store:find(Ref) of
        [_ | _] = Recs ->
            Recs;
        [] ->
            timer:sleep(100),
            stored(Ref, N - 1)
    end.

%% Three callers in a native room: each joins through a loopback INVITE
%% to the mixer (the caller sees no re-INVITE, its FreeSWITCH channel a
%% BYE), mute and kick work, and the events reach the notify process.
%% req: MRF-08 MRF-09
native_conference(Config) ->
    ivr(Config),
    {ok, Conf} = chappe_mrf:conference(<<"room1">>, #{backend => native}),
    ?assertEqual({ok, Conf}, chappe_mrf:conference(<<"room1">>, #{})),
    Calls = [call_in(Config) || _ <- [1, 2, 3]],
    Members = [
        begin
            {ok, M} = chappe_mrf_conf:join(Conf, B2b, #{
                name => <<"p">>, deaf => true
            }),
            _ = fs_what(bye),
            no_ua_event(Ua, reinvite, 100),
            M
        end
     || {Ua, _Ep, B2b, _Owner} <- Calls
    ],
    [M1, M2, M3] = Members,
    [
        receive
            {chappe_mrf_conf, Conf, {joined, M, #{name := <<"p">>}}} -> ok
        after 2000 -> ct:fail({no_joined, M})
        end
     || M <- Members
    ],
    ?assertEqual(3, length(chappe_mrf_conf:members(Conf))),
    ok = chappe_mrf_conf:mute(Conf, M2),
    ok = chappe_mrf_conf:deaf(Conf, M2),
    ok = chappe_mrf_conf:undeaf(Conf, M2),
    ok = chappe_mrf_conf:unmute(Conf, M2),
    ok = chappe_mrf_conf:relate(Conf, M1, M3, nohear),
    ok = chappe_mrf_conf:play(Conf, <<"/media/beep.wav">>),
    receive
        {rtpe_cmd, #{<<"command">> := <<"play media">>}} -> ok
    after 2000 -> ct:fail(no_play_media)
    end,
    ok = chappe_mrf_conf:kick(Conf, M3),
    {Ua3, _, _, _} = lists:nth(3, Calls),
    _ = ua_event(Ua3, bye),
    receive
        {chappe_mrf_conf, Conf, {left, M3, kicked}} -> ok
    after 2000 -> ct:fail(no_left)
    end,
    ok = chappe_mrf_conf:lock(Conf),
    {Ua4, _, B2b4, _} = call_in(Config),
    ?assertEqual({error, locked}, chappe_mrf_conf:join(Conf, B2b4, #{})),
    ok = chappe_mrf_conf:unlock(Conf),
    ?F:ua_bye(Ua4),
    ?assertEqual({error, not_member}, chappe_mrf_conf:mute(Conf, <<"nobody">>)),
    ok = chappe_mrf_conf:stop(Conf).

%% The room belongs to the conference, not to its first caller: the
%% first caller leaves, the room (its chappe_mix conference) stays, and
%% the next caller lands in the same one.
%% req: MRF-07
native_room_outlives_caller(Config) ->
    ivr(Config),
    {ok, Conf} = chappe_mrf:conference(<<"room2">>, #{}),
    {Ua1, _, B1, _} = call_in(Config),
    {ok, M1} = chappe_mrf_conf:join(Conf, B1, #{}),
    Mix1 = mix_conf(Conf, M1),
    MRef = monitor(process, Mix1),
    ?F:ua_bye(Ua1),
    receive
        {chappe_mrf_conf, Conf, {left, M1, departed}} -> ok
    after 5000 -> ct:fail(no_left)
    end,
    receive
        {'DOWN', MRef, process, _, _} -> ct:fail(room_closed)
    after 300 -> ok
    end,
    {_Ua2, _, B2, _} = call_in(Config),
    {ok, M2} = chappe_mrf_conf:join(Conf, B2, #{}),
    ?assertEqual(Mix1, mix_conf(Conf, M2)),
    ok = chappe_mrf_conf:stop(Conf),
    receive
        {'DOWN', MRef, process, _, _} -> ok
    after 5000 -> ct:fail(room_not_closed)
    end.

%% A caller not answered yet joins straight into the room: its INVITE
%% gets the 200 from the mixer through rtpengine, with no loopback B leg
%% first, and it leaves when it hangs up.
native_join_unanswered(Config) ->
    {ok, Conf} = chappe_mrf:conference(<<"room4">>, #{}),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test !
            {join,
                chappe_mrf_conf:join(Conf, {call, Req, Res}, #{name => <<"u">>})}
    end),
    Ua = ?F:ua_call(?config(ep, Config), #{}),
    {ok, 200} = ua_final(Ua),
    {ok, M} =
        receive
            {join, R} -> R
        after 10000 -> ct:fail(no_join)
        end,
    receive
        {chappe_mrf_conf, Conf, {joined, M, #{name := <<"u">>}}} -> ok
    after 2000 -> ct:fail(no_joined)
    end,
    ?assertEqual(1, length(chappe_mrf_conf:members(Conf))),
    ?F:ua_bye(Ua),
    receive
        {chappe_mrf_conf, Conf, {left, M, departed}} -> ok
    after 5000 -> ct:fail(no_left)
    end,
    ok = chappe_mrf_conf:stop(Conf).

mix_local(Conf, Member) ->
    Members = element(9, sys:get_state(Conf)),
    #{session := S} = maps:get(Member, Members),
    #{local := Local} = chappe_sip_media:info(S),
    Local.

mix_conf(Conf, Member) ->
    Members = element(9, sys:get_state(Conf)),
    #{session := S} = maps:get(Member, Members),
    #{conf := Mix} = chappe_sip_media:info(S),
    Mix.

%% A member talking reaches the notify process (the mixer's talker
%% detection, the caller's RTP straight to the mixer leg here).
native_talking(Config) ->
    ivr(Config),
    {ok, Conf} = chappe_mrf:conference(<<"room3">>, #{}),
    {Ua1, _, B1, _} = call_in(Config),
    {ok, M1} = chappe_mrf_conf:join(Conf, B1, #{}),
    {_Ua2, _, B2, _} = call_in(Config),
    {ok, _M2} = chappe_mrf_conf:join(Conf, B2, #{}),
    %% the fake rtpengine leaves the caller's media where it was: send
    %% to the mixer leg itself
    ?F:ua_rtp(Ua1, mix_local(Conf, M1), 1500),
    receive
        {chappe_mrf_conf, Conf, {talking, M1, true}} -> ok
    after 5000 -> ct:fail(no_talking)
    end.

%% An fs room: the endpoint enters the PIN (play_collect), runs the
%% conference application, and its member id comes from add-member; mute
%% and kick are conference api commands.
%% req: MRF-08 MRF-09 MRF-10
fs_conference_pin(Config) ->
    {ok, Conf} = chappe_mrf:conference(<<"fsroom">>, #{
        backend => fs, node => fs1
    }),
    {ok, Ep} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    fs_set_digits(Config, <<"1234">>),
    {ok, Id} = chappe_mrf_conf:join(Conf, Ep, #{
        pin => <<"1234">>, moderator => true
    }),
    ?assert(is_binary(Id)),
    _ = fs_cmd(<<"execute-app-name: play_and_get_digits">>),
    {fake_fs, _, _, {cmd, Join}} = fs_cmd(<<"execute-app-name: conference">>),
    ?assert(has(Join, <<"fsroom@default+flags{moderator}">>)),
    ok = chappe_mrf_conf:mute(Conf, Id),
    _ = fs_cmd(<<"api conference fsroom mute ", Id/binary>>),
    ok = chappe_mrf_conf:lock(Conf),
    _ = fs_cmd(<<"api conference fsroom lock">>),
    ?assertEqual({error, locked}, chappe_mrf_conf:join(Conf, Ep, #{})),
    ok = chappe_mrf_conf:play(Conf, <<"/media/beep.wav">>),
    _ = fs_cmd(<<"api conference fsroom play /media/beep.wav">>),
    ok = chappe_mrf_conf:kick(Conf, Id),
    _ = fs_cmd(<<"api conference fsroom kick ", Id/binary>>),
    receive
        {chappe_mrf_conf, Conf, {left, Id, kicked}} -> ok
    after 2000 -> ct:fail(no_left)
    end,
    ?assertMatch(
        {error, {unsupported, fs}}, chappe_mrf_conf:relate(Conf, Id, Id, hear)
    ),
    chappe_mrf:destroy(Ep).

%% Room flags go on the joining channel, max_members refuses the next
%% join, recording is conference api commands, and the members' mute,
%% digits and prompts come back as events (room-wide ones from the
%% node's events).
fs_conference_room(Config) ->
    {ok, Conf} = chappe_mrf:conference(<<"fsroom3">>, #{
        backend => fs,
        node => fs1,
        max_members => 1,
        room_flags => [<<"wait-mod">>, <<"audio-always">>]
    }),
    {ok, Ep} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    {ok, Id} = chappe_mrf_conf:join(Conf, Ep, #{}),
    _ = fs_cmd(<<"execute-app-arg: conference_flags=wait-mod|audio-always">>),
    _ = fs_cmd(<<"execute-app-name: conference">>),
    {ok, Ep2} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    ?assertEqual({error, full}, chappe_mrf_conf:join(Conf, Ep2, #{})),
    ok = chappe_mrf:destroy(Ep2),
    ok = chappe_mrf_conf:record(Conf, <<"/media/room 3.wav">>),
    _ = fs_cmd(
        <<"api conference fsroom3 recording start '/media/room 3.wav'">>
    ),
    ok = chappe_mrf_conf:stop_record(Conf),
    _ = fs_cmd(<<"api conference fsroom3 recording stop all">>),
    ?assertEqual(
        {error, {bad_option, path}}, chappe_mrf_conf:record(Conf, <<"a\nb">>)
    ),
    Fs = ?config(fs, Config),
    Maint = fun(Action, Extra) ->
        ?F:fs_event(Fs, <<"CUSTOM">>, [
            {<<"Event-Subclass">>, <<"conference::maintenance">>},
            {<<"Conference-Name">>, <<"fsroom3">>},
            {<<"Action">>, Action},
            {<<"Member-ID">>, Id}
            | Extra
        ])
    end,
    Maint(<<"mute-member">>, []),
    conf_event(Conf, {muted, Id, true}),
    ?assertMatch([#{mute := true}], chappe_mrf_conf:members(Conf)),
    Maint(<<"play-file-member-done">>, [{<<"File">>, <<"/media/hi.wav">>}]),
    conf_event(Conf, {play_done, Id, <<"/media/hi.wav">>}),
    ?F:fs_dtmf(Fs, <<"7">>),
    conf_event(Conf, {dtmf, Id, <<"7">>}),
    Conf !
        {chappe_esl_node, fs1,
            {event, #{
                body => <<>>,
                headers => #{
                    <<"Event-Name">> => <<"CUSTOM">>,
                    <<"Event-Subclass">> => <<"conference::maintenance">>,
                    <<"Conference-Name">> => <<"fsroom3">>,
                    <<"Action">> => <<"play-file-done">>,
                    <<"File">> => <<"/media/all.wav">>
                }
            }}},
    conf_event(Conf, {play_done, <<"/media/all.wav">>}),
    {ok, Native} = chappe_mrf:conference(<<"nat3">>, #{}),
    %% native: the target is a recording server's URI, not a path
    ?assertMatch({error, _}, chappe_mrf_conf:record(Native, <<"/x.wav">>)),
    ?assertEqual(ok, chappe_mrf_conf:stop_record(Native)),
    ok = chappe_mrf:destroy(Ep).

%% transfer/3 between two fs rooms of one node: mod_conference moves the
%% channel; the member leaves one with reason transferred and joins the
%% other under its new id. Mixed backends and unknown members are refused.
fs_conference_transfer(Config) ->
    {ok, A} = chappe_mrf:conference(<<"fsa">>, #{backend => fs, node => fs1}),
    {ok, B} = chappe_mrf:conference(<<"fsb">>, #{backend => fs, node => fs1}),
    ok = chappe_mrf_conf:events(B, self()),
    {ok, Ep} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    {ok, Id} = chappe_mrf_conf:join(A, Ep, #{name => <<"ann">>}),
    {ok, NewId} = chappe_mrf_conf:transfer(A, Id, B),
    _ = fs_cmd(<<"api conference fsa transfer fsb ", Id/binary>>),
    conf_event(A, {left, Id, transferred}),
    receive
        {chappe_mrf_conf, B, {joined, NewId, #{name := <<"ann">>}}} -> ok
    after 2000 -> ct:fail(no_joined)
    end,
    ?assertEqual([], chappe_mrf_conf:members(A)),
    ?assertMatch([#{id := NewId}], chappe_mrf_conf:members(B)),
    {ok, N} = chappe_mrf:conference(<<"nat4">>, #{}),
    ?assertEqual(
        {error, backend_mismatch}, chappe_mrf_conf:transfer(B, NewId, N)
    ),
    ?assertEqual(
        {error, not_member}, chappe_mrf_conf:transfer(A, <<"nobody">>, B)
    ),
    ?assertEqual(
        {error, same_conference}, chappe_mrf_conf:transfer(B, NewId, B)
    ),
    ok = chappe_mrf:destroy(Ep).

%% The process moving an fs member dies before the other room adopted
%% it: the room watches it, so the member is not left marked forever
%% (an app's endpoint is the room's member again).
fs_mover_dies(Config) ->
    {ok, A} = chappe_mrf:conference(<<"fsmover">>, #{backend => fs, node => fs1}),
    {ok, Ep} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    {ok, Id} = chappe_mrf_conf:join(A, Ep, #{}),
    Self = self(),
    Mover = spawn(fun() ->
        Self ! {marked, gen_server:call(A, {transfer, out, Id})},
        receive
            stop -> ok
        end
    end),
    receive
        {marked, {ok, {fs, Ep, _, _}}} -> ok
    after 5000 -> ct:fail(no_mark)
    end,
    exit(Mover, kill),
    ok = unmarked(A, Id, 50),
    ok = chappe_mrf:destroy(Ep).

unmarked(_A, Id, 0) ->
    ct:fail({still_marked, Id});
unmarked(A, Id, N) ->
    case maps:get(Id, element(9, sys:get_state(A)), #{}) of
        #{transfer := true} ->
            timer:sleep(100),
            unmarked(A, Id, N - 1);
        _ ->
            ok
    end.

%% transfer/3 between two native rooms: the member's call is re-anchored
%% to the other mixer without a re-INVITE to the caller.
native_conference_transfer(Config) ->
    ivr(Config),
    {ok, A} = chappe_mrf:conference(<<"nata">>, #{}),
    {ok, B} = chappe_mrf:conference(<<"natb">>, #{}),
    ok = chappe_mrf_conf:events(B, self()),
    {Ua, _Ep, B2b, _Owner} = call_in(Config),
    {ok, Id} = chappe_mrf_conf:join(A, B2b, #{name => <<"bob">>}),
    {ok, NewId} = chappe_mrf_conf:transfer(A, Id, B),
    conf_event(A, {left, Id, transferred}),
    receive
        {chappe_mrf_conf, B, {joined, NewId, #{name := <<"bob">>}}} -> ok
    after 2000 -> ct:fail(no_joined)
    end,
    no_ua_event(Ua, reinvite, 200),
    ok = chappe_mrf_conf:mute(B, NewId),
    conf_event(B, {muted, NewId, true}),
    ?F:ua_bye(Ua).

conf_event(Conf, Event) ->
    receive
        {chappe_mrf_conf, Conf, Event} -> ok
    after 3000 -> ct:fail({no_conf_event, Event})
    end.

%% A caller joined from its call: an endpoint is made on the room's node
%% and the caller bridged into it; a wrong PIN keeps it out.
%% req: MRF-10
fs_conference_bad_pin(Config) ->
    ivr(Config),
    {ok, Conf} = chappe_mrf:conference(<<"fsroom2">>, #{
        backend => fs, node => fs1
    }),
    {Ua, _Ep, B2b, _Owner} = call_in(Config),
    fs_set_digits(Config, <<"0000">>),
    meck_targets(Config),
    ?assertEqual(
        {error, bad_pin},
        chappe_mrf_conf:join(Conf, B2b, #{pin => <<"1234">>, pin_tries => 2})
    ),
    _ = ua_event(Ua, bye).

%% create_endpoint(#{node => fs1}) needs fs1's sip_uri: give the node
%% registry a fake fs1
meck_targets(Config) ->
    {_Esl, Port} = ?F:esl_start(),
    ok = chappe_esl:node_add(fs1, #{
        host => "127.0.0.1",
        port => Port,
        sip_uri => fs_uri(Config),
        heartbeat_interval_ms => 60000,
        probe_interval_ms => 60000
    }).

fs_set_digits(Config, Digits) ->
    {Pid, _} = ?config(fs, Config),
    Pid ! {set_digits, Digits}.

%% focus => true: a SUBSCRIBE to the conference gets its state.
conference_focus(Config) ->
    ok = chappe_sip:event_package(
        <<"conference">>, fun chappe_mrf:focus_subscribe/2
    ),
    {ok, Conf} = chappe_mrf:conference(<<"focusroom">>, #{focus => true}),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    ?assert(has(Entity, <<"focusroom@">>)),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    {ok, P} = inet:port(Sock),
    Pb = integer_to_binary(P),
    Sub = iolist_to_binary([
        <<"SUBSCRIBE ">>,
        Entity,
        <<" SIP/2.0\r\n">>,
        <<"Via: SIP/2.0/UDP 127.0.0.1:", Pb/binary,
            ";rport;branch=z9hG4bKsub1\r\n">>,
        <<"Max-Forwards: 70\r\nFrom: <sip:w@127.0.0.1>;tag=w1\r\n">>,
        <<"To: <", Entity/binary,
            ">\r\nCall-ID: sub-1\r\nCSeq: 1 SUBSCRIBE\r\n">>,
        <<"Contact: <sip:w@127.0.0.1:", Pb/binary,
            ">\r\nEvent: conference\r\n">>,
        <<"Accept: application/conference-info+xml\r\nExpires: 60\r\n">>,
        <<"Content-Length: 0\r\n\r\n">>
    ]),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, ?config(ep, Config), Sub),
    ?assert(wait_udp(Sock, <<"SIP/2.0 200">>)),
    ?assert(wait_udp(Sock, <<"conference-info">>)),
    gen_udp:close(Sock).

wait_udp(Sock, Part) ->
    receive
        {udp, Sock, _, Src, Bin} ->
            _ =
                case Bin of
                    <<"NOTIFY ", _/binary>> ->
                        gen_udp:send(Sock, {127, 0, 0, 1}, Src, ok_for(Bin));
                    _ ->
                        ok
                end,
            has(Bin, Part) orelse wait_udp(Sock, Part)
    after 5000 -> false
    end.

ok_for(Req) ->
    {ok, M} = chappe_sip_msg:parse(Req),
    iolist_to_binary([
        <<"SIP/2.0 200 OK\r\n">>,
        [
            [<<"Via: ">>, V, <<"\r\n">>]
         || V <- chappe_sip_msg:get_all(<<"via">>, M)
        ],
        <<"From: ">>,
        chappe_sip_msg:get(<<"from">>, M),
        <<"\r\n">>,
        <<"To: ">>,
        chappe_sip_msg:get(<<"to">>, M),
        <<"\r\n">>,
        <<"Call-ID: ">>,
        chappe_sip_msg:call_id(M),
        <<"\r\n">>,
        <<"CSeq: ">>,
        chappe_sip_msg:get(<<"cseq">>, M),
        <<"\r\n">>,
        <<"Content-Length: 0\r\n\r\n">>
    ]).

%% ---- edges ----

uri_of(Port) ->
    <<"sip:127.0.0.1:", (integer_to_binary(Port))/binary>>.

%% A node whose dialplan never hands the call to the socket: the caller
%% is hung up and connect_caller/3 says why; create_endpoint/1 the same.
attach_timeout(Config) ->
    Silent = ?F:fs_start(<<"silent">>, #{
        esl_port => ?config(lp, Config), no_socket => true
    }),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test !
            {result,
                chappe_mrf:connect_caller(Req, Res, #{
                    targets => [{silent, uri_of(?F:fs_port(Silent))}],
                    attach_timeout => 500
                })}
    end),
    Ua = ?F:ua_call(?config(ep, Config), #{}),
    {ok, 200} = ua_final(Ua),
    receive
        {result, {error, timeout}} -> ok
    after 5000 -> ct:fail(no_result)
    end,
    _ = ua_event(Ua, bye),
    ?assertEqual(
        {error, timeout},
        chappe_mrf:create_endpoint(#{
            targets => [{silent, uri_of(?F:fs_port(Silent))}],
            attach_timeout => 500
        })
    ),
    ?F:fs_stop(Silent).

%% The first node does not answer: the call and create_endpoint/1 move
%% to the next one, and the endpoint knows which node took it.
failover(Config) ->
    {_, DeadPort} = ?F:refuser_start(503),
    Dead = uri_of(DeadPort),
    Targets = [{dead, Dead}, {fs1, fs_uri(Config)}],
    ivr(Config, #{targets => Targets}),
    {Ua, Ep, _, Owner} = call_in(Config),
    ?assertEqual({ok, fs1}, chappe_mrf:node(Ep)),
    {ok, Ep2} = chappe_mrf:create_endpoint(#{
        targets => Targets, timeout => 2000
    }),
    ?assertEqual({ok, fs1}, chappe_mrf:node(Ep2)),
    ?assertMatch(
        {error, _},
        chappe_mrf:create_endpoint(#{targets => [{dead, Dead}], timeout => 1000})
    ),
    chappe_mrf:destroy(Ep2),
    ?F:ua_bye(Ua),
    Owner ! stop.

%% The callee fails: connect_caller/3 returns the error, the endpoint goes.
connect_failure(Config) ->
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test !
            {result,
                chappe_mrf:connect_caller(Req, Res, #{
                    targets => [
                        {dead, uri_of(element(2, ?F:refuser_start(486)))}
                    ]
                })}
    end),
    Ua = ?F:ua_call(?config(ep, Config), #{}),
    {ok, 486} = ua_final(Ua),
    receive
        {result, {error, _}} -> ok
    after 10000 -> ct:fail(no_result)
    end.

%% Errors of the endpoint commands: a bridge on a direct call keeps the
%% endpoint's dialog, an endpoint of connect_caller has no dialog of its
%% own, and a destroyed endpoint answers gone.
%% req: MRF-06
endpoint_errors(Config) ->
    ivr(Config, #{media => direct}),
    {Ua, Ep1, B2b, Owner} = call_in(Config),
    {ok, Ep2} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    ?assertEqual({error, not_anchored}, chappe_mrf:bridge(B2b, Ep2)),
    ?assertMatch(
        #{bridged := false, dialog := D} when D =/= undefined,
        chappe_mrf:info(Ep2)
    ),
    ?assertEqual(
        {error, no_dialog}, chappe_mrf:modify(Ep1, chappe_mrf:inactive_sdp())
    ),
    ?assertEqual({error, no_dialog}, chappe_mrf:bridge(B2b, Ep1)),
    chappe_mrf:destroy(Ep2),
    ?assertEqual({error, gone}, chappe_mrf:uuid(Ep2)),
    ?assertEqual({error, gone}, chappe_mrf:node(Ep2)),
    ?assertEqual({error, gone}, chappe_mrf:modify(Ep2, <<"v=0">>)),
    ?assertEqual(
        {error, gone}, chappe_mrf:play(Ep2, [<<"/a.wav">>, <<"/b.wav">>])
    ),
    ?F:ua_bye(Ua),
    Owner ! stop.

%% The endpoint process on a bare socket: answer off, events to watchers,
%% a second attach refused, the hangup, then the linger.
endpoint_socket(Config) ->
    Id = <<"sock-1">>,
    {ok, Ep} = chappe_mrf_endpoint:start(#{
        id => Id, answer => false, linger => 200
    }),
    ?assertMatch(
        {error, {already_registered, _}}, chappe_mrf_endpoint:start(#{id => Id})
    ),
    ?assertEqual({error, timeout}, chappe_mrf_endpoint:await(Ep, 100)),
    Sock = ?F:socket_start(
        ?config(lp, Config), [{<<"variable_sip_h_X-Chappe-Call">>, Id}], ok
    ),
    {ok, <<"sock-uuid">>} = chappe_mrf_endpoint:await(Ep, 5000),
    ?assertMatch(#{node := undefined, state := ready}, chappe_mrf:info(Ep)),
    Watcher = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    ok = chappe_mrf_endpoint:watch(Ep, self()),
    ok = chappe_mrf_endpoint:watch(Ep, self()),
    ok = chappe_mrf_endpoint:watch(Ep, Watcher),
    exit(Watcher, kill),
    ?assertEqual(
        {error, attached},
        chappe_mrf_endpoint:attach(Ep, self(), #{headers => #{}})
    ),
    ?assertEqual({error, no_dialog}, chappe_mrf_endpoint:handed(Ep)),
    ok = ?F:socket_event(Sock, <<"CUSTOM">>, [
        {<<"Event-Subclass">>, <<"x::y">>}
    ]),
    receive
        {chappe_mrf_endpoint, Ep, {event, _}} -> ok
    after 2000 -> ct:fail(no_event)
    end,
    ok = ?F:socket_event(Sock, <<"CHANNEL_EXECUTE_COMPLETE">>, [
        {<<"Application">>, <<"playback">>},
        {<<"Application-UUID">>, <<"nobody">>}
    ]),
    receive
        {chappe_mrf_endpoint, Ep, {complete, <<"playback">>, _}} -> ok
    after 2000 -> ct:fail(no_complete)
    end,
    ok = ?F:socket_event(Sock, <<"HEARTBEAT">>, []),
    ok = ?F:socket_event(Sock, <<"CHANNEL_HANGUP">>, [
        {<<"Hangup-Cause">>, <<"USER_BUSY">>}
    ]),
    receive
        {chappe_mrf, Ep, {hangup, <<"USER_BUSY">>}} -> ok
    after 2000 -> ct:fail(no_hangup)
    end,
    ?assertEqual({error, hangup}, chappe_mrf_endpoint:await(Ep, 1000)),
    ?assertEqual({error, hangup}, chappe_mrf:play(Ep, <<"/a.wav">>)),
    MRef = monitor(process, Ep),
    receive
        {'DOWN', MRef, process, Ep, _} -> ok
    after 3000 -> ct:fail(no_linger_end)
    end,
    ?F:socket_stop(Sock).

%% The socket closes under a live endpoint; a channel without the header
%% is refused; an answer refused by the node ends the endpoint.
%% req: MRF-02
endpoint_socket_errors(Config) ->
    {ok, Ep} = chappe_mrf_endpoint:start(#{id => <<"sock-2">>, answer => false}),
    Sock = ?F:socket_start(
        ?config(lp, Config),
        [{<<"variable_sip_h_X-Chappe-Call">>, <<"sock-2">>}],
        ok
    ),
    {ok, _} = chappe_mrf_endpoint:await(Ep, 5000),
    ?F:socket_stop(Sock),
    receive
        {chappe_mrf, Ep, {hangup, <<"CONNECTION_CLOSED">>}} -> ok
    after 3000 -> ct:fail(no_closed)
    end,
    ok = chappe_mrf:destroy(Ep),
    {ok, Ep3} = chappe_mrf_endpoint:start(#{id => <<"sock-3">>}),
    Sock3 = ?F:socket_start(
        ?config(lp, Config),
        [{<<"variable_sip_h_X-Chappe-Call">>, <<"sock-3">>}],
        err
    ),
    receive
        {chappe_mrf, Ep3, {hangup, _}} -> ok
    after 3000 -> ct:fail(no_answer_error)
    end,
    ?F:socket_stop(Sock3),
    Anon = ?F:socket_start(?config(lp, Config), [], ok),
    timer:sleep(300),
    ?F:socket_stop(Anon),
    %% the owner dies before any socket
    Owner = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    {ok, Ep4} = chappe_mrf_endpoint:start(#{id => <<"sock-4">>, owner => Owner}),
    M4 = monitor(process, Ep4),
    exit(Owner, kill),
    receive
        {'DOWN', M4, process, Ep4, _} -> ok
    after 3000 -> ct:fail(no_owner_stop)
    end.

%% The endpoint's own dialog ends from our side: the node gets the BYE
%% and the endpoint forgets the dialog.
endpoint_dialog_ends(Config) ->
    {ok, Ep} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    #{dialog := D} = chappe_mrf:info(Ep),
    ok = chappe_mrf_lib:destroy_dialog(D),
    _ = fs_what(bye),
    receive
        {chappe_mrf, Ep, {hangup, _}} -> ok
    after 3000 -> ct:fail(no_hangup)
    end,
    ?assertMatch(#{dialog := undefined}, chappe_mrf:info(Ep)),
    ok = chappe_mrf_lib:destroy_dialog(D).

%% Setup edges: start/1 without a listener, the listener twice, and the
%% app taking esl_port from its env.
setup_edges(Config) ->
    ok = chappe_mrf:start(#{}),
    ok = chappe_mrf:listen(?config(lp, Config)),
    ok = chappe_mrf:stop_listener(),
    ok = chappe_mrf:stop_listener(),
    Port = ?F:pick(),
    ok = application:stop(chappe_mrf),
    ok = application:set_env(chappe_mrf, esl_port, Port),
    ok = application:start(chappe_mrf),
    {ok, T} = gen_tcp:connect({127, 0, 0, 1}, Port, []),
    gen_tcp:close(T),
    ok = application:unset_env(chappe_mrf, esl_port),
    ok = application:stop(chappe_mrf),
    ok = application:start(chappe_mrf),
    ok = chappe_mrf:start(#{esl_port => ?config(lp, Config)}).

%% esl_ip and esl_allow reach the listener, from start/1 and from the app
%% env: a peer outside the allow list is closed and counted.
listener_ip_allow(Config) ->
    ok = chappe_mrf:stop_listener(),
    Port = ?F:pick(),
    Opts = #{
        esl_port => Port,
        esl_ip => {127, 0, 0, 1},
        esl_allow => [<<"192.0.2.0/24">>]
    },
    ?assertEqual(
        {error, {bad_option, allow}},
        chappe_mrf:start(Opts#{esl_allow => [nope]})
    ),
    try
        ok = chappe_mrf:start(Opts),
        ?assertMatch(#{ip := {127, 0, 0, 1}}, chappe_esl:listener_stats(Port)),
        {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port, [
            binary, {active, false}
        ]),
        ?assertEqual({error, closed}, gen_tcp:recv(S, 0, 5000)),
        ?assertMatch(#{refused := 1}, chappe_esl:listener_stats(Port)),
        ok = chappe_mrf:stop_listener(),
        ok = application:stop(chappe_mrf),
        ok = application:set_env(chappe_mrf, esl_port, Port),
        ok = application:set_env(chappe_mrf, esl_allow, ["192.0.2.0/24"]),
        ok = application:start(chappe_mrf),
        {ok, S2} = gen_tcp:connect({127, 0, 0, 1}, Port, [
            binary, {active, false}
        ]),
        ?assertEqual({error, closed}, gen_tcp:recv(S2, 0, 5000))
    after
        _ = application:unset_env(chappe_mrf, esl_port),
        _ = application:unset_env(chappe_mrf, esl_allow),
        _ = application:stop(chappe_mrf),
        ok = application:start(chappe_mrf),
        ok = chappe_mrf:start(#{esl_port => ?config(lp, Config)})
    end.

%% A listener already running on the port with other options is not
%% silently kept: start/1 returns an error naming the running options.
%% The same options again are fine.
listener_options_differ(Config) ->
    Port = ?F:pick(),
    try
        ok = application:stop(chappe_mrf),
        ok = application:set_env(chappe_mrf, esl_port, Port),
        ok = application:start(chappe_mrf),
        Allow = [<<"192.0.2.0/24">>],
        ?assertEqual(
            {error, {listener_running, #{}}},
            chappe_mrf:start(#{esl_port => Port, esl_allow => Allow})
        ),
        ?assertMatch(#{refused := 0}, chappe_esl:listener_stats(Port)),
        ok = chappe_mrf:start(#{esl_port => Port}),
        ok = chappe_mrf:stop_listener(),
        ok = chappe_mrf:start(#{esl_port => Port, esl_allow => Allow}),
        ok = chappe_mrf:start(#{esl_port => Port, esl_allow => Allow}),
        ?assertEqual(
            {error, {listener_running, #{allow => Allow}}},
            chappe_mrf:start(#{esl_port => Port})
        )
    after
        _ = chappe_mrf:stop_listener(),
        _ = application:unset_env(chappe_mrf, esl_port),
        _ = application:stop(chappe_mrf),
        ok = application:start(chappe_mrf),
        ok = chappe_mrf:start(#{esl_port => ?config(lp, Config)})
    end.

%% The registry refuses a key another live process holds (its own again
%% is ok) and a put of no pid, and ignores what it does not know.
registry_edges(_Config) ->
    Key = {test, make_ref()},
    ok = chappe_mrf_registry:put(Key, self()),
    ?assertEqual(ok, chappe_mrf_registry:put(Key, self())),
    Other = idle(),
    ?assertEqual({error, exists}, chappe_mrf_registry:put(Key, Other)),
    Other ! stop,
    ?assertError(function_clause, chappe_mrf_registry:put(Key, not_a_pid)),
    ok = chappe_mrf_registry:delete(Key),
    ?assertEqual(error, chappe_mrf_registry:lookup(Key)),
    ?assertEqual(
        {error, unknown_call}, gen_server:call(chappe_mrf_registry, junk)
    ),
    gen_server:cast(chappe_mrf_registry, junk),
    chappe_mrf_registry ! junk,
    chappe_mrf_registry ! {'DOWN', make_ref(), process, self(), x},
    ?assert(is_process_alive(whereis(chappe_mrf_registry))).

%% The registry's table outlives its process: killed, the registry
%% comes back with every entry and watches their processes again, so a
%% room keeps its name (one room per name) and an endpoint, a loopback
%% join and a member's dialog are still found; a room that ended while
%% the registry was down loses its name.
%% req: MRF-24
registry_restart(_Config) ->
    {ok, Conf} = chappe_mrf:conference(<<"regroom">>, #{}),
    [P1, P2, P3] = [
        spawn(fun() ->
            receive
                stop -> ok
            end
        end)
     || _ <- "abc"
    ],
    Ref = make_ref(),
    ok = chappe_mrf_registry:put({call, <<"regcall">>}, P1),
    ok = chappe_mrf_registry:put({loop, <<"regloop">>}, P2),
    ok = chappe_mrf_registry:put({a_dialog, Ref, dialog}, P3),
    ?FAULTS:restart_registry(),
    ?assertEqual({ok, Conf}, chappe_mrf:conference(<<"regroom">>, #{})),
    ?assertEqual({ok, P1}, chappe_mrf_registry:lookup({call, <<"regcall">>})),
    ?assertEqual({ok, P2}, chappe_mrf_registry:lookup({loop, <<"regloop">>})),
    ?assertEqual(
        [{{a_dialog, Ref, dialog}, P3}],
        chappe_mrf_registry:select({a_dialog, Ref, '_'})
    ),
    ?assertEqual(
        {error, exists}, chappe_mrf_registry:put({call, <<"regcall">>}, self())
    ),
    %% the new registry watches them: an entry goes with its process
    exit(P1, kill),
    until(fun() ->
        chappe_mrf_registry:lookup({call, <<"regcall">>}) =:= error
    end),
    %% a room that ends while the registry is down
    Reg = whereis(chappe_mrf_registry),
    ok = sys:suspend(Reg),
    ok = chappe_mrf_conf:stop(Conf),
    exit(Reg, kill),
    ?FAULTS:restart_registry(Reg),
    until(fun() ->
        chappe_mrf_registry:lookup({conf, <<"regroom">>}) =:= error
    end),
    {ok, Conf2} = chappe_mrf:conference(<<"regroom">>, #{}),
    ?assertNotEqual(Conf, Conf2),
    ?assertEqual({ok, Conf2}, chappe_mrf:conference(<<"regroom">>, #{})),
    P2 ! stop,
    P3 ! stop,
    until(fun() ->
        chappe_mrf_registry:select({a_dialog, Ref, '_'}) =:= [] andalso
            chappe_mrf_registry:lookup({loop, <<"regloop">>}) =:= error
    end),
    ok = chappe_mrf_conf:stop(Conf2).

%% A put or a delete the registry had queued when it was killed is made by
%% the next one: its caller never sees the restart. A put of a key its own
%% process holds already answers ok; a key another live process holds
%% stays taken.
%% req: MRF-24
registry_put_restart(_Config) ->
    P = idle(),
    ok = chappe_mrf_registry:put({call, <<"q-del">>}, P),
    Reg = whereis(chappe_mrf_registry),
    ok = sys:suspend(Reg),
    Put = registry_async(fun() ->
        chappe_mrf_registry:put({call, <<"q-put">>}, P)
    end),
    Del = registry_async(fun() ->
        chappe_mrf_registry:delete({call, <<"q-del">>})
    end),
    until(fun() ->
        element(2, process_info(Reg, message_queue_len)) >= 2
    end),
    exit(Reg, kill),
    ?FAULTS:restart_registry(Reg),
    ?assertEqual(ok, registry_result(Put)),
    ?assertEqual(ok, registry_result(Del)),
    ?assertEqual({ok, P}, chappe_mrf_registry:lookup({call, <<"q-put">>})),
    ?assertEqual(error, chappe_mrf_registry:lookup({call, <<"q-del">>})),
    ?assertEqual(ok, chappe_mrf_registry:put({call, <<"q-put">>}, P)),
    ?assertEqual(
        {error, exists}, chappe_mrf_registry:put({call, <<"q-put">>}, self())
    ),
    exit(P, kill),
    until(fun() ->
        chappe_mrf_registry:lookup({call, <<"q-put">>}) =:= error
    end).

%% A key whose process died before the registry saw it go is taken by
%% the next put: an entry a killed registry left behind, or one whose
%% 'DOWN' is still on its way, which then leaves the new entry alone.
%% req: MRF-24
registry_dead_entry(_Config) ->
    Dead = idle(),
    exit(Dead, kill),
    until(fun() -> not is_process_alive(Dead) end),
    %% as a registry killed before it saw Dead go leaves it
    true = ets:insert(chappe_mrf_registry, {{call, <<"left">>}, Dead}),
    P = idle(),
    ?assertEqual(ok, chappe_mrf_registry:put({call, <<"left">>}, P)),
    ?assertEqual({ok, P}, chappe_mrf_registry:lookup({call, <<"left">>})),
    %% Q's 'DOWN' reaches the registry after the put that takes its key
    Q = idle(),
    ok = chappe_mrf_registry:put({call, <<"late">>}, Q),
    Reg = whereis(chappe_mrf_registry),
    ok = sys:suspend(Reg),
    Put = registry_async(fun() ->
        chappe_mrf_registry:put({call, <<"late">>}, P)
    end),
    until(fun() ->
        element(2, process_info(Reg, message_queue_len)) >= 1
    end),
    exit(Q, kill),
    until(fun() -> not is_process_alive(Q) end),
    ok = sys:resume(Reg),
    ?assertEqual(ok, registry_result(Put)),
    _ = sys:get_state(Reg),
    ?assertEqual({ok, P}, chappe_mrf_registry:lookup({call, <<"late">>})),
    %% and P is watched for both
    exit(P, kill),
    until(fun() ->
        chappe_mrf_registry:lookup({call, <<"late">>}) =:= error andalso
            chappe_mrf_registry:lookup({call, <<"left">>}) =:= error
    end).

%% a process that waits for nothing
idle() ->
    spawn(fun() ->
        receive
            stop -> ok
        end
    end).

%% Fun() in a process of its own, its result or how it failed
registry_async(Fun) ->
    Test = self(),
    spawn(fun() ->
        R =
            try
                Fun()
            catch
                Class:Why -> {Class, Why}
            end,
        Test ! {registry, self(), R}
    end).

registry_result(Pid) ->
    receive
        {registry, Pid, R} -> R
    after 5000 -> ct:fail(registry_no_result)
    end.

%% Fun() holds within 5 s
until(Fun) ->
    ?assert(?FAULTS:eventually(Fun, 50)).

%% What a native room holds for its joins: whether one more may come in,
%% its joins under way, its mixer legs (chappe_mix:legs/1), the rtpengine
%% sessions of this node and its loopback tokens.
holdings(Conf) ->
    #{name := Name} = chappe_mrf_conf:info(Conf),
    S = sys:get_state(Conf),
    #{
        admission => chappe_mrf_conf_backend:admission(S),
        pending => map_size(element(10, S)),
        legs => ?FAULTS:mix_legs(<<"mrf-", Name/binary>>),
        rtpe => proplists:get_value(
            active, supervisor:count_children(chappe_rtpengine_session_sup)
        ),
        loops => [
            T
         || {{loop, T}, P} <- chappe_mrf_registry:select({loop, '_'}),
            P =:= Conf
        ]
    }.

%% the room is back to Base (its cleanups may be under way)
back_to(Conf, Base) ->
    _ = ?FAULTS:eventually(fun() -> holdings(Conf) =:= Base end, 30),
    ?assertEqual(Base, holdings(Conf)).

%% the next rtpengine offer
rtpe_offer() ->
    receive
        {rtpe_cmd, #{<<"command">> := <<"offer">>} = Cmd} -> Cmd
    after 5000 -> ct:fail(no_rtpe_offer)
    end.

%% join/3 in a process of its own: {join, Result} comes back
join_async(Conf, Target) ->
    Test = self(),
    spawn(fun() -> Test ! {join, chappe_mrf_conf:join(Conf, Target, #{})} end).

join_within(Ms) ->
    receive
        {join, R} -> R
    after Ms -> ct:fail(join_not_answered)
    end.

%% A loopback INVITE the room cannot answer (one asking a session timer
%% below the node's Min-SE: 422) fails the join at once: the joiner gets
%% {error, join_failed}, and the room gives its mixer leg, its token and
%% its join slot back.
%% req: MRF-25
native_loop_fails(Config) ->
    ivr(Config),
    Rtpe = ?config(rtpe, Config),
    {ok, Conf} = chappe_mrf:conference(<<"loopfail">>, #{max_members => 1}),
    {_Ua, _Ep, B2b, Owner} = call_in(Config),
    Base = holdings(Conf),
    _ = rtpe_offers(),
    %% the call's own loopback INVITE waits on rtpengine
    ok = ?F:rtpe_fail(Rtpe, #{<<"offer">> => hold}),
    _ = join_async(Conf, B2b),
    _ = rtpe_offer(),
    [Token] = maps:keys(element(10, sys:get_state(Conf))),
    Loop = ?F:ua_call(?config(ep, Config), #{
        ruri => chappe_mrf:loop_target(Token),
        headers => [
            {<<"Supported">>, <<"timer">>}, {<<"Session-Expires">>, <<"30">>}
        ]
    }),
    {ok, 422} = ua_final(Loop),
    ?assertEqual({error, join_failed}, join_within(2000)),
    ok = ?F:rtpe_fail(Rtpe, #{}),
    back_to(Conf, Base),
    Owner ! stop,
    ok = chappe_mrf_conf:stop(Conf).

%% The same for a caller joined from its INVITE: its loopback INVITE fails
%% while the caller's call to the mixer is set up, and the join fails with
%% {error, join_failed}, the caller is refused, and the room gives back
%% what it took.
%% req: MRF-25
native_call_loop_fails(Config) ->
    Rtpe = ?config(rtpe, Config),
    {ok, Conf} = chappe_mrf:conference(<<"callloopfail">>, #{
        max_members => 1
    }),
    Base = holdings(Conf),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test ! {join, chappe_mrf_conf:join(Conf, {call, Req, Res}, #{})}
    end),
    _ = rtpe_offers(),
    %% the caller's call to the mixer waits on rtpengine
    ok = ?F:rtpe_fail(Rtpe, #{<<"offer">> => hold}),
    Ua = ?F:ua_call(?config(ep, Config), #{}),
    _ = rtpe_offer(),
    [Token] = maps:keys(element(10, sys:get_state(Conf))),
    Loop = ?F:ua_call(?config(ep, Config), #{
        ruri => chappe_mrf:loop_target(Token),
        headers => [
            {<<"Supported">>, <<"timer">>}, {<<"Session-Expires">>, <<"30">>}
        ]
    }),
    {ok, 422} = ua_final(Loop),
    ok = ?F:rtpe_fail(Rtpe, #{}),
    ?assertEqual({error, join_failed}, join_within(10000)),
    {ok, St} = ua_final(Ua),
    ?assert(St >= 400),
    back_to(Conf, Base),
    ok = chappe_mrf_conf:stop(Conf).

%% An endpoint's join that fails at any step answers an error, gives the
%% room's mixer leg and rtpengine session back, and the room goes on: no
%% mixer, an rtpengine offer or answer refused, an answer the mixer cannot
%% use, a node that refuses the re-INVITE, an endpoint that does not
%% answer the room, and a dialog that dies under the re-INVITE. A failure
%% once the node took the room's media (its re-INVITE answered) hangs the
%% endpoint up, as that media is gone; before, the endpoint stays as it
%% was.
%% req: MRF-25
native_endpoint_fails(Config) ->
    Rtpe = ?config(rtpe, Config),
    {ok, Conf} = chappe_mrf:conference(<<"epfail">>, #{}),
    NewEp = fun() ->
        {ok, E} = chappe_mrf:create_endpoint(#{
            targets => [{fs1, fs_uri(Config)}]
        }),
        E
    end,
    Ep = NewEp(),
    %% no mixer at all (its first join: the room has no mixer room yet)
    ok = supervisor:terminate_child(chappe_sip_media_sup, chappe_sip_media_mix),
    ?assertMatch({error, _}, chappe_mrf_conf:join(Conf, Ep, #{})),
    {ok, _} = supervisor:restart_child(
        chappe_sip_media_sup, chappe_sip_media_mix
    ),
    ok = channel_after_failure(Ep, uuid_of(Ep), kept),
    Base = holdings(Conf),
    lists:foreach(
        fun({F, After}) ->
            E = NewEp(),
            ok = ?F:rtpe_fail(Rtpe, F),
            {ok, Uuid} = chappe_mrf:uuid(E),
            ?assertMatch({error, _}, chappe_mrf_conf:join(Conf, E, #{})),
            ok = ?F:rtpe_fail(Rtpe, #{}),
            ok = channel_after_failure(E, Uuid, After),
            back_to(Conf, Base),
            chappe_mrf:destroy(E)
        end,
        [
            {#{<<"offer">> => error}, kept},
            {#{<<"answer">> => error}, hung_up},
            {#{<<"answer">> => bad_sdp}, hung_up}
        ]
    ),
    %% a node that refuses the re-INVITE
    Picky = ?F:fs_start(<<"picky">>, #{
        esl_port => ?config(lp, Config), reject_reinvite => true
    }),
    {ok, EpP} = chappe_mrf:create_endpoint(#{
        targets => [{picky, uri_of(?F:fs_port(Picky))}]
    }),
    ?assertMatch({error, _}, chappe_mrf_conf:join(Conf, EpP, #{})),
    ok = channel_after_failure(EpP, uuid_of(EpP), kept),
    back_to(Conf, Base),
    chappe_mrf:destroy(EpP),
    ?F:fs_stop(Picky),
    %% the endpoint does not answer the room once its media is set
    #{dialog := D} = chappe_mrf:info(Ep),
    DPid = chappe_sip_dialog:pid(D),
    Queued = fun(Pid) ->
        fun() -> element(2, process_info(Pid, message_queue_len)) > 0 end
    end,
    Uuid = uuid_of(Ep),
    ok = sys:suspend(DPid),
    _ = join_async(Conf, Ep),
    until(Queued(DPid)),
    ok = sys:suspend(Ep),
    ok = sys:resume(DPid),
    ?assertMatch({error, _}, join_within(15000)),
    ok = channel_bye(Uuid),
    ok = sys:resume(Ep),
    until(fun() -> ep_gone(Ep) end),
    back_to(Conf, Base),
    %% its dialog dies under the re-INVITE
    Ep2 = NewEp(),
    #{dialog := D2} = chappe_mrf:info(Ep2),
    DPid2 = chappe_sip_dialog:pid(D2),
    ok = sys:suspend(DPid2),
    _ = join_async(Conf, Ep2),
    until(Queued(DPid2)),
    exit(DPid2, kill),
    ?assertMatch({error, _}, join_within(5000)),
    back_to(Conf, Base),
    ?assert(is_process_alive(Conf)),
    chappe_mrf:destroy(Ep2),
    ok = chappe_mrf_conf:stop(Conf).

%% after a failed join, the endpoint's channel is kept (no BYE, the
%% endpoint still there) or hung up (its node gets a BYE, the endpoint
%% goes)
channel_after_failure(Ep, Uuid, kept) ->
    receive
        {fake_fs, _, Uuid, {bye, _}} -> ct:fail({hung_up, Ep})
    after 300 -> ok
    end,
    ?assertMatch(#{bridged := false}, chappe_mrf:info(Ep)),
    ok;
channel_after_failure(Ep, Uuid, hung_up) ->
    ok = channel_bye(Uuid),
    until(fun() -> ep_gone(Ep) end),
    ok.

%% the endpoint's channel ended (it lingers a while, gone)
ep_gone(Ep) ->
    case chappe_mrf:info(Ep) of
        #{state := gone} -> true;
        {error, gone} -> true;
        _ -> false
    end.

uuid_of(Ep) ->
    {ok, Uuid} = chappe_mrf:uuid(Ep),
    Uuid.

%% the node of channel Uuid got a BYE
channel_bye(Uuid) ->
    receive
        {fake_fs, _, Uuid, {bye, _}} -> ok
    after 5000 -> ct:fail({no_bye, Uuid})
    end.

%% A join whose worker dies before it reports (the helper of a call's
%% join, or the INVITE's request worker of a caller joined from its
%% INVITE) fails, and the room counts it no more; a join that outlasts
%% join_timeout fails with {error, timeout}.
%% req: MRF-26
native_join_worker_dies(Config) ->
    ivr(Config),
    Rtpe = ?config(rtpe, Config),
    {ok, Conf} = chappe_mrf:conference(<<"wdies">>, #{max_members => 1}),
    {_Ua, _Ep, B2b, Owner} = call_in(Config),
    Base = holdings(Conf),
    _ = rtpe_offers(),
    ok = ?F:rtpe_fail(Rtpe, #{<<"offer">> => hold}),
    %% the helper of a call's join
    _ = join_async(Conf, B2b),
    _ = rtpe_offer(),
    [Helper] = ?FAULTS:join_helpers(),
    exit(Helper, kill),
    ?assertEqual({error, join_failed}, join_within(2000)),
    back_to(Conf, Base),
    %% the request worker of a caller joined from its INVITE
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test ! {worker, self()},
        chappe_mrf_conf:join(Conf, {call, Req, Res}, #{})
    end),
    _ = ?F:ua_call(?config(ep, Config), #{}),
    Worker =
        receive
            {worker, W} -> W
        after 5000 -> ct:fail(no_worker)
        end,
    _ = rtpe_offer(),
    ?assertEqual(1, map_size(element(10, sys:get_state(Conf)))),
    exit(Worker, kill),
    back_to(Conf, Base),
    %% a join that never ends
    {ok, Slow} = chappe_mrf:conference(<<"wslow">>, #{join_timeout => 300}),
    SlowBase = holdings(Slow),
    _ = join_async(Slow, B2b),
    ?assertEqual({error, timeout}, join_within(2000)),
    back_to(Slow, SlowBase),
    ok = ?F:rtpe_fail(Rtpe, #{}),
    Owner ! stop,
    ok = chappe_mrf_conf:stop(Slow),
    ok = chappe_mrf_conf:stop(Conf).

%% A join_timeout that is not a number of milliseconds from 1 to 95000 is
%% refused on either backend before any room runs.
%% req: MRF-26
join_timeout_refused(_Config) ->
    [
        ?assertEqual(
            {error, {bad_option, join_timeout}},
            chappe_mrf:conference(<<"badjt">>, #{join_timeout => Bad}),
            Bad
        )
     || Bad <- [0, -1, 95001, 1.5, infinity, <<"1000">>]
    ],
    ?assertEqual(
        {error, {bad_option, join_timeout}},
        chappe_mrf:conference(<<"badjt">>, #{
            backend => fs, node => fs1, join_timeout => 0
        })
    ),
    ?assertEqual(
        false, lists:keymember(<<"badjt">>, 1, chappe_mrf:conferences())
    ),
    {ok, Conf} = chappe_mrf:conference(<<"okjt">>, #{join_timeout => 95000}),
    ok = chappe_mrf_conf:stop(Conf).

%% A handle that is neither a call, an incoming call nor an endpoint is
%% refused in the caller, and the room counts no join for it.
%% req: MRF-25
native_join_bad_handle(_Config) ->
    {ok, Conf} = chappe_mrf:conference(<<"badh">>, #{max_members => 1}),
    Base = holdings(Conf),
    lists:foreach(
        fun(H) ->
            _ = join_async(Conf, H),
            ?assertEqual({error, badarg}, join_within(2000))
        end,
        [{1, 2}, {self()}, <<"ep">>, {a, b, c, d}]
    ),
    back_to(Conf, Base),
    ok = chappe_mrf_conf:stop(Conf).

%% SIP edges: a loopback INVITE nobody waits for gets 404, one whose
%% join is unknown 488; a SUBSCRIBE for an unknown room 404, for a room
%% without focus 489.
sip_edges(Config) ->
    %% the middleware runs in front of the app's INVITE handler
    ok = chappe_sip:invite(fun(_Req, Res) -> chappe_sip_res:send(Res, 480) end),
    Ua = ?F:ua_call(?config(ep, Config), #{
        ruri => <<"sip:mrf-mix-nobody@127.0.0.1">>
    }),
    {ok, 404} = ua_final(Ua),
    {ok, Conf} = chappe_mrf:conference(<<"edges">>, #{}),
    ok = chappe_mrf_registry:put({loop, <<"stale">>}, Conf),
    Ua2 = ?F:ua_call(?config(ep, Config), #{
        ruri => <<"sip:mrf-mix-stale@127.0.0.1">>
    }),
    {ok, 488} = ua_final(Ua2),
    ok = chappe_sip:event_package(
        <<"conference">>, fun chappe_mrf:focus_subscribe/2
    ),
    ?assertEqual(404, subscribe_status(Config, <<"sip:nowhere@127.0.0.1">>)),
    ?assertEqual(489, subscribe_status(Config, <<"sip:edges@127.0.0.1">>)).

subscribe_status(Config, Uri) ->
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    {ok, P} = inet:port(Sock),
    Pb = integer_to_binary(P),
    Sub = iolist_to_binary([
        <<"SUBSCRIBE ">>,
        Uri,
        <<" SIP/2.0\r\n">>,
        <<"Via: SIP/2.0/UDP 127.0.0.1:", Pb/binary, ";rport;branch=z9hG4bK",
            (integer_to_binary(P))/binary, "\r\n">>,
        <<"Max-Forwards: 70\r\nFrom: <sip:w@127.0.0.1>;tag=w1\r\n">>,
        <<"To: <", Uri/binary, ">\r\nCall-ID: sub-", Pb/binary,
            "\r\nCSeq: 1 SUBSCRIBE\r\n">>,
        <<"Contact: <sip:w@127.0.0.1:", Pb/binary,
            ">\r\nEvent: conference\r\n">>,
        <<"Content-Length: 0\r\n\r\n">>
    ]),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, ?config(ep, Config), Sub),
    Status = sub_final(Sock),
    gen_udp:close(Sock),
    Status.

sub_final(Sock) ->
    receive
        {udp, Sock, _, _, <<"SIP/2.0 1", _/binary>>} ->
            sub_final(Sock);
        {udp, Sock, _, _, <<"SIP/2.0 ", C:3/binary, _/binary>>} ->
            binary_to_integer(C)
    after 5000 -> timeout
    end.

%% Conference edges: the same name twice, the owner going, a listener
%% added and gone, unknown requests, a join that cannot replace the leg,
%% leave/2, a member prompt, and an fs room with no node.
conf_edges(Config) ->
    ivr(Config, #{media => direct}),
    Owner = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    {ok, Conf} = chappe_mrf:conference(<<"edges2">>, #{
        owner => Owner, entity => <<"sip:edges2@x">>, focus => true
    }),
    ?assertMatch(#{entity := <<"sip:edges2@x">>}, chappe_mrf_conf:info(Conf)),
    Listener = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    ok = chappe_mrf_conf:events(Conf, Listener),
    ok = chappe_mrf_conf:events(Conf, Listener),
    exit(Listener, kill),
    ?assertEqual({error, unknown_call}, gen_server:call(Conf, junk)),
    gen_server:cast(Conf, junk),
    Conf ! junk,
    {Ua, _Ep, B2b, IvrOwner} = call_in(Config),
    ?assertEqual({error, not_anchored}, chappe_mrf_conf:join(Conf, B2b, #{})),
    ?assertEqual(
        {error, not_member}, chappe_mrf_conf:play(Conf, <<"x">>, <<"/a.wav">>)
    ),
    ?assertEqual({error, not_member}, chappe_mrf_conf:leave(Conf, <<"x">>)),
    MRef = monitor(process, Conf),
    exit(Owner, kill),
    receive
        {'DOWN', MRef, process, Conf, _} -> ok
    after 3000 -> ct:fail(conf_not_stopped)
    end,
    ?assertEqual({error, noproc}, chappe_mrf_conf:info(Conf)),
    ?assertMatch(
        {error, _}, chappe_mrf:conference(<<"nonode">>, #{backend => fs})
    ),
    ?F:ua_bye(Ua),
    IvrOwner ! stop.

%% dial_codecs goes in the dial string of every party a REFER brings in:
%% anything but codec names joined by commas, or inherit, is refused on
%% either backend before the room is made.
dial_codecs_refused(_Config) ->
    [
        ?assertEqual(
            {error, {bad_option, dial_codecs}},
            chappe_mrf:conference(<<"badcodecs">>, #{dial_codecs => Bad}),
            Bad
        )
     || Bad <- [<<"PCMU]sofia/gateway/gw/1900">>, <<"PCMU,">>, "PCMU", pcmu]
    ],
    ?assertEqual(
        {error, {bad_option, dial_codecs}},
        chappe_mrf:conference(<<"badcodecs">>, #{
            backend => fs, node => fs1, dial_codecs => <<"PCMU}">>
        })
    ),
    ?assertEqual(
        false, lists:keymember(<<"badcodecs">>, 1, chappe_mrf:conferences())
    ).

%% A 16 kHz native room: a caller's offer toward the mixer asks rtpengine
%% for the room's format only (mask all, transcode L16/16000 and
%% telephone-event/16000), the mixer takes the L16 it gets in a 16 kHz
%% chappe_mix room, an endpoint's node is offered G.722 and G.711 in place
%% of the mixer's L16, and the app's own codec flags toward the mixer win,
%% key by key inside codec. An 8 kHz room asks for no transcode; a rate
%% is refused on fs and a rate other than 8000 or 16000 everywhere, and
%% asking a running room for another rate than its own is refused.
native_hd_room(Config) ->
    ivr(Config),
    ?assertEqual(
        {error, {bad_option, rate}},
        chappe_mrf:conference(<<"hdx">>, #{rate => 48000})
    ),
    ?assertEqual(
        {error, {unsupported, rate}},
        chappe_mrf:conference(<<"hdf">>, #{
            backend => fs, node => fs1, rate => 16000
        })
    ),
    %% refused before the room is made
    ?assertEqual(
        false, lists:keymember(<<"hdf">>, 1, chappe_mrf:conferences())
    ),
    {ok, Conf} = chappe_mrf:conference(<<"hd">>, #{rate => 16000}),
    ?assertMatch(#{rate := 16000}, chappe_mrf_conf:info(Conf)),
    %% the running room, at its rate or with none; another rate is refused
    ?assertEqual({ok, Conf}, chappe_mrf:conference(<<"hd">>, #{rate => 16000})),
    ?assertEqual({ok, Conf}, chappe_mrf:conference(<<"hd">>, #{})),
    ?assertEqual(
        {error, {rate_mismatch, 16000}},
        chappe_mrf:conference(<<"hd">>, #{rate => 8000})
    ),
    {Ua, _Ep, B2b, Owner} = call_in(Config),
    _ = rtpe_offers(),
    {ok, M} = chappe_mrf_conf:join(Conf, B2b, #{name => <<"hd">>}),
    [#{<<"codec">> := Codec} | _] = [
        O
     || #{<<"codec">> := _} = O <- rtpe_offers()
    ],
    ?assertEqual(
        #{
            <<"mask">> => [<<"all">>],
            <<"transcode">> => [<<"L16/16000/1">>, <<"telephone-event/16000">>]
        },
        Codec
    ),
    ?assertMatch([#{id := M}], chappe_mrf_conf:members(Conf)),
    %% an endpoint in it: the mixer's offer goes to its node as G.722 and
    %% G.711 with telephone-event/8000, and the answer comes back on the
    %% mixer's own L16 payload type
    {ok, Ep} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    _ = rtpe_offers(),
    {ok, MEp} = chappe_mrf_conf:join(Conf, Ep, #{name => <<"ep">>}),
    ?assertEqual(
        [
            #{
                <<"mask">> => [<<"all">>],
                <<"transcode">> => [
                    <<"G722">>,
                    <<"PCMU">>,
                    <<"PCMA">>,
                    <<"telephone-event/8000">>
                ]
            }
        ],
        [C || #{<<"codec">> := C} <- rtpe_offers()]
    ),
    ok = chappe_mrf_conf:kick(Conf, MEp),
    chappe_mrf:destroy(Ep),
    ok = chappe_mrf_conf:kick(Conf, M),
    _ = ua_event(Ua, bye),
    ok = chappe_mrf_conf:stop(Conf),
    Owner ! stop,
    %% the app's flags toward the mixer win over the room's, key by key
    %% inside codec: its transcode replaces the room's, the room's mask
    %% stays, and a codec key of its own is added
    {ok, Own} = chappe_mrf:conference(<<"hd-own">>, #{
        rate => 16000,
        anchor_params => #{
            b => #{
                codec => #{
                    transcode => [<<"L16/16000/1">>],
                    strip => [<<"CN">>]
                }
            }
        }
    }),
    {_Ua2, _, B2b2, Owner2} = call_in(Config),
    _ = rtpe_offers(),
    {ok, _} = chappe_mrf_conf:join(Own, B2b2, #{}),
    ?assertMatch(
        [
            #{
                <<"codec">> := #{
                    <<"mask">> := [<<"all">>],
                    <<"transcode">> := [<<"L16/16000/1">>],
                    <<"strip">> := [<<"CN">>]
                }
            }
            | _
        ],
        [O || #{<<"codec">> := _} = O <- rtpe_offers()]
    ),
    ok = chappe_mrf_conf:stop(Own),
    Owner2 ! stop,
    %% an 8 kHz room: G.711 through, no transcode asked
    {ok, Nb} = chappe_mrf:conference(<<"nb">>, #{}),
    ?assertMatch(#{rate := 8000}, chappe_mrf_conf:info(Nb)),
    ?assertEqual(
        {error, {rate_mismatch, 8000}},
        chappe_mrf:conference(<<"nb">>, #{rate => 16000})
    ),
    {_Ua3, _, B2b3, Owner3} = call_in(Config),
    _ = rtpe_offers(),
    {ok, _} = chappe_mrf_conf:join(Nb, B2b3, #{}),
    ?assertEqual([], [O || #{<<"codec">> := _} = O <- rtpe_offers()]),
    ok = chappe_mrf_conf:stop(Nb),
    Owner3 ! stop.

%% The rtpengine offers received so far.
rtpe_offers() ->
    receive
        {rtpe_cmd, #{<<"command">> := <<"offer">>} = Cmd} ->
            [Cmd | rtpe_offers()];
        {rtpe_cmd, _} ->
            rtpe_offers()
    after 300 -> []
    end.

%% An endpoint in a native room: re-INVITEd to the mixer through
%% rtpengine, muted and played to, and gone from the room when it hangs
%% up; one with no dialog of its own is refused.
native_endpoint(Config) ->
    ivr(Config),
    {ok, Conf} = chappe_mrf:conference(<<"nep">>, #{focus => true}),
    {ok, Ep} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    {ok, M} = chappe_mrf_conf:join(Conf, Ep, #{name => <<"ep">>, deaf => true}),
    ReInvite = fs_what(reinvite),
    ?assert(has(ReInvite, <<"a=rtpe-offer:mix-">>)),
    ok = chappe_mrf_conf:mute(Conf, M),
    ok = chappe_mrf_conf:play(Conf, M, <<"/media/beep.wav">>),
    _ = fs_cmd(<<"/media/beep.wav">>),
    ok = chappe_mrf_conf:kick(Conf, M),
    receive
        {chappe_mrf_conf, Conf, {left, M, kicked}} -> ok
    after 2000 -> ct:fail(no_left)
    end,
    {ok, M2} = chappe_mrf_conf:join(Conf, Ep, #{}),
    chappe_mrf:destroy(Ep),
    receive
        {chappe_mrf_conf, Conf, {left, M2, hangup}} -> ok
    after 3000 -> ct:fail(no_hangup_left)
    end,
    %% a node that refuses the re-INVITE, and an endpoint already gone
    Picky = ?F:fs_start(<<"picky">>, #{
        esl_port => ?config(lp, Config), reject_reinvite => true
    }),
    {ok, EpP} = chappe_mrf:create_endpoint(#{
        targets => [{picky, uri_of(?F:fs_port(Picky))}]
    }),
    ?assertMatch({error, _}, chappe_mrf_conf:join(Conf, EpP, #{})),
    chappe_mrf:destroy(EpP),
    ?assertEqual({error, gone}, chappe_mrf_conf:join(Conf, EpP, #{})),
    ?F:fs_stop(Picky),
    {Ua, Ep1, _B2b, Owner} = call_in(Config),
    ?assertEqual({error, no_dialog}, chappe_mrf_conf:join(Conf, Ep1, #{})),
    ok = chappe_mrf_conf:lock(Conf),
    ?assertEqual({error, locked}, chappe_mrf_conf:join(Conf, Ep1, #{})),
    ?F:ua_bye(Ua),
    Owner ! stop.

%% fs room edges: flags, talker events, an endpoint on another node, a
%% member that never shows up, one that hangs up first, unmute and
%% undeaf, unlock, and a member that hangs up in the room.
fs_conference_edges(Config) ->
    {ok, Conf} = chappe_mrf:conference(<<"fse">>, #{
        backend => fs, node => fs1, join_timeout => 500
    }),
    {ok, Ep} = chappe_mrf:create_endpoint(#{targets => [{fs1, fs_uri(Config)}]}),
    {ok, Id} = chappe_mrf_conf:join(Conf, Ep, #{
        mute => true, deaf => true, flags => [nomoh]
    }),
    {fake_fs, _, _, {cmd, Join}} = fs_cmd(<<"execute-app-name: conference">>),
    ?assert(has(Join, <<"+flags{mute|deaf|nomoh}">>)),
    Ev = fun(Action, Room) ->
        ?F:fs_event(?config(fs, Config), <<"CUSTOM">>, [
            {<<"Event-Subclass">>, <<"conference::maintenance">>},
            {<<"Action">>, Action},
            {<<"Conference-Name">>, Room},
            {<<"Member-ID">>, Id}
        ])
    end,
    Ev(<<"start-talking">>, <<"fse">>),
    receive
        {chappe_mrf_conf, Conf, {talking, Id, true}} -> ok
    after 2000 -> ct:fail(no_talking)
    end,
    Ev(<<"stop-talking">>, <<"fse">>),
    Ev(<<"volume-level">>, <<"fse">>),
    Ev(<<"start-talking">>, <<"other">>),
    ok = chappe_mrf_conf:unmute(Conf, Id),
    _ = fs_cmd(<<"api conference fse unmute ", Id/binary>>),
    ok = chappe_mrf_conf:undeaf(Conf, Id),
    ok = chappe_mrf_conf:deaf(Conf, Id),
    ok = chappe_mrf_conf:unlock(Conf),
    _ = fs_cmd(<<"api conference fse unlock">>),
    ok = chappe_mrf_conf:play(Conf, Id, <<"/media/x.wav">>),
    _ = fs_cmd(<<"api conference fse play /media/x.wav ", Id/binary>>),
    ok = chappe_mrf_conf:leave(Conf, Id),
    receive
        {chappe_mrf_conf, Conf, {left, Id, departed}} -> ok
    after 2000 -> ct:fail(no_left)
    end,
    {ok, Id2} = chappe_mrf_conf:join(Conf, Ep, #{}),
    ?F:fs_hangup(?config(fs, Config), <<"NORMAL_CLEARING">>),
    receive
        {chappe_mrf_conf, Conf, {left, Id2, hangup}} -> ok
    after 3000 -> ct:fail(no_hangup_left)
    end,
    %% an endpoint on another node
    {ok, EpX} = chappe_mrf:create_endpoint(#{targets => [{fs9, fs_uri(Config)}]}),
    ?assertEqual(
        {error, {wrong_node, fs9}}, chappe_mrf_conf:join(Conf, EpX, #{})
    ),
    chappe_mrf:destroy(EpX),
    %% a room that never adds the member, and one whose member hangs up first
    Silent = ?F:fs_start(<<"fs2">>, #{
        esl_port => ?config(lp, Config), silent_conference => true
    }),
    {ok, Conf2} = chappe_mrf:conference(<<"fse2">>, #{
        backend => fs, node => fs2, join_timeout => 500
    }),
    {ok, Ep2} = chappe_mrf:create_endpoint(#{
        targets => [{fs2, uri_of(?F:fs_port(Silent))}]
    }),
    ?assertEqual({error, timeout}, chappe_mrf_conf:join(Conf2, Ep2, #{})),
    Self = self(),
    _ = spawn(fun() ->
        Self ! {joined, chappe_mrf_conf:join(Conf2, Ep2, #{})}
    end),
    timer:sleep(200),
    ?F:fs_hangup(Silent, <<"NORMAL_CLEARING">>),
    receive
        {joined, {error, hangup}} -> ok
    after 3000 -> ct:fail(no_join_hangup)
    end,
    ?F:fs_stop(Silent).
