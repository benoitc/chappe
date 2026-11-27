%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% HD conferences against the real lab (make interop-mrf): pjsua callers
%% on G.722, Opus and PCMU (apps/chappe_sip/interop/pjsua/hd.sh) in a
%% native 16 kHz room (chappe_mix on L16 behind rtpengine 26.3), and the
%% same calls in a FreeSWITCH room on its 16 kHz `wideband' profile, the
%% reference. Each HD caller plays the 16 kHz band probe for half of the
%% call (A the first half, B the second) and records what it hears; the
%% band check (chappe_mix_test_tone:band_check/3) judges each direction.
%% A PCMU caller joins in the middle, silent, and leaves: the HD pair
%% keeps its band while it is in, and it hears both probes, cut to the
%% narrow band. A FreeSWITCH endpoint joins a native 16 kHz room too, and
%% keeps the band both ways. A REFER to a native 16 kHz room's URI brings
%% in a G.722 callee through the dial-out path, which keeps the band both
%% ways once it answered, and a PCMU-only callee, which answers only
%% because the room offers it G.711 too. The setup is
%% chappe_mrf_live_SUITE's.
%% Skipped unless MRF=1 (apps/chappe_mrf/test/e2e.sh) and docker runs.
%% MRF_PJSUA_NAME (chappe-hd) prefixes the pjsua container names.
-module(chappe_mrf_hd_live_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([native_hd_room/1, native_hd_endpoint/1, fs_wideband_room/1]).
-export([refer_hd_dial_out/1, refer_pcmu_dial_out/1]).

-define(LIVE, chappe_mrf_live_SUITE).

-define(RATE, 16000).

all() ->
    [
        native_hd_room,
        native_hd_endpoint,
        fs_wideband_room,
        refer_hd_dial_out,
        refer_pcmu_dial_out
    ].

init_per_suite(Config) ->
    case os:find_executable("docker") of
        false ->
            {skip, "no docker for the pjsua callers"};
        _ ->
            case ?LIVE:init_per_suite(Config) of
                {skip, _} = Skip -> Skip;
                Config1 -> [{hd_sh, hd_sh()}, {image, pjsua_image()} | Config1]
            end
    end.

%% The pjsua of this checkout, built once before the first call. It is
%% `chappe-conf-pjsua', shared with the conformance lab: lab_image.sh
%% labels the image with the key of the Dockerfile's directory and
%% rebuilds one another checkout made (one without Opus, say), so no
%% tag of its own is needed.
pjsua_image() ->
    LabImage = filename:join([root(), "scripts", "lab_image.sh"]),
    Out = os:cmd(LabImage ++ " pjsua 2>&1"),
    ct:log("pjsua image: ~s", [Out]),
    "chappe-conf-pjsua".

end_per_suite(Config) ->
    ?LIVE:end_per_suite(Config).

init_per_testcase(Case, Config) ->
    ?LIVE:init_per_testcase(Case, Config).

end_per_testcase(Case, Config) ->
    %% native_hd_endpoint's trace, if it failed before stopping it
    _ = dbg:stop(),
    ?LIVE:end_per_testcase(Case, Config).

