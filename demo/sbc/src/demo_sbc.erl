%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% A small SBC to try chappe_sip by hand (`make demo`, see README.md).
%%
%% It runs a registrar for the users of demo.config, sends a call to a
%% registered user through the B2BUA, decides per call whether rtpengine
%% anchors the media (chappe_sip_media:bypass/2: a WebRTC side, a NAT or
%% two private networks anchor), keeps UDP contacts open with OPTIONS, and
%% pings Kamailio. It serves the JsSIP page of web/ for a browser softphone.
%%
%% 1000 (echo), 1001 (a tone) and 1002 (a conference) go to the FreeSWITCH
%% pool: chappe_esl picks the node (node_select/1, by its load), the call
%% fails over through the chappe_sip peers of the same names, and its
%% X-Chappe-Call header comes back in the node's CHANNEL_CREATE, which ties
%% the FreeSWITCH channel to the call.
%%
%% From `make demo-shell':
%%   demo_sbc:calls()        the calls up, with their media mode
%%   demo_sbc:anchor(CallId) move a call's media into rtpengine
%%   demo_sbc:direct(CallId) and back out of it
%%   demo_sbc:peers()        the OPTIONS state of the peers
%%   demo_sbc:nodes()        the FreeSWITCH nodes, their state and load
%%   demo_sbc:drain(fs1)     stop sending calls to a node (resume/1 undoes)
%%
%% 2000 is an IVR on chappe_mrf: the caller lands on a FreeSWITCH endpoint
%% that plays a menu and collects a digit: 1 calls bob, 2 is an echo
%% endpoint, 3 joins a conference on chappe_mix (native), 4 one on
%% FreeSWITCH (PIN 1234), 8 forks the caller's audio into chappe_audio,
%% which prints its level as the caller speaks, 9 records a message and
%% plays it back. The fork and the message land in the recording store
%% (recordings/ next to this file), under the call's call_ref.
%%   demo_sbc:recordings(Ref)  a call's recordings, by its call_ref
%%   demo_sbc:confs()          the conferences and their member count
%%   demo_sbc:members(Name)    a conference's members
%%   demo_sbc:kick(Name, Id)   drop a member
%%
%% 3001 calls bob and records the call through SIPREC (chappe_sip_siprec)
%% to the demo's own recording server, the route sip:srs@ of this node
%% (chappe_sip_siprec_srs, store => default): each party's stream lands in
%% the same recording store, one WAV file per party, found with
%% demo_sbc:recordings(Ref).
%%
%% 1003 and 1004 are HD (16 kHz) rooms, to compare by ear: demo-hd on
%% chappe_mix (rtpengine converts each caller, G.722, Opus or PCMU, to
%% the room's L16) and demo-hd-fs, mod_conference on its `wideband'
%% profile. The room answers the caller itself. Both are focus rooms
%% whose URI (sip:demo-hd@...) takes REFERs from the shell and from
%% registered users (a member's transfer button), to bring in a user or
%% a number of the demo only:
%%   demo_sbc:refer_add(Room, Uri)     REFER the room to bring Uri in
%%   demo_sbc:refer_remove(Room, Uri)  REFER it to drop that member
%% The pool calls the party through this node, which routes it as any
%% call. Only registered users may SUBSCRIBE to a room's roster.
%%
%% 1005 is demo-hd-pin, a room like demo-hd that asks for a PIN (4321 in
%% demo.config): the caller is answered on the FreeSWITCH pool, which
%% plays the hd_pin prompt and reads the digits; with the right PIN the
%% call moves into the chappe_mix room, keeping its codec, and its
%% FreeSWITCH channel is hung up. Three wrong PINs play bad_pin and end
%% the call.
%%
%% route/1 maps a dialled user to where the call goes. It is the one place
%% to add targets: a FreeSWITCH pool, for one, is a {peer_group, G} there.
-module(demo_sbc).

-export([start/1]).
-export([calls/0, anchor/1, direct/1, peers/0, nodes/0, drain/1, resume/1]).
-export([route/1]).
-export([confs/0, members/1, kick/2, recordings/1]).
-export([refer_add/2, refer_remove/2]).

-define(CALLS, demo_sbc_calls).
%% call id => {FreeSWITCH node, channel uuid}
-define(FS, demo_sbc_fs).
%% the IVR's prompt files: 16 kHz, for HD phones
-define(PROMPT_RATE, 16000).

%% Start with the settings of File (demo/sbc/demo.config).
-spec start(file:filename()) -> ok.
start(File) ->
    {ok, [Cfg]} = file:consult(File),
    persistent_term:put({?MODULE, cfg}, Cfg),
    {ok, _} = application:ensure_all_started(chappe_sip),
    %% the FreeSWITCH nodes, registered with chappe_esl when it starts
    ok = application:load(chappe_esl),
    ok = application:set_env(chappe_esl, nodes, maps:get(fs_nodes, Cfg, [])),
    {ok, _} = application:ensure_all_started(chappe_esl),
    {ok, _} = application:ensure_all_started(chappe_mrf),
    ok = audio(Cfg),
    Keeper = keeper(),
    %% the HD rooms send it their events
    persistent_term:put({?MODULE, keeper}, Keeper),
    Ip = env("DEMO_IP", maps:get(ip, Cfg)),
    SipPort = env("DEMO_SIP_PORT", maps:get(sip_port, Cfg)),
    ok = chappe_sip:start(#{
        contact => iolist_to_binary(["sip:", Ip, ":", SipPort]),
        ws => #{
            port => list_to_integer(env("DEMO_WS_PORT", maps:get(ws_port, Cfg)))
        },
        media => #{
            rtpengine => #{nodes => [maps:get(rtpengine, Cfg)]},
            %% conference rooms on this host; rtpengine reaches them at
            %% DEMO_MEDIA_IP (make demo finds it)
            mix => #{
                ip => {0, 0, 0, 0},
                advertise => env("DEMO_MEDIA_IP", "127.0.0.1")
            }
        }
    }),
    {ok, MrfIp} = inet:parse_address(
        env("DEMO_MRF_IP", maps:get(mrf_ip, Cfg, "127.0.0.1"))
    ),
    ok = chappe_mrf:start(#{
        esl_port => list_to_integer(
            env("DEMO_MRF_PORT", maps:get(mrf_port, Cfg, 18084))
        ),
        esl_ip => MrfIp,
        esl_allow => mrf_allow(Cfg)
    }),
    ok = prompts(env("DEMO_MEDIA_DIR", "_build/demo-media")),
    %% the HD rooms: REFERs to their URI (the demo shell's carry this
    %% token as their From user), and SUBSCRIBEs to their roster
    persistent_term:put(
        {?MODULE, refer_token},
        binary:encode_hex(crypto:strong_rand_bytes(16), lowercase)
    ),
    ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
    ok = chappe_sip:event_package(<<"conference">>, fun roster_subscribe/2),
    ok = chappe_sip:peer_subscribe(Keeper),
    _ = [
        chappe_sip:peer_add(Name, Opts)
     || {Name, Opts} <- maps:get(peers, Cfg, [])
    ],
    Users = maps:get(users, Cfg),
    Registrar = chappe_sip:registrar(#{
        auth => #{
            realm => maps:get(realm, Cfg),
            domain => domains(Cfg),
            secret => fun(U) -> secret(U, Users) end
        },
        domains => any,
        qualify_interval_ms => 30000
    }),
    ok = chappe_sip:register(Registrar),
    %% siprec: the demo is its own recording server too (sip:srs@)
    ok = chappe_sip:handle(
        <<"INVITE">>,
        fun(Req, Res) -> invite(Keeper, Req, Res) end,
        #{option_tags => [<<"siprec">>]}
    ),
    ok = http(
        list_to_integer(env("DEMO_HTTP_PORT", maps:get(http_port, Cfg))),
        filename:join(filename:dirname(File), "web/index.html")
    ),
    log("demo up: SIP ~s:~s, WS ~s, page http://localhost:~s/", [
        Ip,
        SipPort,
        env("DEMO_WS_PORT", maps:get(ws_port, Cfg)),
        env("DEMO_HTTP_PORT", maps:get(http_port, Cfg))
    ]),
    ok.

