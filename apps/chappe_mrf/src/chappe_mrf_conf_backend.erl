%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc What a conference backend implements, and the room API it calls.
%%
%% A room (chappe_mrf_conf) is one process; its backend is the module
%% that carries the media: chappe_mrf_conf_native (chappe_mix behind
%% rtpengine) or chappe_mrf_conf_fs (mod_conference). start/2's backend
%% option names it: native, fs, or any module with this behaviour.
%%
%% Two sides:
%%   - join/4, transfer_check/2 and transfer_in/3 run in the caller of
%%     chappe_mrf_conf (join/3, transfer/3): they may block, and talk to
%%     the room with chappe_mrf_conf:call/3. A join sends {join, Req}: the
%%     room checks its lease, then admission/1 (the lock and the member
%%     limit), then hands Req to admit/3.
%%   - every other callback runs in the room process on room(), the
%%     room's state, and returns it. The backend keeps its own state in
%%     it: bstate/1 reads it, bstate/2 sets it (init/2 gives the first).
%%
%% The room handles the requests it knows (members, flags, play, lock,
%% the REFERs, transfers, the cluster lease). A call {backend, Req} goes
%% to handle_call/3, a cast {backend, Msg} to handle_cast/2, and any
%% message the room does not know to handle_info/2 (ignore: not the
%% backend's, the room's focus may take it), every 'DOWN' too but the
%% owner's and the event receivers'. The room reads which optional
%% callbacks its backend has once, when it starts.
%%
%% Callbacks a backend leaves out are features it does not have: the
%% room answers {error, {unsupported, Backend}} (relate, record,
%% stop_record, transfer, a REFER that adds a party). Without lock/2 the
%% room only keeps the flag.
%%
%% The room API, for the room side (Room is room(), Id a member id, Mb
%% the member map the room keeps):
%%   bstate(Room) / bstate(B, Room)  the backend's state
%%   name(Room)                      the conference name
%%   members(Room)                   #{Id => Mb}
%%   member(Opts, Id, Base)          a new Mb: Base plus what the join
%%                                   asked for (name, mute, deaf,
%%                                   moderator; uri and b2b kept)
%%   put_member(Id, Mb, Room)        keep Mb, no event
%%   joined(Id, Mb, Room)            keep Mb, emit {joined, Id, Info},
%%                                   publish (a party a REFER dials, its
%%                                   Mb with refer: once it answered)
%%   public(Id, Mb)                  the Info members/1 shows
%%   emit(Event, Room)               {chappe_mrf_conf, Conf, Event} to
%%                                   the room's receivers
%%   publish(Room)                   the conference-info of a focus room
%%   talking(Id, boolean(), Room)    note it, emit {talking, Id, T}
%%   gone(Id, Room) / gone(Id, Why, Room)
%%                                   the member left: left/2, emit
%%                                   {left, Id, Why}, publish
%%   drop_member(Id, Why, Room)      hang the member up (hangup/3), then
%%                                   gone
%%   member_by(Key, Value, Room)     {ok, Id} of the member whose Mb has
%%                                   Key => Value, or error
%%   admission(Room)                 ok, or {error, locked | full}: may
%%                                   one more come in (members, joins
%%                                   and REFER dial-outs under way count)
%%   refer_progress(Key, St, Room)   for dial/4: the party's 180 or 183,
%%                                   to the referrers of op Key
%%   refer_final(Key, St, Room)      for dial/4: its final status (200
%%                                   once it is a member, joined/3)
-module(chappe_mrf_conf_backend).

-include("chappe_mrf_conf.hrl").

-export([check_opts/1]).
-export([module/1, optional/3, callbacks/1, has/3, supported/4]).
-export([unsupported/1]).
-export([bstate/1, bstate/2, name/1, members/1, member_by/3]).
-export([member/3, put_member/3, joined/3, public/2]).
-export([emit/2, publish/1, talking/3, gone/2, gone/3, drop_member/3]).
-export([close_if_empty/1, admission/1, refer_progress/3, refer_final/3]).