%% A native 16 kHz room: rtpengine transcodes G.722 and Opus to the
%% mixer's L16 and back. Both directions carry the whole band, also while
%% the PCMU caller is in, and the PCMU caller hears both HD callers.
native_hd_room(Config) ->
    {ok, Conf} = chappe_mrf:conference(<<"hd-live">>, #{
        rate => 16000,
        %% callers and the mixer on the host
        anchor_params => #{b => #{direction => [<<"host">>, <<"host">>]}}
    }),
    ?assertMatch(#{rate := 16000}, chappe_mrf_conf:info(Conf)),
    run_room(Config, Conf, <<"hd-live">>).

%% A FreeSWITCH endpoint in a native 16 kHz room (join/3 of an endpoint of
%% create_endpoint/1): the mixer's L16 offer reaches the node through
%% rtpengine as G.722, PCMU and PCMA (mixer_params(16000, endpoint)), the
%% node answers G.722 and rtpengine transcodes it to the mixer's L16 and
%% back. A G.722 pjsua caller plays the band probe while the endpoint
%% records what the room sends it; then the endpoint plays the probe into
%% the room while the caller records. Both directions keep the band. The
%% rtpengine offer and answer on the endpoint's side, flags and SDP, are
%% in the case's log (apps/chappe_mix/test/audit/ATTEMPTS.md has them).
native_hd_endpoint(Config) ->
    Dir = ?config(priv_dir, Config),
    Probe = chappe_mix_test_tone:band_probe(8000),
    _ = wav(?config(media, Config), "hd-probe.wav", Probe, ?RATE),
    {ok, Conf} = chappe_mrf:conference(<<"hd-ep">>, #{
        rate => 16000,
        anchor_params => #{b => #{direction => [<<"host">>, <<"host">>]}},
        endpoint_params => #{
            offer => #{direction => [<<"host">>, <<"docker">>]},
            answer => #{direction => [<<"docker">>, <<"host">>]}
        }
    }),
    {ok, Ep} = chappe_mrf:create_endpoint(#{}),
    ok = trace_ng(),
    Joined = chappe_mrf_conf:join(Conf, Ep, #{name => <<"ep">>}),
    Ng = ng_calls(<<"mrf-hd-ep-">>),
    _ = dbg:stop(),
    [
        ct:log(
            50,
            "~s~nflags ~0p~nsdp:~n~s~nreply sdp:~n~s",
            [C, maps:without([<<"sdp">>], D), maps:get(<<"sdp">>, D, <<>>), R],
            [esc_chars]
        )
     || {#{<<"command">> := C} = D, R} <- Ng
    ],
    ?assertMatch({ok, _}, Joined),
    %% the node is offered G.722 first in place of L16, and answers it;
    %% the mixer gets L16 back on its own payload type
    [{Offer, ToNode}, {Answer, ToMix}] = [
        {D, R}
     || {#{<<"command">> := C} = D, R} <- Ng, C =/= <<"delete">>
    ],
    ?assertMatch(
        #{
            <<"command">> := <<"offer">>,
            <<"codec">> := #{<<"mask">> := [<<"all">>]}
        },
        Offer
    ),
    [
        ?assert(has(ToNode, L), L)
     || L <- [<<"RTP/AVP 9 0 8 ">>, <<"G722/8000">>]
    ],
    #{<<"command">> := <<"answer">>, <<"sdp">> := NodeAnswer} = Answer,
    ?assert(has(NodeAnswer, <<"a=rtpmap:9 G722/8000">>), NodeAnswer),
    [
        ?assert(has(ToMix, L), L)
     || L <- [<<"RTP/AVP 96 101">>, <<"a=rtpmap:96 L16/16000">>]
    ],
    {ok, Vars} = chappe_mrf:vars(Ep),
    ct:log("endpoint channel: ~p", [
        maps:with(
            [
                <<"read_codec">>,
                <<"read_rate">>,
                <<"write_codec">>,
                <<"rtp_use_codec_name">>,
                <<"rtp_use_codec_rate">>
            ],
            Vars
        )
    ]),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test ! {joined, chappe_mrf_conf:join(Conf, {call, Req, Res}, #{})}
    end),
    %% A plays its probe from 1 s to 9 s of its call
    PlayA = wav(Dir, "a-play.wav", zeros(1) ++ Probe ++ zeros(13), ?RATE),
    A = pjsua(
        Config,
        a,
        #{codec => "G722", rate => 16000, play => PlayA, dur => 22},
        target(Config, <<"hd-ep">>)
    ),
    joined(1),
    T0 = erlang:monotonic_time(millisecond),
    %% the endpoint records the room for 7 s, then plays the probe
    Rec =
        "hd-ep-" ++ integer_to_list(erlang:unique_integer([positive])) ++
            ".wav",
    ok = chappe_mrf:record(Ep, list_to_binary("/media/" ++ Rec), #{
        max_secs => 7
    }),
    Play = erlang:monotonic_time(millisecond) - T0,
    ok = chappe_mrf:play(Ep, <<"/media/hd-probe.wav">>),
    wait_pjsua(A, 60000),
    {RateEp, RecEp} = wav_file(filename:join(?config(media, Config), Rec)),
    RecA = wav_samples(filename:join(Dir, "a.wav")),
    Cal = chappe_mix_test_tone:band_calibrate(lists:sublist(Probe, ?RATE * 2)),
    %% the probe in A's recording: from Play ms on, for 8 s
    From = Play div 1000 + 2,
    Checks = [
        {a_to_endpoint,
            case RateEp of
                ?RATE -> band_shape(window(RecEp, ?RATE, 2, 5), Cal);
                _ -> {error, [{recorded_at, RateEp}]}
            end},
        {endpoint_to_a, band_shape(window(RecA, ?RATE, From, From + 3), Cal)}
    ],
    ct:log(
        "endpoint recording at ~p Hz, ~p samples; play at ~p ms~n~p",
        [RateEp, length(RecEp), Play, Checks]
    ),
    ok = chappe_mrf_conf:stop(Conf),
    chappe_mrf:destroy(Ep),
    [?assertEqual({W, ok}, {W, R}) || {W, R} <- Checks].

%% Trace the NG commands as they go to rtpengine (chappe_rtpengine_ng:
%% command/2, flags and SDP) and the SDP of each reply (sdp/1).
trace_ng() ->
    Test = self(),
    {ok, _} = dbg:tracer(
        process, {
            fun(M, ok) ->
                Test ! {ng_trace, M},
                ok
            end,
            ok
        }
    ),
    {ok, _} = dbg:p(all, [c]),
    {ok, _} = dbg:tpl(
        chappe_rtpengine_ng, command, 2, [{'_', [], [{return_trace}]}]
    ),
    {ok, _} = dbg:tpl(chappe_rtpengine_ng, sdp, 1, []),
    ok.

%% The offers and answers of the calls whose call-id starts with Prefix,
%% each with the SDP of the reply that followed it: [{Dict, ReplySdp}].
ng_calls(Prefix) ->
    ng_calls(Prefix, []).

ng_calls(Prefix, Acc) ->
    receive
        {ng_trace,
            {trace, _, return_from, {chappe_rtpengine_ng, command, 2},
                #{<<"call-id">> := Id} = Dict}} ->
            case binary:longest_common_prefix([Id, Prefix]) of
                N when N =:= byte_size(Prefix) ->
                    ng_calls(Prefix, [{Dict, none} | Acc]);
                _ ->
                    ng_calls(Prefix, Acc)
            end;
        {ng_trace,
            {trace, _, call, {chappe_rtpengine_ng, sdp, [#{<<"sdp">> := S}]}}} ->
            case Acc of
                [{Dict, none} | Rest] -> ng_calls(Prefix, [{Dict, S} | Rest]);
                _ -> ng_calls(Prefix, Acc)
            end;
        {ng_trace, _} ->
            ng_calls(Prefix, Acc)
    after 500 -> lists:reverse(Acc)
    end.

has(Bin, Part) ->
    is_binary(Bin) andalso binary:match(Bin, Part) =/= nomatch.

%% A wav file's rate and samples.
wav_file(Path) ->
    {ok, <<"RIFF", _:32, "WAVE", _/binary>> = Bin} = file:read_file(Path),
    {match, [{Pos, _}]} = re:run(Bin, <<"fmt ">>),
    <<_:Pos/binary, "fmt ", _:32/little, _:16/little, _:16/little,
        Rate:32/little, _/binary>> = Bin,
    {Rate, [X || <<X:16/little-signed>> <= data(Bin)]}.

%% The reference: the same calls in a mod_conference room on the
%% `wideband' profile (16 kHz), each caller bridged to a FreeSWITCH
%% endpoint through rtpengine.
fs_wideband_room(Config) ->
    {ok, Conf} = chappe_mrf:conference(<<"hd-fs">>, #{
        backend => fs,
        node => fs1,
        profile => <<"wideband">>,
        bridge => #{
            anchor_params => #{
                a => #{direction => [<<"docker">>, <<"host">>]},
                b => #{direction => [<<"host">>, <<"docker">>]}
            }
        }
    }),
    ?assertEqual(
        {error, {unsupported, rate}},
        chappe_mrf:conference(<<"hd-fs-rate">>, #{
            backend => fs, node => fs1, rate => 16000
        })
    ),
    run_room(Config, Conf, <<"hd-fs">>).

%% An authorized REFER to a native 16 kHz room's URI adds a second HD
%% caller: a G.722 pjsua callee on the lab's network, dialed out from an
%% endpoint on fs1 that joins the mixer out of sight (G.722 toward the
%% node, the room's L16 toward the mixer) and bridges to the callee once
%% it answers. The room's own caller (G.722) and the callee play the band
%% probe for the whole call, and each records the other (N-1): both
%% directions keep the band. The REFER is chappe_sip_refer:send/3 from
%% this node to the room's URI, out of any dialog, as the demo sends it.
refer_hd_dial_out(Config) ->
    Probe = chappe_mix_test_tone:band_probe(8000),
    Play = wav(?config(priv_dir, Config), "probe.wav", Probe, ?RATE),
    Callee = #{codec => "G722", rate => 16000, play => Play},
    {ok, In, RecA, RecCallee} =
        refer_dial_out(Config, <<"hd-refer">>, Callee, #{}),
    Cal = chappe_mix_test_tone:band_calibrate(lists:sublist(Probe, ?RATE * 2)),
    From = In div 1000 + 2,
    Checks = [
        {a_to_callee, band_shape(window(RecCallee, ?RATE, 3, 6), Cal)},
        {callee_to_a, band_shape(window(RecA, ?RATE, From, From + 3), Cal)}
    ],
    ct:log("~p", [Checks]),
    [?assertEqual({W, ok}, {W, R}) || {W, R} <- Checks].

%% The same REFER to a PCMU-only callee: the room's endpoint speaks G.722,
%% and only the codecs the default dial string offers (PCMU among them)
%% let the callee answer; FreeSWITCH's own choice (dial_codecs =>
%% inherit) offers it G.722 alone, which it refuses (488). Once in, it
%% hears the room's caller in the narrow band (1000 and 2500 Hz of the
%% probe), and the caller hears its own two tones.
refer_pcmu_dial_out(Config) ->
    Dir = ?config(priv_dir, Config),
    Probe = chappe_mix_test_tone:band_probe(8000),
    Play = wav(Dir, "probe.wav", Probe, ?RATE),
    Tones = narrow_tones(8),
    Callee = #{
        codec => "PCMU",
        rate => 8000,
        play => wav(Dir, "nb-play.wav", Tones, 8000)
    },
    {ok, In, RecA, RecCallee} =
        refer_dial_out(Config, <<"hd-refer-nb">>, Callee, #{play => Play}),
    Lv = fun(S, Rate) -> chappe_mix_test_tone:levels(S, [1000, 2500], Rate) end,
    From = In div 1000 + 2,
    Hears = [
        {callee_hears_a, Lv(window(RecCallee, 8000, 3, 6), 8000)},
        {a_hears_callee, Lv(window(RecA, ?RATE, From, From + 3), ?RATE)}
    ],
    ct:log("~p", [Hears]),
    [?assert(L > -40.0, {W, F, L}) || {W, Ls} <- Hears, {F, L} <- Ls].

%% A G.722 caller in a native 16 kHz focus room, then a REFER to the
%% room's URI bringing in a pjsua callee (Callee: codec, rate, play) on
%% the lab's network. {ok, In, RecA, RecCallee}: In is the ms from the
%% caller's answer, where its recording starts, to the callee's
%% (NOTIFY 200); the callee is in for 14 s from then.
refer_dial_out(Config, Room, Callee, AOpts) ->
    Net = lab_network(Config),
    Dir = ?config(priv_dir, Config),
    Test = self(),
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    {ok, Conf} = chappe_mrf:conference(Room, #{
        rate => 16000,
        focus => true,
        refer_policy => fun(#{action := Action}) -> Action =:= add end,
        anchor_params => #{b => #{direction => [<<"host">>, <<"host">>]}},
        endpoint_params => #{
            offer => #{direction => [<<"host">>, <<"docker">>]},
            answer => #{direction => [<<"docker">>, <<"host">>]}
        },
        dial_endpoint => #{node => fs1},
        dial_profile => <<"mrf">>,
        dial_timeout => 15000
    }),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test ! {joined, chappe_mrf_conf:join(Conf, {call, Req, Res}, #{})}
    end),
    Play = maps:get(play, AOpts, maps:get(play, Callee)),
    A = pjsua(
        Config,
        a,
        #{codec => "G722", rate => 16000, play => Play, dur => 26},
        target(Config, Room)
    ),
    joined(1),
    %% A's recording starts about when the room answered it: hd.sh's
    %% docker build and the container's start are behind us
    T0 = erlang:monotonic_time(millisecond),
    %% the callee answers the room's call on the lab's network, where fs1
    %% reaches it by its container name
    Name = container(callee),
    CalleeP = pjsua(Config, callee, Callee#{dur => 14, net => Net}, none),
    ok = running(Name, 20),
    #{entity := Entity} = chappe_mrf_conf:info(Conf),
    {Sip, _} = ports(callee),
    Party = iolist_to_binary(
        ["sip:", Name, "@", Name, ":", integer_to_list(Sip)]
    ),
    {ok, Id, #{status := 200}} = chappe_sip_refer:send(Entity, Party, #{}),
    Final = refer_final(Id),
    In = erlang:monotonic_time(millisecond) - T0,
    Members = chappe_mrf_conf:members(Conf),
    ct:log("callee ~p: NOTIFY ~p at ~p ms; members ~p", [
        maps:with([codec, rate], Callee), Final, In, Members
    ]),
    ?assertEqual(200, Final),
    ?assertMatch([_, _], Members),
    ?assert(lists:any(fun(#{uri := U}) -> U =:= Party end, Members)),
    [wait_pjsua(P, 60000) || P <- [CalleeP, A]],
    ok = chappe_mrf_conf:stop(Conf),
    RecA = wav_samples(filename:join(Dir, "a.wav")),
    RecCallee = wav_samples(filename:join(Dir, "callee.wav")),
    ct:log("recordings: A ~p, callee ~p samples", [
        length(RecA), length(RecCallee)
    ]),
    {ok, In, RecA, RecCallee}.

%% Secs of 1000 and 2500 Hz at 8 kHz, 5000 of amplitude each: the narrow
%% band of the probe, which a G.711 party sends
narrow_tones(Secs) ->
    [T1, T2] = [
        chappe_mix_test_tone:tone(F, 5000, Secs * 8000, 8000)
     || F <- [1000, 2500]
    ],
    lists:zipwith(fun erlang:'+'/2, T1, T2).

%% The docker network of the lab's fs1, from the compose command e2e.sh
%% passes (MRF_COMPOSE). The suite runs only under MRF=1, with the lab
%% up: no network there is a broken lab, and the case fails.
lab_network(Config) ->
    case network(?config(compose, Config)) of
        undefined -> ct:fail({no_lab_network, ?config(compose, Config)});
        Net -> Net
    end.

network("") ->
    undefined;
network(Compose) ->
    case string:trim(os:cmd(Compose ++ " ps -q fs1 2>/dev/null")) of
        "" ->
            undefined;
        Id ->
            Out = os:cmd(
                "docker inspect -f '{{json .NetworkSettings.Networks}}' " ++ Id
            ),
            case maps:keys(json:decode(list_to_binary(string:trim(Out)))) of
                [Net | _] -> binary_to_list(Net);
                [] -> undefined
            end
    end.

%% wait for a container to run, then for its pjsua to listen
running(_Name, 0) ->
    {error, not_running};
running(Name, N) ->
    case
        string:trim(os:cmd("docker inspect -f '{{.State.Running}}' " ++ Name))
    of
        "true" ->
            timer:sleep(1500);
        _ ->
            timer:sleep(500),
            running(Name, N - 1)
    end.

%% the referrer's NOTIFYs up to the final one: its status
refer_final(Id) ->
    receive
        {refer_progress, Id, St} ->
            ct:log("NOTIFY ~b", [St]),
            refer_final(Id);
        {refer_done, Id, St} ->
            St
    after 30000 -> ct:fail(no_final_notify)
    end.

%% ---- the calls ----

run_room(Config, Conf, User) ->
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test ! {joined, chappe_mrf_conf:join(Conf, {call, Req, Res}, #{})}
    end),
    Dir = ?config(priv_dir, Config),
    %% two pjsua started in the same second draw the same Call-ID and
    %% tags (their PRNG is seeded from the time): B starts 2 s after A
    Probe = chappe_mix_test_tone:band_probe(8000),
    PlayA = wav(Dir, "a-play.wav", Probe ++ zeros(14), ?RATE),
    PlayB = wav(Dir, "b-play.wav", zeros(8) ++ Probe ++ Probe, ?RATE),
    Target = target(Config, User),
    %% A: its probe at [0, 8) s; B: its own at [10, 26) s, in A's time
    A = pjsua(
        Config,
        a,
        #{codec => "G722", rate => 16000, play => PlayA, dur => 22},
        Target
    ),
    timer:sleep(2000),
    B = pjsua(
        Config,
        b,
        #{codec => "opus", rate => 16000, play => PlayB, dur => 20},
        Target
    ),
    joined(2),
    %% C, silent, from about 5 s to 15 s
    timer:sleep(2000),
    C = pjsua(Config, c, #{codec => "PCMU", rate => 8000, dur => 10}, Target),
    joined(1),
    [wait_pjsua(P, 60000) || P <- [C, B, A]],
    Cal = chappe_mix_test_tone:band_calibrate(lists:sublist(Probe, ?RATE * 2)),
    RecA = wav_samples(filename:join(Dir, "a.wav")),
    RecB = wav_samples(filename:join(Dir, "b.wav")),
    RecC = wav_samples(filename:join(Dir, "c.wav")),
    Check = fun(S) -> band_shape(S, Cal) end,
    Checks = [
        %% A's probe at B, while C is in (B's time: A's 2 s later)
        {a_to_b_with_c, Check(window(RecB, ?RATE, 3, 5))},
        %% B's probe at A, while C is in, then after it left
        {b_to_a_with_c, Check(window(RecA, ?RATE, 11, 13))},
        {b_to_a_after_c, Check(window(RecA, ?RATE, 17, 20))}
    ],
    %% C, at 8 kHz, in its own time: A's probe for its first seconds, B's
    %% from about 5 s on
    Lv = fun(S) -> chappe_mix_test_tone:levels(S, [1000, 2500], 8000) end,
    CHearsA = Lv(window(RecC, 8000, 0, 2)),
    CHearsB = Lv(window(RecC, 8000, 6, 9)),
    ct:log(
        "~s: ~p~nC hears A ~p, B ~p~nrecordings: A ~p, B ~p, C ~p samples",
        [
            User,
            Checks,
            CHearsA,
            CHearsB,
            length(RecA),
            length(RecB),
            length(RecC)
        ]
    ),
    ok = chappe_mrf_conf:stop(Conf),
    [?assertEqual({W, ok}, {W, R}) || {W, R} <- Checks],
    [?assert(L > -40.0, {c_hears, F, L}) || {F, L} <- CHearsA ++ CHearsB].

%% The band check on the shape of the band, not on the path's gain: a
%% caller's codec may move the whole probe a few dB (pjsua's G.722 path
%% comes 6 dB down), so the calibration moves by what 1000 Hz, which any
%% 8 kHz path keeps, lost on the way; then every tone within 3 dB of it,
%% and nothing folded onto the alias bins.
band_shape(Samples, Cal) ->
    case length(Samples) >= 3200 of
        false ->
            {error, [{too_short, length(Samples)}]};
        true ->
            try chappe_mix_test_tone:band_calibrate(Samples) of
                #{1000 := Got} ->
                    Gain = Got - maps:get(1000, Cal),
                    ct:log("path gain at 1000 Hz: ~.1f dB", [Gain]),
                    Shifted = maps:map(fun(_, L) -> L + Gain end, Cal),
                    %% G.722 is on every path here: its QMF bank folds
                    %% 5000 and 6000 Hz onto the alias bins at about 60 dB
                    %% down, so they get 30 dB (a careless drop to 8 kHz
                    %% folds them within a few dB of full level)
                    chappe_mix_test_tone:band_check(Samples, Shifted, #{
                        tolerance => 3.0, alias_db => 30.0
                    })
            catch
                %% a tone 10 dB down or more: the path lost the band
                error:{bad_calibration, F, L} -> {error, [{missing, F, L}]}
            end
    end.

zeros(Secs) ->
    lists:duplicate(Secs * ?RATE, 0).

joined(0) ->
    ok;
joined(N) ->
    receive
        {joined, {ok, _}} -> joined(N - 1);
        {joined, Err} -> ct:fail({join, Err})
    after 30000 -> ct:fail(no_join)
    end.

target(Config, User) ->
    Port = integer_to_list(?config(sip_port, Config)),
    "sip:" ++ binary_to_list(User) ++ "@127.0.0.1:" ++ Port.

%% A pjsua caller through hd.sh, in the background: its recording lands in
%% the case's priv_dir as Name.wav. With Target none it answers the first
%% call instead; net puts it on a docker network (default the host's).
pjsua(Config, Name, Opts, Target) ->
    Dir = ?config(priv_dir, Config),
    N = atom_to_list(Name),
    {Sip, Rtp} = ports(Name),
    Args =
        [
            "-c",
            maps:get(codec, Opts),
            "-r",
            integer_to_list(maps:get(rate, Opts)),
            "-o",
            filename:join(Dir, N ++ ".wav"),
            "-d",
            integer_to_list(maps:get(dur, Opts)),
            "-l",
            integer_to_list(Sip),
            "-m",
            integer_to_list(Rtp),
            "-N",
            container(Name),
            "-i",
            ?config(image, Config)
        ] ++
            case maps:find(play, Opts) of
                {ok, P} -> ["-p", P];
                error -> []
            end ++
            case maps:find(net, Opts) of
                {ok, Net} -> ["-n", Net];
                error -> []
            end ++
            case Target of
                none -> [];
                _ -> [Target]
            end,
    Port = open_port({spawn_executable, ?config(hd_sh, Config)}, [
        {args, Args}, exit_status, stderr_to_stdout, binary
    ]),
    {Name, Port}.

%% a pjsua's container name (MRF_PJSUA_NAME prefixes it), also its SIP
%% user
container(Name) ->
    os:getenv("MRF_PJSUA_NAME", "chappe-hd") ++ "-" ++ atom_to_list(Name).

%% a pjsua's SIP port and first RTP port, by its rank after the first ones
%% (MRF_PJSUA_SIP, MRF_PJSUA_RTP)
ports(Name) ->
    K = maps:get(Name, #{a => 0, b => 1, c => 2, callee => 3}),
    {
        env_port("MRF_PJSUA_SIP", 19560) + K,
        env_port("MRF_PJSUA_RTP", 19600) + 20 * K
    }.

%% the first pjsua SIP (MRF_PJSUA_SIP) and RTP (MRF_PJSUA_RTP) ports
env_port(Var, Default) ->
    list_to_integer(os:getenv(Var, integer_to_list(Default))).

wait_pjsua({Name, Port}, Ms) ->
    receive
        {Port, {data, _}} -> wait_pjsua({Name, Port}, Ms);
        {Port, {exit_status, S}} -> ct:log("pjsua ~p exited ~p", [Name, S])
    after Ms -> ct:fail({pjsua_hangs, Name})
    end.

hd_sh() ->
    filename:join([root(), "apps", "chappe_sip", "interop", "pjsua", "hd.sh"]).

%% the umbrella root: this beam is _build/test/lib/chappe_mrf/test/<beam>
root() ->
    lists:foldl(
        fun(_, D) -> filename:dirname(D) end,
        code:which(?MODULE),
        lists:seq(1, 6)
    ).

%% ---- wav ----

wav(Dir, File, Samples, Rate) ->
    Path = filename:join(Dir, File),
    Data = <<<<S:16/little-signed>> || S <- Samples>>,
    Hdr =
        <<"RIFF", (36 + byte_size(Data)):32/little, "WAVEfmt ", 16:32/little,
            1:16/little, 1:16/little, Rate:32/little, (Rate * 2):32/little,
            2:16/little, 16:16/little, "data", (byte_size(Data)):32/little>>,
    ok = file:write_file(Path, [Hdr, Data]),
    Path.

wav_samples(Path) ->
    {ok, Bin} = file:read_file(Path),
    [X || <<X:16/little-signed>> <= data(Bin)].

data(<<"data", _:32/little, Data/binary>>) -> Data;
data(<<_, Rest/binary>>) -> data(Rest).

%% The samples from second From to second To.
window(Samples, Rate, From, To) ->
    lists:sublist(Samples, From * Rate + 1, (To - From) * Rate).
