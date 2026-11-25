%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Media control-plane facade.
%%
%% One capability-based API over the media engines: the caller asks for a
%% capability (anchor a call's media, run a conference, ...) and the facade
%% routes it to a backend. rtpengine relays/anchors media (SDP in,
%% rewritten SDP out); chappe_mix mixes G.711 legs into a conference room.
%% The SIP processes never touch RTP: it stays in rtpengine and in the
%% chappe_mix conference processes.
%%
%% A session is correlated to its call by SIP dialog identity (Call-ID plus
%% the from/to tags), and its lifetime is bound to the calling process (the
%% call owner): when that process exits the backend session is torn down.
%%
%% The media libraries are dormant until configure/1 runs (from
%% chappe_sip:start/1's `media' option, else the `media' application env);
%% nothing is started otherwise.
%%
%% Usage (explicit, from a call handler):
%% ```
%% {ok, S} = chappe_sip_media:session(Dialog, #{capability => anchor}),
%% {ok, OfferB} = chappe_sip_media:offer(S, OfferA),
%% ... chappe_sip:create_uac(Uri, #{local_sdp => OfferB}) ...
%% {ok, AnswerA} = chappe_sip_media:answer(S, AnswerB),
%% %% BYE / owner exit tears the session down automatically
%% '''
-module(chappe_sip_media).

-export([
    configure/1,
    session/2,
    offer/2, offer/3,
    answer/2, answer/3,
    publish/2, publish/3,
    play/2,
    record/2,
    stop_record/1,
    dtmf/2,
    conference/2, conference/3,
    mixer_params/2,
    leave/1,
    mute/1,
    unmute/1,
    deaf/1,
    undeaf/1,
    relate/3,
    set_remote/2,
    subscribe/2,
    subscribe_answer/2,
    unsubscribe/2,
    duck/2,
    unduck/2,
    stop/1,
    info/1,
    set_owner/2,
    pid/1
]).
-export([anchor_offer/3, anchor_answer/3, anchor_release/1]).
-export([anchor_active/0, anchor_pinned/1]).
-export([bypass/2]).

-export_type([session/0, capability/0, backend/0, side/0]).

%% One side of a call for bypass/2: its SDP, its address, or both with the
%% address its signalling came from (source).
-type side() ::
    iodata()
    | inet:ip_address()
    | #{
        sdp => iodata(),
        addr => inet:ip_address() | binary(),
        source => inet:ip_address() | binary()
    }.

-type backend() :: rtpengine | mix.
-type capability() ::
    relay
    | anchor
    | transcode
    | play
    | record
    | dtmf
    | conference
    | subscribe
    | duck.

-record(media_session, {
    backend :: backend(),
    ref :: term(),
    identity :: map()
}).
-opaque session() :: #media_session{}.

-define(CAPS, {?MODULE, capabilities}).
-define(ANCHOR, {?MODULE, anchor_active}).

%% Default capability -> backend routing (overridable via the `capabilities'
%% key in the media config, or a `backend' option on session/2).
default_backend(relay) -> rtpengine;
default_backend(anchor) -> rtpengine;
default_backend(transcode) -> rtpengine;
default_backend(play) -> rtpengine;
default_backend(record) -> rtpengine;
default_backend(dtmf) -> rtpengine;
default_backend(conference) -> mix;
default_backend(subscribe) -> rtpengine;
default_backend(duck) -> rtpengine;
default_backend(_) -> undefined.

%% Bring up and register the configured backends. `undefined' (no `media'
%% option given to chappe_sip:start/1) reads the `media' application env; an
%% empty map (the default) is a no-op, so nothing in chappe_rtpengine /
%% chappe_mix runs unless media is configured.
-spec configure(map() | undefined) -> ok | {error, term()}.
configure(undefined) ->
    configure(chappe_sip_config:get(media));
configure(Config) when map_size(Config) =:= 0 ->
    ok;
configure(#{freeswitch := _}) ->
    {error, {unsupported_backend, freeswitch}};
configure(Config) when is_map(Config) ->
    persistent_term:put(?CAPS, maps:get(capabilities, Config, #{})),
    persistent_term:put(?ANCHOR, maps:is_key(rtpengine, Config)),
    case configure_backend(rtpengine, Config) of
        ok -> configure_backend(mix, Config);
        {error, _} = Err -> Err
    end;
configure(Other) ->
    {error, {bad_media_config, Other}}.

configure_backend(Backend, Config) ->
    case maps:get(Backend, Config, undefined) of
        undefined ->
            ok;
        BackendConfig ->
            case chappe_sip_media_sup:ensure_app(app(Backend)) of
                ok ->
                    backend_configure(Backend, BackendConfig);
                {error, _} = Err ->
                    Err
            end
    end.

backend_configure(rtpengine, #{nodes := Nodes}) ->
    chappe_sip_media_rtpengine:configure(Nodes);
backend_configure(rtpengine, Other) ->
    {error, {bad_media_config, rtpengine, Other}};
backend_configure(mix, MixConfig) ->
    chappe_sip_media_mix:configure(MixConfig).

%% Start a media session for a call. Identity is a dialog handle (its
%% Call-ID and tags are read out, see resolve_identity/2) or an explicit
%% `#{call_id := _, from_tag => _, to_tag => _}' map. Opts:
%%   #{capability => capability(), backend => backend(),
%%     node => atom(), dtmf => boolean(), role => uas | uac, _ => _}
-spec session(chappe_sip_dialog:dialog() | map(), map()) ->
    {ok, session()} | {error, term()}.
session(Identity, Opts) ->
    Id = resolve_identity(Identity, Opts),
    Cap = maps:get(capability, Opts, anchor),
    case maps:get(backend, Opts, backend_for(Cap)) of
        undefined ->
            {error, {no_backend, Cap}};
        Backend ->
            start_session(Backend, Id, Opts)
    end.

start_session(Backend, Id, Opts) ->
    case backend_start(Backend, Id, Opts) of
        {ok, Ref} ->
            {ok, #media_session{backend = Backend, ref = Ref, identity = Id}};
        {error, _} = Err ->
            Err
    end.

backend_start(rtpengine, Id, Opts) ->
    chappe_sip_media_rtpengine:start(Id, Opts);
backend_start(mix, Id, Opts) ->
    chappe_sip_media_mix:start(Id, Opts);
backend_start(Other, _Id, _Opts) ->
    {error, {unknown_backend, Other}}.

%% Offer the caller's SDP into the session; returns the rewritten SDP to send
%% onward. rtpengine only. Opts: from_tag, params (rtpengine flags), and
%% branch => true for one more offer of the same party while the first
%% waits for its answer (a fork branch with other flags, named by a
%% via_branch in params).
-spec offer(session(), iodata()) -> {ok, binary()} | {error, term()}.
offer(S, Sdp) ->
    offer(S, Sdp, #{}).

-spec offer(session(), iodata(), map()) -> {ok, binary()} | {error, term()}.
offer(#media_session{backend = rtpengine, ref = R, identity = I}, Sdp, O) ->
    chappe_sip_media_rtpengine:offer(R, I, Sdp, O);
offer(_S, _Sdp, _O) ->
    {error, {unsupported, offer}}.

%% Answer the peer's SDP into the session; returns the rewritten SDP.
%% rtpengine only.
-spec answer(session(), iodata()) -> {ok, binary()} | {error, term()}.
answer(S, Sdp) ->
    answer(S, Sdp, #{}).

-spec answer(session(), iodata(), map()) -> {ok, binary()} | {error, term()}.
answer(#media_session{backend = rtpengine, ref = R, identity = I}, Sdp, O) ->
    chappe_sip_media_rtpengine:answer(R, I, Sdp, O);
answer(_S, _Sdp, _O) ->
    {error, {unsupported, answer}}.

%% Anchor a call that has no second leg: the offer is answered by the media
%% engine itself and the returned SDP is what goes into the 200 OK. Use it for
%% a receive-only session (a SIPREC recording server taking N sendonly streams,
%% a publisher feeding subscribers) where there is no onward UAC to negotiate
%% with. Every m-line of the offer is answered. Tap the streams afterwards with
%% subscribe/2. rtpengine only.
-spec publish(session(), iodata()) -> {ok, binary()} | {error, term()}.
publish(S, Sdp) ->
    publish(S, Sdp, #{}).

-spec publish(session(), iodata(), map()) -> {ok, binary()} | {error, term()}.
publish(#media_session{backend = rtpengine, ref = R, identity = I}, Sdp, O) ->
    chappe_sip_media_rtpengine:publish(R, I, Sdp, O);
publish(_S, _Sdp, _O) ->
    {error, {unsupported, publish}}.

%% Play a prompt into the session. Media is an rtpengine param map
%% (#{file => _} etc.). rtpengine only, as are record and dtmf.
-spec play(session(), map()) -> ok | {error, term()}.
play(#media_session{backend = rtpengine, ref = R}, Media) ->
    chappe_sip_media_rtpengine:play(R, Media);
play(_S, _Media) ->
    {error, {unsupported, play}}.

-spec record(session(), map()) -> ok | {error, term()}.
record(#media_session{backend = rtpengine, ref = R}, Opts) ->
    chappe_sip_media_rtpengine:record(R, Opts);
record(_S, _Opts) ->
    {error, {unsupported, record}}.

-spec stop_record(session()) -> ok | {error, term()}.
stop_record(#media_session{backend = rtpengine, ref = R}) ->
    chappe_sip_media_rtpengine:stop_record(R);
stop_record(_S) ->
    {error, {unsupported, record}}.

-spec dtmf(session(), map()) -> ok | {error, term()}.
dtmf(#media_session{backend = rtpengine, ref = R}, Params) ->
    chappe_sip_media_rtpengine:dtmf(R, Params);
dtmf(_S, _Params) ->
    {error, {unsupported, dtmf}}.

%% Join the session to a conference room (chappe_mix backend) and get the
%% SDP to send toward the call: G.711 in an 8 kHz room, L16/16000 in a
%% 16 kHz one. Opts: room (required), sdp (the
%% call's offer: the mixer answers it; without it the mixer offers and you
%% pass the answer to set_remote/2), owner (owner of a room this join
%% creates), persist (true: that room stays up with no leg, until its
%% owner exits), rate (8000 | 16000: the rate of a room this join creates,
%% default the configured one; a join asking another rate than a running
%% room's gets {error, {rate_mismatch, RoomRate}}), law (ulaw | alaw, for
%% an offer in an 8 kHz room), mute, name, direction
%% (sendrecv | sendonly | recvonly | inactive, seen from the room),
%% talk_events (true: the caller gets {chappe_sip_media, {talking, Room,
%% true | false}}), talk_tag (the event is then {chappe_sip_media,
%% {talking, Room, Tag, true | false}}).
-spec conference(session(), #{room := binary(), _ => _}) ->
    {ok, binary()} | {error, term()}.
conference(#media_session{backend = mix, ref = R, identity = I}, Opts) ->
    chappe_sip_media_mix:conference(R, I, Opts);
conference(_S, _Opts) ->
    {error, {unsupported, conference}}.

%% conference/2 with the room named apart.
-spec conference(session(), binary(), map()) ->
    {ok, binary()} | {error, term()}.
conference(S, Room, Opts) ->
    conference(S, Opts#{room => Room}).

%% The rtpengine flags that put a call in front of a mixer room of Rate,
%% for the offer going Toward: mixer (a caller's offer on its way to the
%% mixer leg: rtpengine offers the mixer only the room's format, L16/16000
%% and telephone-event/16000, and transcodes the caller's codec to it) or
%% endpoint (the mixer's offer on its way to an endpoint: rtpengine offers
%% it G.722, PCMU, PCMA and telephone-event/8000 in place of L16). An
%% 8 kHz room needs none: #{}. Merge them under your own anchor params,
%% yours winning. A 16 kHz room needs an rtpengine with L16 (tested on
%% 26.3.1.4; 11.5.1.18 has none; upstream tags have it from 13.4.1.1).
-spec mixer_params(8000 | 16000, mixer | endpoint) -> map().
mixer_params(8000, _Toward) ->
    #{};
mixer_params(16000, mixer) ->
    #{
        codec => #{
            mask => [<<"all">>],
            transcode => [<<"L16/16000/1">>, <<"telephone-event/16000">>]
        }
    };
mixer_params(16000, endpoint) ->
    #{
        codec => #{
            mask => [<<"all">>],
            transcode => [
                <<"G722">>, <<"PCMU">>, <<"PCMA">>, <<"telephone-event/8000">>
            ]
        }
    }.

%% Take the session's leg out of its room. The room stops with its last
%% leg.
-spec leave(session()) -> ok | {error, term()}.
leave(#media_session{backend = mix, ref = R}) ->
    chappe_sip_media_mix:leave(R);
leave(_S) ->
    {error, {unsupported, conference}}.

%% A muted leg hears the room but is not mixed into it.
-spec mute(session()) -> ok | {error, term()}.
mute(#media_session{backend = mix, ref = R}) ->
    chappe_sip_media_mix:mute(R, true);
mute(_S) ->
    {error, {unsupported, conference}}.

-spec unmute(session()) -> ok | {error, term()}.
unmute(#media_session{backend = mix, ref = R}) ->
    chappe_sip_media_mix:mute(R, false);
unmute(_S) ->
    {error, {unsupported, conference}}.

%% A deaf leg is still heard by the room, and the room sends it nothing.
-spec deaf(session()) -> ok | {error, term()}.
deaf(#media_session{backend = mix, ref = R}) ->
    chappe_sip_media_mix:deaf(R, true);
deaf(_S) ->
    {error, {unsupported, conference}}.

-spec undeaf(session()) -> ok | {error, term()}.
undeaf(#media_session{backend = mix, ref = R}) ->
    chappe_sip_media_mix:deaf(R, false);
undeaf(_S) ->
    {error, {unsupported, conference}}.

%% Whether Listener's leg hears Speaker's (both in one room): nohear
%% takes Speaker out of what Listener hears, its CSRC lists and the
%% events it is sent.
-spec relate(session(), session(), hear | nohear) -> ok | {error, term()}.
relate(
    #media_session{backend = mix, ref = L},
    #media_session{backend = mix, ref = Sp},
    Rel
) when Rel =:= hear; Rel =:= nohear ->
    chappe_sip_media_mix:relate(L, Sp, Rel);
relate(_L, _S, _Rel) ->
    {error, {unsupported, conference}}.

%% Tell the leg where the far end is once you know it: the SDP answering
%% the mixer's offer, or an explicit {Ip, Port}.
-spec set_remote(
    session(), iodata() | {inet:ip_address(), inet:port_number()}
) -> ok | {error, term()}.
set_remote(#media_session{backend = mix, ref = R}, Remote) ->
    chappe_sip_media_mix:set_remote(R, Remote);
set_remote(_S, _Remote) ->
    {error, {unsupported, conference}}.

%% Tap the session's media to an external consumer (e.g. an STT receiver).
%% Returns an SDP offer for the tapped streams plus a to-tag naming the
%% subscription; answer it with subscribe_answer/2. Opts select the tapped
%% party (`party => caller | callee' or `from_tags => [Tag]', or `flags =>
%% [all]' for everyone) and the fork output (`codec', `ptime'); the fork
%% defaults to PCMU so the receiver decode is trivial. Transcoded forks need an
%% rtpengine built with transcoding support; a node without it surfaces the
%% rtpengine error. rtpengine only.
%%
%% `streams' lists the offered media streams in m-line order with their
%% a=label, which is what a multi-stream tap (one m-line per recorded party)
%% is keyed on: subscribe once per stream and answer each subscription with
%% chappe_rtpengine_sdp:fork_answer/3 to route that one stream to its own
%% receiver.
%%
%% `holder => pid()' gives the subscription to that process: the media
%% session removes it from rtpengine when the process exits, so a consumer
%% that crashes leaves no fork behind (unsubscribe/2 releases it).
-spec subscribe(session(), map()) ->
    {ok, #{
        sdp := binary(),
        to_tag := binary(),
        streams := [chappe_rtpengine_sdp:stream()]
    }}
    | {error, term()}.
subscribe(#media_session{backend = rtpengine, ref = R, identity = I}, Opts) ->
    chappe_sip_media_rtpengine:subscribe(R, I, Opts);
subscribe(_S, _Opts) ->
    {error, {unsupported, subscribe}}.

%% Answer a subscription with the consumer's SDP. Opts: #{to_tag := _, sdp := _}.
-spec subscribe_answer(session(), map()) -> ok | {error, term()}.
subscribe_answer(#media_session{backend = rtpengine, ref = R}, Params) ->
    chappe_sip_media_rtpengine:subscribe_answer(R, Params);
subscribe_answer(_S, _Params) ->
    {error, {unsupported, subscribe}}.

%% Tear a subscription down. Opts: #{to_tag := _}.
-spec unsubscribe(session(), map()) -> ok | {error, term()}.
unsubscribe(#media_session{backend = rtpengine, ref = R}, Params) ->
    chappe_sip_media_rtpengine:unsubscribe(R, Params);
unsubscribe(_S, _Params) ->
    {error, {unsupported, subscribe}}.

%% Duck a party's media while a prompt plays. Opts: #{party => caller | callee
%% (whole call if omitted), mode => block | silence (default block)}. `block'
%% stops the party's packets; `silence' keeps them flowing but muted. rtpengine
%% only.
-spec duck(session(), map()) -> ok | {error, term()}.
duck(#media_session{backend = rtpengine, ref = R}, Opts) ->
    chappe_sip_media_rtpengine:duck(R, Opts);
duck(_S, _Opts) ->
    {error, {unsupported, duck}}.

%% Undo duck/2 (the matching unblock/unsilence). Same Opts as duck/2.
-spec unduck(session(), map()) -> ok | {error, term()}.
unduck(#media_session{backend = rtpengine, ref = R}, Opts) ->
    chappe_sip_media_rtpengine:unduck(R, Opts);
unduck(_S, _Opts) ->
    {error, {unsupported, duck}}.

-spec stop(session()) -> ok.
stop(#media_session{backend = rtpengine, ref = R}) ->
    chappe_sip_media_rtpengine:stop(R);
stop(#media_session{backend = mix, ref = R}) ->
    chappe_sip_media_mix:stop(R).

%% Hand an rtpengine session to another process: its death ends the
%% session from now on (a call carried on by another process than the
%% one that set it up).
-spec set_owner(session(), pid()) -> ok | {error, term()}.
set_owner(#media_session{backend = rtpengine, ref = R}, Owner) ->
    chappe_sip_media_rtpengine:set_owner(R, Owner);
set_owner(_S, _Owner) ->
    {error, {unsupported, set_owner}}.

%% The process holding an rtpengine session (undefined for another
%% backend): what the call's lookup (chappe_sip_call) watches.
-spec pid(session()) -> pid() | undefined.
pid(#media_session{backend = rtpengine, ref = R}) when is_pid(R) -> R;
pid(_S) -> undefined.

-spec info(session()) -> map() | {error, term()}.
info(#media_session{backend = rtpengine, ref = R}) ->
    chappe_sip_media_rtpengine:info(R);
info(#media_session{backend = mix, ref = R}) ->
    chappe_sip_media_mix:info(R).

%% ---- stateless anchor (proxy media) ----
%%
%% For a record-routing proxy that anchors media without owning a session
%% process: rtpengine holds the call by Call-ID and the node is pinned by
%% Call-ID. Always the rtpengine backend. Identity is a map read from the SIP
%% message; Params carries rtpengine flags.

%% Anchor the offer. Identity: #{call_id, from_tag}. Returns the rewritten SDP.
-spec anchor_offer(map(), iodata(), map()) ->
    {ok, binary()} | {error, term()}.
anchor_offer(Identity, Sdp, Params) ->
    chappe_sip_media_rtpengine:anchor_offer(Identity, Sdp, Params).

%% Anchor the answer. Identity: #{call_id, from_tag, to_tag}.
-spec anchor_answer(map(), iodata(), map()) ->
    {ok, binary()} | {error, term()}.
anchor_answer(Identity, Sdp, Params) ->
    chappe_sip_media_rtpengine:anchor_answer(Identity, Sdp, Params).

%% Release the anchored call. Identity: #{call_id, from_tag}.
-spec anchor_release(map()) -> ok.
anchor_release(Identity) ->
    chappe_sip_media_rtpengine:anchor_release(Identity).

%% Whether media anchoring is configured (an rtpengine backend). A proxy uses
%% this to decide, without an app option, whether to consult the call pin on the
%% engine-driven in-dialog path. False (the default) means the anchor is never
%% touched, so a plain proxy is unaffected.
-spec anchor_active() -> boolean().
anchor_active() ->
    persistent_term:get(?ANCHOR, false).

%% Whether this Call-ID currently has an anchored (pinned) media session.
-spec anchor_pinned(binary()) -> boolean().
anchor_pinned(CallId) ->
    chappe_sip_media_rtpengine:anchor_pinned(CallId).

%% ---- topology ----

%% Whether a call's media can flow directly between its two sides or must
%% go through rtpengine. It anchors when:
%%   - either side is WebRTC (a SAVPF profile or ICE): rtpengine bridges
%%     DTLS-SRTP and ICE to plain RTP;
%%   - a side's address is unknown, or the two are of different families;
%%   - a side's SDP c= address is not the address its signalling came from
%%     (source): the endpoint is behind a NAT;
%%   - an address is private and no configured network holds both.
%% Otherwise (two public addresses, or two in one of the networks) it is
%% direct. Opts: #{networks => [Cidr]}, each Cidr a binary such as
%% <<"10.1.0.0/16">>. A pure function: use it in the media fun of
%% chappe_sip_b2b.
-spec bypass(#{a := side(), b := side()}, #{networks => [binary()]}) ->
    direct | anchor.
bypass(#{a := A, b := B}, Opts) ->
    SA = side(A),
    SB = side(B),
    Nets = [
        N
     || C <- maps:get(networks, Opts, []), {ok, N} <- [chappe_sip_net:cidr(C)]
    ],
    case
        webrtc_side(SA) orelse webrtc_side(SB) orelse natted(SA) orelse
            natted(SB)
    of
        true -> anchor;
        false -> bypass_addrs(maps:get(addr, SA), maps:get(addr, SB), Nets)
    end.

bypass_addrs(undefined, _B, _Nets) ->
    anchor;
bypass_addrs(_A, undefined, _Nets) ->
    anchor;
bypass_addrs(A, B, _Nets) when tuple_size(A) =/= tuple_size(B) ->
    anchor;
bypass_addrs(A, B, Nets) ->
    case private(A) orelse private(B) of
        false ->
            direct;
        true ->
            case
                lists:any(
                    fun(N) ->
                        chappe_sip_net:in_net(A, N) andalso
                            chappe_sip_net:in_net(B, N)
                    end,
                    Nets
                )
            of
                true -> direct;
                false -> anchor
            end
    end.

side(#{} = M) ->
    Sdp = maps:get(sdp, M, undefined),
    SdpAddr =
        case Sdp of
            undefined -> undefined;
            _ -> chappe_sip_sdp:connection(Sdp)
        end,
    Given = ip(maps:get(addr, M, undefined)),
    #{
        sdp => Sdp,
        addr =>
            case SdpAddr of
                undefined -> Given;
                _ -> SdpAddr
            end,
        source => ip(maps:get(source, M, undefined))
    };
side(Ip) when is_tuple(Ip) ->
    side(#{addr => Ip});
side(Sdp) ->
    side(#{sdp => Sdp}).

webrtc_side(#{sdp := undefined}) -> false;
webrtc_side(#{sdp := Sdp}) -> chappe_sip_sdp:webrtc(Sdp).

%% the media address an SDP gives is not where its signalling came from
natted(#{sdp := Sdp, addr := Addr, source := Src}) when
    Sdp =/= undefined, Addr =/= undefined, Src =/= undefined
->
    Addr =/= Src;
natted(_Side) ->
    false.

ip(undefined) ->
    undefined;
ip(Ip) when is_tuple(Ip) ->
    Ip;
ip(Bin) when is_binary(Bin) ->
    case chappe_sip_sdp:address(Bin) of
        {ok, Ip} -> Ip;
        error -> undefined
    end.

%% RFC 1918, RFC 6598 (shared), loopback and link-local, and their IPv6
%% counterparts (RFC 4193 unique local, link-local, loopback)
private({10, _, _, _}) -> true;
private({172, B, _, _}) when B >= 16 andalso B =< 31 -> true;
private({192, 168, _, _}) -> true;
private({100, B, _, _}) when B >= 64 andalso B =< 127 -> true;
private({127, _, _, _}) -> true;
private({169, 254, _, _}) -> true;
private({A, _, _, _, _, _, _, _}) when A band 16#fe00 =:= 16#fc00 -> true;
private({A, _, _, _, _, _, _, _}) when A band 16#ffc0 =:= 16#fe80 -> true;
private({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
private(_) -> false.

%% internal

%% Resolve the routed backend for a capability: config override first, then
%% the built-in default map.
backend_for(Cap) ->
    Overrides =
        try
            persistent_term:get(?CAPS)
        catch
            error:badarg -> #{}
        end,
    maps:get(Cap, Overrides, default_backend(Cap)).

%% A dialog handle read out as rtpengine's identity. from_tag is the From
%% tag of the dialog: the peer's tag in a UAS dialog, ours in a UAC dialog.
%% The role comes from Opts (`role'), else from the dialog index; a dialog
%% the index does not hold (not yet confirmed) is taken as UAS, the usual
%% case of anchoring an incoming call.
resolve_identity(Id, _Opts) when is_map(Id) ->
    Id;
resolve_identity(Dialog, Opts) ->
    CallId = chappe_sip_dialog:call_id(Dialog),
    Local = chappe_sip_dialog:local_tag(Dialog),
    Remote = chappe_sip_dialog:remote_tag(Dialog),
    {From, To} =
        case dialog_role(CallId, Local, Remote, Opts) of
            uac -> {Local, Remote};
            uas -> {Remote, Local}
        end,
    #{call_id => CallId, from_tag => From, to_tag => To}.

dialog_role(CallId, Local, Remote, Opts) ->
    case maps:find(role, Opts) of
        {ok, Role} ->
            Role;
        error ->
            case chappe_sip_dialog_index:lookup({CallId, Local, Remote}) of
                {ok, {_Pid, _Id, _State, Role}} -> Role;
                not_found -> uas
            end
    end.

app(rtpengine) -> chappe_rtpengine;
app(mix) -> chappe_mix.