-export_type([room/0, member/0, member_info/0, reply/0]).

-type room() :: #state{}.
-type member() :: binary().
-type member_info() :: map().
-type reply() :: {reply, term(), room()} | {noreply, room()}.

%% ---- in the caller ----

%% Bring Target in (chappe_mrf_conf:join/3); Info is the room's info/1.
-callback join(Conf :: pid(), Info :: map(), Target :: term(), Opts :: map()) ->
    {ok, member()} | {error, term()}.
%% Whether a member can move from the room From to Dest (their info/1).
-callback transfer_check(From :: map(), Dest :: map()) -> ok | {error, term()}.
%% Bring a member handed over by handover/1 into To: the handover with
%% the member's join options appended.
-callback transfer_in(
    To :: pid(),
    Handover :: tuple(),
    From :: #{name := binary(), member := member()}
) -> {ok, member()} | {error, term()}.

%% ---- in the room ----

-callback init(Name :: binary(), Opts :: map()) ->
    {ok, term()} | {error, term()}.
%% Keys the backend adds to the room's info/1 (node, bridge).
-callback info(BState :: term()) -> map().
%% A join request ({join, Req}) the room took.
-callback admit(Req :: term(), From :: gen_server:from(), room()) -> reply().
-callback handle_call(Req :: term(), From :: gen_server:from(), room()) ->
    reply().
-callback handle_cast(Msg :: term(), room()) -> {noreply, room()}.
-callback handle_info(Msg :: term(), room()) -> {noreply, room()} | ignore.
%% mute or deaf a member; the room keeps the flag once it is ok.
-callback set_flag(member(), member_info(), mute | deaf, boolean(), room()) ->
    {ok, room()} | {error, unsupported | term()}.
%% Hang a member up (kick, leave, the room's end).
-callback hangup(member(), member_info(), room()) -> ok.
%% A member left the room (Why transferred: it lives on elsewhere).
-callback left(member_info(), Why :: atom()) -> ok.
-callback play(all | {member(), member_info()}, binary(), room()) ->
    ok | {error, term()}.
%% Whether the room's members can move to a room on another node.
-callback portable() -> boolean().
-callback lock(boolean(), room()) -> ok.
-callback relate(member_info(), member_info(), hear | nohear, room()) ->
    ok | {error, term()}.
-callback record(Path :: binary(), Opts :: map(), room()) ->
    {ok | {error, term()}, room()}.
-callback stop_record(room()) -> {ok | {error, term()}, room()}.
%% What transfer_in/3 needs to bring the member into another room, as a
%% tuple the member's join options are appended to; {native, B2b} is a
%% call, which joins the other room through join/3. Watch: the room
%% watches the mover, and takes the member back (or ends an endpoint it
%% owns) when it dies.
-callback handover(member_info()) ->
    {ok, Handover :: tuple(), Watch :: boolean()} | {error, term()}.
%% Dial a party in for a REFER (chappe_mrf_conf_refer), in the room, for
%% the op Key; Cfg has the room's dial options, what the REFER asked for
%% (replaces, referred_by) and dial_string, the dial string the room's
%% policy saw (dial it, do not make another). ok once it is under way;
%% then report, in the room, with refer_progress/3 and refer_final/3 (200
%% once the party is a member: add it with joined/3 when it answered).
%% An error fails the REFER with 503.
-callback dial(
    Target :: binary(), Key :: term(), Cfg :: map(), room()
) -> {ok | {error, term()}, room()}.
-callback terminate(room()) -> ok.

-optional_callbacks([
    transfer_check/2,
    transfer_in/3,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    lock/2,
    relate/4,
    record/3,
    stop_record/1,
    handover/1,
    dial/4,
    terminate/1
]).

%% The module of a backend start/2 names.
-spec module(atom()) -> module().
module(native) -> chappe_mrf_conf_native;
module(fs) -> chappe_mrf_conf_fs;
module(Mod) -> Mod.

%% Whether Mod has an optional callback, in the caller.
-spec optional(module(), atom(), arity()) -> boolean().
optional(Mod, F, Arity) ->
    _ = code:ensure_loaded(Mod),
    erlang:function_exported(Mod, F, Arity).

%% The optional callbacks Mod has, read once when the room starts.
-spec callbacks(module()) -> #{{atom(), arity()} => true}.
callbacks(Mod) ->
    {module, Mod} = code:ensure_loaded(Mod),
    #{
        FA => true
     || {F, A} = FA <- ?MODULE:behaviour_info(optional_callbacks),
        erlang:function_exported(Mod, F, A)
    }.

