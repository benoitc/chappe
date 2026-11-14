%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Per-call media session: a gen_statem owning one rtpengine session
%% (one call-id, one pinned node) across both B2BUA legs.
%%
%% States:
%%   idle -> offering -> offered -> answering -> established
%%   idle -> publishing -> established     (one-sided offer)
%%   established -> reoffering -> offered  (re-INVITE)
%%   offered -> established                 (re-INVITE rejected,
%%                                           reoffer_rejected/1)
%%   any active state -> deleting -> stop
%%
%% The FSM never blocks in a state callback: the public API is
%% gen_statem:call, but client requests go out through
%% chappe_rtpengine_client:cmd_async and the caller is answered when the
%% {chappe_rtpengine_reply, Ref, Result} message arrives. The intermediate states
%% exist to await that message, which keeps stop and owner-down
%% handling live during the client's retry window.
%%
%% The owner (the process that started the session) is monitored;
%% owner death triggers a delete. An offer while another offer/answer
%% exchange is open (offering, offered, answering, reoffering,
%% publishing) gets {error, glare} immediately: SIP owns glare
%% resolution (491), the FSM must not queue competing offers.
%%
%% stop/1 and owner death move to deleting even with a request in
%% flight. Its reply, when it arrives there, answers the original
%% caller with {error, stopped} and leaves the FSM in deleting; any
%% request still pending when the delete completes gets the same.
%%
%% The FSM uses handle_event_function rather than state_functions:
%% most events (info, the auxiliary commands, client replies) are
%% handled the same in several states, and the reply to a call often
%% depends on the state it lands in.
%%
%% Tag direction: rtpengine's from-tag is always the tag of the party
%% sending the offer. The session stores the caller's tag (from_tag)
%% and the callee's tag (to_tag) once known; a callee-initiated
%% re-INVITE (offer with initiator => callee) swaps them on the wire
%% for the offer and the following answer.
%%
%% The owner receives {chappe_rtpengine_session, Pid, Event} messages:
%%   {node_down, Node}       the pinned node stopped answering
%%   {node_restarted, Node}  the node came back with a new generation,
%%                           or replied "unknown call-id": the media
%%                           session on it is gone. The owner decides
%%                           between re-offer and teardown; the
%%                           library never re-offers on its own.
-module(chappe_rtpengine_session).
-behaviour(gen_statem).

-export([start/1, start_link/2]).
-export([
    offer/2, answer/2, publish/2, reoffer_rejected/1, query/1, stop/1, info/1
]).
-export([set_owner/2]).
-export([
    cmd/3,
    play_media/2,
    stop_media/1,
    play_dtmf/2,
    block_dtmf/1,
    unblock_dtmf/1,
    block_media/1,
    block_media/2,
    unblock_media/1,
    unblock_media/2,
    silence_media/1,
    silence_media/2,
    unsilence_media/1,
    unsilence_media/2,
    start_recording/1,
    stop_recording/1,
    subscribe_request/2,
    subscribe_answer/2,
    unsubscribe/2
]).
-export([callback_mode/0, init/1, handle_event/4, terminate/3]).

-record(data, {
    owner :: pid(),
    owner_mon :: reference(),
    call_id :: binary(),
    node :: atom(),
    generation :: non_neg_integer(),
    pinned :: boolean(),
    from_tag :: binary() | undefined,
    to_tag :: binary() | undefined,
    reoffer_initiator = caller :: caller | callee,
    %% true while the open offer is a re-INVITE of an established call
    reoffer = false :: boolean(),
    branches = [] :: [binary()],
    media_lost = false :: boolean(),
    %% subscriptions held by a process (subscribe_request/2 with
    %% holder): its monitor to the subscription's to-tag
    holds = #{} :: #{reference() => binary()},
    pending = #{} ::
        #{reference() => {gen_statem:from() | undefined, term()}}
}).

