%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The same input into two mixers: FreeSWITCH mod_conference (the
%% reference) and chappe_mix. Used by chappe_mix_ref_SUITE and by the
%% ref_latency bench arm, so both judge the two mixers with the same code.
%%
%% FreeSWITCH comes from apps/chappe_mix/interop/freeswitch (native on
%% arm64 and amd64; apps/chappe_mix/test/ref.sh brings it up): a call to
%% conf-<name> on its SIP port joins conference <name>@default. It reads:
%%
%%   FREESWITCH_HOST       where its SIP and RTP ports are published
%%   FREESWITCH_SIP_PORT   default 15060
%%   FREESWITCH_MEDIA_IP   the address the container reaches this machine
%%                         at (RTPENGINE_MEDIA_IP is used if unset)
-module(chappe_mix_ref).

-export([env/0, parties/3, close/1, latency/3]).

%% {ok, Env} or {skip, Why}.
env() ->
    case os:getenv("FREESWITCH_HOST") of
        false ->
            {skip, "FREESWITCH_HOST not set"};
        Host ->
            case media_ip() of
                undefined ->
                    {skip, "FREESWITCH_MEDIA_IP not set"};
                Adv ->
                    {ok, Ip} = inet:parse_address(Host),
                    {ok, #{
                        host => Ip,
                        sip_port => int_env("FREESWITCH_SIP_PORT", 15060),
                        advertise => list_to_binary(Adv)
                    }}
            end
    end.

%% One tone endpoint per frequency, joined to a fresh conference on
%% Mixer (fs | chappe). A frequency given as {Freq, Ptime} sends Ptime ms
%% packets (and says so in its SDP); the others send 20 ms. Returns a
%% handle; endpoints are {Pid, Id, Freq}.
parties(fs, Env, Freqs) ->
    User = conf_user(),
    Eps = [fs_party(Env, User, F) || F <- Freqs],
    {fs, Eps};
parties(chappe, _Env, Freqs) ->
    {ok, Conf} = chappe_mix:start(#{}),
    Eps = [chappe_party(Conf, F) || F <- Freqs],
    {chappe, Conf, Eps}.

close({fs, Eps}) ->
    [chappe_mix_sip_ua:hangup(Call) || {_, Call, _} <- Eps],
    [chappe_mix_test_tone:stop(Pid) || {Pid, _, _} <- Eps],
    ok;
close({chappe, Conf, Eps}) ->
    [chappe_mix_test_tone:stop(Pid) || {Pid, _, _} <- Eps],
    chappe_mix:stop(Conf).

%% Burst latency from A to B through Mixer (see chappe_mix_probe).
%% Opts: bursts (default 50), settle (frames before the first burst).
latency(fs, Env, Opts) ->
    #{host := Host} = Env,
    {Probe, PA, PB} = chappe_mix_probe:start(#{ip => {0, 0, 0, 0}}),
    User = conf_user(),
    {ok, CA, #{port := FA}} = fs_call(Env, User, PA),
    {ok, CB, #{port := FB}} = fs_call(Env, User, PB),
    %% the harness plays no enter tone; the settle still covers one
    R = chappe_mix_probe:run(Probe, #{
        a_dst => {Host, FA},
        b_dst => {Host, FB},
        bursts => maps:get(bursts, Opts, 50),
        settle => maps:get(settle, Opts, 100)
    }),
    chappe_mix_sip_ua:hangup(CA),
    chappe_mix_sip_ua:hangup(CB),
    chappe_mix_probe:stop(Probe),
    R;
latency(chappe, _Env, Opts) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {ok, _, #{port := MA}} = chappe_mix:add_leg(Conf, #{}),
    {ok, _, #{port := MB}} = chappe_mix:add_leg(Conf, #{}),
    {Probe, _, _} = chappe_mix_probe:start(#{}),
    R = chappe_mix_probe:run(Probe, #{
        a_dst => {{127, 0, 0, 1}, MA},
        b_dst => {{127, 0, 0, 1}, MB},
        bursts => maps:get(bursts, Opts, 50),
        settle => maps:get(settle, Opts, 25)
    }),
    chappe_mix_probe:stop(Probe),
    ok = chappe_mix:stop(Conf),
    R.

%% ---- internal ----

fs_party(Env, User, {Freq, Ptime}) ->
    fs_party(Env, User, Freq, Ptime);
fs_party(Env, User, Freq) ->
    fs_party(Env, User, Freq, 20).

fs_party(#{host := Host} = Env, User, Freq, Ptime) ->
    {Pid, Port} = chappe_mix_test_tone:endpoint(#{
        freq => Freq, ip => {0, 0, 0, 0}, ptime => Ptime
    }),
    {ok, Call, #{port := FsPort}} = fs_call(Env, User, Port, Ptime),
    %% the SDP names the container address; the port is published 1:1
    Pid ! {dst, {Host, FsPort}},
    {Pid, Call, Freq}.

fs_call(Env, User, RtpPort) ->
    fs_call(Env, User, RtpPort, 20).

fs_call(
    #{host := Host, sip_port := SipPort, advertise := Adv}, User, RtpPort, Ptime
) ->
    case
        chappe_mix_sip_ua:call(#{
            host => Host,
            port => SipPort,
            user => User,
            advertise => Adv,
            rtp_port => RtpPort,
            ptime => Ptime
        })
    of
        {ok, _, #{port := P}} = Ok when is_integer(P) -> Ok;
        {ok, _, Media} -> error({no_media_in_answer, Media});
        {error, Reason} -> error({freeswitch_call_failed, Reason})
    end.

chappe_party(Conf, {Freq, Ptime}) ->
    chappe_party(Conf, Freq, Ptime);
chappe_party(Conf, Freq) ->
    chappe_party(Conf, Freq, 20).

chappe_party(Conf, Freq, Ptime) ->
    {ok, Leg, #{port := MixPort}} = chappe_mix:add_leg(Conf, #{ptime => Ptime}),
    {Pid, _} = chappe_mix_test_tone:endpoint(#{
        freq => Freq, dst => {{127, 0, 0, 1}, MixPort}, ptime => Ptime
    }),
    {Pid, Leg, Freq}.

conf_user() ->
    N = binary:encode_hex(crypto:strong_rand_bytes(4), lowercase),
    <<"conf-mixref", N/binary>>.

media_ip() ->
    case os:getenv("FREESWITCH_MEDIA_IP") of
        V when is_list(V), V =/= "" ->
            V;
        _ ->
            case os:getenv("RTPENGINE_MEDIA_IP") of
                V when is_list(V), V =/= "" -> V;
                _ -> undefined
            end
    end.

int_env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        V -> list_to_integer(V)
    end.