%% chappe_audio: the recording store in recordings/ next to this file,
%% the FreeSWITCH media folder mapped for adoption, and a fork listener
%% the nodes reach at host.docker.internal.
audio(Cfg) ->
    Media = env("DEMO_MEDIA_DIR", "_build/demo-media"),
    ok = application:set_env(chappe_mrf, shared_dir, #{
        freeswitch => "/media", local => Media
    }),
    {ok, _} = application:ensure_all_started(chappe_audio),
    Dir = env(
        "DEMO_RECORDINGS", maps:get(recordings, Cfg, "demo/sbc/recordings")
    ),
    ok = chappe_audio_store:configure(#{dir => Dir}),
    Port = list_to_integer(
        env("DEMO_AUDIO_PORT", maps:get(audio_port, Cfg, 18090))
    ),
    {ok, L} = chappe_audio:listen(#{
        ip => {0, 0, 0, 0},
        port => Port,
        url => iolist_to_binary([
            "ws://host.docker.internal:", integer_to_list(Port)
        ])
    }),
    persistent_term:put({?MODULE, audio}, L),
    ok.

%% The recordings of a call, wherever they were made, from the store.
-spec recordings(binary()) -> [map()].
recordings(Ref) ->
    [
        maps:with([id, source, duration_ms, path], R)
     || R <- chappe_audio_store:find(Ref)
    ].

%% DEMO_MRF_ALLOW (comma-separated) wins over mrf_allow; neither, any peer.
mrf_allow(Cfg) ->
    case os:getenv("DEMO_MRF_ALLOW", "") of
        "" -> maps:get(mrf_allow, Cfg, []);
        V -> string:lexemes(V, ",")
    end.

env(Name, Default) ->
    case os:getenv(Name) of
        false -> to_list(Default);
        "" -> to_list(Default);
        V -> V
    end.

to_list(V) when is_integer(V) -> integer_to_list(V);
to_list(V) when is_binary(V) -> binary_to_list(V);
to_list(V) -> V.

secret(User, Users) ->
    case lists:keyfind(User, 1, Users) of
        {_, Pass} -> {ok, Pass};
        false -> error
    end.

%% ---- calls ----

%% Where a dialled user's call goes, and the options it needs:
%% {ok, Target, Opts} or {error, Status}.
-spec route(binary()) ->
    {ok, chappe_sip_b2b:target(), map()} | {error, 400..699}.
route(User) ->
    Cfg = persistent_term:get({?MODULE, cfg}),
    case
        {
            lists:keymember(User, 1, maps:get(users, Cfg)),
            lists:member(User, maps:get(extensions, Cfg, []))
        }
    of
        {true, _} -> registered(User, Cfg);
        {_, true} -> pool(User);
        _ -> extra_route(User, Cfg)
    end.

%% A FreeSWITCH number: the node chappe_esl picks first, then the other up
%% peers of the pool; FreeSWITCH reaches rtpengine on its docker side
pool(Ext) ->
    First =
        case chappe_esl:node_select(#{}) of
            {ok, Node} ->
                case chappe_esl:node_status(Node) of
                    {ok, #{sip_uri := Uri}} when is_binary(Uri) -> [Uri];
                    _ -> []
                end;
            {error, _} ->
                []
        end,
    Rest = [
        U
     || U <- chappe_sip_peers:candidates(fs, priority),
        not lists:member(U, First)
    ],
    case [with_user(U, Ext) || U <- First ++ Rest] of
        [] ->
            {error, 503};
        Uris ->
            {ok, Uris, #{
                b_side => fs,
                anchor_params => #{
                    a => #{direction => [docker, host]},
                    b => #{direction => [host, docker]}
                }
            }}
    end.

