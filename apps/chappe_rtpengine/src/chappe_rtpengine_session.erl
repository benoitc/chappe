%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Per-call media session: a gen_statem owning one rtpengine session
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
-export([cmd/3]).
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
    %% the via-branch each branch answered under, when it had its own offer
    branch_vias = #{} :: #{binary() => binary()},
    media_lost = false :: boolean(),
    %% the app's opaque reference (a call ref): in every owner event, and
    %% sent to the daemon as call metadata
    ref :: binary() | undefined,
    %% subscriptions held by a process (subscribe_request/2 with
    %% holder): its monitor to the subscription's to-tag
    holds = #{} :: #{reference() => binary()},
    pending = #{} ::
        #{reference() => {gen_statem:from() | undefined, term()}}
}).

%% Opts: call_id (required), node (optional; pool-selected and pinned
%% when absent), dtmf (optional; true subscribes the session to the
%% chappe_rtpengine_dtmf listener and forwards events to the owner as
%% {chappe_rtpengine_session, Pid, {dtmf, Event}}), ref (optional; an opaque
%% binary, such as a call ref: info/1 returns it, the owner events keep
%% their {chappe_rtpengine_session, Pid, Event} shape, and each offer,
%% answer and publish sends it as metadata call_ref:<Ref>, unless the
%% params set metadata). The calling process becomes the owner.
-spec start(map()) -> {ok, pid()} | {error, term()}.
start(#{ref := Ref}) when not is_binary(Ref) ->
    {error, {bad_option, ref}};
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
                pinned = Pinned,
                ref = maps:get(ref, Opts, undefined)
            }};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_event({call, From}, Request, State, Data) ->
    call(From, Request, State, Data);
handle_event(info, Info, State, Data) ->
    info(Info, State, Data).

