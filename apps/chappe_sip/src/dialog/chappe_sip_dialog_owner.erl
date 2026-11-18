%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc What a dialog fsm tells others: its owner (the events and the
%% destroy), the dialog index and its state stream (RFC 3891 Replaces,
%% chappe_sip:dialog_events/1), the call record (chappe_sip_cdr), and the
%% calls that read the dialog's data in any state past init.
%%
%% Runs in the chappe_sip_dialog_fsm process, on its #data{}.
-module(chappe_sip_dialog_owner).

-export([dialog/1, reply/2, reply_await/2, sip_error/2, parse_req/3]).
-export([notify/4, notify4/3, notify_terminal/2, notify_terminal_req/2]).
-export([stop/2]).
-export([index/1, unindex/1, set_index_state/2, publish_state/2]).
-export([cdr_bind/1, addr_tag/1]).
-export([is_query/1, query/3]).

-include("chappe_sip.hrl").
-include("chappe_sip_dialog_fsm.hrl").

-spec dialog(#data{}) -> chappe_sip_dialog:dialog().
dialog(#data{leg = LegH}) ->
    chappe_sip_dialog:make(self(), LegH).

-spec reply(gen_statem:from() | undefined, term()) -> ok.
reply(undefined, _) -> ok;
reply(From, Msg) -> gen_statem:reply(From, Msg).

-spec reply_await(#data{}, term()) -> ok.
reply_await(#data{await_from = From}, Msg) -> reply(From, Msg).

-spec sip_error(100..699, chappe_sip_msg:msg()) -> #chappe_sip_error{}.
sip_error(Status, Msg) ->
    #chappe_sip_error{
        status = Status,
        reason =
            case chappe_sip_msg:reason(Msg) of
                undefined -> <<>>;
                R -> R
            end,
        response = Msg
    }.

%% an in-dialog request carries the dialog's call_ref
-spec parse_req(binary(), non_neg_integer() | undefined, #data{}) ->
    chappe_sip_req:req().
parse_req(Raw, TxnH, #data{call_ref = Ref}) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, Msg} -> chappe_sip_req:new(Msg, TxnH, #{}, Ref);
        {error, _} -> chappe_sip_req:new(empty_msg(), TxnH, #{}, Ref)
    end.

empty_msg() ->
    {ok, M} = chappe_sip_msg:parse(<<"BYE sip:x SIP/2.0\r\n\r\n">>),
    M.

%% claimed events and ack carry a Res slot (5-tuple)
-spec notify(#data{}, term(), chappe_sip_req:req(), term()) -> ok.
notify(#data{owner = Owner} = D, Event, Req, Res) ->
    Owner ! {chappe_sip_dialog, dialog(D), Event, Req, Res},
    ok.

%% auto-answered notifications are informational (4-tuple, no Res)
-spec notify4(#data{}, term(), chappe_sip_req:req()) -> ok.
notify4(#data{owner = Owner} = D, Event, Req) ->
    Owner ! {chappe_sip_dialog, dialog(D), Event, Req},
    ok.

%% the index entry goes first, so an owner told of the destroy never finds
%% the dialog again
-spec notify_terminal_req(#data{}, chappe_sip_req:req()) -> ok.
notify_terminal_req(#data{owner = Owner} = D, Req) ->
    unindex(D),
    chappe_sip_cdr:stop(D#data.cdr, {bye, remote}),
    Owner ! {chappe_sip_dialog, dialog(D), destroy, Req},
    ok.

-spec notify_terminal(#data{}, term()) -> ok.
notify_terminal(#data{owner = Owner} = D, Reason) ->
    unindex(D),
    chappe_sip_cdr:stop(D#data.cdr, cdr_reason(Reason, D)),
    Owner ! {chappe_sip_dialog, dialog(D), destroy, Reason},
    ok.

%% the dialog is over: the owner hears why, then the fsm stops
-spec stop(term(), #data{}) -> {stop, normal, #data{}}.
stop(Reason, D) ->
    notify_terminal(D, Reason),
    {stop, normal, D}.

%% ---- queries: answered in every state once the dialog is set up ----

%% calls that read dialog state (or set the handled events, the owner) and
%% never touch the wire
-spec is_query(term()) -> boolean().
is_query(local_tag) -> true;
is_query(remote_tag) -> true;
is_query(remote_addr) -> true;
is_query(call_id) -> true;
is_query(remote_sdp) -> true;
is_query(local_sdp) -> true;
is_query(local_contact) -> true;
is_query(local_addr) -> true;
is_query(call_ref) -> true;
is_query({set_handled, _}) -> true;
is_query({set_owner, _}) -> true;
is_query(_) -> false.

-spec query(gen_statem:from(), term(), #data{}) ->
    gen_statem:event_handler_result(atom()).
query(From, local_tag, #data{local_tag = T} = D) ->
    {keep_state, D, [{reply, From, T}]};
query(From, remote_tag, #data{remote_addr = RA} = D) ->
    {keep_state, D, [{reply, From, addr_tag(RA)}]};
query(From, remote_addr, #data{remote_addr = RA} = D) ->
    {keep_state, D, [{reply, From, RA}]};
query(From, call_id, #data{call_id = C} = D) ->
    {keep_state, D, [{reply, From, C}]};
query(From, remote_sdp, #data{remote_sdp = S} = D) ->
    {keep_state, D, [{reply, From, S}]};
query(From, local_sdp, #data{local_sdp = S} = D) ->
    {keep_state, D, [{reply, From, S}]};
query(From, local_contact, #data{local_contact = C} = D) ->
    {keep_state, D, [{reply, From, C}]};
query(From, local_addr, #data{local_addr = LA} = D) ->
    {keep_state, D, [{reply, From, LA}]};
query(From, call_ref, #data{call_ref = Ref} = D) ->
    {keep_state, D, [{reply, From, Ref}]};
query(From, {set_handled, Events}, D) ->
    {keep_state, D#data{handled = Events}, [{reply, From, ok}]};
query(From, {set_owner, Owner}, #data{owner_mon = Old} = D) ->
    erlang:demonitor(Old, [flush]),
    MRef = erlang:monitor(process, Owner),
    {keep_state, D#data{owner = Owner, owner_mon = MRef}, [{reply, From, ok}]}.

%% ---- call records (chappe_sip_cdr) ----

%% the dialog drives its call record from now on
-spec cdr_bind(#data{}) -> ok.
cdr_bind(#data{cdr = undefined}) ->
    ok;
cdr_bind(#data{cdr = Id, local_tag = L, remote_addr = RA}) ->
    chappe_sip_cdr:bind(Id, self(), #{
        local_tag => L, remote_tag => addr_tag(RA)
    }).

%% the destroy reason the owner gets, as the record's normalized reason
cdr_reason(byed, #data{cdr_why = undefined}) -> {bye, local};
cdr_reason(byed, #data{cdr_why = Why}) -> Why;
cdr_reason({request_failed, 408}, _D) -> timeout;
cdr_reason({request_failed, Status}, _D) -> {final, Status};
cdr_reason({early_ended, Status}, _D) -> {final, Status};
cdr_reason(Reason, _D) -> Reason.

%% Peer dialog tag out of the stored remote address (a name-addr with ;tag=).
-spec addr_tag(binary()) -> binary() | undefined.
addr_tag(Addr) ->
    case chappe_sip_hdr:name_addr(Addr) of
        {ok, #{params := P}} ->
            case maps:get(<<"tag">>, P, undefined) of
                true -> undefined;
                V -> V
            end;
        _ ->
            undefined
    end.

%% ---- dialog index (RFC 3891 Replaces) ----

%% index under {CallId, LocalTag, RemoteTag}; a dialog whose peer never
%% tagged it cannot be named by a Replaces and is not indexed
-spec index(#data{}) -> #data{}.
index(#data{sub = Sub} = D) when Sub =/= undefined ->
    %% a Replaces names an INVITE dialog, never a subscription
    D;
index(#data{remote_addr = RA} = D) ->
    case addr_tag(RA) of
        undefined ->
            D;
        RemoteTag ->
            Key = {D#data.call_id, D#data.local_tag, RemoteTag},
            case
                chappe_sip_dialog_index:insert(
                    Key, D#data.leg, D#data.index_state, D#data.role, self()
                )
            of
                ok ->
                    D#data{indexed = Key};
                {error, Reason} ->
                    logger:warning(
                        "chappe_sip_dialog_fsm: not indexed ~p: ~p",
                        [Key, Reason]
                    ),
                    D
            end
    end.

-spec set_index_state(#data{}, chappe_sip_dialog_index:dialog_state()) -> ok.
set_index_state(#data{indexed = undefined}, _State) ->
    ok;
set_index_state(#data{indexed = Key} = D, State) ->
    ok = chappe_sip_dialog_index:set_state(Key, State),
    publish_state(D, State).

%% leaving the index ends the dialog for the state stream, unless its BYE
%% did already (or an earlier unindex/1)
-spec unindex(#data{}) -> ok.
unindex(#data{indexed = undefined}) ->
    ok;
unindex(#data{indexed = Key} = D) ->
    _ =
        case chappe_sip_dialog_index:lookup(Key) of
            {ok, {_, _, State, _}} when State =/= terminated ->
                publish_state(D, terminated);
            _ ->
                ok
        end,
    chappe_sip_dialog_index:delete(Key).

%% the dialog state stream (chappe_sip:dialog_events/1)
-spec publish_state(#data{}, chappe_sip_dialog_index:dialog_state()) -> ok.
publish_state(#data{indexed = {CallId, Local, Remote}} = D, State) ->
    chappe_sip_dialog_index:publish(#{
        dialog => dialog(D),
        state => State,
        call_id => CallId,
        local_tag => Local,
        remote_tag => Remote,
        role => D#data.role,
        call_ref => D#data.call_ref
    }).
