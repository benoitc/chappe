%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The offer/answer table of a media session, as pure functions: which
%% tags go on the wire for a re-offer or an answer, which state a reply
%% must find the session in, and where the session goes once rtpengine
%% has answered. It also builds the params of every command the session
%% sends (call-id, from-tag, the ref as metadata, the party sugar of the
%% auxiliary commands). chappe_rtpengine_session holds the state and
%% applies the outcome; nothing here sends or receives.
%%
%% Tag direction: rtpengine's from-tag is always the tag of the party
%% sending the offer. FromTag is the caller's tag and ToTag the
%% callee's; a callee-initiated re-offer swaps them on the wire.
-module(chappe_rtpengine_offer).

-export([reoffer_tags/4, answer_tags/4, pinned_state/1, negotiated/3]).
-export([params/5, resolve_party/4]).

-export_type([tag/0, kind/0, initiator/0, update/0]).

-type tag() :: binary() | undefined.
-type initiator() :: caller | callee.
%% what a request in flight waits for; answer_sent carries the state the
%% answer was sent from, the branch tag (none when the callee re-offered),
%% the final flag and the to-tag to restore on failure
-type kind() ::
    offer
    | publish
    | reoffer
    | {answer_sent, answering | established, tag() | none, boolean(), tag()}
    | query
    | aux
    | {held, pid()}
    | released
    | branch_delete
    | delete.
%% a change the session applies to its data, in order
-type update() ::
    {settle, tag() | none, boolean()}
    | {reoffer, boolean()}
    | {reoffer_initiator, caller}
    | {to_tag, tag()}.

%% A re-offer naming a via_branch opens a branch: rtpengine only tells
%% branches apart when it carries no to-tag, a to-tag there makes every
%% via-branch the established leg.
-spec reoffer_tags(initiator(), map(), tag(), tag()) -> map().
reoffer_tags(caller, #{via_branch := _}, FromTag, _ToTag) ->
    #{from_tag => FromTag};
reoffer_tags(caller, _Params, FromTag, undefined) ->
    #{from_tag => FromTag};
reoffer_tags(caller, _Params, FromTag, ToTag) ->
    #{from_tag => FromTag, to_tag => ToTag};
reoffer_tags(callee, _Params, FromTag, ToTag) ->
    #{from_tag => ToTag, to_tag => FromTag}.

%% The wire tags of an answer and the branch it settles. Answering a
%% callee-initiated re-offer keeps the swapped direction and settles no
%% branch; otherwise the answering party's tag (from the params, else the
%% stored one) is the branch.
-spec answer_tags(initiator(), map(), tag(), tag()) ->
    {map(), tag() | none}.
