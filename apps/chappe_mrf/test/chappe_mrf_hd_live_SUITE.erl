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
%% narrow band. The setup is chappe_mrf_live_SUITE's. Skipped unless MRF=1
%% (apps/chappe_mrf/test/e2e.sh) and docker runs.
-module(chappe_mrf_hd_live_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([native_hd_room/1, fs_wideband_room/1]).

-define(LIVE, chappe_mrf_live_SUITE).

-define(RATE, 16000).

all() ->
    [native_hd_room, fs_wideband_room].

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

%% The pjsua of this checkout, under a tag of its own: `chappe-conf-pjsua',
%% hd.sh's default, is shared with the conformance lab, and a checkout
%% whose Dockerfile has no Opus overwrites it. Cached after the first
%% build.
pjsua_image() ->
    Tag = "chappe-hd-pjsua",
    Dir = filename:dirname(hd_sh()),
    Out = os:cmd("docker build -q -t " ++ Tag ++ " " ++ Dir ++ " 2>&1"),
    ct:log("pjsua image ~s: ~s", [Tag, Out]),
    Tag.

end_per_suite(Config) ->
    ?LIVE:end_per_suite(Config).

init_per_testcase(Case, Config) ->
    ?LIVE:init_per_testcase(Case, Config).

end_per_testcase(Case, Config) ->
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
            #{1000 := Got} = chappe_mix_test_tone:band_calibrate(Samples),
            Gain = Got - maps:get(1000, Cal),
            ct:log("path gain at 1000 Hz: ~.1f dB", [Gain]),
            Shifted = maps:map(fun(_, L) -> L + Gain end, Cal),
            chappe_mix_test_tone:band_check(Samples, Shifted, #{
                tolerance => 3.0
            })
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
%% the case's priv_dir as Name.wav.
pjsua(Config, Name, Opts, Target) ->
    Dir = ?config(priv_dir, Config),
    N = atom_to_list(Name),
    Off = #{a => 0, b => 1, c => 2},
    K = maps:get(Name, Off),
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
            integer_to_list(env_port("MRF_PJSUA_SIP", 19560) + K),
            "-m",
            integer_to_list(env_port("MRF_PJSUA_RTP", 19600) + 20 * K),
            "-N",
            "chappe-hd-" ++ N,
            "-i",
            ?config(image, Config)
        ] ++
            case maps:find(play, Opts) of
                {ok, P} -> ["-p", P];
                error -> []
            end ++ [Target],
    Port = open_port({spawn_executable, ?config(hd_sh, Config)}, [
        {args, Args}, exit_status, stderr_to_stdout, binary
    ]),
    {Name, Port}.

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
    %% _build/test/lib/chappe_mrf/test/<this beam>
    Root = lists:foldl(
        fun(_, D) -> filename:dirname(D) end,
        code:which(?MODULE),
        lists:seq(1, 6)
    ),
    filename:join([Root, "apps", "chappe_sip", "interop", "pjsua", "hd.sh"]).

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
