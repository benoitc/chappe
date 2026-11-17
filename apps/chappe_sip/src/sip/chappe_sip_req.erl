%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Inbound request handle.
%%
%% Wraps the parsed message plus engine metadata (transaction handle,
%% source). Created by the engine layer (M2); the accessors here are the
%% surface application handlers see.
-module(chappe_sip_req).

-export([new/3, new/4]).
-export([
    msg/1,
    txn/1,
    meta/1,
    method/1,
    uri/1,
    body/1,
    get/2,
    get_all/2,
    call_id/1,
    from_tag/1,
    source_ip/1,
    source_port/1,
    calling_number/1,
    calling_name/1,
    called_number/1
]).
-export([call_ref/1, set_call_ref/2]).
-export([set_local/3, local/2, local/3, locals/1, is_req/1]).

-record(req, {
    msg :: chappe_sip_msg:msg(),
    txn :: non_neg_integer() | undefined,
    meta :: map(),
    %% the call this request belongs to (chappe_sip_call)
    call_ref :: binary() | undefined,
    %% what middleware and handlers attach to the request (set_local/3)
    locals = #{} :: map()
}).

-opaque req() :: #req{}.
-export_type([req/0]).

-spec new(chappe_sip_msg:msg(), non_neg_integer() | undefined, map()) -> req().
new(Msg, TxnH, Meta) ->
    #req{msg = Msg, txn = TxnH, meta = Meta}.

%% new/3 for a request of call CallRef.
-spec new(
    chappe_sip_msg:msg(),
    non_neg_integer() | undefined,
    map(),
    binary() | undefined
) -> req().
new(Msg, TxnH, Meta, CallRef) ->
    #req{msg = Msg, txn = TxnH, meta = Meta, call_ref = CallRef}.

%% The call_ref of the call this request belongs to: made when the first
%% request of a call arrives, the dialog's for an in-dialog request.
%% undefined for a request built outside the stack.
-spec call_ref(req()) -> binary() | undefined.
call_ref(#req{call_ref = R}) -> R.

%% The request with another call_ref: a middleware taking the ref an
%% upstream node gave (an X-Call-Ref header it trusts). {error, badarg}
%% unless Ref is a token of 1 to 128 characters (chappe_sip_call:valid/1).
-spec set_call_ref(req(), binary()) -> req() | {error, badarg}.
set_call_ref(#req{} = Req, Ref) ->
    case chappe_sip_call:valid(Ref) of
        true -> Req#req{call_ref = Ref};
        false -> {error, badarg}
    end.

%% The request with Key set to Value among its locals: data a middleware
%% hands to the middleware and the handler after it (an authenticated
%% account, a tenant, a route decision). The locals live in the request
%% value, not in a process: hand the new request on with {next, Req1}
%% (chappe_sip_middleware).
-spec set_local(term(), term(), req()) -> req().
set_local(Key, Value, #req{locals = L} = Req) ->
    Req#req{locals = L#{Key => Value}}.

%% The local Key of the request; error(badarg) when it is not set.
-spec local(term(), req()) -> term().
local(Key, #req{locals = L}) ->
    case L of
        #{Key := V} -> V;
        _ -> error(badarg, [Key])
    end.

%% The local Key of the request, or Default.
-spec local(term(), req(), term()) -> term().
local(Key, #req{locals = L}, Default) ->
    maps:get(Key, L, Default).

-spec is_req(term()) -> boolean().
is_req(#req{}) -> true;
is_req(_) -> false.

%% Every local of the request.
-spec locals(req()) -> map().
locals(#req{locals = L}) -> L.

-spec msg(req()) -> chappe_sip_msg:msg().
msg(#req{msg = M}) -> M.

-spec txn(req()) -> non_neg_integer() | undefined.
txn(#req{txn = T}) -> T.

-spec meta(req()) -> map().
meta(#req{meta = M}) -> M.

-spec method(req()) -> binary() | undefined.
method(#req{msg = M}) -> chappe_sip_msg:method(M).

-spec uri(req()) -> binary() | undefined.
uri(#req{msg = M}) -> chappe_sip_msg:uri(M).

-spec body(req()) -> binary().
body(#req{msg = M}) -> chappe_sip_msg:body(M).

-spec get(binary(), req()) -> binary() | undefined.
get(Name, #req{msg = M}) -> chappe_sip_msg:get(Name, M).

-spec get_all(binary(), req()) -> [binary()].
get_all(Name, #req{msg = M}) -> chappe_sip_msg:get_all(Name, M).

-spec call_id(req()) -> binary() | undefined.
call_id(#req{msg = M}) -> chappe_sip_msg:call_id(M).

-spec from_tag(req()) -> binary() | undefined.
from_tag(#req{msg = M}) -> chappe_sip_msg:from_tag(M).

%% The wire source address of the request (the engine's peer, not the spoofable
%% Via sent-by). undefined if the transport did not report it. This is the
%% trust anchor for a source-IP ACL.
-spec source_ip(req()) -> binary() | undefined.
source_ip(#req{meta = Meta}) ->
    case maps:get(source_ip, Meta, undefined) of
        <<>> -> undefined;
        Ip -> Ip
    end.

-spec source_port(req()) -> non_neg_integer() | undefined.
source_port(#req{meta = Meta}) ->
    maps:get(source_port, Meta, undefined).

%% P-Asserted-Identity user, else From user (drachtio semantics).
-spec calling_number(req()) -> binary() | undefined.
calling_number(#req{msg = M}) ->
    case chappe_sip_msg:get(<<"p-asserted-identity">>, M) of
        undefined ->
            user_of(chappe_sip_msg:from(M));
        Pai ->
            case chappe_sip_hdr:name_addr(Pai) of
                {ok, Na} -> user_of({ok, Na});
                _ -> user_of(chappe_sip_msg:from(M))
            end
    end.

-spec calling_name(req()) -> binary() | undefined.
calling_name(#req{msg = M}) ->
    case chappe_sip_msg:from(M) of
        {ok, #{display := D}} -> D;
        _ -> undefined
    end.

%% user part of the request URI
-spec called_number(req()) -> binary() | undefined.
called_number(#req{msg = M}) ->
    case chappe_sip_msg:uri(M) of
        undefined ->
            undefined;
        U ->
            case chappe_sip_uri:parse(U) of
                {ok, #{user := User}} -> User;
                _ -> undefined
            end
    end.

user_of({ok, #{uri := U}}) ->
    case chappe_sip_uri:parse(U) of
        {ok, #{user := User}} -> User;
        _ -> undefined
    end;
user_of(_) ->
    undefined.