%% Opts: call_id (required), node (optional; pool-selected and pinned
%% when absent), dtmf (optional; true subscribes the session to the
%% chappe_rtpengine_dtmf listener and forwards events to the owner as
%% {chappe_rtpengine_session, Pid, {dtmf, Event}}). The calling process becomes
%% the owner.
-spec start(map()) -> {ok, pid()} | {error, term()}.
start(#{call_id := _} = Opts) ->
    supervisor:start_child(chappe_rtpengine_session_sup, [self(), Opts]);
start(_Opts) ->
    {error, missing_call_id}.

-spec start_link(pid(), map()) -> gen_statem:start_ret().
start_link(Owner, Opts) ->
    gen_statem:start_link(?MODULE, [Owner, Opts], []).

%% First offer needs from_tag and sdp. A re-INVITE offer needs sdp,
%% reuses the stored tags, and accepts initiator => callee to swap
%% the tag direction.
-spec offer(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
offer(Session, Params) ->
    safe_call(Session, {offer, Params}).

%% First answer needs to_tag and sdp; later answers reuse the stored
%% tags. A forked call answers once per branch with distinct to_tags;
%% pass final => true with the winning answer and the session deletes
%% the losing branches (best effort, by to-tag).
-spec answer(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
answer(Session, Params) ->
    safe_call(Session, {answer, Params}).

%% One-sided offer: rtpengine answers it itself, so the call is
%% established with a single party and no second leg to negotiate.
%% That is the anchor for a receive-only session (a SIPREC recording
%% server, a media publisher): every m-line of the offer comes back
%% answered in the reply SDP, ready to go into the 200 OK, and the
%% streams are then tapped with subscribe_request/2. Needs from_tag
%% and sdp; goes straight to established (answer/2 does not follow).
-spec publish(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
publish(Session, Params) ->
    safe_call(Session, {publish, Params}).

%% The peer rejected the re-INVITE whose offer this session relayed
%% (a 488 or any other final error): go back to established with the
%% dialog's tags as they were. rtpengine is not told; the next offer
%% renegotiates. Only valid in offered after a re-INVITE offer,
%% {error, no_reoffer} otherwise.
-spec reoffer_rejected(pid()) -> ok | {error, term()}.
reoffer_rejected(Session) ->
    safe_call(Session, reoffer_rejected).

-spec query(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
query(Session) ->
    safe_call(Session, query).

%% Deletes the rtpengine session and stops the process.
-spec stop(pid()) -> ok | {error, term()}.
stop(Session) ->
    safe_call(Session, stop).

-spec info(pid()) -> map() | {error, term()}.
info(Session) ->
    safe_call(Session, info).

%% Hand the session to another process: it gets the events from now on,
%% and its death deletes the session instead of the old owner's.
-spec set_owner(pid(), pid()) -> ok | {error, term()}.
set_owner(Session, Owner) when is_pid(Owner) ->
    safe_call(Session, {set_owner, Owner}).

%% Any other NG command against this session (call_id and from_tag
%% injected). Allowed once an offer is in flight.
-spec cmd(pid(), atom(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
cmd(Session, Command, Params) ->
    safe_call(Session, {aux, Command, Params}).

%% Announcement or prompt to the from-tag party by default; pass
%% party => caller | callee | all (or label) to pick the leg. Provide
%% the audio as file, blob (raw bytes), blob64 (base64) or db_id, and
%% loop with repeat_times. The reply may carry duration in ms.
-spec play_media(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
play_media(Session, Params) ->
    cmd(Session, play_media, Params).

-spec stop_media(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
stop_media(Session) ->
    cmd(Session, stop_media, #{}).

%% Params: code (digit), and optionally duration, volume, pause.
-spec play_dtmf(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
play_dtmf(Session, Params) ->
    cmd(Session, play_dtmf, Params).

-spec block_dtmf(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
block_dtmf(Session) ->
    cmd(Session, block_dtmf, #{}).

-spec unblock_dtmf(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
unblock_dtmf(Session) ->
    cmd(Session, unblock_dtmf, #{}).

%% Media blocking and silencing, the ducking primitives. Blocking
%% stops a party's packets entirely; silencing keeps them flowing but
%% replaces the audio with silence. With no options the whole call is
%% affected. Target one direction with party => caller | callee: the
%% party's tag goes out as from-tag together with the directional
%% flag, which rtpengine requires for per-party media control. Raw NG
%% keys (label, address, to_tag, flags, ...) pass through and win.
-spec block_media(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
block_media(Session) ->
    block_media(Session, #{}).

-spec block_media(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
block_media(Session, Opts) ->
    cmd(Session, block_media, Opts).

-spec unblock_media(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
unblock_media(Session) ->
    unblock_media(Session, #{}).

-spec unblock_media(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
unblock_media(Session, Opts) ->
    cmd(Session, unblock_media, Opts).

-spec silence_media(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
silence_media(Session) ->
    silence_media(Session, #{}).

-spec silence_media(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
silence_media(Session, Opts) ->
    cmd(Session, silence_media, Opts).

-spec unsilence_media(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
unsilence_media(Session) ->
    unsilence_media(Session, #{}).

-spec unsilence_media(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
unsilence_media(Session, Opts) ->
    cmd(Session, unsilence_media, Opts).

-spec start_recording(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
start_recording(Session) ->
    cmd(Session, start_recording, #{}).

-spec stop_recording(pid()) -> chappe_rtpengine_ng:result() | {error, term()}.
stop_recording(Session) ->
    cmd(Session, stop_recording, #{}).

%% Media subscriptions are how a consumer (a recorder, an STT feed, a
%% conference mixer leg, a listen-in party) taps this call's media.
%% subscribe request returns an SDP offer describing the source
%% streams plus a to-tag naming the subscription; answer it with the
%% consumer's SDP. No from-tag is injected on subscription commands:
%% pass party => caller | callee (or from_tags => [Tag]) to tap one
%% participant, or flags => [all] for everyone. Control the output
%% with codec => #{mask => [...], transcode => [...]} and ptime.
%%
%% The offer describes every media stream of the tapped participants,
%% so a participant with N streams (a SIPREC recording offer, one
%% m-line per party) is tapped as N streams in m-line order. rtpengine
%% has no request-side selector for one of them: the answer decides,
%% by giving that m-line a port and rejecting the rest. Build it with
%% chappe_rtpengine_sdp:fork_answer/3 to send one stream to one receiver.
%%
%% holder => pid() makes the subscription that process's: the session
%% monitors it and unsubscribes when it exits, however it exits, so a
%% consumer that crashes leaves no fork running. unsubscribe/2 of the
%% to-tag releases it.
-spec subscribe_request(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
subscribe_request(Session, Params) ->
    cmd(Session, subscribe_request, Params).

-spec subscribe_answer(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
subscribe_answer(Session, Params) ->
    case check([to_tag, sdp], Params) of
        ok -> cmd(Session, subscribe_answer, Params);
        {error, _} = Error -> Error
    end.

-spec unsubscribe(pid(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
unsubscribe(Session, Params) ->
    case check([to_tag], Params) of
        ok -> cmd(Session, unsubscribe, Params);
        {error, _} = Error -> Error
    end.

%% gen_statem callbacks

callback_mode() ->
    handle_event_function.

init([Owner, Opts]) ->
    CallId = maps:get(call_id, Opts),
    Mon = erlang:monitor(process, Owner),
    case resolve_node(CallId, Opts) of
        {ok, Node, Gen, Pinned} ->
            ok = chappe_rtpengine_pool:subscribe(),
            case maps:get(dtmf, Opts, false) of
                true -> ok = chappe_rtpengine_dtmf:subscribe(CallId);
                false -> ok
            end,
            {ok, idle, #data{
                owner = Owner,
                owner_mon = Mon,
                call_id = CallId,
                node = Node,
                generation = Gen,
                pinned = Pinned
            }};
        {error, Reason} ->
            {stop, Reason}
    end.

%% offer

handle_event({call, From}, {offer, Params}, idle, Data) ->
    case check([from_tag, sdp], Params) of
        ok ->
            case send_async(offer, Params, Data) of
                {ok, Ref, Data1} ->
                    Data2 = Data1#data{
                        from_tag = maps:get(from_tag, Params)
                    },
                    {next_state, offering,
                        add_pending(Ref, From, offer, Data2)};
                {error, Reason} ->
                    {keep_state_and_data, [{reply, From, {error, Reason}}]}
            end;
        {error, _} = Error ->
            {keep_state_and_data, [{reply, From, Error}]}
    end;
handle_event({call, From}, {offer, Params0}, established, Data) ->
    %% re-INVITE
    Initiator = maps:get(initiator, Params0, caller),
    Params1 = maps:remove(initiator, Params0),
    case check([sdp], Params1) of
        ok when Initiator =:= callee, Data#data.to_tag =:= undefined ->
            {keep_state_and_data, [{reply, From, {error, no_to_tag}}]};
        ok ->
            Params = maps:merge(
                reoffer_tags(Initiator, Params1, Data), Params1
            ),
            case send_async(offer, Params, Data) of
                {ok, Ref, Data1} ->
                    Data2 = Data1#data{reoffer_initiator = Initiator},
                    {next_state, reoffering,
                        add_pending(Ref, From, reoffer, Data2)};
                {error, Reason} ->
                    {keep_state_and_data, [{reply, From, {error, Reason}}]}
            end;
        {error, _} = Error ->
            {keep_state_and_data, [{reply, From, Error}]}
    end;
handle_event({call, From}, {offer, _Params}, deleting, _Data) ->
    {keep_state_and_data, [{reply, From, {error, busy}}]};
handle_event({call, From}, {offer, _Params}, _State, _Data) ->
    %% an offer/answer exchange is already open
    {keep_state_and_data, [{reply, From, {error, glare}}]};
%% re-INVITE rejected by the peer
handle_event(
    {call, From}, reoffer_rejected, offered, #data{reoffer = true} = Data
) ->
    {next_state, established,
        Data#data{reoffer = false, reoffer_initiator = caller}, [
            {reply, From, ok}
        ]};
handle_event({call, From}, reoffer_rejected, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, no_reoffer}}]};
%% publish (one-sided offer; rtpengine writes the answer)

handle_event({call, From}, {publish, Params}, idle, Data) ->
    case check([from_tag, sdp], Params) of
        ok ->
            case send_async(publish, Params, Data) of
                {ok, Ref, Data1} ->
                    Data2 = Data1#data{
                        from_tag = maps:get(from_tag, Params)
                    },
                    {next_state, publishing,
                        add_pending(Ref, From, publish, Data2)};
                {error, Reason} ->
                    {keep_state_and_data, [{reply, From, {error, Reason}}]}
            end;
        {error, _} = Error ->
            {keep_state_and_data, [{reply, From, Error}]}
    end;
handle_event({call, From}, {publish, _Params}, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, busy}}]};
%% answer

handle_event({call, From}, {answer, Params}, offered, Data) ->
    do_answer(From, Params, answering, Data);
handle_event({call, From}, {answer, Params}, established, Data) ->
    %% repeated answer (early media then final, or a fork branch)
    do_answer(From, Params, established, Data);
handle_event({call, From}, {answer, _Params}, idle, _Data) ->
    {keep_state_and_data, [{reply, From, {error, no_offer}}]};
handle_event({call, From}, {answer, _Params}, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, busy}}]};
%% query

handle_event({call, From}, query, idle, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_started}}]};
handle_event({call, From}, query, deleting, _Data) ->
    {keep_state_and_data, [{reply, From, {error, busy}}]};
handle_event({call, From}, query, _State, Data) ->
    case send_async(query, #{}, Data) of
        {ok, Ref, Data1} ->
            {keep_state, add_pending(Ref, From, query, Data1)};
        {error, Reason} ->
            {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end;
%% auxiliary commands (playback, DTMF, recording, ...)

handle_event({call, From}, {aux, _Command, _Params}, idle, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_started}}]};
handle_event({call, From}, {aux, _Command, _Params}, deleting, _Data) ->
    {keep_state_and_data, [{reply, From, {error, busy}}]};
handle_event({call, From}, {aux, Command, Params0}, _State, Data) ->
    {Kind, Params1} = aux_kind(Command, Params0),
    case resolve_party(Command, Params1, Data) of
        {ok, Params} ->
            case send_async(Command, Params, release(Command, Params, Data)) of
                {ok, Ref, Data1} ->
                    {keep_state, add_pending(Ref, From, Kind, Data1)};
                {error, Reason} ->
                    {keep_state_and_data, [{reply, From, {error, Reason}}]}
            end;
        {error, Reason} ->
            {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end;
%% stop

handle_event({call, From}, stop, idle, _Data) ->
    {stop_and_reply, normal, [{reply, From, ok}]};
handle_event({call, From}, stop, deleting, _Data) ->
    {keep_state_and_data, [{reply, From, {error, busy}}]};
handle_event({call, From}, stop, _State, Data) ->
    case send_async(delete, #{}, Data) of
        {ok, Ref, Data1} ->
            {next_state, deleting, add_pending(Ref, From, delete, Data1)};
        {error, Reason} ->
            %% cannot reach the client; terminate/3 makes a last
            %% best-effort delete attempt
            {stop_and_reply, normal, [{reply, From, {error, Reason}}]}
    end;
%% owner

handle_event({call, From}, {set_owner, Owner}, _State, Data) ->
    demonitor(Data#data.owner_mon, [flush]),
    Data1 = Data#data{owner = Owner, owner_mon = monitor(process, Owner)},
    {keep_state, Data1, [{reply, From, ok}]};
%% info

handle_event({call, From}, info, State, Data) ->
    Info = #{
        state => State,
        call_id => Data#data.call_id,
        node => Data#data.node,
        generation => Data#data.generation,
        from_tag => Data#data.from_tag,
        to_tag => Data#data.to_tag,
        branches => Data#data.branches,
        media_lost => Data#data.media_lost
    },
    {keep_state_and_data, [{reply, From, Info}]};
%% client replies

handle_event(info, {chappe_rtpengine_reply, Ref, Result}, State, Data) ->
    case maps:take(Ref, Data#data.pending) of
        {{From, Kind}, Rest} ->
            Data1 = note_media_lost(Kind, Result, State, Data#data{
                pending = Rest
            }),
            handle_reply(Kind, From, Result, State, Data1);
        error ->
            keep_state_and_data
    end;
%% pool events for the pinned node

handle_event(
    info,
    {chappe_rtpengine_pool, {node_down, Node}},
    State,
    #data{node = Node} = Data
) ->
    case active(State) of
        true -> notify_owner({node_down, Node}, Data);
        false -> ok
    end,
    keep_state_and_data;
handle_event(
    info,
    {chappe_rtpengine_pool, {node_up, Node, Gen}},
    State,
    #data{node = Node, generation = OldGen} = Data
) when Gen > OldGen ->
    Data1 = Data#data{generation = Gen},
    case active(State) andalso not Data#data.media_lost of
        true ->
            notify_owner({node_restarted, Node}, Data1),
            {keep_state, Data1#data{media_lost = true}};
        false ->
            {keep_state, Data1}
    end;
handle_event(info, {chappe_rtpengine_pool, _Event}, _State, _Data) ->
    keep_state_and_data;
%% DTMF events for this call (subscription made with dtmf => true)

handle_event(
    info,
    {chappe_rtpengine_dtmf, CallId, Event},
    _State,
    #data{call_id = CallId} = Data
) ->
    notify_owner({dtmf, Event}, Data),
    keep_state_and_data;
%% a holder of subscriptions exited: its forks are removed

handle_event(
    info,
    {'DOWN', Mon, process, _Pid, _Reason},
    State,
    #data{holds = Holds} = Data
) when is_map_key(Mon, Holds) ->
    {ToTag, Rest} = maps:take(Mon, Holds),
    Data1 = Data#data{holds = Rest},
    case active(State) of
        true ->
            case send_async(unsubscribe, #{to_tag => ToTag}, Data1) of
                {ok, Ref, Data2} ->
                    {keep_state, add_pending(Ref, undefined, released, Data2)};
                {error, _} ->
                    {keep_state, Data1}
            end;
        false ->
            {keep_state, Data1}
    end;
%% owner death

handle_event(
    info,
    {'DOWN', Mon, process, _Pid, _Reason},
    State,
    #data{owner_mon = Mon} = Data
) ->
    case State of
        idle ->
            {stop, normal};
        deleting ->
            keep_state_and_data;
        _ ->
            case send_async(delete, #{}, Data) of
                {ok, Ref, Data1} ->
                    {next_state, deleting,
                        add_pending(Ref, undefined, delete, Data1)};
                {error, _} ->
                    {stop, normal}
            end
    end;
handle_event(info, _Info, _State, _Data) ->
    keep_state_and_data;
handle_event({call, From}, _Request, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, unknown_call}}]}.

terminate(_Reason, State, Data) ->
    _ = final_delete(State, Data),
    case Data#data.pinned of
        true -> chappe_rtpengine_pool:unpin(Data#data.call_id);
        false -> ok
    end.

%% internal

%% Answers share one path from offered (first answer) and established
%% (repeated answers). Branch = the answering party's tag when the
%% offer direction is caller; final => true prunes losing branches.
do_answer(From, Params0, StateKind, Data) ->
    Final = maps:get(final, Params0, false),
    Params1 = maps:remove(final, Params0),
    PrevToTag = Data#data.to_tag,
    NeedToTag =
        Data#data.reoffer_initiator =:= caller andalso
            Data#data.to_tag =:= undefined andalso
            not maps:is_key(to_tag, Params1),
    case check([sdp | [to_tag || NeedToTag]], Params1) of
        ok ->
            {Tags, BranchTag} = answer_tags(Params1, Data),
            Params = maps:merge(Tags, Params1),
            Kind = {answer_sent, StateKind, BranchTag, Final, PrevToTag},
            case send_async(answer, Params, Data) of
                {ok, Ref, Data1} ->
                    Data2 =
                        case {StateKind, BranchTag} of
                            {answering, none} -> Data1;
                            {answering, _} -> Data1#data{to_tag = BranchTag};
                            _ -> Data1
                        end,
                    Next =
                        case StateKind of
                            answering -> answering;
                            established -> established
                        end,
                    Actions = add_pending(Ref, From, Kind, Data2),
                    case Next of
                        answering -> {next_state, answering, Actions};
                        established -> {keep_state, Actions}
                    end;
                {error, Reason} ->
                    {keep_state_and_data, [{reply, From, {error, Reason}}]}
            end;
        {error, _} = Error ->
            {keep_state_and_data, [{reply, From, Error}]}
    end.

%% A re-offer naming a via_branch opens a branch: rtpengine only tells
%% branches apart when it carries no to-tag, a to-tag there makes every
%% via-branch the established leg.
reoffer_tags(caller, #{via_branch := _}, Data) ->
    #{from_tag => Data#data.from_tag};
reoffer_tags(caller, _Params, Data) ->
    Base = #{from_tag => Data#data.from_tag},
    case Data#data.to_tag of
        undefined -> Base;
        ToTag -> Base#{to_tag => ToTag}
    end;
reoffer_tags(callee, _Params, Data) ->
    #{from_tag => Data#data.to_tag, to_tag => Data#data.from_tag}.

answer_tags(_Params, #data{reoffer_initiator = callee} = Data) ->
    %% answering a callee-initiated re-INVITE: same swapped direction
    {#{from_tag => Data#data.to_tag, to_tag => Data#data.from_tag}, none};
answer_tags(Params, Data) ->
    ToTag = maps:get(to_tag, Params, Data#data.to_tag),
    {#{from_tag => Data#data.from_tag, to_tag => ToTag}, ToTag}.

handle_reply(Kind, From, Result, State, Data) ->
    case pinned_state(Kind) of
        any ->
            reply(Kind, From, Result, State, Data);
        State ->
            reply(Kind, From, Result, State, Data);
        _Other ->
            %% stop/1 or owner death moved on while this was in flight
            {keep_state, Data, reply_stopped(From)}
    end.

%% The state a reply of this kind must find the FSM in; any other
%% state means the session is being torn down.
pinned_state(offer) -> offering;
pinned_state(publish) -> publishing;
pinned_state(reoffer) -> reoffering;
pinned_state({answer_sent, answering, _, _, _}) -> answering;
pinned_state(_Kind) -> any.

reply_stopped(undefined) -> [];
reply_stopped(From) -> [{reply, From, {error, stopped}}].

reply(offer, From, Result, offering, Data) ->
    Next =
        case Result of
            {ok, _} -> offered;
            _ -> idle
        end,
    {next_state, Next, Data, [{reply, From, Result}]};
reply(publish, From, Result, publishing, Data) ->
    Next =
        case Result of
            {ok, _} -> established;
            _ -> idle
        end,
    {next_state, Next, Data, [{reply, From, Result}]};
reply(reoffer, From, Result, reoffering, Data) ->
    case Result of
        {ok, _} ->
            {next_state, offered, Data#data{reoffer = true}, [
                {reply, From, Result}
            ]};
        _ ->
            {next_state, established, Data#data{reoffer_initiator = caller}, [
                {reply, From, Result}
            ]}
    end;
reply(
    {answer_sent, answering, BranchTag, Final, PrevToTag},
    From,
    Result,
    answering,
    Data
) ->
    case Result of
        {ok, _} ->
            Data1 = settle_answer(BranchTag, Final, Data),
            {next_state, established,
                Data1#data{reoffer_initiator = caller, reoffer = false}, [
                    {reply, From, Result}
                ]};
        _ ->
            %% a failed answer leaves the dialog's to-tag as it was:
            %% undefined before the first answer, the established
            %% call's tag after a re-INVITE
            {next_state, offered, Data#data{to_tag = PrevToTag}, [
                {reply, From, Result}
            ]}
    end;
reply(
    {answer_sent, established, BranchTag, Final, _PrevToTag},
    From,
    Result,
    _State,
    Data
) ->
    Data1 =
        case Result of
            {ok, _} -> settle_answer(BranchTag, Final, Data);
            _ -> Data
        end,
    {keep_state, Data1, [{reply, From, Result}]};
reply(query, From, Result, _State, Data) ->
    {keep_state, Data, [{reply, From, Result}]};
reply(aux, From, Result, _State, Data) ->
    {keep_state, Data, [{reply, From, Result}]};
reply({held, Holder}, From, {ok, #{<<"to-tag">> := ToTag}} = Result, _, Data) ->
    Mon = monitor(process, Holder),
    Holds = maps:put(Mon, ToTag, Data#data.holds),
    {keep_state, Data#data{holds = Holds}, [{reply, From, Result}]};
reply({held, _Holder}, From, Result, _State, Data) ->
    {keep_state, Data, [{reply, From, Result}]};
reply(released, undefined, _Result, _State, Data) ->
    {keep_state, Data};
reply(branch_delete, undefined, _Result, _State, Data) ->
    {keep_state, Data};
reply(delete, undefined, _Result, _State, Data) ->
    {stop_and_reply, normal, stopped_replies(Data), Data};
reply(delete, From, Result, _State, Data) ->
    {stop_and_reply, normal,
        [{reply, From, delete_result(Result)} | stopped_replies(Data)], Data}.

%% Callers still waiting when the session ends hear that it stopped
%% rather than seeing the process exit.
stopped_replies(Data) ->
    lists:append([
        reply_stopped(From)
     || {From, _Kind} <- maps:values(Data#data.pending)
    ]).

%% Record the branch tag; on the final answer, best-effort delete of
%% every losing branch by its to-tag.
settle_answer(none, _Final, Data) ->
    Data;
settle_answer(BranchTag, false, Data) ->
    Branches = lists:usort([BranchTag | Data#data.branches]),
    Data#data{branches = Branches};
settle_answer(BranchTag, true, Data) ->
    Losing = lists:usort(Data#data.branches) -- [BranchTag],
    Data1 = lists:foldl(
        fun(LosingTag, Acc) ->
            case send_async(delete, #{to_tag => LosingTag}, Acc) of
                {ok, Ref, Acc1} ->
                    add_pending(Ref, undefined, branch_delete, Acc1);
                {error, _} ->
                    Acc
            end
        end,
        Data,
        Losing
    ),
    Data1#data{branches = [BranchTag], to_tag = BranchTag}.

delete_result({ok, _}) -> ok;
delete_result({error, Reason, _Reply}) -> {error, Reason};
delete_result(Other) -> Other.

%% An "unknown call-id" error on a session we believe exists means the
%% node lost it (restart without the health check noticing, or manual
%% flush). Tell the owner once.
note_media_lost(delete, _Result, _State, Data) ->
    Data;
note_media_lost(branch_delete, _Result, _State, Data) ->
    Data;
note_media_lost(_Kind, Result, State, Data) ->
    case
        active(State) andalso not Data#data.media_lost andalso
            is_unknown_call_id(Result)
    of
        true ->
            notify_owner({node_restarted, Data#data.node}, Data),
            Data#data{media_lost = true};
        false ->
            Data
    end.

is_unknown_call_id({error, Reason, _Reply}) when is_binary(Reason) ->
    binary:match(string:lowercase(Reason), <<"unknown call">>) =/= nomatch;
is_unknown_call_id(_Result) ->
    false.

active(State) ->
    lists:member(State, [
        offering, offered, answering, established, reoffering, publishing
    ]).

notify_owner(Event, Data) ->
    Data#data.owner ! {chappe_rtpengine_session, self(), Event},
    ok.

resolve_node(CallId, Opts) ->
    case maps:find(node, Opts) of
        {ok, Node} ->
            case chappe_rtpengine_pool:pin_to(CallId, Node) of
                {ok, Node, Gen} -> {ok, Node, Gen, true};
                {error, not_managed} -> {ok, Node, 0, false}
            end;
        error ->
            case chappe_rtpengine_pool:pin(CallId) of
                {ok, Node, Gen} -> {ok, Node, Gen, true};
                {error, no_nodes} -> {error, no_nodes}
            end
    end.

%% call_id always comes from the session; the stored from_tag fills in
%% when the caller does not override it. Subscription commands get no
%% from-tag injection: there it selects which participant to tap, and
%% the default is the caller's choice, not the session's.
send_async(Command, Params0, Data) ->
    Params1 = Params0#{call_id => Data#data.call_id},
    Inject =
        inject_from_tag(Command) andalso
            Data#data.from_tag =/= undefined andalso
            not maps:is_key(from_tag, Params1),
    Params =
        case Inject of
            true -> Params1#{from_tag => Data#data.from_tag};
            false -> Params1
        end,
    try chappe_rtpengine_client:cmd_async(Data#data.node, Command, Params) of
        {ok, Ref} -> {ok, Ref, Data};
        {error, {bad_param, _, _}} = Error -> Error;
        {error, too_large} = Error -> Error;
        {error, Reason} -> {error, {send_failed, Reason}}
    catch
        exit:_ -> {error, client_down}
    end.

%% a subscription with a holder is answered as any auxiliary command, and
%% then held (reply/5); the holder is the session's, never rtpengine's
aux_kind(subscribe_request, #{holder := Holder} = Params) when
    is_pid(Holder)
->
    {{held, Holder}, maps:remove(holder, Params)};
aux_kind(_Command, Params) ->
    {aux, maps:remove(holder, Params)}.

%% an unsubscribe of a held subscription releases it
release(unsubscribe, #{to_tag := ToTag}, #data{holds = Holds} = Data) ->
    Held = [M || {M, T} <- maps:to_list(Holds), T =:= ToTag],
    _ = [demonitor(M, [flush]) || M <- Held],
    Data#data{holds = maps:without(Held, Holds)};
release(_Command, _Params, Data) ->
    Data.

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
resolve_party(Command, Params, Data) ->
    case maps:take(party, Params) of
        error ->
            {ok, default_target(Command, Params)};
        {all, Rest} ->
            {ok, add_flag(all, Rest)};
        {caller, Rest} ->
            tag_target(Command, Data#data.from_tag, Rest);
        {callee, Rest} ->
            case Data#data.to_tag of
                undefined -> {error, no_to_tag};
                ToTag -> tag_target(Command, ToTag, Rest)
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

add_pending(Ref, From, Kind, Data) ->
    Data#data{pending = maps:put(Ref, {From, Kind}, Data#data.pending)}.

check(Keys, Params) ->
    case [K || K <- Keys, not maps:is_key(K, Params)] of
        [] -> ok;
        Missing -> {error, {missing_params, Missing}}
    end.

%% Best-effort synchronous delete for exits that bypassed the deleting
%% state (crash, supervisor shutdown, unreachable client at stop).
final_delete(State, #data{from_tag = FromTag} = Data) when
    FromTag =/= undefined
->
    case active(State) of
        true ->
            try
                chappe_rtpengine:delete(Data#data.node, #{
                    call_id => Data#data.call_id,
                    from_tag => FromTag
                })
            catch
                _:_ -> ok
            end;
        false ->
            ok
    end;
final_delete(_State, _Data) ->
    ok.

safe_call(Session, Request) ->
    try
        gen_statem:call(Session, Request, infinity)
    catch
        exit:{noproc, _} -> {error, session_down};
        exit:{normal, _} -> {error, session_down};
        exit:{shutdown, _} -> {error, session_down}
    end.