%% Whether the room's backend has an optional callback.
-spec has(atom(), arity(), room()) -> boolean().
has(F, Arity, #state{callbacks = C}) ->
    is_map_key({F, Arity}, C).

%% Run Fun(Mod) when the backend has F/Arity; the one place a room
%% answers a feature its backend lacks.
-spec supported(atom(), arity(), room(), fun((module()) -> R)) ->
    R | {reply, {error, {unsupported, atom()}}, room()}.
supported(F, Arity, #state{mod = Mod} = S, Fun) ->
    case has(F, Arity, S) of
        true -> Fun(Mod);
        false -> {reply, unsupported(S), S}
    end.

-spec unsupported(room()) -> {error, {unsupported, atom()}}.
unsupported(#state{backend = B}) ->
    {error, {unsupported, B}}.

%% ---- the room API ----

-spec bstate(room()) -> term().
bstate(#state{bstate = B}) -> B.

-spec bstate(term(), room()) -> room().
bstate(B, S) -> S#state{bstate = B}.

-spec name(room()) -> binary().
name(#state{name = Name}) -> Name.

-spec members(room()) -> #{member() => member_info()}.
members(#state{members = M}) -> M.

-spec member_by(atom(), term(), room()) -> {ok, member()} | error.
member_by(Key, Value, #state{members = M}) ->
    case [Id || Id := #{Key := V} <- M, V =:= Value] of
        [Id | _] -> {ok, Id};
        [] -> error
    end.

%% A member as the conference keeps it: Base (its media) and what the
%% join asked for.
-spec member(map(), member(), map()) -> member_info().
member(Opts, Id, Base0) ->
    %% uri: who the member is, for a REFER's method=BYE and the roster;
    %% b2b: its call, for a transfer (when the backend's own base has
    %% none); joining, referred: how it came (a dial-out, a referred
    %% INVITE) for the roster (RFC 4575 5.7.2), private: its caller asked
    %% for privacy (RFC 4579 6), refer: the REFER op that dials it, which
    %% keeps it out of sight until it answered
    Base = maps:merge(
        maps:with([uri, b2b, joining, referred, private, refer], Opts), Base0
    ),
    Base#{
        name => chappe_mrf_lib:to_bin(maps:get(name, Opts, Id)),
        mute => maps:get(mute, Opts, false),
        deaf => maps:get(deaf, Opts, false),
        moderator => maps:get(moderator, Opts, false),
        talking => false
    }.

-spec put_member(member(), member_info(), room()) -> room().
put_member(Id, Mb, #state{members = M} = S) ->
    S#state{members = M#{Id => Mb}}.

-spec joined(member(), member_info(), room()) -> room().
joined(Id, #{refer := _} = Mb, S) ->
    %% a party a REFER dials: out of sight until it answered
    chappe_mrf_conf_refer_dial:hidden(Id, Mb, S);
joined(Id, Mb, S) ->
    publish(emit({joined, Id, public(Id, Mb)}, put_member(Id, Mb, S))).

-spec public(member(), member_info()) -> map().
public(Id, Mb) ->
    (maps:with([name, mute, deaf, moderator, talking, uri], Mb))#{id => Id}.

-spec emit(term(), room()) -> room().
emit(Event, #state{listeners = L} = S) ->
    _ = [Pid ! {chappe_mrf_conf, self(), Event} || Pid <- maps:keys(L)],
    S.

%% the conference-info of a focus room (chappe_mrf_conf_focus)
-spec publish(room()) -> room().
publish(S) ->
    chappe_mrf_conf_focus:publish(S).

-spec talking(member(), boolean(), room()) -> room().
talking(Id, Talking, #state{members = M} = S) ->
    case M of
        #{Id := Mb} ->
            S1 = S#state{members = M#{Id := Mb#{talking => Talking}}},
            emit({talking, Id, Talking}, S1);
        _ ->
            S
    end.

-spec gone(member(), room()) -> room().
gone(Id, S) ->
    gone(Id, departed, S).

%% A member on its way to another room leaves as transferred, whatever
%% Why: its call or channel lives on there.
-spec gone(member(), atom(), room()) -> room().
gone(Id, Reason, #state{members = M, mod = Mod} = S) ->
    case maps:take(Id, M) of
        {Mb, M1} ->
            Why =
                case Mb of
                    #{transfer := true} -> transferred;
                    _ -> Reason
                end,
            ok = Mod:left(Mb, Why),
            %% the roster shows it disconnected, then without it
            S0 = chappe_mrf_conf_focus:departed(Id, Mb, Why, S),
            S1 = publish(emit({left, Id, Why}, S0#state{members = M1})),
            ok = close_if_empty(S1),
            S1;
        error ->
            S
    end.

%% Drop member Id for Reason (leave/2, kick/2, a REFER's method=BYE).
-spec drop_member(member(), atom(), room()) -> {reply, ok, room()}.
drop_member(Id, Reason, #state{members = M, mod = Mod} = S) ->
    _ = Mod:hangup(Id, maps:get(Id, M), S),
    {reply, ok, gone(Id, Reason, S)}.

%% Whether one more may come in: not into a locked room, nor past
%% max_members, the joins (pending) and the REFER dial-outs under way
%% counting as members.
-spec admission(room()) -> ok | {error, locked | full}.
admission(#state{locked = true}) ->
    {error, locked};
admission(#state{members = M, pending = P, max_members = Max} = S) ->
    case map_size(M) + map_size(P) + dials(S) >= Max of
        true -> {error, full};
        false -> ok
    end.

dials(#state{refer_ops = Ops}) ->
    length([
        K
     || {K, #{kind := new, action := add}} <- chappe_mrf_conf_refer_op:in_flight(
            Ops
        )
    ]).

%% A party a backend's dial/4 brings in for op Key rings (180) or has
%% early media (183): the referrers hear it.
-spec refer_progress(term(), 101..199, room()) -> room().
refer_progress(Key, St, S) ->
    chappe_mrf_conf_refer:progress(Key, St, S).

%% That party's final status: 200 once it is a member, the failure
%% otherwise; the op is done.
-spec refer_final(term(), 200..699, room()) -> room().
refer_final(Key, St, S) ->
    chappe_mrf_conf_refer:final(Key, St, S).

%% A room that lost its name ends with its last member.
-spec close_if_empty(room()) -> ok.
close_if_empty(#state{lost = Lost, members = M, pending = P}) ->
    case chappe_mrf_conf_cluster:closing(Lost, M, P) of
        true -> gen_server:cast(self(), lost_empty);
        false -> ok
    end.

%% The options of a room that start/2 refuses before any room runs: a
%% rate the backend cannot mix at, a join_timeout that is no number of
%% milliseconds up to 95000, and dial_codecs that do not fit in a dial
%% string.
-spec check_opts(map()) -> ok | {error, term()}.
check_opts(Opts) ->
    maybe
        ok ?= chappe_mrf_conf_native:check_rate(Opts),
        ok ?= chappe_mrf_conf_native:check_join_timeout(Opts),
        chappe_mrf_conf_refer_dial:check_codecs(Opts)
    end.
