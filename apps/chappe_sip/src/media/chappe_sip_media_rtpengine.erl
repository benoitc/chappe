%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc rtpengine backend adapter for chappe_sip_media.
%%
%% Maps the facade operations onto chappe_rtpengine. A session is an
%% chappe_rtpengine_session process started with the facade caller (the call owner) as
%% its owner, so chappe_rtpengine's own owner-monitor tears the rtpengine
%% session down when the call ends. This adapter holds no process of its
%% own: the returned Ref is the chappe_rtpengine_session pid, and each operation calls
%% chappe_rtpengine directly with the SIP dialog identity injected as the
%% rtpengine call-id / from-tag / to-tag.
-module(chappe_sip_media_rtpengine).

-export([
    configure/1,
    start/2,
    offer/4,
    answer/4,
    publish/4,
    play/2,
    record/2,
    dtmf/2,
    subscribe/3,
    subscribe_answer/2,
    unsubscribe/2,
    duck/2,
    unduck/2,
    stop/1,
    info/1
]).
-export([anchor_offer/3, anchor_answer/3, anchor_release/1, anchor_pinned/1]).
-export([set_owner/2]).

-export_type([identity/0]).

-type identity() :: #{call_id := binary(), _ => _}.

%% Register the configured rtpengine nodes with the pool.
-spec configure([map()]) -> ok.
configure(Nodes) ->
    lists:foreach(fun add_node/1, Nodes).