with_user(Uri, User) ->
    {ok, U} = chappe_sip_uri:parse(Uri),
    iolist_to_binary(chappe_sip_uri:format(U#{user => User})).

registered(User, Cfg) ->
    case located(User, domains(Cfg)) of
        {ok, Uri, Flow} when is_integer(Flow) ->
            %% a browser over WebSocket: WebRTC media, always anchored
            {ok, Uri, #{flow => Flow, b_side => ws}};
        {ok, Uri, {udp, Ip, _Port} = Flow} ->
            %% location_flow/1 gives the address the REGISTER came from when
            %% the Contact is not reachable (a NAT): the call and its
            %% dialog's requests go there
            {ok, Uri, #{flow => Flow, b_side => {Ip, Uri}}};
        {ok, Uri, Flow} when Flow =/= undefined ->
            {ok, Uri, #{flow => Flow}};
        {ok, Uri, undefined} ->
            {ok, Uri, #{}};
        {error, not_found} ->
            {error, 480}
    end.

%% the users register under any of the demo's domains
located(_User, []) ->
    {error, not_found};
located(User, [D | Ds]) ->
    case chappe_sip:location_flow(<<"sip:", User/binary, "@", D/binary>>) of
        {ok, _, _} = Found -> Found;
        {error, not_found} -> located(User, Ds)
    end.

domains(Cfg) ->
    lists:usort([
        list_to_binary(env("DEMO_IP", maps:get(ip, Cfg)))
        | maps:get(domains, Cfg)
    ]).

%% the targets that are not registered users (demo.config `routes')
extra_route(User, Cfg) ->
    case lists:keyfind(User, 1, maps:get(routes, Cfg, [])) of
        {_, Target} -> {ok, Target, #{}};
        false -> {error, 404}
    end.

invite(Keeper, Req, Res) ->
    CallId = chappe_sip_req:call_id(Req),
    Called = user(chappe_sip_req:uri(Req)),
    Cfg = persistent_term:get({?MODULE, cfg}),
    Ivr = maps:get(ivr, Cfg, <<"2000">>),
    Recorded = maps:get(record, Cfg, <<"3001">>),
    case {Called, hd_room(Called)} of
        {<<"srs">>, _} ->
            recording_server(Req, Res);
        {Recorded, _} ->
            recorded_call(Keeper, CallId, Req, Res);
        {_, {ok, Room, Backend, Join}} ->
            hd_call(CallId, Room, Backend, Join, Req, Res);
        {_, error} ->
            invite(Keeper, CallId, Called, Ivr, Req, Res)
    end.

invite(Keeper, CallId, Called, Ivr, Req, Res) ->
    case Called =:= Ivr orelse route(Called) of
        true ->
            ivr(Req, Res);
        {ok, Target, Opts0} ->
            {BSide, Opts1} = take(b_side, Opts0),
            Opts = Opts1#{
                media => policy(BSide),
                notify => Keeper,
                %% FreeSWITCH hands it back in CHANNEL_CREATE
                b_headers => [{<<"X-Chappe-Call">>, CallId}]
            },
            bridge(CallId, Called, Req, Res, Target, dialed(Req, BSide, Opts));
        {error, Status} ->
            _ = chappe_sip_res:send(Res, Status),
            log("call ~s to ~s: ~b", [CallId, Called, Status])
    end.

take(Key, Map) ->
    {maps:get(Key, Map, undefined), maps:remove(Key, Map)}.

bridge(CallId, Called, Req, Res, Target, Opts) ->
    case chappe_sip:create_b2bua(Req, Res, Target, maps:remove(record, Opts)) of
        {ok, #{b2b := B2b, media := M} = Legs} ->
            From = user(chappe_sip_req:get(<<"from">>, Req)),
            true = ets:insert(?CALLS, {CallId, B2b, From, Called}),
            log("call ~s ~s -> ~s up, media ~p", [
                CallId, From, Called, chappe_sip_b2b_media:mode(M)
            ]),
            %% this process runs the call's relay once bridge/6 returns, so
            %% the recording starts from another one (it reads the call);
            %% the keeper owns it, and the call's end stops it
            _ =
                maps:get(record, Opts, false) andalso
                    spawn(fun() ->
                        record_call(CallId, B2b, maps:get(notify, Opts))
                    end),
            Done = chappe_sip_b2b:relay(Legs),
            ets:delete(?CALLS, CallId),
            ets:delete(?FS, CallId),
            log("call ~s ended ~p", [CallId, Done]);
        {error, Why} ->
            log("call ~s to ~s failed: ~p", [CallId, Called, Why])
    end.

%% bypass/2 per call: the caller as its SDP and signalling address, the
%% callee as its registration's source (or a WebSocket or FreeSWITCH,
%% always anchored)
policy(ws) ->
    anchor;
policy(fs) ->
    anchor;
policy(BSide) ->
    Cfg = persistent_term:get({?MODULE, cfg}),
    fun(#{sdp := Sdp, source := Source}) ->
        B =
            case BSide of
                {Ip, _Uri} -> #{addr => Ip};
                undefined -> #{}
            end,
        chappe_sip_media:bypass(
            #{a => #{sdp => Sdp, source => Source}, b => B},
            #{networks => maps:get(networks, Cfg, [])}
        )
    end.

user(undefined) ->
    undefined;
user(Value) ->
    case chappe_sip_uri:parse(addr(Value)) of
        {ok, #{user := User}} -> User;
        _ -> undefined
    end.

%% the URI of a name-addr (a From, a To), or the value as it is
addr(Value) ->
    case chappe_sip_hdr:name_addr(Value) of
        {ok, #{uri := U}} -> U;
        _ -> Value
    end.

%% ---- 3001: a call to bob, recorded through SIPREC ----

%% bob's route, anchored (each party is tapped in rtpengine), recorded once
%% it is up
recorded_call(Keeper, CallId, Req, Res) ->
    case route(<<"bob">>) of
        {ok, Target, Opts0} ->
            {_BSide, Opts1} = take(b_side, Opts0),
            bridge(CallId, <<"bob">>, Req, Res, Target, Opts1#{
                media => anchor, notify => Keeper, record => true
            });
        {error, Status} ->
            _ = chappe_sip_res:send(Res, Status),
            log("call ~s to 3001: ~b", [CallId, Status])
    end.

record_call(CallId, B2b, Owner) ->
    Cfg = persistent_term:get({?MODULE, cfg}),
    Srs = iolist_to_binary([
        "sip:srs@",
        env("DEMO_IP", maps:get(ip, Cfg)),
        ":",
        env("DEMO_SIP_PORT", maps:get(sip_port, Cfg))
    ]),
    case chappe_sip_siprec:start(B2b, Srs, #{owner => Owner}) of
        {ok, _Rec} -> log("call ~s recorded to ~s", [CallId, Srs]);
        {error, Why} -> log("call ~s not recorded: ~p", [CallId, Why])
    end.

%% the recording server: rtpengine sends the streams to this host
%% (DEMO_MEDIA_IP), each one written to the recording store
recording_server(Req, Res) ->
    case
        chappe_sip_siprec_srs:serve(Req, Res, #{
            store => default,
            ip => {0, 0, 0, 0},
            advertise => list_to_binary(env("DEMO_MEDIA_IP", "127.0.0.1"))
        })
    of
        {ok, #{call_ref := Ref, streams := Streams} = Srs} ->
            log("recording ~s: ~b streams", [Ref, length(Streams)]),
            {stopped, _} = chappe_sip_siprec_srs:run(Srs),
            %% each stream's writer closes when this handler returns
            log("recording ~s ended: demo_sbc:recordings(<<\"~s\">>)", [
                Ref, Ref
            ]);
        {error, not_recording_session} ->
            _ = chappe_sip_res:send(Res, 404);
        {error, Why} ->
            log("recording refused: ~p", [Why])
    end.

%% ---- the 2000 IVR ----

%% rtpengine's interfaces: FreeSWITCH is on the docker network, phones and
%% the conference mixer on the host
to_fs() ->
    #{a => #{direction => [docker, host]}, b => #{direction => [host, docker]}}.

to_host(BSide) ->
    Webrtc =
        case BSide of
            ws ->
                #{
                    ice => force,
                    transport_protocol => <<"UDP/TLS/RTP/SAVPF">>,
                    rtcp_mux => [offer, require]
                };
            _ ->
                #{}
        end,
    #{b => Webrtc#{direction => [host, host]}}.

prompt(Name) ->
    <<"/media/", (atom_to_binary(Name))/binary, ".wav">>.

ivr(Req, Res) ->
    CallId = chappe_sip_req:call_id(Req),
    case chappe_mrf:connect_caller(Req, Res, #{anchor_params => to_fs()}) of
        {ok, Ep, B2b} ->
            {ok, Node} = chappe_mrf:node(Ep),
            log("call ~s in the IVR on ~p", [CallId, Node]),
            menu(Ep, B2b, CallId, 3);
        {error, Why} ->
            log("IVR call ~s failed: ~p", [CallId, Why])
    end.

menu(_Ep, B2b, CallId, 0) ->
    log("call ~s: no choice, bye", [CallId]),
    chappe_sip_b2b:hangup(B2b, #{});
menu(Ep, B2b, CallId, Tries) ->
    case
        chappe_mrf:play_collect(Ep, #{
            file => prompt(menu), max => 1, timeout => 8000
        })
    of
        {ok, <<"1">>} ->
            to_bob(Ep, B2b, CallId);
        {ok, <<"2">>} ->
            echo(B2b, CallId);
        {ok, <<"3">>} ->
            native_conf(B2b, CallId);
        {ok, <<"4">>} ->
            fs_conf(B2b, CallId);
        {ok, <<"8">>} ->
            fork(Ep, CallId),
            menu(Ep, B2b, CallId, 3);
        {ok, <<"9">>} ->
            record(Ep, CallId),
            menu(Ep, B2b, CallId, 3);
        {ok, _} ->
            menu(Ep, B2b, CallId, Tries - 1);
        {error, Why} ->
            log("call ~s left the IVR: ~p", [CallId, Why])
    end.

%% 1: bob takes the call; the IVR's channel goes, the caller sees no
%% re-INVITE
to_bob(Ep, B2b, CallId) ->
    case route(<<"bob">>) of
        {ok, Uri, Opts} ->
            Side = maps:get(b_side, Opts, undefined),
            BOpts = (maps:with([flow], Opts))#{anchor_params => to_host(Side)},
            case chappe_mrf:bridge(B2b, Uri, BOpts) of
                ok ->
                    log("call ~s: bridged to bob", [CallId]),
                    wait_end(B2b, CallId);
                {error, Why} ->
                    log("call ~s: bob did not answer: ~p", [CallId, Why]),
                    _ = chappe_mrf:play(Ep, prompt(sorry)),
                    menu(Ep, B2b, CallId, 3)
            end;
        {error, _} ->
            _ = chappe_mrf:play(Ep, prompt(sorry)),
            menu(Ep, B2b, CallId, 3)
    end.

%% 2: a new endpoint that echoes; the caller moves onto it
echo(B2b, CallId) ->
    {ok, Echo} = chappe_mrf:create_endpoint(#{}),
    ok = chappe_mrf:bridge(B2b, Echo, #{anchor_params => to_fs()}),
    log("call ~s: on an echo endpoint", [CallId]),
    _ = spawn(fun() -> chappe_mrf:execute(Echo, <<"echo">>, <<>>) end),
    wait_end(B2b, CallId).

%% 3: the room on chappe_mix (it outlives every caller)
native_conf(B2b, CallId) ->
    {ok, Conf} = chappe_mrf:conference(<<"demo-native">>, #{
        anchor_params => to_host(undefined)
    }),
    {ok, Member} = chappe_mrf_conf:join(Conf, B2b, #{name => CallId}),
    log("call ~s: member ~s of demo-native", [CallId, Member]),
    wait_end(B2b, CallId).

%% 4: the room on FreeSWITCH, PIN 1234
fs_conf(B2b, CallId) ->
    {ok, Conf} = chappe_mrf:conference(<<"demo-fs">>, #{
        backend => fs, bridge => #{anchor_params => to_fs()}
    }),
    Opts = #{pin => <<"1234">>, pin_prompt => prompt(pin), name => CallId},
    case chappe_mrf_conf:join(Conf, B2b, Opts) of
        {ok, Member} ->
            log("call ~s: member ~s of demo-fs", [CallId, Member]),
            wait_end(B2b, CallId);
        {error, Why} ->
            log("call ~s: not in demo-fs: ~p", [CallId, Why]),
            chappe_sip_b2b:hangup(B2b, #{})
    end.

%% 8: fork the caller's audio into chappe_audio for 10 s: a process
%% prints its level twice a second, and the stream is written to the store
fork(Ep, CallId) ->
    Ref = call_ref(Ep),
    Printer = spawn(fun() -> levels(CallId, Ref, 0, []) end),
    {ok, Stream, Url} = chappe_audio:open(
        persistent_term:get({?MODULE, audio}), #{
            ref => Ref, owner => Printer, store => default
        }
    ),
    _ = chappe_mrf:play(Ep, prompt(speak)),
    Meta = iolist_to_binary(["{\"call\":\"", Ref, "\"}"]),
    case
        chappe_mrf:fork_audio_start(Ep, Url, #{
            mix => mono, rate => 8000, metadata => Meta
        })
    of
        ok ->
            log("call ~s: forking to ~s", [
                CallId, hd(binary:split(Url, <<"?">>))
            ]),
            timer:sleep(10000),
            _ = chappe_mrf:fork_audio_stop(Ep);
        {error, Why} ->
            log("call ~s: no fork: ~p", [CallId, Why]),
            chappe_audio:close(Stream)
    end.

%% The fork's events: a level line every 25 frames (500 ms), the loudest
%% of them, drawn as a bar.
levels(CallId, Ref, N, Lv) ->
    receive
        {chappe_audio, _, {connected, #{peer := Peer}}} ->
            log("call ~s: fork connected from ~p", [CallId, Peer]),
            levels(CallId, Ref, N, Lv);
        {chappe_audio, _, {text, Meta}} ->
            log("call ~s: fork metadata ~s", [CallId, Meta]),
            levels(CallId, Ref, N, Lv);
        {chappe_audio, _, {frame, Pcm}} when N =:= 24 ->
            Db = lists:max([
                db(L)
             || L <- [hd(chappe_audio:levels(Pcm, 1)) | Lv]
            ]),
            Bar = lists:duplicate(max(0, round((Db + 60) / 2)), $#),
            log("call ~s: ~6.1f dBFS ~s", [CallId, Db, Bar]),
            levels(CallId, Ref, 0, []);
        {chappe_audio, _, {frame, Pcm}} ->
            levels(CallId, Ref, N + 1, [hd(chappe_audio:levels(Pcm, 1)) | Lv]);
        {chappe_audio, _, {closed, Why}} ->
            log("call ~s: fork closed (~p); recordings: ~p", [
                CallId, Why, recordings(Ref)
            ])
    end.

db('-inf') -> -90.0;
db(X) -> max(-90.0, X).

call_ref(Ep) ->
    case chappe_mrf_endpoint:info(Ep) of
        #{call_ref := Ref} when is_binary(Ref) -> Ref;
        #{id := Id} -> Id
    end.

%% 9: record up to 10 s (or until silence), play it back, then adopt it
%% into the store under the call's call_ref (record/3 with store =>
%% default does both at once; the demo plays the file before moving it)
record(Ep, CallId) ->
    Id = binary:encode_hex(crypto:hash(md5, CallId), lowercase),
    File = <<"/media/msg-", Id/binary, ".wav">>,
    _ = chappe_mrf:play(Ep, prompt(record)),
    _ = chappe_mrf:record(Ep, File, #{
        max_secs => 10, silence_thresh => 200, silence_hits => 3
    }),
    log("call ~s: recorded ~s", [CallId, File]),
    _ = chappe_mrf:play(Ep, File),
    Ref = call_ref(Ep),
    case chappe_mrf_store:adopt(File, Ref, #{}) of
        {ok, Rec} ->
            log("call ~s: message ~s in the store: ~p", [
                CallId, Rec, recordings(Ref)
            ]);
        {error, Why} ->
            log("call ~s: message not stored: ~p", [CallId, Why])
    end.

%% the call runs in its own process; this one waits for its end
wait_end({_, Ref}, CallId) ->
    receive
        {chappe_sip_b2b, Ref, {done, Why}} ->
            log("call ~s ended ~p", [CallId, Why])
    end.

%% The IVR's prompts, in /media of the FreeSWITCH nodes: spoken by macOS
%% `say' when it is there, else a tone each. 16 kHz files, so an HD phone
%% hears them in wideband; FreeSWITCH resamples them for a G.711 one.
prompts(Dir) ->
    ok = filelib:ensure_path(Dir),
    Texts = [
        {menu, 440,
            "Press 1 for bob, 2 for an echo, 3 for the chappe conference, "
            "4 for the FreeSWITCH conference, 8 to see your voice level, "
            "or 9 to record a message."},
        {speak, 600, "Speak now. The demo prints your level for ten seconds."},
        {pin, 520, "Enter the conference PIN."},
        {record, 700,
            "Record your message after the beep. Stop talking to hear it back."},
        {sorry, 300, "Bob is not available."},
        {hd_pin, 520, "Welcome to the HD room. Enter its PIN."},
        {bad_pin, 300, "That PIN is not right. Goodbye."}
    ],
    lists:foreach(
        fun({Name, Freq, Text}) -> prompt_file(Dir, Name, Freq, Text) end, Texts
    ).

prompt_file(Dir, Name, Freq, Text) ->
    Path = filename:join(Dir, atom_to_list(Name) ++ ".wav"),
    _ =
        case os:find_executable("say") of
            false ->
                tone_wav(Path, Freq);
            Say ->
                _ = os:cmd(
                    Say ++ " -o '" ++ Path ++ "' --data-format=LEI16@" ++
                        integer_to_list(?PROMPT_RATE) ++ " '" ++ Text ++ "'"
                ),
                filelib:is_regular(Path) orelse tone_wav(Path, Freq)
        end,
    _ = file:change_mode(Path, 8#644),
    ok.

%% one second of Freq at ?PROMPT_RATE, 16-bit mono
tone_wav(Path, Freq) ->
    Rate = ?PROMPT_RATE,
    Data = <<
        <<
            (round(8000 * math:sin(2 * math:pi() * Freq * I / Rate))):16/little-signed
        >>
     || I <- lists:seq(0, Rate - 1)
    >>,
    Size = byte_size(Data),
    file:write_file(
        Path,
        <<"RIFF", (36 + Size):32/little, "WAVE", "fmt ", 16:32/little,
            1:16/little, 1:16/little, Rate:32/little, (2 * Rate):32/little,
            2:16/little, 16:16/little, "data", Size:32/little, Data/binary>>
    ).

%% ---- 1003, 1004 and 1005: the HD rooms ----

%% The HD room a dialled user names, by its number (1003) or the room's
%% name (demo-hd, the user of its conference URI): {ok, Room, Backend,
%% Join}, Join what its callers enter (#{} or #{pin => Pin}).
hd_room(User) ->
    Rooms = maps:get(hd_rooms, persistent_term:get({?MODULE, cfg}), []),
    case
        [
            {R, B, J}
         || {N, R, B, J} <- [with_join(Room) || Room <- Rooms],
            User =:= N orelse User =:= R
        ]
    of
        [{Room, Backend, Join} | _] -> {ok, Room, Backend, Join};
        [] -> error
    end.

with_join({N, R, B}) -> {N, R, B, #{}};
with_join({_N, _R, _B, _J} = Room) -> Room.

%% The caller joins straight from its INVITE: the room answers it (native:
%% the mixer through rtpengine; fs: an endpoint on the room's node), and
%% the call runs on its own once it is in. A room with a PIN has the
%% caller answered on the pool first (join_opts/2); a caller that does
%% not get in has heard why, and its call is over.
hd_call(CallId, Room, Backend, Join, Req, Res) ->
    maybe
        {ok, Conf} ?= hd_conf(Room, Backend),
        Opts = join_opts(CallId, Join),
        {ok, Member} ?= chappe_mrf_conf:join(Conf, {call, Req, Res}, Opts),
        log("call ~s: member ~s of ~s", [CallId, Member, Room])
    else
        {error, Why} ->
            %% a caller answered for its PIN has heard why and its call
            %% is over: the 503 is then refused (already_final)
            _ = chappe_sip_res:send(Res, 503),
            log("call ~s: not in ~s: ~p", [CallId, Room, Why])
    end.

%% A room with a pin: the caller enters it on an endpoint of the pool,
%% which it reaches through rtpengine as the IVR's callers do, asked by
%% the hd_pin prompt (16 kHz, so an HD phone hears it in HD), three tries,
%% and bad_pin before the call ends.
join_opts(CallId, #{pin := _} = Join) ->
    maps:merge(
        #{
            pin_prompt => prompt(hd_pin),
            pin_fail_prompt => prompt(bad_pin),
            pin_endpoint => #{anchor_params => to_fs()}
        },
        Join#{name => CallId}
    );
join_opts(CallId, Join) ->
    Join#{name => CallId}.

%% Every HD room is a focus room (RFC 4575 roster, REFERs to the room's
%% URI), its events to the keeper, who may REFER and where to, who may
%% take a member's place (Replaces), and how a party is dialed, with the
%% codecs chappe_mrf would offer it.
hd_conf(Room, Backend) ->
    Opts = hd_backend(Backend),
    Codecs = chappe_mrf:dial_codecs(Opts),
    chappe_mrf:conference(Room, Opts#{
        focus => true,
        notify => persistent_term:get({?MODULE, keeper}),
        refer_policy => fun(Info) -> refer_policy(Room, Info) end,
        replaces_policy => fun(Info) -> replaces_policy(Room, Info) end,
        dial => fun(Target) -> dial(Room, Codecs, Target) end
    }).

%% native: chappe_mix at 16 kHz on this host, behind rtpengine; the room
%% lays the L16 transcoding under these params (its own keys lose). The
%% endpoint a REFER dials out from joins it from the docker side.
hd_backend(native) ->
    #{
        rate => 16000,
        anchor_params => to_host(undefined),
        endpoint_params => #{
            offer => #{direction => [host, docker]},
            answer => #{direction => [docker, host]}
        }
    };
%% fs: mod_conference at 16 kHz, each caller bridged to an endpoint on
%% the room's node through rtpengine
hd_backend(fs) ->
    #{
        backend => fs,
        profile => <<"wideband">>,
        bridge => #{anchor_params => to_fs()}
    }.

%% Who may REFER an HD room, and where to. Who: the demo shell
%% (refer_add/2, refer_remove/2), whose From user is a random token made
%% at start, and the users registered here (a member's transfer button).
%% Nothing authenticates a From: anyone who reaches the node can pass as
%% a registered user. Where: a party to bring in must be a user or a
%% number of the demo (ours/2), so a REFER cannot make the pool call out;
%% a removal names a member, and the room checks that. Anything else
%% gets 403.
refer_policy(Room, #{action := Action, target := Target, referrer := From}) ->
    Cfg = persistent_term:get({?MODULE, cfg}),
    Who = sender(From, Cfg),
    Ok = Who =/= refused andalso target_allowed(Action, Target, Cfg),
    log("~s: REFER ~p ~s from ~s: ~s", [
        Room, Action, Target, sender_name(Who, From), allowed(Ok)
    ]),
    Ok.

allowed(true) -> "allowed";
allowed(false) -> "refused".

%% Who may take a member's place in an HD room with an INVITE whose
%% Replaces names the member's call: the senders refer_policy/2 trusts,
%% the demo shell and the users registered here, as the caller (its
%% From) or as who referred it (its Referred-By: an attended transfer
%% into the room). Nothing authenticates either header (the README's
%% Notes). The room checks that the Replaces names a member.
replaces_policy(Room, Info) ->
    #{caller := Caller, replaced := Id} = Info,
    {Ok, Why} = may_replace(Info, persistent_term:get({?MODULE, cfg})),
    log("~s: Replaces of member ~s from ~s (~s): ~s", [
        Room, Id, Caller, Why, allowed(Ok)
    ]),
    Ok.

%% Never an anonymous caller. Otherwise: the member itself, or a caller
%% whose Referred-By names it (chappe_mrf's own default), or a caller the
%% demo trusts as a REFER sender, by its From or its Referred-By. None of
%% it is authenticated.
may_replace(#{caller := Caller} = Info, Cfg) ->
    case anonymous(Caller) of
        true -> {false, "anonymous"};
        false -> may_replace_named(Info, Cfg)
    end.

may_replace_named(
    #{caller := Caller, referred_by := By, replaced_aor := Own}, Cfg
) ->
    case lists:member(Own, [aor(Caller), aor(By)]) of
        true ->
            {true, "the member or a caller it referred"};
        false ->
            case trusted([Caller, By], Cfg) of
                refused -> {false, "nobody the demo trusts"};
                {shell, _} -> {true, "vouched for by the demo shell"};
                {_Who, Uri} -> {true, ["vouched for by ", Uri]}
            end
    end.

%% the first of these URIs sender/2 trusts, with the URI, else refused
trusted([], _Cfg) ->
    refused;
trusted([undefined | Uris], Cfg) ->
    trusted(Uris, Cfg);
trusted([Uri | Uris], Cfg) ->
    case sender(Uri, Cfg) of
        refused -> trusted(Uris, Cfg);
        Who -> {Who, Uri}
    end.

aor(undefined) -> undefined;
aor(Uri) -> chappe_mrf_conf_refer_op:aor(addr(Uri)).

%% RFC 3323 4: a URI that names nobody (user anonymous, or host
%% anonymous.invalid), or none
anonymous(undefined) ->
    true;
anonymous(Uri) ->
    case chappe_sip_uri:parse(addr(Uri)) of
        {ok, #{user := <<"anonymous">>}} -> true;
        {ok, #{host := <<"anonymous.invalid">>}} -> true;
        {ok, _} -> false;
        error -> true
    end.

target_allowed(remove, _Target, _Cfg) -> true;
target_allowed(add, Target, Cfg) -> ours(Target, Cfg);
target_allowed(refer, Target, Cfg) -> ours(Target, Cfg);
target_allowed(_Action, _Target, _Cfg) -> false.

%% Whether a URI names a user or a FreeSWITCH number of the demo on one of
%% its domains (sip:bob@chappe.demo, sip:1000@127.0.0.1)
ours(Uri, Cfg) ->
    case chappe_sip_uri:parse(Uri) of
        {ok, #{user := User, host := Host}} ->
            lists:member(Host, domains(Cfg)) andalso
                (lists:keymember(User, 1, maps:get(users, Cfg)) orelse
                    lists:member(User, maps:get(extensions, Cfg, [])));
        _ ->
            false
    end.

%% Who a REFER or a SUBSCRIBE to an HD room comes from, by its From:
%% shell (the demo shell's token), {user, User} (a user registered here),
%% else refused.
sender(From, Cfg) ->
    Token = persistent_term:get({?MODULE, refer_token}),
    case referrer(From) of
        {Token, _Host} ->
            shell;
        {User, Host} when is_binary(User) ->
            Domains = domains(Cfg),
            case {lists:member(Host, Domains), located(User, Domains)} of
                {true, {ok, _, _}} -> {user, User};
                _ -> refused
            end;
        _ ->
            refused
    end.

%% the log never shows the shell's token
sender_name(shell, _From) -> "the demo shell";
sender_name(_Who, From) -> From.

%% the user and host of a From
referrer(From) ->
    case chappe_sip_uri:parse(addr(From)) of
        {ok, #{host := Host} = U} -> {maps:get(user, U, undefined), Host};
        _ -> undefined
    end.

%% A SUBSCRIBE to an HD room's roster (the conference package): from a
%% user registered here, else 403. The From is not authenticated: anyone
%% who can name a registered user reads the roster.
roster_subscribe(Req, Res) ->
    Cfg = persistent_term:get({?MODULE, cfg}),
    From = chappe_sip_req:get(<<"from">>, Req),
    case sender(From, Cfg) of
        {user, _} ->
            chappe_mrf:focus_subscribe(Req, Res);
        _ ->
            log("roster SUBSCRIBE from ~s: refused", [From]),
            _ = chappe_sip_res:send(Res, 403),
            ok
    end.

%% The dial string of a party a REFER brings in, a user or a number of
%% the demo (refer_policy/2 lets no other through): the pool calls it
%% through this node, which routes it as any call (route/1) and finds
%% where a user registered; the demo-room parameter tells invite/3 the
%% call comes from the pool. A dial fun builds the whole string, so it
%% puts the codecs chappe_mrf would offer (chappe_mrf:dial_codecs/1): a
%% native room bridges the party from its endpoint, which would offer
%% only its own codec (G.722 in a 16 kHz room).
dial(Room, Codecs, Target) ->
    Cfg = persistent_term:get({?MODULE, cfg}),
    {ok, #{user := User}} = chappe_sip_uri:parse(Target),
    [
        case Codecs of
            inherit -> [];
            _ -> [<<"[^^:absolute_codec_string=">>, Codecs, <<"]">>]
        end,
        <<"sofia/esl/sip:">>,
        User,
        <<"@host.docker.internal:">>,
        env("DEMO_SIP_PORT", maps:get(sip_port, Cfg)),
        <<";demo-room=">>,
        Room
    ].

%% A call a room dials out comes from the pool (docker), to a phone (the
%% host) or to a number of the pool: anchored, each side on the
%% rtpengine interface it is reached on.
dialed(Req, BSide, Opts) ->
    {ok, #{params := Params}} = chappe_sip_uri:parse(chappe_sip_req:uri(Req)),
    case maps:get(<<"demo-room">>, Params, false) of
        Room when is_binary(Room) ->
            log("call ~s: dialed out by ~s", [
                chappe_sip_req:call_id(Req), Room
            ]),
            Opts#{media => anchor, anchor_params => from_pool(BSide)};
        _ ->
            Opts
    end.

from_pool(fs) ->
    #{
        a => #{direction => [docker, docker]},
        b => #{direction => [docker, docker]}
    };
from_pool(_BSide) ->
    #{a => #{direction => [host, docker]}, b => #{direction => [docker, host]}}.

%% Ask an HD room to bring Uri in: an out-of-dialog REFER to the room's
%% URI with Uri as its Refer-To, as a phone's transfer would send. Prints
%% the REFER's answer and each NOTIFY; returns the final status.
-spec refer_add(binary() | string(), binary() | string()) ->
    {ok, 100..699} | {error, term()}.
refer_add(Room, Uri) ->
    refer(Room, #{uri => iolist_to_binary(Uri)}).

%% Ask an HD room to drop the member Uri names, by its address-of-record
%% (sip:bob@chappe.demo) or its endpoint entity (<room URI>;member=Id, as
%% the roster shows it): Refer-To <Uri;method=BYE>.
-spec refer_remove(binary() | string(), binary() | string()) ->
    {ok, 100..699} | {error, term()}.
refer_remove(Room, Uri) ->
    refer(Room, #{uri => iolist_to_binary(Uri), method => <<"BYE">>}).

refer(Room, Target) ->
    Cfg = persistent_term:get({?MODULE, cfg}),
    From = iolist_to_binary([
        "<sip:",
        persistent_term:get({?MODULE, refer_token}),
        "@",
        env("DEMO_IP", maps:get(ip, Cfg)),
        ":",
        env("DEMO_SIP_PORT", maps:get(sip_port, Cfg)),
        ">"
    ]),
    maybe
        {ok, Conf} ?= room(iolist_to_binary(Room)),
        {ok, Entity} ?= entity(chappe_mrf_conf:info(Conf)),
        sent(Entity, chappe_sip_refer:send(Entity, Target, #{from => From}))
    end.

%% a room's conference URI, which takes the REFERs
entity(#{entity := Entity}) when is_binary(Entity) -> {ok, Entity};
entity(#{}) -> {error, not_a_focus};
entity({error, _} = Err) -> Err.

%% the REFER's answer, then each NOTIFY up to the final status
sent(Entity, {ok, Id, #{status := St, subscription := Sub}}) ->
    io:format("REFER ~s: ~b~n", [Entity, St]),
    case Sub of
        true -> notifies(Id);
        false -> {ok, St}
    end;
sent(Entity, {error, {rejected, St, _Msg}}) ->
    io:format("REFER ~s: ~b~n", [Entity, St]),
    {ok, St};
sent(_Entity, {error, _} = Err) ->
    Err.

%% a running room, or an HD room started now
room(Name) ->
    case {lists:keyfind(Name, 1, chappe_mrf:conferences()), hd_room(Name)} of
        {{_, Conf}, _} -> {ok, Conf};
        {false, {ok, Room, Backend, _Join}} -> hd_conf(Room, Backend);
        {false, error} -> {error, no_conference}
    end.

notifies(Id) ->
    receive
        {refer_progress, Id, St} ->
            io:format("NOTIFY ~b~n", [St]),
            notifies(Id);
        {refer_done, Id, St} ->
            io:format("NOTIFY ~b (done)~n", [St]),
            {ok, St}
    after 45000 -> {error, no_final_notify}
    end.

%% The conferences running: name, backend, member count.
-spec confs() -> [{binary(), atom(), non_neg_integer()}].
confs() ->
    [
        {Name, maps:get(backend, I), maps:get(members, I)}
     || {Name, C} <- chappe_mrf:conferences(),
        I <- [chappe_mrf_conf:info(C)],
        is_map(I)
    ].

-spec members(binary() | string()) -> [map()] | {error, term()}.
members(Name) ->
    with_conf(Name, fun chappe_mrf_conf:members/1).

-spec kick(binary() | string(), binary() | string()) -> ok | {error, term()}.
kick(Name, Member) ->
    with_conf(Name, fun(C) ->
        chappe_mrf_conf:kick(C, iolist_to_binary(Member))
    end).

with_conf(Name, Fun) ->
    case lists:keyfind(iolist_to_binary(Name), 1, chappe_mrf:conferences()) of
        {_, C} -> Fun(C);
        false -> {error, no_conference}
    end.

%% ---- the shell ----

-spec calls() ->
    [#{call_id := binary(), from := binary(), to := binary(), media := atom()}].
calls() ->
    [
        maps:merge(
            #{call_id => C, from => F, to => T, media => mode(B2b)}, fs_of(C)
        )
     || {C, B2b, F, T} <- ets:tab2list(?CALLS)
    ].

fs_of(CallId) ->
    case ets:lookup(?FS, CallId) of
        [{_, Node, Uuid}] -> #{fs_node => Node, fs_uuid => Uuid};
        [] -> #{}
    end.

-spec anchor(binary() | string()) -> ok | {error, term()}.
anchor(CallId) -> switch(CallId, anchor).

-spec direct(binary() | string()) -> ok | {error, term()}.
direct(CallId) -> switch(CallId, direct).

switch(CallId, Mode) ->
    case ets:lookup(?CALLS, iolist_to_binary(CallId)) of
        [{_, B2b, _, _}] -> chappe_sip_b2b:set_media(B2b, Mode);
        [] -> {error, no_call}
    end.

%% The FreeSWITCH nodes: state, then sessions and idle CPU from their
%% HEARTBEAT.
-spec nodes() -> [{atom(), atom(), map()}].
nodes() ->
    [{N, St, load(N)} || {N, St} <- chappe_esl:nodes()].

load(Node) ->
    case chappe_esl:node_status(Node) of
        {ok, #{load := L}} -> maps:with([sessions, max_sessions, idle_cpu], L);
        _ -> #{}
    end.

-spec drain(atom()) -> ok | {error, not_found}.
drain(Node) -> chappe_esl:node_drain(Node).

-spec resume(atom()) -> ok | {error, not_found}.
resume(Node) -> chappe_esl:node_resume(Node).

-spec peers() -> [{term(), atom(), term()}].
peers() ->
    [
        {N, maps:get(state, I), maps:get(last_status, I)}
     || {N, I} <- chappe_sip:peers()
    ].

mode(B2b) ->
    case chappe_sip_b2b:info(B2b) of
        #{media := M} -> M;
        _ -> unknown
    end.

%% the calls table, and the process that logs peer and hold events; the
%% start fails if the keeper dies or is not up within 10 s
keeper() ->
    Self = self(),
    {Pid, Mon} = spawn_monitor(fun() ->
        _ = ets:new(?CALLS, [named_table, public]),
        _ = ets:new(?FS, [named_table, public]),
        ok = chappe_esl:node_subscribe(all),
        ok = chappe_esl:node_events(all),
        Self ! {keeper, self()},
        keep()
    end),
    receive
        {keeper, Pid} ->
            true = erlang:demonitor(Mon, [flush]),
            Pid;
        {'DOWN', Mon, process, Pid, Why} ->
            error({keeper, Why})
    after 10000 ->
        true = erlang:demonitor(Mon, [flush]),
        exit(Pid, kill),
        error({keeper, timeout})
    end.

keep() ->
    receive
        {chappe_sip_peer, Name, State} ->
            log("peer ~p is ~p", [Name, State]);
        {chappe_sip_qualify, Aor, Contact, unreachable} ->
            log("~s at ~s stopped answering, binding dropped", [Aor, Contact]);
        {chappe_esl_node, Name, {event, #{headers := H}}} ->
            channel(Name, H);
        {chappe_esl_node, Name, State} when is_atom(State) ->
            log("FreeSWITCH ~p is ~p", [Name, State]);
        %% the SIPREC recordings of 3001, which the keeper owns
        {chappe_sip_siprec, _Rec, {started, _}} ->
            log("recording started", []);
        {chappe_sip_siprec, _Rec, {stopped, #{reason := Why}}} ->
            log("recording stopped: ~p", [Why]);
        %% the B leg rings: the call is not in the table yet
        {chappe_sip_b2b, _Ref, {b_request, #{call_id := BCallId, uri := Uri}}} ->
            log("B leg ~s to ~s", [BCallId, Uri]);
        {chappe_sip_b2b, _Ref, {b_provisional, Msg}} ->
            log("B leg answered ~b", [chappe_sip_msg:status(Msg)]);
        {chappe_sip_b2b, _Ref, {b_early, _Dialog}} ->
            log("B leg early dialog", []);
        {chappe_sip_b2b, Ref, Event} ->
            Calls = [C || {C, {_, R}, _, _} <- ets:tab2list(?CALLS), R =:= Ref],
            log("call ~s: ~p", [Calls, Event]);
        %% the HD rooms' events, which the keeper gets (talking is noise)
        {chappe_mrf_conf, _Conf, {talking, _, _}} ->
            ok;
        {chappe_mrf_conf, Conf, Event} ->
            Names = [N || {N, C} <- chappe_mrf:conferences(), C =:= Conf],
            log("~s: ~0p", [Names, Event]);
        _ ->
            ok
    end,
    keep().

%% a CHANNEL_CREATE carrying our X-Chappe-Call: the call's channel there
channel(Node, #{<<"Event-Name">> := <<"CHANNEL_CREATE">>} = H) ->
    case maps:get(<<"variable_sip_h_X-Chappe-Call">>, H, undefined) of
        undefined ->
            ok;
        CallId ->
            Uuid = maps:get(<<"Unique-ID">>, H, undefined),
            true = ets:insert(?FS, {CallId, Node, Uuid}),
            log("call ~s is channel ~s on ~p", [CallId, Uuid, Node])
    end;
channel(_Node, _H) ->
    ok.

%% ---- the web page ----

%% A tiny HTTP server for web/index.html (the JsSIP softphone).
http(Port, Page) ->
    %% the listener lives in its own process, not the one that starts us
    Self = self(),
    _ = spawn(fun() ->
        {ok, L} = gen_tcp:listen(Port, [
            binary,
            {active, false},
            {reuseaddr, true},
            {packet, http_bin}
        ]),
        Self ! {http, self()},
        accept(L, Page)
    end),
    receive
        {http, _} -> ok
    after 5000 -> {error, http_listen}
    end.

accept(L, Page) ->
    {ok, S} = gen_tcp:accept(L),
    _ = spawn(fun() -> serve(S, Page) end),
    accept(L, Page).

serve(S, Page) ->
    _ = gen_tcp:recv(S, 0, 5000),
    {ok, Body} = file:read_file(Page),
    _ = gen_tcp:send(S, [
        <<"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n">>,
        <<"Content-Length: ">>,
        integer_to_binary(byte_size(Body)),
        <<"\r\nConnection: close\r\n\r\n">>,
        Body
    ]),
    gen_tcp:close(S).

log(Fmt, Args) ->
    io:format("demo: " ++ Fmt ++ "~n", Args).
