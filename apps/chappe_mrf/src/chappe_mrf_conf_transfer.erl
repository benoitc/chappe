%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Moving a member from one conference to another (chappe_mrf_conf:
%% transfer/3).
%%
%% transfer/3 runs in the caller: each room only does its part. The room
%% the member leaves marks it ({transfer, out, Id}: what leaves it here is
%% the transfer, run by the caller, its mover) and hands over what the
%% other room needs (its backend's handover/1); the other room takes the
%% member in; the first room then lets it go ({transfer, done, Id}), or
%% unmarks it after a failed join there ({transfer, cancel, Id}).
%%
%% The room's side, step/4 and mover_down/2, works on the room's members
%% and the joins under way, and returns {Reply, Members, Actions}: the
%% room runs the actions ({monitor, Id, Mover}, {gone, Id, Reason},
%% {destroy, Ep}).
-module(chappe_mrf_conf_transfer).

-export([transfer/3, step/4, mover_down/2, handed_over/2, cut/2]).

-export_type([action/0, members/0, handover/0]).

-type members() :: #{binary() => map()}.
-type action() ::
    {monitor, binary(), pid()} | {gone, binary(), atom()} | {destroy, pid()}.
-type handover() :: fun((map()) -> {ok, tuple(), boolean()} | {error, term()}).

%% ---- in the caller ----

-spec transfer(pid(), binary(), pid()) -> {ok, binary()} | {error, term()}.
transfer(Conf, _Member, Conf) ->
    {error, same_conference};
transfer(Conf, Member, To) ->
    case {chappe_mrf_conf:info(Conf), chappe_mrf_conf:info(To)} of
        {#{backend := B} = From, #{backend := B} = Dest} ->
            transfer_to(Conf, Member, To, From, Dest);
        {#{backend := _}, #{backend := _}} ->
            {error, backend_mismatch};
        {#{backend := _}, Err} ->
            Err;
        {Err, _} ->
            Err
    end.

transfer_to(Conf, Member, To, #{backend := B, name := FromName} = From, Dest) ->
    Mod = chappe_mrf_conf_backend:module(B),
    Out = {transfer, out, Member},
    maybe
        ok ?= check(Mod, From, Dest),
        {ok, Handover} ?= chappe_mrf_conf:call(Conf, Out, 30000),
        Joined = arrive(Mod, To, Handover, #{
            name => FromName, member => Member
        }),
        finish(Conf, Member, Joined)
    end.

check(Mod, From, Dest) ->
    case chappe_mrf_conf_backend:optional(Mod, transfer_check, 2) of
        true -> Mod:transfer_check(From, Dest);
        false -> ok
    end.

%% a call ({native, B2b, Opts}) joins the other room as any call does;
%% the rest is the backend's
arrive(_Mod, To, {native, B2b, Opts}, _From) ->
    chappe_mrf_conf:join(To, B2b, Opts);
arrive(Mod, To, Handover, From) ->
    Mod:transfer_in(To, Handover, From).

finish(Conf, Member, {ok, _} = Ok) ->
    %% the member is the other room's now: it leaves this one at once,
    %% not when its old leg's BYE comes, so a room ending meanwhile never
    %% hangs it up
    _ = chappe_mrf_conf:call(Conf, {transfer, done, Member}, 30000),
    Ok;
finish(Conf, Member, Error) ->
    _ = chappe_mrf_conf:call(Conf, {transfer, cancel, Member}, 30000),
    Error.

%% ---- in the room ----

%% A step, sent as {transfer, Step, Arg}. out: Arg is the member, Mover
%% the caller, Handover the backend's handover/1. handle_of and holds: a
%% crashed move asks which call a member is and whether this room has it
%% (chappe_mrf_conf_move).
-spec step(
    out | handle_of | holds | done | cancel,
    term(),
    {pid() | undefined, handover()},
    {members(), map()}
) -> {term(), members(), [action()]}.
step(out, Id, {Mover, Handover}, {M, _P}) ->
    out(Id, Mover, Handover, M);
step(handle_of, Id, _Mover, {M, _P}) ->
    case M of
        #{Id := #{b2b := B2b}} -> {{ok, {b2b, B2b}}, M, []};
        #{Id := #{ep := Ep}} -> {{ok, {ep, Ep}}, M, []};
        _ -> {none, M, []}
    end;
step(holds, Handle, _Mover, {M, P}) ->
    {holds(Handle, maps:values(M), maps:values(P)), M, []};
step(done, Id, _Mover, {M, _P}) ->
    case M of
        #{Id := #{transfer := true}} -> {ok, M, [{gone, Id, transferred}]};
        _ -> {ok, M, []}
    end;
step(cancel, Id, _Mover, {M, _P}) ->
    case M of
        #{Id := Mb} -> {ok, M#{Id := maps:without([transfer, mover], Mb)}, []};
        _ -> {ok, M, []}
    end.

%% A member leaves for another room: the process that moves it (Mover)
%% is noted, so the room's end hands it the member's dialog rather than
%% cutting the call halfway through the move.
out(Id, Mover, Handover, M) ->
    case M of
        #{Id := #{transfer := true}} ->
            {{error, transferring}, M, []};
        #{Id := Mb} ->
            case Handover(Mb) of
                {ok, H, Watch} ->
                    Marked = M#{Id := Mb#{transfer => true, mover => Mover}},
                    %% the handover ends with what the member asked for
                    %% when it joined
                    Reply = {ok, erlang:append_element(H, join_opts(Mb))},
                    {Reply, Marked, watch(Watch, Id, Mover)};
                {error, _} = Err ->
                    {Err, M, []}
            end;
        _ ->
            {{error, not_member}, M, []}
    end.

%% A watched move: if its mover dies before the other room took the
%% member (it is still here, marked), the room acts rather than keep it
%% marked for good (mover_down/2).
watch(true, Id, Mover) when is_pid(Mover) -> [{monitor, Id, Mover}];
watch(_Watch, _Id, _Mover) -> [].

%% The mover of a watched member died: an endpoint the room owns is
%% destroyed (its channel may be half way through a conference
%% transfer), an app's endpoint is a member here again.
-spec mover_down(reference(), members()) -> {members(), [action()]}.
mover_down(Mon, M) ->
    case [{Id, Mb} || Id := #{mover_mon := MM, transfer := true} = Mb <- M, MM =:= Mon] of
        [{Id, #{ep := Ep, owned := true}}] ->
            {M, [{destroy, Ep}, {gone, Id, hangup}]};
        [{Id, Mb}] ->
            {M#{Id := maps:without([transfer, mover, mover_mon], Mb)}, []};
        [] ->
            {M, []}
    end.

%% At the room's end: whether a member on its way out is its mover's
%% now. Outside a drain its dialog goes to the mover; in a drain it is
%% not, and is hung up.
-spec handed_over(map(), boolean()) -> boolean().
handed_over(#{transfer := true}, true) ->
    false;
handed_over(#{transfer := true, mover := Mover, dialog := D}, false) when
    is_pid(Mover)
->
    %% a dead mover, here or on another node, is the dialog's to see
    try chappe_sip_dialog:set_owner(D, Mover) of
        ok -> true
    catch
        _:_ -> false
    end;
handed_over(#{transfer := true}, false) ->
    %% fs: the endpoint goes with its owner, this room, unless the other
    %% room adopted it already
    true;
handed_over(_Mb, _Draining) ->
    false.

%% A member cut mid-move by a drain gets its whole call ended, so its
%% caller hears a clean BYE whatever state the move left the call in.
-spec cut(map(), boolean()) -> ok.
cut(#{transfer := true, b2b := {Pid, _} = B2b}, true) ->
    erpc:cast(node(Pid), chappe_sip_b2b, hangup, [B2b, #{}]);
cut(_Mb, _Draining) ->
    ok.

%% whether a call (its b2b) or an endpoint is one of the members, or one
%% joining
holds(Handle, Members, Pending) ->
    case {lists:any(has(Handle), Members), lists:any(has(Handle), Pending)} of
        {true, _} -> member;
        {false, true} -> pending;
        {false, false} -> no
    end.

has({b2b, B2b}) -> fun(Mb) -> maps:get(b2b, Mb, undefined) =:= B2b end;
has({ep, Ep}) -> fun(Mb) -> maps:get(ep, Mb, undefined) =:= Ep end.

%% What a member asked for when it joined, for the conference it moves to.
join_opts(Mb) ->
    maps:with([name, mute, deaf, moderator], Mb).