add_node(#{name := Name} = Node) ->
    _ = chappe_rtpengine:add_node(Name, maps:without([name], Node)),
    ok.

%% Start a media session pinned to one rtpengine node. The caller becomes
%% the chappe_rtpengine_session owner (teardown on its exit).
-spec start(identity(), map()) -> {ok, pid()} | {error, term()}.
start(#{call_id := CallId}, Opts) ->
    SessOpts0 = #{call_id => CallId},
    SessOpts1 = maybe_put(node, maps:get(node, Opts, undefined), SessOpts0),
    SessOpts = maybe_put(dtmf, maps:get(dtmf, Opts, undefined), SessOpts1),
    chappe_rtpengine:start_session(SessOpts).

%% The offerer's SDP in, the rewritten SDP out. from_tag is the offering
%% party's dialog tag (identity, overridable via Opts). branch => true
%% sends one more offer of the same party while the first still waits
%% for its answer: another fork branch, told apart by the via_branch in
%% its params.
-spec offer(pid(), identity(), iodata(), map()) ->
    {ok, binary()} | {error, term()}.
offer(Pid, Id, Sdp, Opts) ->
    Params = tag_param(from_tag, Id, Opts, #{sdp => Sdp}),
    case maps:get(branch, Opts, false) of
        true -> reply_sdp(chappe_rtpengine_session:cmd(Pid, offer, Params));
        false -> reply_sdp(chappe_rtpengine_session:offer(Pid, Params))
    end.

%% The answerer's SDP in, the rewritten SDP out. to_tag is the answering
%% party's dialog tag.
-spec answer(pid(), identity(), iodata(), map()) ->
    {ok, binary()} | {error, term()}.
answer(Pid, Id, Sdp, Opts) ->
    Params = tag_param(to_tag, Id, Opts, #{sdp => Sdp}),
    reply_sdp(chappe_rtpengine_session:answer(Pid, Params)).

%% One-sided anchor: rtpengine answers the offer itself, so the rewritten SDP
%% out is the answer to send back to the offering party. from_tag is that
%% party's dialog tag; there is no answer/4 to follow.
-spec publish(pid(), identity(), iodata(), map()) ->
    {ok, binary()} | {error, term()}.
publish(Pid, Id, Sdp, Opts) ->
    Params = tag_param(from_tag, Id, Opts, #{sdp => Sdp}),
    reply_sdp(chappe_rtpengine_session:publish(Pid, Params)).

-spec play(pid(), map()) -> ok | {error, term()}.
play(Pid, Media) ->
    to_ok(chappe_rtpengine_cmd:play_media(Pid, Media)).

-spec record(pid(), map()) -> ok | {error, term()}.
record(Pid, _Opts) ->
    to_ok(chappe_rtpengine_cmd:start_recording(Pid)).

-spec dtmf(pid(), map()) -> ok | {error, term()}.
dtmf(Pid, Params) ->
    to_ok(chappe_rtpengine_cmd:play_dtmf(Pid, Params)).

%% Tap the media to an external consumer. Party/flags/codec/ptime select the
%% source and the fork output; chappe_rtpengine_session injects call-id and resolves the
%% party against the tags it stored during offer/answer. Returns the tapped
%% SDP offer plus the subscription to-tag.
-spec subscribe(pid(), identity(), map()) ->
    {ok, #{
        sdp := binary(),
        to_tag := binary(),
        streams := [chappe_rtpengine_sdp:stream()]
    }}
    | {error, term()}.
subscribe(Pid, _Id, Opts) ->
    reply_sub(
        chappe_rtpengine_cmd:subscribe_request(Pid, sub_params(Opts))
    ).

-spec subscribe_answer(pid(), map()) -> ok | {error, term()}.
subscribe_answer(Pid, Params) ->
    to_ok(chappe_rtpengine_cmd:subscribe_answer(Pid, Params)).

-spec unsubscribe(pid(), map()) -> ok | {error, term()}.
unsubscribe(Pid, Params) ->
    to_ok(chappe_rtpengine_cmd:unsubscribe(Pid, Params)).

%% Duck a party (or the whole call) by blocking or silencing its media. The
%% party sugar is resolved by chappe_rtpengine_session from its stored tags.
-spec duck(pid(), map()) -> ok | {error, term()}.
duck(Pid, Opts) ->
    P = party_params(Opts),
    case maps:get(mode, Opts, block) of
        block -> to_ok(chappe_rtpengine_cmd:block_media(Pid, P));
        silence -> to_ok(chappe_rtpengine_cmd:silence_media(Pid, P))
    end.

-spec unduck(pid(), map()) -> ok | {error, term()}.
unduck(Pid, Opts) ->
    P = party_params(Opts),
    case maps:get(mode, Opts, block) of
        block -> to_ok(chappe_rtpengine_cmd:unblock_media(Pid, P));
        silence -> to_ok(chappe_rtpengine_cmd:unsilence_media(Pid, P))
    end.

-spec stop(pid()) -> ok.
stop(Pid) ->
    _ = chappe_rtpengine_session:stop(Pid),
    ok.

-spec info(pid()) -> map() | {error, term()}.
info(Pid) ->
    chappe_rtpengine_session:info(Pid).

-spec set_owner(pid(), pid()) -> ok | {error, term()}.
set_owner(Pid, Owner) ->
    chappe_rtpengine_session:set_owner(Pid, Owner).

%% ---- stateless anchor (proxy media) ----
%%
%% A record-routing proxy has no call-lifetime owner process, so media is
%% anchored statelessly: rtpengine holds the call keyed by Call-ID and the pool
%% pins the node by Call-ID. offer/answer/delete are issued directly, no
%% chappe_rtpengine_session process. Params carries the rtpengine flags
%% (ICE, address-family, SDES, SIP-source-address) the caller wants.

-spec anchor_offer(map(), iodata(), map()) ->
    {ok, binary()} | {error, term()}.
anchor_offer(#{call_id := CallId, from_tag := FromTag}, Sdp, Params) ->
    case pin_node(CallId) of
        {ok, Node} ->
            Base = #{call_id => CallId, from_tag => FromTag, sdp => Sdp},
            reply_sdp(chappe_rtpengine:offer(Node, maps:merge(Base, Params)));
        {error, _} = Err ->
            Err
    end.

-spec anchor_answer(map(), iodata(), map()) ->
    {ok, binary()} | {error, term()}.
anchor_answer(
    #{call_id := CallId, from_tag := FromTag, to_tag := ToTag},
    Sdp,
    Params
) ->
    case chappe_rtpengine_pool:pinned(CallId) of
        {ok, Node, _Gen} ->
            Base = #{
                call_id => CallId,
                from_tag => FromTag,
                to_tag => ToTag,
                sdp => Sdp
            },
            reply_sdp(chappe_rtpengine:answer(Node, maps:merge(Base, Params)));
        error ->
            {error, not_pinned}
    end.

-spec anchor_release(map()) -> ok.
anchor_release(#{call_id := CallId, from_tag := FromTag}) ->
    case chappe_rtpengine_pool:pinned(CallId) of
        {ok, Node, _Gen} ->
            _ = chappe_rtpengine:delete(
                Node, #{call_id => CallId, from_tag => FromTag}
            ),
            _ = chappe_rtpengine_pool:unpin(CallId),
            ok;
        error ->
            ok
    end.

-spec anchor_pinned(binary()) -> boolean().
anchor_pinned(CallId) ->
    %% Safe even if the pool is not running (the ETS table is absent): treat a
    %% missing pool as "not anchored" so the proxy falls back to its plain path.
    try chappe_rtpengine_pool:pinned(CallId) of
        {ok, _Node, _Gen} -> true;
        error -> false
    catch
        _:_ -> false
    end.

%% Reuse the node already pinned to this call, else select and pin one.
pin_node(CallId) ->
    case chappe_rtpengine_pool:pinned(CallId) of
        {ok, Node, _Gen} ->
            {ok, Node};
        error ->
            case chappe_rtpengine_pool:pin(CallId) of
                {ok, Node, _Gen} -> {ok, Node};
                {error, _} = Err -> Err
            end
    end.

%% internal

tag_param(Key, Id, Opts, Params) ->
    Tag = maps:get(Key, Opts, maps:get(Key, Id, undefined)),
    Merged = maybe_put(Key, Tag, Params),
    maps:merge(Merged, maps:get(params, Opts, #{})).

maybe_put(_Key, undefined, Map) -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => Value}.

%% Subscription params: keep only the tap knobs and default the fork codec to
%% PCMU so an STT receiver needs no codec logic. A caller-supplied `codec' wins
%% (`codec => #{}' disables the default transcode).
sub_params(Opts) ->
    Keep = maps:with(
        [party, from_tags, flags, codec, ptime, holder, transport_protocol],
        Opts
    ),
    maps:merge(#{codec => #{transcode => [<<"PCMU">>]}}, Keep).

party_params(Opts) ->
    maybe_put(party, maps:get(party, Opts, undefined), #{}).

reply_sub({ok, Reply}) ->
    case
        {
            chappe_rtpengine_ng:sdp(Reply),
            maps:get(<<"to-tag">>, Reply, undefined)
        }
    of
        {undefined, _} ->
            {error, no_sdp};
        {_, undefined} ->
            {error, no_to_tag};
        {Sdp, ToTag} ->
            {ok, #{
                sdp => Sdp,
                to_tag => ToTag,
                streams => chappe_rtpengine_sdp:streams(Sdp)
            }}
    end;
reply_sub({error, Reason, _Reply}) ->
    {error, Reason};
reply_sub({error, Reason}) ->
    {error, Reason}.

reply_sdp({ok, Reply}) ->
    case chappe_rtpengine_ng:sdp(Reply) of
        undefined -> {error, no_sdp};
        Sdp -> {ok, Sdp}
    end;
reply_sdp({error, Reason, _Reply}) ->
    {error, Reason};
reply_sdp({error, Reason}) ->
    {error, Reason}.

to_ok({ok, _Reply}) -> ok;
to_ok({error, Reason, _Reply}) -> {error, Reason};
to_ok({error, Reason}) -> {error, Reason}.
