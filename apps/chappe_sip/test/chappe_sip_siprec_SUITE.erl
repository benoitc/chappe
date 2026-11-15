%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The SIPREC client (chappe_sip_siprec, RFC 7866) over real SIP on
%% loopback.
%%
%% A gen_udp caller calls the app, which bridges it to a gen_udp callee
%% with create_b2bua/4, media anchored on a fake rtpengine
%% (chappe_sip_test_rtpe, which also answers the subscriptions). The
%% recording server is a gen_udp peer, so each case sees the wire, or
%% chappe itself (a route taking siprec), for client against server.
-module(chappe_sip_siprec_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([invite_is_a_recording_session/1, chappe_as_recording_server/1,
         pause_and_resume/1, party_change_reinvites/1,
         snapshot_request_answered/1, srs_reinvite_answered/1,
         srs_refuses/1, srs_never_answers/1, srs_byes/1,
         call_end_byes_srs/1, owner_death_byes_srs/1,
         recording_crash_spares_call/1, recording_crash_removes_taps/1,
         too_many_per_call/1,
         bad_arguments/1, metadata_privacy/1, legacy_content_type/1,
         from_another_node/1]).
-export([server_writes_store/1, server_not_a_recording_session/1,
         server_sink_and_stream_crash/1, server_refuses_bad_body/1,
         server_answers_on_the_wire/1]).
-export([room_recorded/1, room_not_up/1, server_sink_bound/1,
         server_metadata_update/1, room_ends_recording/1, recording_over_tls/1,
         server_writes_audio_store/1, room_recorded_to_store/1]).
-export([server_latches_to_client/1, server_takes_srtp/1,
         server_refuses_srtp_it_cannot_take/1, server_srtp_rekey/1,
         server_srtp_flood/1, server_srtp_lifetime/1,
         anchor_keeps_srtp_caller/1, log/2,
         srtp_call_tapped_as_srtp/1, tls_call_needs_tls_srs/1]).
-export([too_many_at_once/1, srs_reinvite_more_streams/1,
         dialog_event_without_response/1]).

all() ->
    [invite_is_a_recording_session, chappe_as_recording_server,
     pause_and_resume, party_change_reinvites, snapshot_request_answered,
     srs_reinvite_answered, srs_refuses, srs_never_answers, srs_byes,
     call_end_byes_srs, owner_death_byes_srs, recording_crash_spares_call,
     recording_crash_removes_taps,
     too_many_per_call, bad_arguments, metadata_privacy,
     legacy_content_type, from_another_node, server_writes_store,
     server_not_a_recording_session, server_sink_and_stream_crash,
     server_refuses_bad_body, server_answers_on_the_wire,
     server_sink_bound, server_metadata_update, room_recorded, room_not_up,
     room_ends_recording, recording_over_tls,
     server_writes_audio_store, room_recorded_to_store,
     server_latches_to_client, server_takes_srtp,
     server_refuses_srtp_it_cannot_take, server_srtp_rekey,
     server_srtp_flood, server_srtp_lifetime, anchor_keeps_srtp_caller,
     srtp_call_tapped_as_srtp,
     tls_call_needs_tls_srs, too_many_at_once, srs_reinvite_more_streams,
     dialog_event_without_response].

-define(UA, chappe_sip_test_ua).
-define(M, chappe_sip_siprec_meta).
-define(SRTP, chappe_sip_test_srtp).

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

end_per_testcase(_Case, _Config) ->
    _ = case whereis(siprec_test_rtpe) of
            undefined -> ok;
            Rtpe -> unregister(siprec_test_rtpe), chappe_sip_test_rtpe:stop(Rtpe)
        end,
    _ = [exit(P, kill) || {_, P, _, _} <- supervisor:which_children(chappe_sip_siprec_sup)],
    application:unset_env(chappe_sip, siprec_max_per_call),
    application:unset_env(chappe_sip, siprec_store),
    _ = persistent_term:erase(siprec_test_ep),
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% ---- cases ----

%% RFC 7866 6.1.1: Contact +sip.src and Require siprec; 9.1: a
%% multipart/mixed of an SDP offer and the metadata; 7.1.1: each recorded
%% stream sendonly with an a=label the metadata's stream refers to. RFC
%% 7865: the participants (A's From, B's To), who sends which stream, and
%% chappe's call_ref. The answer reaches rtpengine, one per party.
%% req: R7866-6.1.1-3 R7866-6.1.1-4 R7866-7.1.1-1 R7866-7.1.1-2 R7866-9.1-1
%% req: R7866-9.1-2 R7866-9.1-3 R7866-8.3-1 R7865-5.1.2-1 R7865-6.10-1 R9806-2-1
invite_is_a_recording_session(_Config) ->
    #{b2b := B2b, call_ref := Ref} = call(),
    SP = ?UA:pick(),
    srs(SP, fun(_Sock, _D, _Src) -> ok end),
    {ok, Rec} = chappe_sip_siprec:start(B2b, srs_uri(SP), #{}),
    Inv = got(srs_invite),
    ?assertEqual(<<"siprec">>, ?UA:hdr(Inv, <<"require">>)),
    ?assertMatch({_, _}, binary:match(?UA:hdr(Inv, <<"contact">>), <<";+sip.src">>)),
    ?assertEqual(Ref, ?UA:hdr(Inv, <<"x-chappe-call">>)),
    {Sdp, Doc} = parts(Inv),
    {_, Media} = chappe_sip_sdp:sections(Sdp),
    ?assertEqual(2, length(Media)),
    Labels = [label(M) || M <- Media],
    ?assertEqual([<<"1">>, <<"2">>], Labels),
    ?assert(lists:all(fun(M) -> lists:member(<<"a=sendonly">>, M) end, Media)),
    %% the caller's stream is tapped from A's tag, the callee's from B's
    ?assert(lists:member(<<"a=rtpe-sub:atag">>, hd(Media))),
    [#{call_ref := Ref}] = maps:get(sessions, Doc),
    ?assertMatch([#{names := [#{aor := <<"sip:caller@127.0.0.1:", _/binary>>}]},
                  #{names := [#{aor := <<"sip:callee@127.0.0.1:", _/binary>>}]}],
                 maps:get(participants, Doc)),
    [S1, S2] = ?M:senders(Doc),
    ?assertMatch(#{label := <<"1">>, participants := [#{names := [#{aor := <<"sip:caller", _/binary>>}]}]}, S1),
    ?assertMatch(#{label := <<"2">>, participants := [#{names := [#{aor := <<"sip:callee", _/binary>>}]}]}, S2),
    {started, #{call_ref := Ref, srs := _}} = event(Rec),
    Answers = [C || {rtpe_cmd, #{<<"command">> := <<"subscribe answer">>} = C} <- drain()],
    ?assertEqual(2, length(Answers)),
    ?assertMatch(#{siprec := [Rec]}, element(2, chappe_sip:calls(#{call_ref => Ref}))),
    ok = chappe_sip_siprec:stop(Rec),
    {stopped, #{reason := stopped, call_ref := Ref}} = event(Rec),
    _ = got(srs_bye).

%% chappe as client against chappe as recording server: the route takes
%% siprec, reads the metadata, answers recvonly, and gets the BYE.
%% req: R7866-6.1.1-2
chappe_as_recording_server(_Config) ->
    #{b2b := B2b, call_ref := Ref, ep := EP} = call(),
    {ok, Rec} = chappe_sip_siprec:start(
                  B2b, <<"sip:srs@127.0.0.1:", (integer_to_binary(EP))/binary>>, #{}),
    {started, #{call_ref := Ref}} = event(Rec),
    {Doc, Contact} = got(srs_doc),
    ?assertMatch({_, _}, binary:match(Contact, <<"+sip.src">>)),
    ?assertMatch([#{call_ref := Ref}], maps:get(sessions, Doc)),
    ?assertEqual(2, length(?M:senders(Doc))),
    #{state := active, labels := [<<"1">>, <<"2">>]} = chappe_sip_siprec:info(Rec),
    ok = chappe_sip_siprec:stop(Rec),
    {stopped, _} = event(Rec),
    ?assertMatch(#{method := <<"BYE">>}, got(srs_destroy)).

%% RFC 7866 7.1.1.1: pause re-INVITEs with every stream inactive, at the
%% ports it had; resume with sendonly again. While paused, the taps are
%% gone from rtpengine.
%% req: R7866-7.1.1.1-1 R6341-REQ-011
pause_and_resume(_Config) ->
    #{b2b := B2b} = call(),
    SP = ?UA:pick(),
    srs(SP, fun(Sock, _D, _Src) -> reinvites(Sock, 2) end),
    {ok, Rec} = chappe_sip_siprec:start(B2b, srs_uri(SP), #{}),
    {started, _} = event(Rec),
    _ = drain(),
    ok = chappe_sip_siprec:pause(Rec),
    {paused, _} = event(Rec),
    {Re1, _} = got(srs_reinvite),
    {Sdp1, _} = parts(Re1),
    {_, M1} = chappe_sip_sdp:sections(Sdp1),
    ?assert(lists:all(fun(M) -> lists:member(<<"a=inactive">>, M) end, M1)),
    ?assertEqual(2, length([C || {rtpe_cmd, #{<<"command">> := <<"unsubscribe">>} = C} <- drain()])),
    #{state := paused} = chappe_sip_siprec:info(Rec),
    ok = chappe_sip_siprec:resume(Rec),
    {resumed, _} = event(Rec),
    {Re2, _} = got(srs_reinvite),
    {Sdp2, _} = parts(Re2),
    {_, M2} = chappe_sip_sdp:sections(Sdp2),
    ?assert(lists:all(fun(M) -> lists:member(<<"a=sendonly">>, M) end, M2)),
    ?assertEqual([<<"1">>, <<"2">>], [label(M) || M <- M2]),
    Cmds = [maps:get(<<"command">>, C) || {rtpe_cmd, C} <- drain()],
    ?assertEqual(2, length([C || <<"subscribe request">> = C <- Cmds])),
    ?assertEqual(2, length([C || <<"subscribe answer">> = C <- Cmds])),
    ok = chappe_sip_siprec:stop(Rec).

%% A party change (replace_b/3): the new callee is tapped on the same
%% stream and label, and the re-INVITE's metadata disassociates the old
%% callee and associates the new one (RFC 7865 6.6, 6.8).
%% req: R7866-9.1-4 R6341-REQ-020
party_change_reinvites(_Config) ->
    #{b2b := B2b, cp := _CP} = call(),
    SP = ?UA:pick(),
    srs(SP, fun(Sock, _D, _Src) -> reinvites(Sock, 1) end),
    {ok, Rec} = chappe_sip_siprec:start(B2b, srs_uri(SP), #{}),
    {started, _} = event(Rec),
    NP = ?UA:pick(),
    ?UA:peer(NP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, <<"newb">>, [contact(Sock)],
                                     ?UA:sdp(<<"newcallee">>))),
        timer:sleep(infinity)
    end),
    _ = drain(),
    ok = chappe_sip_b2b:replace_b(B2b, <<"sip:other@127.0.0.1:", (integer_to_binary(NP))/binary>>, #{}),
    {Re, _} = got(srs_reinvite),
    {updated, _} = event(Rec),
    {Sdp, Doc} = parts(Re),
    {_, Media} = chappe_sip_sdp:sections(Sdp),
    ?assertEqual([<<"1">>, <<"2">>], [label(M) || M <- Media]),
    %% the callee's tap is taken again (rtpengine keeps B's monologue for
    %% the new B, so its tag is still B's), the caller's is left alone
    Subs = [C || {rtpe_cmd, #{<<"command">> := <<"subscribe request">>} = C} <- drain()],
    ?assertMatch([#{<<"from-tags">> := [<<"btag">>]}], Subs),
    Ps = maps:get(participants, Doc),
    ?assertEqual(3, length(Ps)),
    [Old] = [Id || #{id := Id, names := [#{aor := <<"sip:callee", _/binary>>}]} <- Ps],
    [New] = [Id || #{id := Id, names := [#{aor := <<"sip:other", _/binary>>}]} <- Ps],
    Assocs = maps:get(participant_stream_assocs, Doc),
    ?assertMatch([#{disassociate_time := _}], [A || #{participant_id := P} = A <- Assocs, P =:= Old]),
    [NewA] = [A || #{participant_id := P} = A <- Assocs, P =:= New],
    ?assertNot(maps:is_key(disassociate_time, NewA)),
    [#{label := <<"2">>, participants := [#{id := New}]}] =
        [S || #{label := <<"2">>} = S <- ?M:senders(Doc)],
    ok = chappe_sip_siprec:stop(Rec).

%% RFC 7866 9.2 and 9.1: an UPDATE of the SRS asking for a snapshot is
%% answered, and a full snapshot follows in its own transaction.
%% req: R7866-9.1-5 R7866-9.2-1
snapshot_request_answered(_Config) ->
    #{b2b := B2b} = call(),
    SP = ?UA:pick(),
    Test = self(),
    srs(SP, fun(Sock, D, Src) ->
        {Up0, _} = ?UA:in_dialog(D, <<"UPDATE">>, [{<<"Content-Disposition">>, <<"recording-session">>}],
                                ?M:snapshot_request(<<"lost it">>)),
        Up = binary:replace(Up0, <<"Content-Type: application/sdp">>,
                            <<"Content-Type: application/rs-metadata+xml">>),
        ?UA:send(Sock, Src, Up),
        Test ! {update_final, ?UA:recv_any(Sock, 6000)},
        reinvites(Sock, 1)
    end),
    {ok, Rec} = chappe_sip_siprec:start(B2b, srs_uri(SP), #{}),
    {started, _} = event(Rec),
    ?assertEqual(200, ?UA:status(got(update_final))),
    {snapshot, #{reason := <<"lost it">>}} = event(Rec),
    {Re, _} = got(srs_reinvite),
    {_, Doc} = parts(Re),
    ?assertEqual(complete, maps:get(datamode, Doc)),
    ?assertEqual(2, length(maps:get(participants, Doc))),
    ok = chappe_sip_siprec:stop(Rec).

%% RFC 7866 7.2: the SRS re-INVITEs (ready now, say): the recorded
%% streams are answered as they are, and its offer reaches rtpengine.
srs_reinvite_answered(_Config) ->
    #{b2b := B2b} = call(),
    SP = ?UA:pick(),
    Test = self(),
    srs(SP, fun(Sock, D, Src) ->
        {Re, D1} = ?UA:in_dialog(D, <<"INVITE">>, [], answer_sdp(2, <<"recvonly">>)),
        ?UA:send(Sock, Src, Re),
        R = ?UA:recv_status(Sock, 200),
        ?UA:ack(D1, Src),
        Test ! {srs_got, R}
    end),
    {ok, Rec} = chappe_sip_siprec:start(B2b, srs_uri(SP), #{}),
    {started, _} = event(Rec),
    R = got(srs_got),
    ?assertEqual(<<"application/sdp">>, ?UA:hdr(R, <<"content-type">>)),
    {_, Media} = chappe_sip_sdp:sections(?UA:body(R)),
    ?assertEqual([<<"1">>, <<"2">>], [label(M) || M <- Media]),
    timer:sleep(200),
    %% two answers to the INVITE, two to the SRS's offer
    ?assertEqual(4, length([C || {rtpe_cmd, #{<<"command">> := <<"subscribe answer">>} = C} <- drain()])),
    ok = chappe_sip_siprec:stop(Rec).

%% The SRS refuses: the owner hears the status, the taps are removed.
%% req: R6341-REQ-015
srs_refuses(_Config) ->
    #{b2b := B2b, call_ref := Ref} = call(),
    SP = ?UA:pick(),
    ?UA:peer(SP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 488, <<"Not Acceptable Here">>, ?UA:tag(), [], <<>>)),
        timer:sleep(infinity)
    end),
    {ok, Rec} = chappe_sip_siprec:start(B2b, srs_uri(SP), #{}),
    {stopped, #{reason := {rejected, 488}, call_ref := Ref}} = event(Rec),
    ?assertEqual(2, length([C || {rtpe_cmd, #{<<"command">> := <<"unsubscribe">>} = C} <- drain()])),
    ?assertMatch(#{media := anchor}, chappe_sip_b2b:info(B2b)).

%% A recording server that never answers is given answer_timeout: the
%% INVITE is CANCELled and the owner told, the call untouched.
srs_never_answers(_Config) ->
    #{b2b := B2b} = call(),
    SP = ?UA:pick(),
    Test = self(),
    ?UA:peer(SP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        %% alive, but never answers
        ?UA:send(Sock, Src, ?UA:resp(Inv, 100, <<"Trying">>, <<>>, [], <<>>)),
        {Cancel, _} = ?UA:recv_req(Sock, <<"CANCEL">>, 8000),
        Test ! {srs_cancel, Cancel},
        timer:sleep(infinity)
    end),
    T0 = erlang:monotonic_time(millisecond),
    {ok, Rec} = chappe_sip_siprec:start(B2b, srs_uri(SP), #{answer_timeout => 500}),
    {stopped, #{reason := {srs, timeout}}} = event(Rec),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 3000),
    _ = got(srs_cancel),
    ?assertMatch(#{media := anchor}, chappe_sip_b2b:info(B2b)).

%% The SRS ends the session: the owner hears srs_bye, the call goes on.
srs_byes(_Config) ->
    #{b2b := B2b} = call(),
    SP = ?UA:pick(),
    srs(SP, fun(Sock, D, Src) ->
        {Bye, _} = ?UA:in_dialog(D, <<"BYE">>, [], <<>>),
        ?UA:send(Sock, Src, Bye)
    end),
    {ok, Rec} = chappe_sip_siprec:start(B2b, srs_uri(SP), #{}),
    {started, _} = event(Rec),
    {stopped, #{reason := srs_bye}} = event(Rec),
    ?assertMatch(#{media := anchor}, chappe_sip_b2b:info(B2b)).

%% The call ends: the SRS gets a BYE and the owner call_ended.
%% req: R6341-REQ-015
call_end_byes_srs(_Config) ->
    #{b2b := B2b, caller := Caller} = call(),
    SP = ?UA:pick(),
    srs(SP, fun(_Sock, _D, _Src) -> ok end),
    {ok, Rec} = chappe_sip_siprec:start(B2b, srs_uri(SP), #{}),
    {started, _} = event(Rec),
    Caller ! bye,
    {stopped, #{reason := call_ended}} = event(Rec),
    _ = got(srs_bye).

%% The owner dies: the recording ends, its SRS gets a BYE, and the call
%% no longer lists it.
owner_death_byes_srs(_Config) ->
    #{b2b := B2b, call_ref := Ref} = call(),
    SP = ?UA:pick(),
    srs(SP, fun(_Sock, _D, _Src) -> ok end),
    Test = self(),
    Owner = spawn(fun() ->
        {ok, Rec} = chappe_sip_siprec:start(B2b, srs_uri(SP), #{}),
        Test ! {rec, Rec},
        receive {chappe_sip_siprec, Rec, {started, _}} -> Test ! started end,
        receive die -> ok end
    end),
    Rec = got(rec),
    ok = ?UA:expect(started),
    MRef = monitor(process, Rec),
    Owner ! die,
    receive {'DOWN', MRef, process, Rec, _} -> ok after 5000 -> ct:fail(rec_alive) end,
    _ = got(srs_bye),
    timer:sleep(100),
    ?assertMatch({ok, #{siprec := []}}, chappe_sip:calls(#{call_ref => Ref})),
    ?assertMatch(#{media := anchor}, chappe_sip_b2b:info(B2b)).

%% The recording crashes: its RS dialog sends the BYE, the call goes on,
%% and a new recording of the same call starts.
recording_crash_spares_call(_Config) ->
    #{b2b := B2b} = call(),
    SP = ?UA:pick(),
    srs(SP, fun(_Sock, _D, _Src) -> ok end),
    {ok, Rec} = chappe_sip_siprec:start(B2b, srs_uri(SP), #{}),
    {started, _} = event(Rec),
    MRef = monitor(process, Rec),
    exit(Rec, kill),
    receive {'DOWN', MRef, process, Rec, killed} -> ok after 2000 -> ct:fail(alive) end,
    _ = got(srs_bye),
    ?assertMatch(#{media := anchor}, chappe_sip_b2b:info(B2b)),
    SP2 = ?UA:pick(),
    srs(SP2, fun(_Sock, _D, _Src) -> ok end),
    {ok, Rec2} = chappe_sip_siprec:start(B2b, srs_uri(SP2), #{}),
    {started, _} = event(Rec2),
    ok = chappe_sip_siprec:stop(Rec2).

%% A recording killed outright runs no cleanup of its own: the call's
%% media session holds its taps and removes them, so rtpengine stops
%% forking the parties' media to the SRS.
recording_crash_removes_taps(_Config) ->
    #{b2b := B2b} = call(),
    SP = ?UA:pick(),
    srs(SP, fun(_Sock, _D, _Src) -> ok end),
    {ok, Rec} = chappe_sip_siprec:start(B2b, srs_uri(SP), #{}),
    {started, _} = event(Rec),
    Tags = lists:sort(
             [T || {rtpe_cmd, #{<<"command">> := <<"subscribe answer">>,
                                <<"to-tag">> := T}} <- drain()]),
    ?assertEqual(2, length(Tags)),
    MRef = monitor(process, Rec),
    exit(Rec, kill),
    receive {'DOWN', MRef, process, Rec, killed} -> ok after 2000 -> ct:fail(alive) end,
    Gone = lists:sort(
             [T || {rtpe_cmd, #{<<"command">> := <<"unsubscribe">>,
                                <<"to-tag">> := T}} <- drain()]),
    ?assertEqual(Tags, Gone),
    ?assertMatch(#{media := anchor}, chappe_sip_b2b:info(B2b)).

%% siprec_max_per_call bounds the recordings of one call.
too_many_per_call(_Config) ->
    application:set_env(chappe_sip, siprec_max_per_call, 1),
    #{b2b := B2b} = call(),
    SP = ?UA:pick(),
    srs(SP, fun(_Sock, _D, _Src) -> ok end),
    {ok, Rec} = chappe_sip_siprec:start(B2b, srs_uri(SP), #{}),
    ?assertEqual({error, too_many}, chappe_sip_siprec:start(B2b, srs_uri(SP), #{})),
    {started, _} = event(Rec),
    ok = chappe_sip_siprec:stop(Rec).

%% The bound holds for starts at the same time: of twenty started at once
%% with siprec_max_per_call at 2, two run.
too_many_at_once(_Config) ->
    application:set_env(chappe_sip, siprec_max_per_call, 2),
    #{b2b := B2b} = call(),
    SP = ?UA:pick(),
    srs(SP, fun(_Sock, _D, _Src) -> ok end),
    Test = self(),
    _ = [spawn(fun() ->
                   Test ! {start, chappe_sip_siprec:start(B2b, srs_uri(SP),
                                                          #{owner => Test})}
               end) || _ <- lists:seq(1, 20)],
    Rs = [receive {start, R} -> R after 10000 -> ct:fail(no_start) end
          || _ <- lists:seq(1, 20)],
    Ok = [Rec || {ok, Rec} <- Rs],
    ct:log("~p started", [length(Ok)]),
    ?assertEqual(2, length(Ok)),
    ?assertEqual(18, length([E || {error, too_many} = E <- Rs])),
    _ = [chappe_sip_siprec:stop(R) || R <- Ok].

%% RFC 3264 6: the answer to a re-INVITE of the SRS has as many m-lines as
%% its offer: an m-line past the recorded streams is refused with port 0.
%% req: R7866-7.2-1
srs_reinvite_more_streams(_Config) ->
    #{b2b := B2b} = call(),
    SP = ?UA:pick(),
    Test = self(),
    srs(SP, fun(Sock, D, Src) ->
        {Re, D1} = ?UA:in_dialog(D, <<"INVITE">>, [], answer_sdp(3, <<"recvonly">>)),
        ?UA:send(Sock, Src, Re),
        R = ?UA:recv_status(Sock, 200),
        ?UA:ack(D1, Src),
        Test ! {srs_got, R}
    end),
    {ok, Rec} = chappe_sip_siprec:start(B2b, srs_uri(SP), #{}),
    {started, _} = event(Rec),
    R = got(srs_got),
    {_, Media} = chappe_sip_sdp:sections(?UA:body(R)),
    ?assertEqual(3, length(Media)),
    [M1, M2, M3] = Media,
    ?assertEqual([<<"1">>, <<"2">>], [label(M1), label(M2)]),
    ?assertMatch(<<"m=audio 0 RTP/AVP", _/binary>>, hd(M3)),
    ok = chappe_sip_siprec:stop(Rec).

%% A dialog event with no response to send (an ACK) is not answered: the
%% recording goes on.
dialog_event_without_response(_Config) ->
    #{b2b := B2b} = call(),
    SP = ?UA:pick(),
    srs(SP, fun(_Sock, _D, _Src) -> ok end),
    {ok, Rec} = chappe_sip_siprec:start(B2b, srs_uri(SP), #{}),
    {started, _} = event(Rec),
    MRef = erlang:monitor(process, Rec),
    Rec ! {chappe_sip_dialog, {dialog, self(), 0}, ack, ack_req, undefined},
    receive {'DOWN', MRef, process, Rec, Why} -> ct:fail({crashed, Why})
    after 500 -> ok
    end,
    ok = chappe_sip_siprec:stop(Rec).

%% Bad arguments fail in the caller; a direct call cannot be recorded;
%% default needs a configured SRS.
bad_arguments(_Config) ->
    ?assertEqual({error, badarg}, chappe_sip_siprec:start(nope, <<"sip:srs@x">>, #{})),
    #{b2b := B2b} = call(),
    ?assertEqual({error, badarg}, chappe_sip_siprec:start(B2b, <<"http://srs">>, #{})),
    ?assertEqual({error, badarg}, chappe_sip_siprec:start(B2b, <<"sip:srs@x">>, #{owner => x})),
    ?assertEqual({error, badarg}, chappe_sip_siprec:start(B2b, <<"sip:srs@x">>, #{nope => 1})),
    ?assertEqual({error, no_srs}, chappe_sip_siprec:start(B2b, default, #{})),
    ?assertEqual({error, badarg}, chappe_sip_siprec:pause(not_a_pid)),
    ?assertEqual(ok, chappe_sip_siprec:stop(spawn(fun() -> ok end))),
    #{b2b := Direct} = call(#{media => direct}),
    ?assertEqual({error, not_anchored}, chappe_sip_siprec:start(Direct, <<"sip:srs@x">>, #{})).

%% RFC 7865 10: the SRC may keep metadata back. The app's names for the
%% parties, no display names, no AORs, no call_ref.
%% req: R7865-10-1
metadata_privacy(_Config) ->
    #{b2b := B2b} = call(),
    SP = ?UA:pick(),
    srs(SP, fun(_Sock, _D, _Src) -> ok end),
    {ok, Rec} = chappe_sip_siprec:start(B2b, srs_uri(SP), #{
        participants => #{a => #{aor => <<"sip:agent-7@example.com">>, name => <<"Agent">>}},
        metadata => #{names => false, call_ref => false}
    }),
    {_, Doc} = parts(got(srs_invite)),
    [#{names := [A]}, #{names := [_]}] = maps:get(participants, Doc),
    ?assertEqual(#{aor => <<"sip:agent-7@example.com">>}, A),
    [S] = maps:get(sessions, Doc),
    ?assertNot(maps:is_key(call_ref, S)),
    {started, _} = event(Rec),
    ok = chappe_sip_siprec:stop(Rec),
    #{b2b := B2b2} = call(),
    SP2 = ?UA:pick(),
    srs(SP2, fun(_Sock, _D, _Src) -> ok end),
    {ok, Rec2} = chappe_sip_siprec:start(B2b2, srs_uri(SP2), #{metadata => #{aors => false}}),
    {_, Doc2} = parts(got(srs_invite)),
    ?assertEqual([<<"sip:anonymous@anonymous.invalid">>, <<"sip:anonymous@anonymous.invalid">>],
                 [Aor || #{names := [#{aor := Aor}]} <- maps:get(participants, Doc2)]),
    ok = chappe_sip_siprec:stop(Rec2).

%% RFC 9806 renamed the media type; legacy_content_type sends RFC 7866's
%% name to a recorder that predates it.
legacy_content_type(_Config) ->
    #{b2b := B2b} = call(),
    SP = ?UA:pick(),
    srs(SP, fun(_Sock, _D, _Src) -> ok end),
    {ok, Rec} = chappe_sip_siprec:start(B2b, srs_uri(SP), #{legacy_content_type => true}),
    Inv = got(srs_invite),
    ?assertMatch({_, _}, binary:match(?UA:body(Inv), <<"Content-Type: application/rs-metadata\r\n">>)),
    ok = chappe_sip_siprec:stop(Rec).

%% A peer node starts the recording of a call this node holds: the
%% process runs here, next to the call, the events reach the peer, and
%% the peer finds it by the call's call_ref.
from_another_node(_Config) ->
    ok = chappe_sip_test_dist:ensure(),
    Paths = lists:append([["-pa", P] || P <- code:get_path()]),
    {ok, Peer, Node} = peer:start_link(#{name => peer:random_name(), args => Paths}),
    try
        {ok, _} = erpc:call(Node, pg, start, [chappe_sip]),
        #{b2b := B2b, call_ref := Ref} = call(),
        SP = ?UA:pick(),
        srs(SP, fun(_Sock, _D, _Src) -> ok end),
        Test = self(),
        Uri = srs_uri(SP),
        _ = erpc:call(Node, erlang, spawn, [fun() ->
            {ok, Rec} = chappe_sip_siprec:start(B2b, Uri, #{}),
            receive {chappe_sip_siprec, Rec, Ev} -> Test ! {peer_event, node(), Rec, Ev} end,
            receive stop -> chappe_sip_siprec:stop(Rec) end
        end]),
        {Node, Rec, {started, #{call_ref := Ref}}} = got3(peer_event),
        ?assertEqual(node(), node(Rec)),
        {ok, #{siprec := [Rec]}} = erpc:call(Node, chappe_sip, calls, [#{call_ref => Ref}])
    after
        peer:stop(Peer)
    end,
    %% the peer (the owner) is gone: the recording ends with it
    _ = got(srs_bye).

%% ---- the recording server side (chappe_sip_siprec_srs) ----

%% chappe records to chappe: the server takes the RS (RFC 7866 6.2), answers
%% each stream recvonly with +sip.srs in its Contact, and writes each
%% stream to the store, under the call's call_ref with the stream's
%% sender as its party; the BYE finishes the recordings.
%% req: R7866-6.2-1 R7865-10-2
server_writes_store(_Config) ->
    persistent_term:put(chappe_sip_test_store, self()),
    application:set_env(chappe_sip, siprec_store, chappe_sip_test_store),
    #{b2b := B2b, call_ref := Ref, ep := EP} = call(),
    {ok, Rec} = chappe_sip_siprec:start(
                  B2b, <<"sip:store@127.0.0.1:", (integer_to_binary(EP))/binary>>, #{}),
    {started, _} = event(Rec),
    #{streams := [#{port := P1, parties := [A1]}, #{port := P2, parties := [A2]}]} =
        got(srs_served),
    ?assertMatch(<<"sip:caller@", _/binary>>, A1),
    ?assertMatch(<<"sip:callee@", _/binary>>, A2),
    Opens = [receive {store_open, R, Meta, _} -> {R, Meta} after 2000 -> ct:fail(no_open) end
             || _ <- [1, 2]],
    ?assert(lists:all(fun({_, #{call_ref := C, source := siprec}}) -> C =:= Ref end, Opens)),
    %% only what the store needs of the metadata (RFC 7865 10)
    [[call_ref, format, parties, source]] = lists:usort([lists:sort(maps:keys(M)) || {_, M} <- Opens]),
    {ok, Sock} = gen_udp:open(0, [binary]),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, P1, rtp(0, binary:copy(<<16#FF>>, 160))),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, P2, rtp(8, binary:copy(<<16#D5>>, 160))),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, P1, <<"not rtp">>),
    Writes = [receive {store_write, R, Pcm} -> {R, Pcm} after 2000 -> ct:fail(no_write) end
              || _ <- [1, 2]],
    %% 160 samples of 16-bit PCM each: mu-law 0xFF and A-law 0xD5 are the
    %% smallest positive levels
    ?assert(lists:all(fun({_, Pcm}) -> byte_size(Pcm) =:= 320 end, Writes)),
    ok = chappe_sip_siprec:stop(Rec),
    {stopped, _} = event(Rec),
    [receive {store_close, R, _} -> ok after 5000 -> ct:fail(no_close) end
     || {R, _} <- Opens],
    gen_udp:close(Sock).

%% store => default with no siprec_store set: each stream lands in
%% chappe_audio's store, found by the call's call_ref with source siprec
%% and the stream's sender as its party.
server_writes_audio_store(Config) ->
    with_audio_store(Config, fun() ->
        #{b2b := B2b, call_ref := Ref, ep := EP} = call(),
        {ok, Rec} = chappe_sip_siprec:start(B2b, store_uri(EP), #{}),
        {started, _} = event(Rec),
        #{streams := [#{port := P1}, #{port := P2}]} = got(srs_served),
        {ok, Sock} = gen_udp:open(0, [binary]),
        ok = gen_udp:send(Sock, {127, 0, 0, 1}, P1, rtp(0, binary:copy(<<16#FF>>, 160))),
        ok = gen_udp:send(Sock, {127, 0, 0, 1}, P2, rtp(8, binary:copy(<<16#D5>>, 160))),
        timer:sleep(200),
        ok = chappe_sip_siprec:stop(Rec),
        {stopped, _} = event(Rec),
        gen_udp:close(Sock),
        Recs = stored(Ref, 2),
        ?assertEqual([<<"siprec">>], lists:usort([source(R) || R <- Recs])),
        ?assertMatch([[<<"sip:callee@", _/binary>>], [<<"sip:caller@", _/binary>>]],
                     lists:sort([maps:get(parties, R) || R <- Recs])),
        %% 160 samples of 16-bit PCM after the 44-byte WAVE header
        ?assert(lists:all(fun(R) -> maps:get(bytes, R) >= 44 + 320 end, Recs))
    end).

%% A native room recorded through SIPREC to chappe's own recording server:
%% the mix is one stream, in the store under the room's call_ref.
room_recorded_to_store(Config) ->
    with_audio_store(Config, fun() ->
        ok = chappe_sip_media:configure(#{mix => #{ip => {127, 0, 0, 1}}}),
        EP = start_app(),
        persistent_term:put(siprec_test_opts, #{test => self(), cp => 0}),
        {ok, Party} = chappe_sip_media:session(#{call_id => <<"room-party-3">>},
                                               #{capability => conference}),
        {ok, _} = chappe_sip_media:conference(Party, <<"r3">>, #{}),
        {ok, Rec} = chappe_sip_siprec:start({room, <<"r3">>}, store_uri(EP),
                                            #{call_ref => <<"room-r3">>}),
        {started, _} = event(Rec),
        #{streams := [_]} = got(srs_served),
        timer:sleep(500),
        ok = chappe_sip_siprec:stop(Rec),
        {stopped, _} = event(Rec),
        ok = chappe_sip_media:stop(Party),
        [R] = stored(<<"room-r3">>, 1),
        ?assertEqual(<<"siprec">>, source(R)),
        ?assertEqual([<<"sip:r3@chappe.invalid">>], maps:get(parties, R)),
        ?assert(maps:get(bytes, R) > 44)
    end).

with_audio_store(Config, Fun) ->
    Dir = filename:join(?config(priv_dir, Config), "audio-store"),
    {ok, _} = application:ensure_all_started(chappe_audio),
    try
        ok = chappe_audio_store:configure(#{dir => Dir}),
        Fun()
    after
        ok = application:stop(chappe_audio)
    end.

store_uri(EP) ->
    <<"sip:store@127.0.0.1:", (integer_to_binary(EP))/binary>>.

source(#{source := S}) when is_atom(S) -> atom_to_binary(S);
source(#{source := S}) -> S.

%% the N recordings of Ref, once the writers have closed them
stored(Ref, N) -> stored(Ref, N, 50).

stored(Ref, N, 0) ->
    ct:fail({not_stored, Ref, N, chappe_audio_store:find(Ref)});
stored(Ref, N, Tries) ->
    case chappe_audio_store:find(Ref) of
        Recs when length(Recs) =:= N -> Recs;
        _ -> timer:sleep(100), stored(Ref, N, Tries - 1)
    end.

%% RFC 7866 6.2: without +sip.src and siprec it is not a recording
%% session; the app decides (here a 403).
%% req: R7866-6.2-1
server_not_a_recording_session(_Config) ->
    #{ep := EP} = call(),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(), from_tag => ?UA:tag(),
                                     ruri => <<"sip:store@127.0.0.1">>,
                                     headers => [{<<"Require">>, <<"siprec">>}]}),
        ?UA:send(Sock, EP, Inv),
        b2b_relay_tell({plain, ?UA:recv_any(Sock, 6000)})
    end),
    ?assertEqual({error, not_recording_session}, got(srs_served)),
    ?assertEqual(403, ?UA:status(got(plain))).

%% sink => pid(): each stream's audio to a process; a stream that crashes
%% leaves the session and the other stream going.
server_sink_and_stream_crash(_Config) ->
    #{b2b := B2b, ep := EP} = call(),
    {ok, Rec} = chappe_sip_siprec:start(
                  B2b, <<"sip:sink@127.0.0.1:", (integer_to_binary(EP))/binary>>, #{}),
    {started, _} = event(Rec),
    #{streams := [#{pid := S1}, #{pid := S2, port := P2}]} = got(srs_served),
    exit(S1, kill),
    {ok, Sock} = gen_udp:open(0, [binary]),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, P2, rtp(0, binary:copy(<<16#FF>>, 160))),
    receive {chappe_sip_siprec_rtp, S2, {audio, Pcm}} -> 320 = byte_size(Pcm)
    after 2000 -> ct:fail(no_audio)
    end,
    #{state := active} = chappe_sip_siprec:info(Rec),
    ok = chappe_sip_siprec:stop(Rec),
    gen_udp:close(Sock).

%% A sink that does not read is sent at most max_queue frames; the rest
%% is dropped, and the stream goes on.
server_sink_bound(_Config) ->
    #{b2b := B2b, ep := EP} = call(),
    persistent_term:put(siprec_test_sink_queue, 5),
    {ok, Rec} = chappe_sip_siprec:start(
                  B2b, <<"sip:sink@127.0.0.1:", (integer_to_binary(EP))/binary>>, #{}),
    {started, _} = event(Rec),
    #{streams := [#{pid := S1, port := P1} | _]} = got(srs_served),
    {ok, Sock} = gen_udp:open(0, [binary]),
    _ = [ok = gen_udp:send(Sock, {127, 0, 0, 1}, P1, rtp(0, binary:copy(<<16#FF>>, 160)))
         || _ <- lists:seq(1, 50)],
    timer:sleep(500),
    {messages, Ms} = process_info(self(), messages),
    N = length([M || {chappe_sip_siprec_rtp, S, {audio, _}} = M <- Ms, S =:= S1]),
    ct:log("frames queued: ~p", [N]),
    ?assert(N =< 5 + 1),
    ?assert(is_process_alive(S1)),
    ok = chappe_sip_siprec:stop(Rec),
    persistent_term:erase(siprec_test_sink_queue),
    gen_udp:close(Sock).

%% RFC 7866 9.2: the SRS keeps track of the metadata updates. Each
%% re-INVITE's metadata reaches the server's app as an event, and the
%% re-INVITE is answered with the streams as they were.
%% req: R7866-9.2-3
server_metadata_update(_Config) ->
    #{b2b := B2b, ep := EP} = call(),
    {ok, Rec} = chappe_sip_siprec:start(
                  B2b, <<"sip:sink@127.0.0.1:", (integer_to_binary(EP))/binary>>, #{}),
    {started, _} = event(Rec),
    #{dialog := D} = got(srs_served),
    ok = chappe_sip_siprec:pause(Rec),
    receive
        {chappe_sip_siprec_srs, D, {metadata, Doc}} ->
            ?assertEqual(2, length(maps:get(participants, Doc)))
    after 5000 ->
        ct:fail(no_metadata_event)
    end,
    ok = chappe_sip_siprec:resume(Rec),
    receive {chappe_sip_siprec_srs, D, {metadata, _}} -> ok
    after 5000 -> ct:fail(no_second_metadata_event)
    end,
    ok = chappe_sip_siprec:stop(Rec),
    receive {chappe_sip_siprec_srs, D, {stopped, _}} -> ok
    after 5000 -> ct:fail(no_stopped_event)
    end.

%% A body that does not parse is refused 488.
server_refuses_bad_body(_Config) ->
    #{ep := EP} = call(),
    ?UA:peer(0, fun(Sock) ->
        P = integer_to_binary(?UA:lport(Sock)),
        Inv = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(), from_tag => ?UA:tag(),
                                     ruri => <<"sip:store@127.0.0.1">>,
                                     body => <<"--x\r\nbroken">>,
                                     headers => [{<<"Require">>, <<"siprec">>}]}),
        Inv1 = binary:replace(
                 binary:replace(Inv, <<"Content-Type: application/sdp">>,
                                <<"Content-Type: multipart/mixed;boundary=x">>),
                 <<"Contact: <sip:caller@127.0.0.1:", P/binary, ">">>,
                 <<"Contact: <sip:caller@127.0.0.1:", P/binary, ">;+sip.src">>),
        ?UA:send(Sock, EP, Inv1),
        b2b_relay_tell({bad, ?UA:recv_any(Sock, 6000)})
    end),
    ?assertMatch({error, _}, got(srs_served)),
    ?assertEqual(488, ?UA:status(got(bad))).

%% ---- native conference recording ----

%% A chappe_mix room recorded as one participant: one sendonly stream, the
%% room's mix, which reaches the recording server's port once it answered.
%% req: R7866-9.1-1 R7866-7.1.1-1
room_recorded(_Config) ->
    ok = chappe_sip_media:configure(#{mix => #{ip => {127, 0, 0, 1}}}),
    _ = start_app(),
    %% a party in the room
    {ok, Party} = chappe_sip_media:session(#{call_id => <<"room-party">>},
                                           #{capability => conference}),
    {ok, _Offer} = chappe_sip_media:conference(Party, <<"r1">>, #{}),
    {ok, Media} = gen_udp:open(0, [binary, {ip, {127, 0, 0, 1}}, {active, true}]),
    {ok, MPort} = inet:port(Media),
    SP = ?UA:pick(),
    Test = self(),
    ?UA:peer(SP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Test ! {srs_invite, Inv},
        Answer = <<"v=0\r\no=srs 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n"
                   "m=audio ", (integer_to_binary(MPort))/binary, " RTP/AVP 0\r\na=recvonly\r\n"
                   "a=label:1\r\n">>,
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, ?UA:tag(), [contact(Sock)], Answer)),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        srs_bye(Sock, Test)
    end),
    {ok, Rec} = chappe_sip_siprec:start({room, <<"r1">>}, srs_uri(SP),
                                        #{call_ref => <<"room-r1">>}),
    {Sdp, Doc} = parts(got(srs_invite)),
    {_, [M]} = chappe_sip_sdp:sections(Sdp),
    ?assert(lists:member(<<"a=sendonly">>, M)),
    ?assertEqual(<<"1">>, label(M)),
    ?assertMatch([#{names := [#{aor := <<"sip:r1@chappe.invalid">>}]}], maps:get(participants, Doc)),
    ?assertMatch([#{call_ref := <<"room-r1">>}], maps:get(sessions, Doc)),
    ?assertMatch([#{label := <<"1">>, participants := [_]}], ?M:senders(Doc)),
    {started, #{call_ref := <<"room-r1">>}} = event(Rec),
    receive {udp, Media, _, _, <<2:2, _/bits>>} -> ok
    after 3000 -> ct:fail(no_room_media)
    end,
    ok = chappe_sip_siprec:stop(Rec),
    _ = got(srs_bye),
    ok = chappe_sip_media:stop(Party),
    gen_udp:close(Media).

%% The last party leaves: the room ends although the recording's leg is
%% still in it, and the recording ends with it (room_ended, a BYE).
room_ends_recording(_Config) ->
    ok = chappe_sip_media:configure(#{mix => #{ip => {127, 0, 0, 1}}}),
    _ = start_app(),
    {ok, Party} = chappe_sip_media:session(#{call_id => <<"room-party-2">>},
                                           #{capability => conference}),
    {ok, _} = chappe_sip_media:conference(Party, <<"r2">>, #{}),
    SP = ?UA:pick(),
    srs(SP, fun(_Sock, _D, _Src) -> ok end),
    {ok, Rec} = chappe_sip_siprec:start({room, <<"r2">>}, srs_uri(SP), #{}),
    {started, _} = event(Rec),
    ok = chappe_sip_media:stop(Party),
    {stopped, #{reason := room_ended}} = event(Rec),
    _ = got(srs_bye).

%% RFC 7866 12: a sips: recording server URI takes the RS over TLS, the
%% server's certificate checked against the CA; chappe answers it over
%% its TLS listener.
%% req: R7866-12-1
recording_over_tls(Config) ->
    chappe_sip_tls_SUITE:with_ca(Config, "siprec", fun(Dir) ->
        TP = chappe_sip_tls_SUITE:start_tls(Dir, #{}),
        EP = chappe_sip_tls_SUITE:engine_port(),
        ok = chappe_sip:handle(<<"INVITE">>, fun handler/2, #{option_tags => [<<"siprec">>]}),
        persistent_term:put(siprec_test_ep, EP),
        #{b2b := B2b, call_ref := Ref} = call(),
        {ok, Rec} = chappe_sip_siprec:start(
                      B2b, <<"sips:sink@127.0.0.1:", (integer_to_binary(TP))/binary>>, #{}),
        {started, #{call_ref := Ref}} = event(Rec),
        ?assertMatch(<<"SIP/2.0/TLS ", _/binary>>, got(srs_transport)),
        #{streams := [_, _]} = got(srs_served),
        ok = chappe_sip_siprec:stop(Rec),
        {stopped, _} = event(Rec)
    end).

%% A room that is not up is not made by its recording.
room_not_up(_Config) ->
    ok = chappe_sip_media:configure(#{mix => #{ip => {127, 0, 0, 1}}}),
    _ = start_app(),
    {ok, Rec} = chappe_sip_siprec:start({room, <<"nobody">>}, srs_uri(?UA:pick()), #{}),
    {stopped, #{reason := {error, no_room}}} = event(Rec),
    ?assertEqual({error, badarg}, chappe_sip_siprec:start({room, <<"a b">>}, srs_uri(1), #{})).

rtp(PT, Payload) ->
    rtp(PT, 1, Payload).

rtp(PT, Seq, Payload) ->
    <<2:2, 0:1, 0:1, 0:4, 0:1, PT:7, Seq:16, (Seq * 160):32, 16#1234:32, Payload/binary>>.

%% A recording client on the wire: the 200 carries +sip.srs (RFC 7866
%% 6.2) and answers each stream recvonly with its label (7.2); a stream in
%% a codec the server does not take is refused with port 0 (RFC 3264 6),
%% and the answer keeps every m-line (RFC 7866 8.3.1).
%% req: R7866-6.2-2 R7866-7.2-1 R7866-8.3.1-1
server_answers_on_the_wire(_Config) ->
    persistent_term:put(chappe_sip_test_store, self()),
    application:set_env(chappe_sip, siprec_store, chappe_sip_test_store),
    #{ep := EP} = call(),
    Sdp = <<"v=0\r\no=src 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n"
            "m=audio 30000 RTP/AVP 0\r\na=sendonly\r\na=label:1\r\n"
            "m=audio 30002 RTP/AVP 18\r\na=sendonly\r\na=label:2\r\n">>,
    {CT, Body} = chappe_sip_multipart:build([
        #{content_type => <<"application/sdp">>, body => Sdp},
        #{content_type => ?M:content_type(), disposition => ?M:disposition(),
          body => ?M:build(#{streams => [#{id => <<"s1">>, label => <<"1">>}]})}
    ]),
    ?UA:peer(0, fun(Sock) ->
        P = integer_to_binary(?UA:lport(Sock)),
        Inv0 = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(), from_tag => ?UA:tag(),
                                      ruri => <<"sip:store@127.0.0.1">>, body => Body,
                                      headers => [{<<"Require">>, <<"siprec">>}]}),
        Inv = binary:replace(
                binary:replace(Inv0, <<"Content-Type: application/sdp">>,
                               <<"Content-Type: ", CT/binary>>),
                <<"Contact: <sip:caller@127.0.0.1:", P/binary, ">">>,
                <<"Contact: <sip:caller@127.0.0.1:", P/binary, ">;+sip.src">>),
        ?UA:send(Sock, EP, Inv),
        R = ?UA:recv_status(Sock, 200),
        D = ?UA:dialog_from_2xx(Sock, Inv, R),
        ?UA:ack(D, EP),
        b2b_relay_tell({srs_200, R}),
        {Bye, _} = ?UA:in_dialog(D, <<"BYE">>, [], <<>>),
        receive bye -> ?UA:send(Sock, EP, Bye) end,
        timer:sleep(infinity)
    end),
    R = got(srs_200),
    ?assertMatch({_, _}, binary:match(?UA:hdr(R, <<"contact">>), <<";+sip.srs">>)),
    {_, [M1, M2]} = chappe_sip_sdp:sections(?UA:body(R)),
    ?assert(lists:member(<<"a=recvonly">>, M1)),
    ?assertEqual(<<"1">>, label(M1)),
    ?assertNotMatch(<<"m=audio 0 ", _/binary>>, hd(M1)),
    ?assertMatch(<<"m=audio 0 ", _/binary>>, hd(M2)),
    #{streams := [#{label := <<"1">>}]} = got(srs_served).

%% ---- the security of the recording session (RFC 7866 12) ----

%% A receiver takes RTP from the recording client only: the address its
%% SDP gave, latched to the first source there; another source, or a
%% stream whose client is elsewhere, is dropped.
server_latches_to_client(_Config) ->
    #{ep := EP} = call(),
    {ok, Src} = gen_udp:open(0, [binary, {ip, {127, 0, 0, 1}}]),
    {ok, Other} = gen_udp:open(0, [binary, {ip, {127, 0, 0, 1}}]),
    SP = integer_to_binary(?UA:lport(Src)),
    Sdp = <<"v=0\r\no=src 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n"
            "m=audio ", SP/binary, " RTP/AVP 0\r\na=sendonly\r\na=label:1\r\n"
            "m=audio 30002 RTP/AVP 0\r\nc=IN IP4 192.0.2.10\r\na=sendonly\r\na=label:2\r\n">>,
    R = wire_rs(EP, <<"sip:sink@127.0.0.1">>, Sdp),
    ?assertEqual(200, ?UA:status(R)),
    #{streams := [#{pid := S1, port := P1}, #{pid := S2, port := P2}]} = got(srs_served),
    Frame = rtp(0, binary:copy(<<16#FF>>, 160)),
    ok = gen_udp:send(Src, {127, 0, 0, 1}, P1, Frame),
    receive {chappe_sip_siprec_rtp, S1, {audio, _}} -> ok after 2000 -> ct:fail(no_audio) end,
    ok = gen_udp:send(Other, {127, 0, 0, 1}, P1, Frame),
    ok = gen_udp:send(Src, {127, 0, 0, 1}, P2, Frame),
    receive {chappe_sip_siprec_rtp, S, {audio, _}} when S =:= S1; S =:= S2 ->
        ct:fail({spoofed, S})
    after 500 -> ok
    end,
    ok = gen_udp:send(Src, {127, 0, 0, 1}, P1, Frame),
    receive {chappe_sip_siprec_rtp, S1, {audio, _}} -> ok after 2000 -> ct:fail(no_audio) end,
    gen_udp:close(Src),
    gen_udp:close(Other).

%% RFC 7866 12.2, RFC 4568 7.1.2: a stream offered as RTP/SAVP or
%% RTP/SAVPF is answered in its profile with the first a=crypto line the
%% server can take (its tag and suite, a key of its own), and its SRTP is
%% decrypted to the sink. A forged packet (another key) is dropped and
%% does not latch the stream, a replayed one is dropped, both counted; an
%% SRTCP packet on the port authenticates and is dropped. DTLS-SRTP is
%% answered port 0. The stream's status shows no key.
%% req: R7866-12.2-1 R7866-12.2-2 R4568-5.1.2-1 R4568-5.1.2-3 R4568-7.1.2-1
%% req: R3711-3.3-1 R3711-3.3-2 R3711-3.3.2-2 R3711-3.4-1 R3711-4.3-1 R4568-6.4.1-1
server_takes_srtp(_Config) ->
    #{ep := EP} = call(),
    {ok, Src} = gen_udp:open(0, [binary, {ip, {127, 0, 0, 1}}]),
    {ok, Other} = gen_udp:open(0, [binary, {ip, {127, 0, 0, 1}}]),
    SP = integer_to_binary(?UA:lport(Src)),
    Master = ?SRTP:master(),
    M2 = ?SRTP:master(),
    Sdp = <<"v=0\r\no=src 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n"
            "m=audio ", SP/binary, " RTP/SAVP 0\r\n",
            (crypto_line(<<"1 F8_128_HMAC_SHA1_80">>, ?SRTP:master()))/binary,
            (crypto_line(<<"2 AES_CM_128_HMAC_SHA1_80">>, Master))/binary,
            "a=sendonly\r\na=label:1\r\n"
            "m=audio 30002 RTP/SAVPF 0\r\n",
            (crypto_line(<<"5 AES_CM_128_HMAC_SHA1_32">>, M2))/binary,
            "a=sendonly\r\na=label:2\r\n"
            "m=audio 30004 UDP/TLS/RTP/SAVP 0\r\na=fingerprint:sha-256 AB:CD\r\n"
            "a=sendonly\r\na=label:3\r\n">>,
    R = wire_rs(EP, <<"sip:sink@127.0.0.1">>, Sdp),
    ?assertEqual(200, ?UA:status(R)),
    {_, [A1, A2, A3]} = chappe_sip_sdp:sections(?UA:body(R)),
    ?assertMatch(<<"m=audio ", _/binary>>, hd(A1)),
    ?assertNotMatch(<<"m=audio 0 ", _/binary>>, hd(A1)),
    ?assertMatch({_, _}, binary:match(hd(A1), <<" RTP/SAVP 0">>)),
    [<<"2 AES_CM_128_HMAC_SHA1_80 inline:", K1/binary>>] = [C || <<"a=crypto:", C/binary>> <- A1],
    ?assertNotEqual(?SRTP:inline(Master), K1),
    ?assertMatch({_, _}, binary:match(hd(A2), <<" RTP/SAVPF 0">>)),
    ?assertMatch([<<"5 AES_CM_128_HMAC_SHA1_32 inline:", _/binary>>],
                 [C || <<"a=crypto:", C/binary>> <- A2]),
    ?assertMatch(<<"m=audio 0 UDP/TLS/RTP/SAVP", _/binary>>, hd(A3)),
    #{streams := [#{pid := S1, port := P1, profile := <<"RTP/SAVP">>},
                  #{profile := <<"RTP/SAVPF">>}]} = got(srs_served),
    Snd = ?SRTP:sender(Master),
    Payload = binary:copy(<<16#20>>, 160),
    Pkt = fun(Seq) -> ?SRTP:protect(rtp(0, Seq, Payload), 0, Snd) end,
    %% a forged packet from another port of the client's address first
    ok = gen_udp:send(Other, {127, 0, 0, 1}, P1,
                      ?SRTP:protect(rtp(0, 1, Payload), 0, ?SRTP:sender(?SRTP:master()))),
    ok = gen_udp:send(Src, {127, 0, 0, 1}, P1, Pkt(2)),
    Pcm = chappe_sip_siprec_rtp:decode(ulaw, Payload),
    receive {chappe_sip_siprec_rtp, S1, {audio, Got}} -> ?assertEqual(Pcm, Got)
    after 2000 -> ct:fail(no_audio)
    end,
    %% replayed, then SRTCP: neither reaches the sink
    ok = gen_udp:send(Src, {127, 0, 0, 1}, P1, Pkt(2)),
    Rtcp = <<2:2, 0:1, 0:5, 201:8, 1:16, 16#1234:32>>,
    ok = gen_udp:send(Src, {127, 0, 0, 1}, P1, ?SRTP:protect_rtcp(Rtcp, 0, Snd)),
    ok = gen_udp:send(Src, {127, 0, 0, 1}, P1, Pkt(3)),
    receive {chappe_sip_siprec_rtp, S1, {audio, _}} -> ok after 2000 -> ct:fail(no_audio) end,
    receive {chappe_sip_siprec_rtp, S1, {audio, _}} -> ct:fail(replayed_heard)
    after 300 -> ok
    end,
    ?assertEqual(#{packets => 2, failed => 1, replayed => 1}, chappe_sip_siprec_rtp:stats(S1)),
    %% no key in the stream's status
    Status = iolist_to_binary(io_lib:format("~p", [sys:get_status(S1)])),
    Keys = [B || {_, B} <- maps:to_list(Snd), is_binary(B), byte_size(B) >= 14],
    [?assertEqual(nomatch, binary:match(Status, octets(B))) || B <- [Master | Keys]],
    gen_udp:close(Src),
    gen_udp:close(Other).

%% A secure stream with no line the server takes (F8, several keys, a key
%% derivation rate, no a=crypto at all) is refused with port 0, and an
%% offer left with no stream is refused 488 with Warning 302 (RFC 3261
%% 20.43). By default SDES keys offered over UDP are refused the same way (RFC 4568 8.3, 7.1.2: the stream is rejected; RFC 3261 21.4.26: 488).
%% req: R4568-5.1.2-2 R4568-6.1-2 R4568-6.3.7-1 R4568-8.3-1
server_refuses_srtp_it_cannot_take(_Config) ->
    #{ep := EP} = call(),
    K = ?SRTP:inline(?SRTP:master()),
    Head = <<"v=0\r\no=src 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n">>,
    Only = <<Head/binary, "m=audio 30000 RTP/SAVP 0\r\n"
             "a=crypto:1 F8_128_HMAC_SHA1_80 inline:", K/binary, "\r\n"
             "a=crypto:2 AES_CM_128_HMAC_SHA1_80 inline:", K/binary, " KDR=4\r\n"
             "a=crypto:3 AES_CM_128_HMAC_SHA1_80 inline:", K/binary, "|2^20|1:4;inline:", K/binary,
             "|2^20|2:4\r\n"
             "a=crypto:4 AES_CM_128_HMAC_SHA1_80 inline:", (base64:encode(<<1:200>>))/binary, "\r\n"
             "a=crypto:5 AES_CM_128_HMAC_SHA1_80 inline:", K/binary, " NEW_PARAM\r\n"
             "a=sendonly\r\na=label:1\r\n">>,
    R1 = wire_rs(EP, <<"sip:sink@127.0.0.1">>, Only),
    ?assertEqual(488, ?UA:status(R1)),
    ?assertMatch(<<"302 ", _/binary>>, ?UA:hdr(R1, <<"warning">>)),
    ?assertEqual({error, srtp}, got(srs_served)),
    Mixed = <<Head/binary, "m=audio 30000 RTP/SAVP 0\r\na=sendonly\r\na=label:1\r\n"
              "m=audio 30002 RTP/AVP 0\r\na=sendonly\r\na=label:2\r\n">>,
    R2 = wire_rs(EP, <<"sip:sink@127.0.0.1">>, Mixed),
    ?assertEqual(200, ?UA:status(R2)),
    {_, [M1, M2]} = chappe_sip_sdp:sections(?UA:body(R2)),
    ?assertMatch(<<"m=audio 0 RTP/SAVP", _/binary>>, hd(M1)),
    ?assertNotMatch(<<"m=audio 0 ", _/binary>>, hd(M2)),
    #{streams := [#{label := <<"2">>}]} = got(srs_served),
    Good = <<Head/binary, "m=audio 30000 RTP/SAVP 0\r\n"
             "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:", K/binary, "\r\n"
             "a=sendonly\r\na=label:1\r\n">>,
    R3 = wire_rs(EP, <<"sip:tlskeys@127.0.0.1">>, Good),
    ?assertEqual(488, ?UA:status(R3)),
    ?assertEqual({error, srtp}, got(srs_served)).

%% RFC 4568 7.1.4, RFC 3711 3.3.1: a re-INVITE with a new key gives the
%% stream the new one (the answer echoes its tag, at a new o= version);
%% the stream's index and replay list carry on, and the old key no longer
%% authenticates.
%% req: R3711-3.3.1-1 R3711-3.3.1-2
server_srtp_rekey(_Config) ->
    #{ep := EP} = call(),
    {ok, Src} = gen_udp:open(0, [binary, {ip, {127, 0, 0, 1}}]),
    SP = integer_to_binary(?UA:lport(Src)),
    Old = ?SRTP:master(),
    New = ?SRTP:master(),
    Sdp = fun(Tag, M) ->
              <<"v=0\r\no=src 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n"
                "m=audio ", SP/binary, " RTP/SAVP 0\r\n",
                (crypto_line(<<Tag/binary, " AES_CM_128_HMAC_SHA1_80">>, M))/binary,
                "a=sendonly\r\na=label:1\r\n">>
          end,
    {R, Peer} = wire_rs_session(EP, <<"sip:sink@127.0.0.1">>, Sdp(<<"1">>, Old)),
    ?assertEqual(200, ?UA:status(R)),
    #{streams := [#{pid := S1, port := P1}]} = got(srs_served),
    Send = fun(M, Seq) ->
               gen_udp:send(Src, {127, 0, 0, 1}, P1,
                            ?SRTP:protect(rtp(0, Seq, <<0:1280>>), 0, ?SRTP:sender(M)))
           end,
    ok = Send(Old, 10),
    receive {chappe_sip_siprec_rtp, S1, {audio, _}} -> ok after 2000 -> ct:fail(no_audio) end,
    Peer ! {reinvite, Sdp(<<"7">>, New)},
    R2 = got(wire_reinvite),
    ?assertEqual(200, ?UA:status(R2)),
    ?assertMatch({_, _}, binary:match(?UA:body(R2), <<"o=chappe 1 2 ">>)),
    ?assertMatch({_, _}, binary:match(?UA:body(R2), <<"a=crypto:7 AES_CM_128_HMAC_SHA1_80 inline:">>)),
    ok = Send(Old, 11),
    ok = Send(New, 10),
    ok = Send(New, 12),
    receive {chappe_sip_siprec_rtp, S1, {audio, _}} -> ok after 2000 -> ct:fail(no_audio) end,
    receive {chappe_sip_siprec_rtp, S1, {audio, _}} -> ct:fail(old_key_heard) after 300 -> ok end,
    ?assertEqual(#{packets => 2, failed => 1, replayed => 1}, chappe_sip_siprec_rtp:stats(S1)),
    %% the same key again changes nothing
    Peer ! {reinvite, Sdp(<<"7">>, New)},
    R3 = got(wire_reinvite),
    ?assertMatch({_, _}, binary:match(?UA:body(R3), <<"o=chappe 1 2 ">>)),
    gen_udp:close(Src).

%% RFC 4568 6.1: a key's lifetime is kept; past it, packets are dropped.
%% req: R4568-6.1-1
server_srtp_lifetime(_Config) ->
    #{ep := EP} = call(),
    {ok, Src} = gen_udp:open(0, [binary, {ip, {127, 0, 0, 1}}]),
    SP = integer_to_binary(?UA:lport(Src)),
    Master = ?SRTP:master(),
    Sdp = <<"v=0\r\no=src 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n"
            "m=audio ", SP/binary, " RTP/SAVP 0\r\n"
            "a=crypto:1 AES_CM_128_HMAC_SHA1_32 inline:", (?SRTP:inline(Master))/binary,
            "|2^1|3:1\r\na=sendonly\r\na=label:1\r\n">>,
    ?assertEqual(200, ?UA:status(wire_rs(EP, <<"sip:sink@127.0.0.1">>, Sdp))),
    #{streams := [#{pid := S1, port := P1}]} = got(srs_served),
    Snd = ?SRTP:sender(Master, #{tag => 4, mki => <<3>>}),
    [ok = gen_udp:send(Src, {127, 0, 0, 1}, P1, ?SRTP:protect(rtp(0, Seq, <<0:1280>>), 0, Snd))
     || Seq <- [1, 2, 3]],
    [receive {chappe_sip_siprec_rtp, S1, {audio, _}} -> ok after 2000 -> ct:fail(no_audio) end
     || _ <- [1, 2]],
    ?assertEqual(#{packets => 2, failed => 1, replayed => 0}, wait_stats(S1)),
    gen_udp:close(Src).

%% A flood of forged packets costs one log line per window and no memory:
%% each is counted and dropped.
server_srtp_flood(_Config) ->
    #{ep := EP} = call(),
    {ok, Src} = gen_udp:open(0, [binary, {ip, {127, 0, 0, 1}}]),
    SP = integer_to_binary(?UA:lport(Src)),
    Sdp = <<"v=0\r\no=src 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n"
            "m=audio ", SP/binary, " RTP/SAVP 0\r\n",
            (crypto_line(<<"1 AES_CM_128_HMAC_SHA1_80">>, ?SRTP:master()))/binary,
            "a=sendonly\r\na=label:1\r\n">>,
    ?assertEqual(200, ?UA:status(wire_rs(EP, <<"sip:sink@127.0.0.1">>, Sdp))),
    #{streams := [#{pid := S1, port := P1}]} = got(srs_served),
    ok = logger:add_handler(t_srtp_log, ?MODULE, #{config => #{pid => self()}}),
    try
        Forger = ?SRTP:sender(?SRTP:master()),
        _ = sys:get_state(S1),
        {memory, Before} = process_info(S1, memory),
        lists:foreach(
          fun(Seq) ->
              ok = gen_udp:send(Src, {127, 0, 0, 1}, P1,
                                ?SRTP:protect(rtp(0, Seq, <<0:1280>>), 0, Forger)),
              Seq rem 100 =:= 0 andalso timer:sleep(5)
          end, lists:seq(1, 1000)),
        #{packets := 0, failed := F} = wait_stats(S1),
        ?assert(F >= 900),
        garbage_collect(S1),
        {memory, After} = process_info(S1, memory),
        ct:log("stream memory ~p -> ~p", [Before, After]),
        ?assert(After < Before + 64 * 1024),
        timer:sleep(200),
        Logs = log_lines(),
        ?assertMatch([#{what := siprec_srtp_dropped, dropped := 1}], Logs)
    after
        logger:remove_handler(t_srtp_log)
    end,
    gen_udp:close(Src).

%% the stream's counters once they stop moving
wait_stats(S) ->
    wait_stats(S, chappe_sip_siprec_rtp:stats(S)).

wait_stats(S, Last) ->
    timer:sleep(200),
    case chappe_sip_siprec_rtp:stats(S) of
        Last -> Last;
        Now -> wait_stats(S, Now)
    end.

%% logger handler: the SRTP drop reports, to the test
log(#{msg := {report, #{what := siprec_srtp_dropped} = R}}, #{config := #{pid := Pid}}) ->
    Pid ! {srtp_log, R};
log(_Event, _Config) ->
    ok.

log_lines() ->
    receive {srtp_log, R} -> [R | log_lines()] after 0 -> [] end.

crypto_line(TagSuite, Master) ->
    <<"a=crypto:", TagSuite/binary, " inline:", (?SRTP:inline(Master))/binary, "\r\n">>.

%% how ~p prints the first octets of a binary
octets(<<A, B, C, D, _/binary>>) ->
    iolist_to_binary(io_lib:format("~b,~b,~b,~b", [A, B, C, D])).

%% The anchor keeps each leg's profile: an SRTP caller (RTP/SAVP) is
%% answered RTP/SAVP, never downgraded to RTP/AVP, while the offer to a
%% callee nobody heard from yet stays RTP/AVP; a plain caller stays plain.
anchor_keeps_srtp_caller(_Config) ->
    Proto = fun(Cmds, Name) ->
                [maps:get(<<"transport-protocol">>, C, none)
                 || {rtpe_cmd, #{<<"command">> := N} = C} <- Cmds, N =:= Name]
            end,
    _ = call(#{media => anchor, savp => true}),
    Cmds = drain(),
    ?assertEqual([<<"RTP/AVP">>], Proto(Cmds, <<"offer">>)),
    ?assertEqual([<<"RTP/SAVP">>], Proto(Cmds, <<"answer">>)),
    _ = call(#{media => anchor}),
    Plain = drain(),
    ?assertEqual([<<"RTP/AVP">>], Proto(Plain, <<"answer">>)).

%% RFC 7866 12, 12.2: a call with an SRTP leg is recorded as SRTP: every
%% tap, the plain party's too, is asked of rtpengine as RTP/SAVP (with its
%% own keys); allow_downgrade => true records it as the parties send.
%% req: R7866-12-1
srtp_call_tapped_as_srtp(_Config) ->
    #{b2b := B2b} = call(#{media => anchor, savp => true}),
    _ = drain(),
    SP = ?UA:pick(),
    srs(SP, fun(_Sock, _D, _Src) -> ok end),
    {ok, Rec} = chappe_sip_siprec:start(B2b, srs_uri(SP), #{}),
    {started, _} = event(Rec),
    Subs = [C || {rtpe_cmd, #{<<"command">> := <<"subscribe request">>} = C} <- drain()],
    ?assertEqual(2, length(Subs)),
    ?assert(lists:all(fun(C) -> maps:get(<<"transport-protocol">>, C, none) =:= <<"RTP/SAVP">> end,
                      Subs)),
    ok = chappe_sip_siprec:stop(Rec),
    {stopped, _} = event(Rec),
    SP2 = ?UA:pick(),
    srs(SP2, fun(_Sock, _D, _Src) -> ok end),
    {ok, Rec2} = chappe_sip_siprec:start(B2b, srs_uri(SP2), #{allow_downgrade => true}),
    {started, _} = event(Rec2),
    Subs2 = [C || {rtpe_cmd, #{<<"command">> := <<"subscribe request">>} = C} <- drain()],
    ?assertEqual(2, length(Subs2)),
    ?assertNot(lists:any(fun(C) -> maps:is_key(<<"transport-protocol">>, C) end, Subs2)),
    ok = chappe_sip_siprec:stop(Rec2).

%% RFC 7866 12: a call signalled over TLS (its leg A's dialog has our sips
%% Contact) is not recorded to a plain sip SRS; to a sips one it is, and
%% allow_downgrade => true lets the app choose the plain one.
%% req: R7866-12-1
tls_call_needs_tls_srs(Config) ->
    chappe_sip_tls_SUITE:with_ca(Config, "siprecsec", fun(Dir) ->
        TP = chappe_sip_tls_SUITE:start_tls(Dir, #{}),
        EP = chappe_sip_tls_SUITE:engine_port(),
        ok = chappe_sip:handle(<<"INVITE">>, fun handler/2, #{option_tags => [<<"siprec">>]}),
        persistent_term:put(siprec_test_ep, EP),
        #{b2b := B2b} = call(#{media => anchor, ruri => <<"sips:app@127.0.0.1">>}),
        Plain = <<"sip:sink@127.0.0.1:", (integer_to_binary(EP))/binary>>,
        ?assertEqual({error, {insecure_srs, tls}}, chappe_sip_siprec:start(B2b, Plain, #{})),
        {ok, Rec} = chappe_sip_siprec:start(
                      B2b, <<"sips:sink@127.0.0.1:", (integer_to_binary(TP))/binary>>, #{}),
        {started, _} = event(Rec),
        ok = chappe_sip_siprec:stop(Rec),
        {stopped, _} = event(Rec),
        {ok, Rec2} = chappe_sip_siprec:start(B2b, Plain, #{allow_downgrade => true}),
        {started, _} = event(Rec2),
        ok = chappe_sip_siprec:stop(Rec2)
    end).

%% ---- helpers ----

%% the caller's offer as SRTP
savp(Inv) ->
    Crypto = <<"a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:WVNfX19zZW1jdGwgKCkgewkyMjA7fQp9CnVubGVz\r\n">>,
    [Head, Sdp0] = binary:split(Inv, <<"\r\n\r\n">>),
    Sdp = <<(binary:replace(Sdp0, <<" RTP/AVP ">>, <<" RTP/SAVP ">>))/binary, Crypto/binary>>,
    Len = integer_to_binary(byte_size(Sdp)),
    Head1 = re:replace(Head, <<"Content-Length: *[0-9]+">>, <<"Content-Length: ", Len/binary>>,
                       [{return, binary}, caseless]),
    <<Head1/binary, "\r\n\r\n", Sdp/binary>>.

%% the RS body of an SDP: multipart with an empty metadata snapshot
rs_body(Sdp) ->
    chappe_sip_multipart:build([
        #{content_type => <<"application/sdp">>, body => Sdp},
        #{content_type => ?M:content_type(), disposition => ?M:disposition(),
          body => ?M:build(#{})}
    ]).

%% a recording client on the wire whose session stays up: {200, Peer};
%% Peer ! {reinvite, Sdp} re-INVITEs and tells {wire_reinvite, Response}
wire_rs_session(EP, Ruri, Sdp) ->
    {CT, Body} = rs_body(Sdp),
    Test = self(),
    Peer = ?UA:peer(0, fun(Sock) ->
        P = integer_to_binary(?UA:lport(Sock)),
        Inv0 = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(), from_tag => ?UA:tag(),
                                      ruri => Ruri, body => Body,
                                      headers => [{<<"Require">>, <<"siprec">>}]}),
        Inv = binary:replace(
                binary:replace(Inv0, <<"Content-Type: application/sdp">>,
                               <<"Content-Type: ", CT/binary>>),
                <<"Contact: <sip:caller@127.0.0.1:", P/binary, ">">>,
                <<"Contact: <sip:caller@127.0.0.1:", P/binary, ">;+sip.src">>),
        ?UA:send(Sock, EP, Inv),
        R = ?UA:recv_status(Sock, 200),
        D = ?UA:dialog_from_2xx(Sock, Inv, R),
        ?UA:ack(D, EP),
        Test ! {wire_rs, R},
        rs_session(Sock, EP, D, Test)
    end),
    {got(wire_rs), Peer}.

rs_session(Sock, EP, D, Test) ->
    receive
        {reinvite, Sdp} ->
            {CT, Body} = rs_body(Sdp),
            {Re0, D1} = ?UA:in_dialog(D, <<"INVITE">>, [{<<"Require">>, <<"siprec">>}], Body),
            Re = binary:replace(Re0, <<"Content-Type: application/sdp">>,
                                <<"Content-Type: ", CT/binary>>),
            ?UA:send(Sock, EP, Re),
            R = ?UA:recv_status(Sock, 200),
            ?UA:ack(D1, EP),
            Test ! {wire_reinvite, R},
            rs_session(Sock, EP, D1, Test)
    end.

%% a recording client on the wire: an RS INVITE of Sdp to Ruri, its final
%% response (ACKed and left up when a 2xx)
wire_rs(EP, Ruri, Sdp) ->
    {CT, Body} = rs_body(Sdp),
    ?UA:peer(0, fun(Sock) ->
        P = integer_to_binary(?UA:lport(Sock)),
        Inv0 = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(), from_tag => ?UA:tag(),
                                      ruri => Ruri, body => Body,
                                      headers => [{<<"Require">>, <<"siprec">>}]}),
        Inv = binary:replace(
                binary:replace(Inv0, <<"Content-Type: application/sdp">>,
                               <<"Content-Type: ", CT/binary>>),
                <<"Contact: <sip:caller@127.0.0.1:", P/binary, ">">>,
                <<"Contact: <sip:caller@127.0.0.1:", P/binary, ">;+sip.src">>),
        ?UA:send(Sock, EP, Inv),
        R = ?UA:recv_any(Sock, 6000),
        case ?UA:status(R) of
            200 -> ?UA:ack(?UA:dialog_from_2xx(Sock, Inv, R), EP);
            _ -> ok
        end,
        b2b_relay_tell({wire_rs, R}),
        timer:sleep(infinity)
    end),
    got(wire_rs).

srs_uri(SP) -> <<"sip:srs@127.0.0.1:", (integer_to_binary(SP))/binary>>.

%% An anchored call from a caller peer to a callee peer through the app;
%% the INVITE to sip:srs@ (chappe as recording server) goes to srs/2.
call() -> call(#{media => anchor}).

call(Opts) ->
    case whereis(siprec_test_rtpe) of
        undefined -> register(siprec_test_rtpe, chappe_sip_test_rtpe:start(self()));
        _ -> ok
    end,
    EP = case persistent_term:get(siprec_test_ep, undefined) of
             undefined -> start_app();
             P -> P
         end,
    CP = ?UA:pick(),
    Test = self(),
    persistent_term:put(siprec_test_opts, Opts#{test => Test, cp => CP}),
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Tag = <<"btag">>,
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag, [contact(Sock)],
                                     ?UA:sdp(<<"callee">>))),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        D = ?UA:dialog_from_invite(Sock, Inv, Tag, Src),
        callee_loop(Sock, D)
    end),
    Caller = ?UA:peer(0, fun(Sock) ->
        Inv0 = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(), from_tag => <<"atag">>,
                                      ruri => maps:get(ruri, Opts, <<"sip:app@127.0.0.1">>)}),
        Inv = case Opts of
                  #{savp := true} -> savp(Inv0);
                  _ -> Inv0
              end,
        ?UA:send(Sock, EP, Inv),
        R = ?UA:recv_status(Sock, 200),
        D = ?UA:dialog_from_2xx(Sock, Inv, R),
        ?UA:ack(D, EP),
        receive bye ->
            {Bye, _} = ?UA:in_dialog(D, <<"BYE">>, [], <<>>),
            ?UA:send(Sock, EP, Bye),
            timer:sleep(infinity)
        end
    end),
    #{b2b := B2b, call_ref := Ref} = got(legs),
    #{b2b => B2b, call_ref => Ref, ep => EP, cp => CP, caller => Caller}.

callee_loop(Sock, D) ->
    receive
        {udp, Sock, _, Src, <<"BYE ", _/binary>> = Bye} ->
            ?UA:send(Sock, Src, ?UA:resp(Bye, 200, <<"OK">>, <<>>, [], <<>>)),
            callee_loop(Sock, D);
        {udp, Sock, _, Src, <<"INVITE ", _/binary>> = Re} ->
            ?UA:send(Sock, Src, ?UA:resp(Re, 200, <<"OK">>, <<>>, [contact(Sock)],
                                         ?UA:sdp(<<"callee">>, <<"2">>))),
            callee_loop(Sock, D);
        _ ->
            callee_loop(Sock, D)
    end.

start_app() ->
    EP = ?UA:pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>}),
    ok = chappe_sip:handle(<<"INVITE">>, fun handler/2, #{option_tags => [<<"siprec">>]}),
    persistent_term:put(siprec_test_ep, EP),
    EP.

handler(Req, Res) ->
    #{test := Test, cp := CP} = Opts = persistent_term:get(siprec_test_opts),
    case chappe_sip_req:uri(Req) of
        <<"sip:srs@", _/binary>> ->
            recording_server(Test, Req, Res);
        <<"sip:store@", _/binary>> ->
            served(Test, Req, Res, #{store => default});
        <<"sips:sink@", _/binary>> ->
            Test ! {srs_transport, chappe_sip_req:get(<<"via">>, Req)},
            served(Test, Req, Res, #{sink => Test});
        <<"sip:tlskeys@", _/binary>> ->
            %% the default: SDES keys only over TLS (RFC 4568 8.3)
            served(Test, Req, Res, #{sink => Test});
        <<"sip:sink@", _/binary>> ->
            %% the plain UDP recording client of these cases
            served(Test, Req, Res, #{sink => Test, keys_over_tls => false,
                                     max_queue => persistent_term:get(siprec_test_sink_queue, 500)});
        _ ->
            Callee = <<"sip:callee@127.0.0.1:", (integer_to_binary(CP))/binary>>,
            {ok, Legs} = chappe_sip:create_b2bua(Req, Res, Callee,
                                                 maps:without([test, cp, ruri, savp], Opts)),
            Test ! {legs, Legs},
            chappe_sip_b2b:relay(Legs)
    end.

%% chappe_sip_siprec_srs in the handler: it waits on the dialog, so the
%% streams live as long as the session
served(Test, Req, Res, Opts) ->
    case chappe_sip_siprec_srs:serve(Req, Res, Opts) of
        {ok, Srs} ->
            Test ! {srs_served, Srs},
            chappe_sip_siprec_srs:run(Srs);
        {error, not_recording_session} = E ->
            Test ! {srs_served, E},
            chappe_sip_res:send(Res, 403);
        {error, _} = E ->
            Test ! {srs_served, E}
    end.

%% chappe as the recording server: a route that takes siprec
recording_server(Test, Req, Res) ->
    {ok, Parts} = chappe_sip_multipart:parse(chappe_sip_req:get(<<"content-type">>, Req),
                                             chappe_sip_req:body(Req)),
    {ok, #{body := Sdp}} = chappe_sip_multipart:find(<<"application/sdp">>, Parts),
    [#{body := Xml}] = [P || #{content_type := CT} = P <- Parts, ?M:is_content_type(CT)],
    {ok, Doc} = ?M:parse(Xml),
    Test ! {srs_doc, {Doc, chappe_sip_req:get(<<"contact">>, Req)}},
    {_, Media} = chappe_sip_sdp:sections(Sdp),
    {ok, D} = chappe_sip:create_uas(Req, Res, #{local_sdp => answer_sdp(length(Media), <<"recvonly">>)}),
    case chappe_sip_dialog:wait(D) of
        {destroyed, Why} -> Test ! {srs_destroy, destroyed(Why)}
    end.

destroyed(Why) when is_atom(Why) -> Why;
destroyed(Req) -> #{method => chappe_sip_req:method(Req)}.

%% A recording server peer on SP: answers the INVITE with every stream
%% recvonly, then runs Fun(Sock, Dialog, Src), then answers BYE.
srs(SP, Fun) ->
    Test = self(),
    ?UA:peer(SP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Test ! {srs_invite, Inv},
        Tag = ?UA:tag(),
        {Sdp, _} = parts(Inv),
        {_, Media} = chappe_sip_sdp:sections(Sdp),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag, [contact(Sock)],
                                     answer_sdp(length(Media), <<"recvonly">>))),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        Fun(Sock, ?UA:dialog_from_invite(Sock, Inv, Tag, Src), Src),
        srs_bye(Sock, Test)
    end).

srs_bye(Sock, Test) ->
    receive
        {udp, Sock, _, Src, <<"BYE ", _/binary>> = Bye} ->
            ?UA:send(Sock, Src, ?UA:resp(Bye, 200, <<"OK">>, <<>>, [], <<>>)),
            Test ! {srs_bye, Bye};
        {udp, Sock, _, Src, <<"INVITE ", _/binary>> = Re} ->
            %% a re-INVITE nobody waits for: answered all the same
            {Sdp, _} = parts(Re),
            {_, Media} = chappe_sip_sdp:sections(Sdp),
            ?UA:send(Sock, Src, ?UA:resp(Re, 200, <<"OK">>, <<>>, [contact(Sock)],
                                         answer_sdp(length(Media), <<"recvonly">>))),
            srs_bye(Sock, Test);
        _ ->
            srs_bye(Sock, Test)
    after 20000 ->
        ok
    end.

%% the SRS answers N re-INVITEs and tells the test each one
reinvites(_Sock, 0) ->
    ok;
reinvites(Sock, N) ->
    {Re, Src} = ?UA:recv_req(Sock, <<"INVITE">>, 10000),
    {Sdp, _} = parts(Re),
    {_, Media} = chappe_sip_sdp:sections(Sdp),
    ?UA:send(Sock, Src, ?UA:resp(Re, 200, <<"OK">>, <<>>, [contact(Sock)],
                                 answer_sdp(length(Media), <<"recvonly">>))),
    {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
    b2b_relay_tell({srs_reinvite, {Re, Src}}),
    reinvites(Sock, N - 1).

b2b_relay_tell(Msg) ->
    #{test := Test} = persistent_term:get(siprec_test_opts),
    Test ! Msg.

answer_sdp(N, Dir) ->
    iolist_to_binary([
        <<"v=0\r\no=srs 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n">>,
        [[<<"m=audio ">>, integer_to_binary(41000 + 2 * I), <<" RTP/AVP 0\r\na=">>, Dir,
          <<"\r\na=label:">>, integer_to_binary(I), <<"\r\n">>]
         || I <- lists:seq(1, N)]
    ]).

%% the SDP and the parsed metadata of a recording session request
parts(Req) ->
    {ok, Parts} = chappe_sip_multipart:parse(?UA:hdr(Req, <<"content-type">>), ?UA:body(Req)),
    {ok, #{body := Sdp}} = chappe_sip_multipart:find(<<"application/sdp">>, Parts),
    [#{body := Xml, disposition := <<"recording-session">>}] =
        [P || #{content_type := CT} = P <- Parts, ?M:is_content_type(CT)],
    {ok, Doc} = ?M:parse(Xml),
    {Sdp, Doc}.

label(Section) ->
    hd([L || <<"a=label:", L/binary>> <- Section]).

contact(Sock) ->
    {<<"Contact">>, <<"<sip:peer@127.0.0.1:", (integer_to_binary(?UA:lport(Sock)))/binary, ">">>}.

event(Rec) ->
    receive {chappe_sip_siprec, Rec, Ev} -> Ev after 10000 -> ct:fail(no_event) end.

got(Tag) ->
    receive {Tag, V} -> V after 10000 -> ct:fail({missing, Tag}) end.

got3(Tag) ->
    receive {Tag, A, B, C} -> {A, B, C} after 10000 -> ct:fail({missing, Tag}) end.

drain() ->
    receive {rtpe_cmd, _} = C -> [C | drain()] after 300 -> [] end.

