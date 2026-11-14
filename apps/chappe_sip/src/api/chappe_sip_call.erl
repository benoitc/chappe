%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Call correlation: one call_ref per call, and the processes that
%% serve it.
%%
%% A call gets one call_ref, an opaque binary made when its first request
%% arrives (chappe_sip_req:call_ref/1) or given by the app (the call_ref
%% option of create_b2bua/4, create_uas/3 and create_uac/2). It goes on
%% every leg the call creates as X-Chappe-Call, in every call record, and
%% in a HEP log packet per Call-ID.
%%
%% A process that serves the call (the B2BUA, a dialog, the rtpengine
%% session, a SIPREC recording) joins it while it does: the pg group
%% {chappe_sip_call, Ref} of the `chappe' scope for the cluster, and a
%% node-local table that keeps the handle it serves under (a b2b(), a
%% dialog(), a media session, a recording's pid). A
%% process leaves on leave/2 or when it exits. lookup/1 asks the members'
%% nodes for their handles, so a call is found from any node.
-module(chappe_sip_call).
-behaviour(gen_server).

-export([start_scope/0, start_link/0]).
-export([new_ref/0, valid/1, valid_opts/1, header/0]).
-export([join/3, join/4, leave/2, leave/3, lookup/1, local/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([call_ref/0, role/0, calls/0]).

-define(SCOPE, chappe).
-define(TAB, chappe_sip_call_members).
%% the longest call_ref taken from an app
-define(MAX_REF, 128).

%% the processes watched, and the rows each one holds
-record(state, {
    watched = #{} :: #{pid() => {reference(), [{binary(), atom(), pid()}]}}
}).
-type state() :: #state{}.

-type call_ref() :: binary().
-type role() :: b2b | dialog | media | siprec.
%% What lookup/1 finds of a call, on every node.
-type calls() :: #{
    b2b := [chappe_sip_b2b:b2b()],
    dialogs := [chappe_sip_dialog:dialog()],
    media := [chappe_sip_media:session()],
    siprec := [chappe_sip_siprec:rec()]
}.

%% The `chappe' pg scope, unless an app of the node started it already.
-spec start_scope() -> {ok, pid()} | ignore | {error, term()}.
start_scope() ->
    case pg:start_link(?SCOPE) of
        {error, {already_started, _}} -> ignore;
        Other -> Other
    end.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% A fresh call_ref: 24 lowercase hex characters.
-spec new_ref() -> call_ref().
new_ref() ->
    binary:encode_hex(crypto:strong_rand_bytes(12), lowercase).

%% A call_ref an app may give: 1 to 128 characters of a SIP token (RFC
%% 3261 25.1), so it goes in a header as it is.
-spec valid(term()) -> boolean().
valid(Ref) when
    is_binary(Ref), byte_size(Ref) > 0, byte_size(Ref) =< ?MAX_REF
->
    lists:all(fun token_char/1, binary_to_list(Ref));
valid(_) ->
    false.

%% The call_ref and related options of Opts, when given, are valid/1.
-spec valid_opts(map()) -> boolean().
valid_opts(Opts) ->
    lists:all(
        fun(K) ->
            case maps:find(K, Opts) of
                {ok, V} -> valid(V);
                error -> true
            end
        end,
        [call_ref, related]
    ).

token_char(C) when C >= $a, C =< $z -> true;
token_char(C) when C >= $A, C =< $Z -> true;
token_char(C) when C >= $0, C =< $9 -> true;
token_char(C) -> lists:member(C, "-.!%*_+`'~").

%% The header a call's legs carry its call_ref in.
-spec header() -> binary().
header() -> <<"X-Chappe-Call">>.

%% Pid (a process of this node) serves call Ref as Role, under Handle.
%% A process of a call without a ref (undefined) joins nothing.
-spec join(call_ref() | undefined, role(), term()) -> ok.
join(Ref, Role, Handle) ->
    join(Ref, Role, Handle, self()).