answer_tags(callee, _Params, FromTag, ToTag) ->
    {#{from_tag => ToTag, to_tag => FromTag}, none};
answer_tags(caller, Params, FromTag, ToTag0) ->
    ToTag = maps:get(to_tag, Params, ToTag0),
    {#{from_tag => FromTag, to_tag => ToTag}, ToTag}.

%% The state a reply of this kind must find the session in; any other
%% state means the session is being torn down.
-spec pinned_state(kind()) -> atom().
pinned_state(offer) -> offering;
pinned_state(publish) -> publishing;
pinned_state(reoffer) -> reoffering;
pinned_state({answer_sent, answering, _, _, _}) -> answering;
pinned_state(_Kind) -> any.

%% Where an offer/answer exchange goes once rtpengine replied: the next
%% state (keep: stay) and the updates to apply. The caller always gets
%% the reply as it came.
-spec negotiated(kind(), term(), atom()) -> {atom(), [update()]}.
negotiated(offer, {ok, _}, offering) ->
    {offered, []};
negotiated(offer, _Result, offering) ->
    {idle, []};
negotiated(publish, {ok, _}, publishing) ->
    {established, []};
negotiated(publish, _Result, publishing) ->
    {idle, []};
negotiated(reoffer, {ok, _}, reoffering) ->
    {offered, [{reoffer, true}]};
negotiated(reoffer, _Result, reoffering) ->
    {established, [{reoffer_initiator, caller}]};
negotiated({answer_sent, answering, Branch, Final, _}, {ok, _}, answering) ->
    {established, [
        {settle, Branch, Final}, {reoffer_initiator, caller}, {reoffer, false}
    ]};
negotiated({answer_sent, answering, _, _, PrevToTag}, _Result, answering) ->
    %% a failed answer leaves the dialog's to-tag as it was: undefined
    %% before the first answer, the established call's tag after a
    %% re-INVITE
    {offered, [{to_tag, PrevToTag}]};
negotiated({answer_sent, established, Branch, Final, _}, {ok, _}, _State) ->
    {keep, [{settle, Branch, Final}]};
negotiated({answer_sent, established, _, _, _}, _Result, _State) ->
    {keep, []}.

%% The params of a command the session sends. call_id always comes from
%% the session; the stored from_tag fills in when the caller does not
%% override it. Subscription commands get no from-tag injection: there it
%% selects which participant to tap, and the default is the caller's
%% choice, not the session's.
-spec params(atom(), map(), binary(), tag(), binary() | undefined) -> map().
params(Command, Params0, CallId, FromTag, Ref) ->
    Params = with_ref(Command, Params0#{call_id => CallId}, Ref),
    Inject =
        inject_from_tag(Command) andalso
            FromTag =/= undefined andalso
            not maps:is_key(from_tag, Params),
    case Inject of
        true -> Params#{from_tag => FromTag};
        false -> Params
    end.

%% The ref goes on every offer, answer and publish as NG metadata, as the
%% key:value pair rtpengine writes into its recording metadata
%% (call_ref:<ref>), unless the caller sets metadata itself.
with_ref(Command, Params, Ref) when
    is_binary(Ref) andalso
        (Command =:= offer orelse Command =:= answer orelse
            Command =:= publish)
->
    case maps:is_key(metadata, Params) of
        true -> Params;
        false -> Params#{metadata => <<"call_ref:", (meta_value(Ref))/binary>>}
    end;
with_ref(_Command, Params, _Ref) ->
    Params.

%% rtpengine reads metadata as key:value pairs split on `|': the ref's
%% own `|' (and `%', so the encoding reads back) are percent-encoded, so
%% a ref cannot add a key.
meta_value(Ref) ->
    binary:replace(
        binary:replace(Ref, <<"%">>, <<"%25">>, [global]),
        <<"|">>,
        <<"%7C">>,
        [global]
    ).

inject_from_tag(subscribe_request) -> false;
inject_from_tag(subscribe_answer) -> false;
inject_from_tag(unsubscribe) -> false;
inject_from_tag(_Command) -> true.

%% party => caller | callee | all sugar on auxiliary commands. The
%% wire form differs by command: subscriptions select with the
%% from-tags list; block/silence media need from-tag plus the
%% directional flag (rtpengine ignores a bare from-tag there); play
%% media targets with a plain from-tag. Media control commands with
%% no target at all default to the whole call (all flag).
-spec resolve_party(atom(), map(), tag(), tag()) ->
    {ok, map()} | {error, term()}.
resolve_party(Command, Params, FromTag, ToTag) ->
    case maps:take(party, Params) of
        error ->
            {ok, default_target(Command, Params)};
        {all, Rest} ->
            {ok, add_flag(all, Rest)};
        {caller, Rest} ->
            tag_target(Command, FromTag, Rest);
        {callee, Rest} ->
            case ToTag of
                undefined -> {error, no_to_tag};
                _ -> tag_target(Command, ToTag, Rest)
            end;
        {Other, _Rest} ->
            {error, {bad_party, Other}}
    end.

default_target(Command, Params) ->
    case media_control(Command) andalso not targeted(Params) of
        true -> add_flag(all, Params);
        false -> Params
    end.

tag_target(_Command, undefined, _Params) ->
    {error, no_from_tag};
tag_target(subscribe_request, Tag, Params) ->
    {ok, Params#{from_tags => [Tag]}};
tag_target(Command, Tag, Params) ->
    case media_control(Command) of
        true -> {ok, add_flag(directional, Params#{from_tag => Tag})};
        false -> {ok, Params#{from_tag => Tag}}
    end.

media_control(block_media) -> true;
media_control(unblock_media) -> true;
media_control(silence_media) -> true;
media_control(unsilence_media) -> true;
media_control(start_forwarding) -> true;
media_control(stop_forwarding) -> true;
media_control(_Command) -> false.

targeted(Params) ->
    lists:any(
        fun(K) -> maps:is_key(K, Params) end,
        [from_tag, to_tag, label, to_label, address, flags]
    ).

add_flag(Flag, Params) ->
    Flags = maps:get(flags, Params, []),
    case lists:member(Flag, Flags) of
        true -> Params;
        false -> Params#{flags => Flags ++ [Flag]}
    end.