terminate(_Reason, State, Data) ->
    _ = final_delete(State, Data),
    case Data#data.pinned of
        true -> chappe_rtpengine_pool:unpin(Data#data.call_id);
        false -> ok
    end.

%% internal

%% calls, by request and then by state

%% offer

call(From, {offer, Params}, idle, Data) ->
    first_offer(From, offer, Params, offering, Data);
call(From, {offer, Params}, established, Data) ->
    reoffer(From, Params, Data);
call(From, {offer, _Params}, deleting, _Data) ->
    reply_now(From, {error, busy});
call(From, {offer, _Params}, _State, _Data) ->
    %% an offer/answer exchange is already open
    reply_now(From, {error, glare});
%% re-INVITE rejected by the peer
call(From, reoffer_rejected, offered, #data{reoffer = true} = Data) ->
    Data1 = Data#data{reoffer = false, reoffer_initiator = caller},
    {next_state, established, Data1, [{reply, From, ok}]};
call(From, reoffer_rejected, _State, _Data) ->
    reply_now(From, {error, no_reoffer});
%% publish (one-sided offer; rtpengine writes the answer)

call(From, {publish, Params}, idle, Data) ->
    first_offer(From, publish, Params, publishing, Data);
call(From, {publish, _Params}, _State, _Data) ->
    reply_now(From, {error, busy});
%% answer

call(From, {answer, Params}, offered, Data) ->
    do_answer(From, Params, answering, Data);
call(From, {answer, Params}, established, Data) ->
    %% repeated answer (early media then final, or a fork branch)
    do_answer(From, Params, established, Data);
call(From, {answer, _Params}, idle, _Data) ->
    reply_now(From, {error, no_offer});
call(From, {answer, _Params}, _State, _Data) ->
    reply_now(From, {error, busy});
%% query and the auxiliary commands (playback, DTMF, recording, ...)

call(From, query, State, Data) ->
    case started(State) of
        ok -> send(query, #{}, {From, query}, keep, Data);
        Error -> reply_now(From, Error)
    end;
call(From, {aux, Command, Params}, State, Data) ->
    case started(State) of
        ok -> aux(From, Command, Params, Data);
        Error -> reply_now(From, Error)
    end;
%% stop

call(From, stop, idle, _Data) ->
    {stop_and_reply, normal, [{reply, From, ok}]};
call(From, stop, deleting, _Data) ->
    reply_now(From, {error, busy});
call(From, stop, _State, Data) ->
    case send_async(delete, delete_params(#{}), Data) of
        {ok, Ref, Data1} ->
            {next_state, deleting, add_pending(Ref, From, delete, Data1)};
        {error, Reason} ->
            %% cannot reach the client; terminate/3 makes a last
            %% best-effort delete attempt
            {stop_and_reply, normal, [{reply, From, {error, Reason}}]}
    end;
%% owner and info

call(From, {set_owner, Owner}, _State, Data) ->
    demonitor(Data#data.owner_mon, [flush]),
    Data1 = Data#data{owner = Owner, owner_mon = monitor(process, Owner)},
    {keep_state, Data1, [{reply, From, ok}]};
call(From, info, State, Data) ->
    reply_now(From, info_map(State, Data));
call(From, _Request, _State, _Data) ->
    reply_now(From, {error, unknown_call}).

%% info messages

%% client replies

info({chappe_rtpengine_reply, Ref, Result}, State, Data) ->
    case maps:take(Ref, Data#data.pending) of
        {{From, Kind}, Rest} ->
            Data1 = Data#data{pending = Rest},
            Data2 = note_media_lost(Kind, Result, State, Data1),
            handle_reply(Kind, From, Result, State, Data2);
        error ->
            keep_state_and_data
    end;
%% pool events for the pinned node

info({chappe_rtpengine_pool, {node_down, Node}}, State, #data{node = Node} = D) ->
    case active(State) of
        true -> notify_owner({node_down, Node}, D);
        false -> ok
    end,
    keep_state_and_data;
info(
    {chappe_rtpengine_pool, {node_up, Node, Gen}},
    State,
    #data{node = Node, generation = OldGen} = Data
) when Gen > OldGen ->
    node_restarted(State, Data#data{generation = Gen});
info({chappe_rtpengine_pool, _Event}, _State, _Data) ->
    keep_state_and_data;
%% DTMF events for this call (subscription made with dtmf => true)

info({chappe_rtpengine_dtmf, CallId, Event}, _, #data{call_id = CallId} = D) ->
    notify_owner({dtmf, Event}, D),
    keep_state_and_data;
%% a holder of subscriptions exited: its forks are removed

info({'DOWN', Mon, process, _, _}, State, #data{holds = H} = Data) when
    is_map_key(Mon, H)
->
    holder_down(Mon, State, Data);
%% owner death

info({'DOWN', Mon, process, _, _}, State, #data{owner_mon = Mon} = Data) ->
    owner_down(State, Data);
info(_Info, _State, _Data) ->
    keep_state_and_data.

%% Send a command whose reply From waits for (Kind says how to settle
%% it, reply/5), then move to Next (keep: stay); a send that fails
%% answers From with the error at once.
send(Command, Params, {From, Kind}, Next, Data) ->
    case send_async(Command, Params, Data) of
        {ok, Ref, Data1} ->
            next(Next, add_pending(Ref, From, Kind, Data1));
        {error, Reason} ->
            reply_now(From, {error, Reason})
    end.

next(keep, Data) -> {keep_state, Data};
next(State, Data) -> {next_state, State, Data}.

reply_now(From, Reply) ->
    {keep_state_and_data, [{reply, From, Reply}]}.

%% The first offer, or a publish: it sets the caller's tag.
first_offer(From, Command, Params, Next, Data) ->
    case require([from_tag, sdp], Params) of
        ok ->
            Data1 = Data#data{from_tag = maps:get(from_tag, Params)},
            send(Command, Params, {From, Command}, Next, Data1);
        {error, _} = Error ->
            reply_now(From, Error)
    end.

%% query and the auxiliary commands need a session on the node, and none
%% goes out while it is being deleted.
started(idle) -> {error, not_started};
started(deleting) -> {error, busy};
started(_State) -> ok.

%% A re-INVITE offer: the stored tags, swapped when the callee offers.
reoffer(From, Params0, Data) ->
    Initiator = maps:get(initiator, Params0, caller),
    Params1 = maps:remove(initiator, Params0),
    case require([sdp], Params1) of
        ok when Initiator =:= callee, Data#data.to_tag =:= undefined ->
            reply_now(From, {error, no_to_tag});
        ok ->
            #data{from_tag = FromTag, to_tag = ToTag} = Data,
            Tags = chappe_rtpengine_offer:reoffer_tags(
                Initiator, Params1, FromTag, ToTag
            ),
            Params = maps:merge(Tags, Params1),
            Data1 = Data#data{reoffer_initiator = Initiator},
            send(offer, Params, {From, reoffer}, reoffering, Data1);
        {error, _} = Error ->
            reply_now(From, Error)
    end.

aux(From, Command, Params0, Data) ->
    {Kind, Params1} = aux_kind(Command, Params0),
    #data{from_tag = FromTag, to_tag = ToTag} = Data,
    case
        chappe_rtpengine_offer:resolve_party(Command, Params1, FromTag, ToTag)
    of
        {ok, Params} ->
            Data1 = release(Command, Params, Data),
            send(Command, Params, {From, Kind}, keep, Data1);
        {error, Reason} ->
            reply_now(From, {error, Reason})
    end.

info_map(State, Data) ->
    #{
        state => State,
        call_id => Data#data.call_id,
        node => Data#data.node,
        generation => Data#data.generation,
        from_tag => Data#data.from_tag,
        to_tag => Data#data.to_tag,
        branches => Data#data.branches,
        media_lost => Data#data.media_lost,
        ref => Data#data.ref
    }.

%% The pinned node came back with a new generation: the media on it is
%% gone, the owner hears it once.
node_restarted(State, Data) ->
    case active(State) andalso not Data#data.media_lost of
        true ->
            notify_owner({node_restarted, Data#data.node}, Data),
            {keep_state, Data#data{media_lost = true}};
        false ->
            {keep_state, Data}
    end.

holder_down(Mon, State, #data{holds = Holds} = Data) ->
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
    end.

owner_down(idle, _Data) ->
    {stop, normal};
owner_down(deleting, _Data) ->
    keep_state_and_data;
owner_down(_State, Data) ->
    case send_async(delete, delete_params(#{}), Data) of
        {ok, Ref, Data1} ->
            {next_state, deleting, add_pending(Ref, undefined, delete, Data1)};
        {error, _} ->
            {stop, normal}
    end.

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
    case require([sdp | [to_tag || NeedToTag]], Params1) of
        ok ->
            #data{
                reoffer_initiator = Initiator,
                from_tag = FromTag,
                to_tag = ToTag
            } = Data,
            {Tags, BranchTag} = chappe_rtpengine_offer:answer_tags(
                Initiator, Params1, FromTag, ToTag
            ),
            Params = maps:merge(Tags, Params1),
            Kind = {answer_sent, StateKind, BranchTag, Final, PrevToTag},
            DataV = note_via(BranchTag, Params1, Data),
            {Next, Data1} =
                case {StateKind, BranchTag} of
                    {answering, none} ->
                        {answering, DataV};
                    {answering, _} ->
                        {answering, DataV#data{to_tag = BranchTag}};
                    {established, _} ->
                        {keep, DataV}
                end,
            send(answer, Params, {From, Kind}, Next, Data1);
        {error, _} = Error ->
            reply_now(From, Error)
    end.

handle_reply(Kind, From, Result, State, Data) ->
    case chappe_rtpengine_offer:pinned_state(Kind) of
        any ->
            reply(Kind, From, Result, State, Data);
        State ->
            reply(Kind, From, Result, State, Data);
        _Other ->
            %% stop/1 or owner death moved on while this was in flight
            {keep_state, Data, reply_stopped(From)}
    end.

reply_stopped(undefined) -> [];
reply_stopped(From) -> [{reply, From, {error, stopped}}].

%% A reply settles the auxiliary command it answers, or else an
%% offer/answer exchange (negotiated/5).
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
        [{reply, From, delete_result(Result)} | stopped_replies(Data)], Data};
reply(Kind, From, Result, State, Data) ->
    negotiated(Kind, From, Result, State, Data).

%% The table in chappe_rtpengine_offer says where the exchange goes; the
%% caller gets the reply as it came.
negotiated(Kind, From, Result, State, Data) ->
    {Next, Updates} = chappe_rtpengine_offer:negotiated(Kind, Result, State),
    Data1 = lists:foldl(fun update/2, Data, Updates),
    Actions = [{reply, From, Result}],
    case Next of
        keep -> {keep_state, Data1, Actions};
        _ -> {next_state, Next, Data1, Actions}
    end.

update({settle, BranchTag, Final}, Data) ->
    settle_answer(BranchTag, Final, Data);
update({reoffer, Reoffer}, Data) ->
    Data#data{reoffer = Reoffer};
update({reoffer_initiator, Initiator}, Data) ->
    Data#data{reoffer_initiator = Initiator};
update({to_tag, ToTag}, Data) ->
    Data#data{to_tag = ToTag}.

%% Callers still waiting when the session ends hear that it stopped
%% rather than seeing the process exit.
stopped_replies(Data) ->
    lists:append([
        reply_stopped(From)
     || {From, _Kind} <- maps:values(Data#data.pending)
    ]).

note_via(none, _Params, Data) ->
    Data;
note_via(BranchTag, #{via_branch := Via}, #data{branch_vias = Vias} = Data) ->
    Data#data{branch_vias = Vias#{BranchTag => Via}};
note_via(_BranchTag, _Params, Data) ->
    Data.

%% Record the branch tag; on the final answer, best-effort delete of
%% every losing branch that had an offer of its own (a via-branch).
%% Branches answered on one offer share the callee's monologue: from
%% rtpengine 13 on, a later to-tag renames it and keeps the earlier ones
%% as aliases of the winner, so deleting a losing tag would end the call;
%% they need no delete.
settle_answer(none, _Final, Data) ->
    Data;
settle_answer(BranchTag, false, Data) ->
    Branches = lists:usort([BranchTag | Data#data.branches]),
    Data#data{branches = Branches};
settle_answer(BranchTag, true, #data{branch_vias = Vias} = Data) ->
    Losing = [
        {Tag, Via}
     || Tag <- lists:usort(Data#data.branches) -- [BranchTag],
        {ok, Via} <- [maps:find(Tag, Vias)]
    ],
    Data1 = lists:foldl(
        fun({LosingTag, Via}, Acc) ->
            Params = #{to_tag => LosingTag, via_branch => Via},
            case send_async(delete, delete_params(Params), Acc) of
                {ok, Ref, Acc1} ->
                    add_pending(Ref, undefined, branch_delete, Acc1);
                {error, _} ->
                    Acc
            end
        end,
        Data,
        Losing
    ),
    Data1#data{
        branches = [BranchTag],
        branch_vias = maps:with([BranchTag], Vias),
        to_tag = BranchTag
    }.

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

send_async(Command, Params0, Data) ->
    #data{call_id = CallId, from_tag = FromTag, ref = CallRef} = Data,
    Params = chappe_rtpengine_offer:params(
        Command, Params0, CallId, FromTag, CallRef
    ),
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

add_pending(Ref, From, Kind, Data) ->
    Data#data{pending = maps:put(Ref, {From, Kind}, Data#data.pending)}.

require(Keys, Params) ->
    chappe_rtpengine_ng:require(Keys, Params).

%% Best-effort synchronous delete for exits that bypassed the deleting
%% state (crash, supervisor shutdown, unreachable client at stop).
final_delete(State, #data{from_tag = FromTag} = Data) when
    FromTag =/= undefined
->
    case active(State) of
        true ->
            try
                chappe_rtpengine:delete(
                    Data#data.node,
                    delete_params(#{
                        call_id => Data#data.call_id,
                        from_tag => FromTag
                    })
                )
            catch
                _:_ -> ok
            end;
        false ->
            ok
    end;
final_delete(_State, _Data) ->
    ok.

%% The session never reads a delete's call statistics, so it asks for
%% none (`fast'): with them the reply of a call with many streams is
%% large enough to be split into IP fragments, which some paths drop
%% (10 KB for a three-stream recording with three forks on rtpengine
%% 26.3). A delete naming a to-tag (a losing branch) carries the `to-tag'
%% flag: rtpengine 13 and later ignore the to-tag without it and delete
%% the whole call. Older rtpengine ignores both flags.
delete_params(Params) ->
    Fast = chappe_rtpengine_offer:add_flag(fast, Params),
    case Params of
        #{to_tag := _} -> chappe_rtpengine_offer:add_flag(to_tag, Fast);
        #{} -> Fast
    end.

safe_call(Session, Request) ->
    try
        gen_statem:call(Session, Request, infinity)
    catch
        exit:{noproc, _} -> {error, session_down};
        exit:{normal, _} -> {error, session_down};
        exit:{shutdown, _} -> {error, session_down}
    end.