-spec join(call_ref() | undefined, role(), term(), pid()) -> ok.
join(Ref, Role, Handle, Pid) when is_binary(Ref), node(Pid) =:= node() ->
    Key = {Ref, Role, Pid},
    case ets:insert_new(?TAB, {Key, Handle}) of
        true ->
            ok = pg:join(?SCOPE, group(Ref), Pid),
            gen_server:cast(?MODULE, {watch, Pid, Key});
        false ->
            %% joined already: the handle it serves under changed
            true = ets:insert(?TAB, {Key, Handle}),
            ok
    end;
join(_Ref, _Role, _Handle, _Pid) ->
    ok.

%% The calling process no longer serves call Ref as Role.
-spec leave(call_ref() | undefined, role()) -> ok.
leave(Ref, Role) ->
    leave(Ref, Role, self()).

-spec leave(call_ref() | undefined, role(), pid()) -> ok.
leave(Ref, Role, Pid) when is_binary(Ref) ->
    Key = {Ref, Role, Pid},
    case ets:take(?TAB, Key) of
        [_] ->
            _ = pg:leave(?SCOPE, group(Ref), Pid),
            gen_server:cast(?MODULE, {unwatch, Pid, Key});
        [] ->
            ok
    end;
leave(_Ref, _Role, _Pid) ->
    ok.

%% The handles that serve call Ref on every node of the cluster. A node
%% that does not answer in 5 s is left out.
-spec lookup(call_ref()) -> calls().
lookup(Ref) ->
    Nodes = lists:usort([node(P) || P <- pg:get_members(?SCOPE, group(Ref))]),
    Found = lists:append([at(N, Ref) || N <- Nodes]),
    #{
        b2b => [H || {b2b, H} <- Found],
        dialogs => [H || {dialog, H} <- Found],
        media => [H || {media, H} <- Found],
        siprec => [H || {siprec, H} <- Found]
    }.

at(Node, Ref) when Node =:= node() ->
    local(Ref);
at(Node, Ref) ->
    try
        erpc:call(Node, ?MODULE, local, [Ref], 5000)
    catch
        _:_ -> []
    end.

%% The handles of call Ref on this node, live processes only.
-spec local(call_ref()) -> [{role(), term()}].
local(Ref) ->
    case ets:info(?TAB, size) of
        undefined ->
            [];
        _ ->
            [
                {Role, H}
             || [Role, Pid, H] <- ets:match(?TAB, {{Ref, '$1', '$2'}, '$3'}),
                is_process_alive(Pid)
            ]
    end.

group(Ref) -> {chappe_sip_call, Ref}.

%% ---- gen_server: owns the table, drops what a dead process held ----

init([]) ->
    _ = ets:new(?TAB, [
        named_table, public, ordered_set, {write_concurrency, true}
    ]),
    {ok, #state{}}.

-spec handle_call(term(), gen_server:from(), state()) ->
    {reply, {error, badarg}, state()}.
handle_call(_Req, _From, S) ->
    {reply, {error, badarg}, S}.

handle_cast({watch, Pid, Key}, #state{watched = W} = S) ->
    case W of
        #{Pid := {Mon, Keys}} ->
            Keys1 = [Key | lists:delete(Key, Keys)],
            {noreply, S#state{watched = W#{Pid := {Mon, Keys1}}}};
        _ ->
            Mon = erlang:monitor(process, Pid),
            {noreply, S#state{watched = W#{Pid => {Mon, [Key]}}}}
    end;
handle_cast({unwatch, Pid, Key}, #state{watched = W} = S) ->
    case W of
        #{Pid := {Mon, Keys}} ->
            case lists:delete(Key, Keys) of
                [] ->
                    erlang:demonitor(Mon, [flush]),
                    {noreply, S#state{watched = maps:remove(Pid, W)}};
                Rest ->
                    {noreply, S#state{watched = W#{Pid := {Mon, Rest}}}}
            end;
        _ ->
            {noreply, S}
    end.

handle_info({'DOWN', _Mon, process, Pid, _Why}, #state{watched = W} = S) ->
    case maps:take(Pid, W) of
        {{_, Keys}, W1} ->
            _ = [ets:delete(?TAB, K) || K <- Keys],
            {noreply, S#state{watched = W1}};
        error ->
            {noreply, S}
    end;
handle_info(_Msg, S) ->
    {noreply, S}.
