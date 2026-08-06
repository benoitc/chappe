%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Media control-plane facade.
%%
%% One capability-based API over the external media engines: the caller asks
%% for a capability (anchor a call's media, run a conference, ...) and the
%% facade routes it to a backend. rtpengine relays/anchors media (SDP in,
%% rewritten SDP out); FreeSWITCH (over ESL) terminates a media leg for
%% conferencing and IVR. The media plane (RTP) stays in those external
%% daemons; only this control plane runs in the BEAM.
%%
%% A session is correlated to its call by SIP dialog identity (Call-ID plus
%% the from/to tags), and its lifetime is bound to the calling process (the
%% call owner): when that process exits the backend session is torn down.
%%
%% The media libraries are dormant until configure/1 runs (from chappe_sip:start/1's
%% `media' option); nothing is started otherwise.
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
    play/2,
    record/2,
    stop_record/1,
    dtmf/2,
    conference/3,
    subscribe/2,
    subscribe_answer/2,
    unsubscribe/2,
    duck/2,
    unduck/2,
    stop/1,
    info/1
]).
-export([anchor_offer/3, anchor_answer/3, anchor_release/1]).
-export([anchor_active/0, anchor_pinned/1]).

-export_type([session/0, capability/0, backend/0]).

-type backend() :: rtpengine | freeswitch.
-type capability() ::
    relay
    | anchor
    | transcode
    | play
    | record
    | dtmf
    | conference
    | ivr
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
default_backend(conference) -> freeswitch;
default_backend(ivr) -> freeswitch;
default_backend(subscribe) -> rtpengine;
default_backend(duck) -> rtpengine;
default_backend(_) -> undefined.

%% Bring up and register the configured backends. Called once at start with
%% the `media' config map; an empty map (the default) is a no-op, so nothing
%% in chappe_rtpengine / chappe_esl runs unless media is configured.
-spec configure(map() | undefined) -> ok | {error, term()}.
configure(undefined) ->
    ok;
configure(Config) when map_size(Config) =:= 0 ->
    ok;
configure(Config) ->
    persistent_term:put(?CAPS, maps:get(capabilities, Config, #{})),
    persistent_term:put(?ANCHOR, maps:is_key(rtpengine, Config)),
    case configure_backend(rtpengine, Config) of
        ok -> configure_backend(freeswitch, Config);
        {error, _} = Err -> Err
    end.

configure_backend(Backend, Config) ->
    case maps:get(Backend, Config, undefined) of
        undefined ->
            ok;
        #{nodes := Nodes} ->
            case chappe_sip_media_sup:ensure_app(app(Backend)) of
                ok ->
                    backend_configure(Backend, Nodes);
                {error, _} = Err ->
                    Err
            end
    end.

backend_configure(rtpengine, Nodes) ->
    chappe_sip_media_rtpengine:configure(Nodes);
backend_configure(freeswitch, Nodes) ->
    chappe_sip_media_freeswitch:configure(Nodes).

%% Start a media session for a call. Identity is a dialog handle (its
%% Call-ID and tags are read out) or an explicit
%% `#{call_id := _, from_tag => _, to_tag => _}' map. Opts:
%%   #{capability => capability(), backend => backend(),
%%     node => atom(), dtmf => boolean(), _ => _}
-spec session(chappe_sip_dialog:dialog() | map(), map()) ->
    {ok, session()} | {error, term()}.
session(Identity, Opts) ->
    Id = resolve_identity(Identity),
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
backend_start(freeswitch, Id, Opts) ->
    chappe_sip_media_freeswitch:start(Id, Opts).

%% Offer the caller's SDP into the session; returns the rewritten SDP to send
%% onward. rtpengine only; unsupported on the FreeSWITCH backend.
-spec offer(session(), iodata()) -> {ok, binary()} | {error, term()}.
offer(S, Sdp) ->
    offer(S, Sdp, #{}).

-spec offer(session(), iodata(), map()) -> {ok, binary()} | {error, term()}.
offer(#media_session{backend = rtpengine, ref = R, identity = I}, Sdp, O) ->
    chappe_sip_media_rtpengine:offer(R, I, Sdp, O);
offer(#media_session{backend = freeswitch, ref = R, identity = I}, Sdp, O) ->
    chappe_sip_media_freeswitch:offer(R, I, Sdp, O).

%% Answer the peer's SDP into the session; returns the rewritten SDP.
-spec answer(session(), iodata()) -> {ok, binary()} | {error, term()}.
answer(S, Sdp) ->
    answer(S, Sdp, #{}).

-spec answer(session(), iodata(), map()) -> {ok, binary()} | {error, term()}.
answer(#media_session{backend = rtpengine, ref = R, identity = I}, Sdp, O) ->
    chappe_sip_media_rtpengine:answer(R, I, Sdp, O);
answer(#media_session{backend = freeswitch, ref = R, identity = I}, Sdp, O) ->
    chappe_sip_media_freeswitch:answer(R, I, Sdp, O).

%% Play a prompt into the session. Media is a backend param map (rtpengine:
%% #{file => _} etc.).
-spec play(session(), map()) -> ok | {error, term()}.
play(#media_session{backend = rtpengine, ref = R}, Media) ->
    chappe_sip_media_rtpengine:play(R, Media);
play(#media_session{backend = freeswitch, ref = R}, Media) ->
    chappe_sip_media_freeswitch:play(R, Media).

-spec record(session(), map()) -> ok | {error, term()}.
record(#media_session{backend = rtpengine, ref = R}, Opts) ->
    chappe_sip_media_rtpengine:record(R, Opts);
record(#media_session{backend = freeswitch, ref = R}, Opts) ->
    chappe_sip_media_freeswitch:record(R, Opts).

-spec stop_record(session()) -> ok | {error, term()}.
stop_record(#media_session{backend = rtpengine, ref = R}) ->
    chappe_sip_media_rtpengine:stop_record(R);
stop_record(#media_session{backend = freeswitch, ref = R}) ->
    chappe_sip_media_freeswitch:stop_record(R).

-spec dtmf(session(), map()) -> ok | {error, term()}.
dtmf(#media_session{backend = rtpengine, ref = R}, Params) ->
    chappe_sip_media_rtpengine:dtmf(R, Params);
dtmf(#media_session{backend = freeswitch, ref = R}, Params) ->
    chappe_sip_media_freeswitch:dtmf(R, Params).

%% Join the session's media to a named conference (FreeSWITCH backend).
-spec conference(session(), binary(), map()) -> ok | {error, term()}.
conference(#media_session{backend = rtpengine, ref = R}, Room, Opts) ->
    chappe_sip_media_rtpengine:conference(R, Room, Opts);
conference(#media_session{backend = freeswitch, ref = R}, Room, Opts) ->
    chappe_sip_media_freeswitch:conference(R, Room, Opts).

%% Tap the session's media to an external consumer (e.g. an STT receiver).
%% Returns an SDP offer for the tapped streams plus a to-tag naming the
%% subscription; answer it with subscribe_answer/2. Opts select the tapped
%% party (`party => caller | callee' or `from_tags => [Tag]', or `flags =>
%% [all]' for everyone) and the fork output (`codec', `ptime'); the fork
%% defaults to PCMU so the receiver decode is trivial. Transcoded forks need an
%% rtpengine built with transcoding support; a node without it surfaces the
%% rtpengine error. rtpengine only.
-spec subscribe(session(), map()) ->
    {ok, #{sdp := binary(), to_tag := binary()}} | {error, term()}.
subscribe(#media_session{backend = rtpengine, ref = R, identity = I}, Opts) ->
    chappe_sip_media_rtpengine:subscribe(R, I, Opts);
subscribe(#media_session{backend = freeswitch, ref = R}, Opts) ->
    chappe_sip_media_freeswitch:subscribe(R, Opts).

%% Answer a subscription with the consumer's SDP. Opts: #{to_tag := _, sdp := _}.
-spec subscribe_answer(session(), map()) -> ok | {error, term()}.
subscribe_answer(#media_session{backend = rtpengine, ref = R}, Params) ->
    chappe_sip_media_rtpengine:subscribe_answer(R, Params);
subscribe_answer(#media_session{backend = freeswitch, ref = R}, Params) ->
    chappe_sip_media_freeswitch:subscribe_answer(R, Params).

%% Tear a subscription down. Opts: #{to_tag := _}.
-spec unsubscribe(session(), map()) -> ok | {error, term()}.
unsubscribe(#media_session{backend = rtpengine, ref = R}, Params) ->
    chappe_sip_media_rtpengine:unsubscribe(R, Params);
unsubscribe(#media_session{backend = freeswitch, ref = R}, Params) ->
    chappe_sip_media_freeswitch:unsubscribe(R, Params).

%% Duck a party's media while a prompt plays. Opts: #{party => caller | callee
%% (whole call if omitted), mode => block | silence (default block)}. `block'
%% stops the party's packets; `silence' keeps them flowing but muted. rtpengine
%% only.
-spec duck(session(), map()) -> ok | {error, term()}.
duck(#media_session{backend = rtpengine, ref = R}, Opts) ->
    chappe_sip_media_rtpengine:duck(R, Opts);
duck(#media_session{backend = freeswitch, ref = R}, Opts) ->
    chappe_sip_media_freeswitch:duck(R, Opts).

%% Undo duck/2 (the matching unblock/unsilence). Same Opts as duck/2.
-spec unduck(session(), map()) -> ok | {error, term()}.
unduck(#media_session{backend = rtpengine, ref = R}, Opts) ->
    chappe_sip_media_rtpengine:unduck(R, Opts);
unduck(#media_session{backend = freeswitch, ref = R}, Opts) ->
    chappe_sip_media_freeswitch:unduck(R, Opts).

-spec stop(session()) -> ok.
stop(#media_session{backend = rtpengine, ref = R}) ->
    chappe_sip_media_rtpengine:stop(R);
stop(#media_session{backend = freeswitch, ref = R}) ->
    chappe_sip_media_freeswitch:stop(R).

-spec info(session()) -> map() | {error, term()}.
info(#media_session{backend = rtpengine, ref = R}) ->
    chappe_sip_media_rtpengine:info(R);
info(#media_session{backend = freeswitch, ref = R}) ->
    chappe_sip_media_freeswitch:info(R).

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

resolve_identity(Id) when is_map(Id) ->
    Id;
resolve_identity(Dialog) ->
    #{
        call_id => chappe_sip_dialog:call_id(Dialog),
        from_tag => chappe_sip_dialog:remote_tag(Dialog),
        to_tag => chappe_sip_dialog:local_tag(Dialog)
    }.

app(rtpengine) -> chappe_rtpengine;
app(freeswitch) -> chappe_esl.
