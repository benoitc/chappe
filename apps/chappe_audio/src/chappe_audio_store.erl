%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The recording store: where a call's audio is kept, found by its
%% call_ref, read back and deleted.
%%
%% chappe never decides where a recording lives: the app configures the
%% store (the `storage' env, or configure/1), and the default is the file
%% backend in a folder, `#{backend => file, dir => "recordings"}'. Another
%% backend (an object store, a database) is a module implementing the
%% callbacks below, named as `backend => Module'.
%%
%% Writing. open/2 starts a writer process for one recording, owned by
%% the process that feeds it (a stream, a SIPREC session): write/2 hands
%% it audio, close/2 finishes it and returns its id. When the feeder dies
%% the writer finishes what it has. A writer that crashes leaves a
%% partial file the next sweep removes, and never touches the call.
%% adopt/3 takes in a file something else finished (FreeSWITCH or
%% rtpengine writing into a folder shared with chappe).
%%
%% Reading. find/1 asks the store of every node through pg (the
%% chappe_audio_store group of the `chappe' scope), since the file backend
%% keeps a recording on the node that wrote it; get/1, read/2 and
%% delete/1 go to the node that holds the recording.
-module(chappe_audio_store).

-export([open/2, write/2, close/2, writer/1, adopt/3]).
-export([find/1, get/1, read/2, delete/1, sweep/0, configure/1, config/0]).

-export_type([recording/0, meta/0, rec/0]).

%% A recording as the store reports it: its id, the call_ref, the node
%% whose store holds it, where its audio is (path, for the file
%% backend), and what its sidecar says (parties, source, start,
%% duration_ms, format, bytes).
-type recording() :: #{
    id := binary(),
    call_ref := binary(),
    node := node(),
    path => file:filename_all(),
    atom() => term()
}.

%% call_ref: the call's opaque binary; source: where the audio comes
%% from (siprec, fork, freeswitch, rtpengine, room, or a binary);
%% parties: who is on the call, as the app names them (binaries or
%% JSON-able maps); format: the rate and channels of the PCM write/2
%% takes (default 8000, 1).
-type meta() :: #{
    call_ref := binary(),
    source => atom() | binary(),
    parties => [binary() | map()],
    format => #{rate => pos_integer(), channels => pos_integer()},
    start => non_neg_integer(),
    keep => boolean()
}.

%% A recording being written: its writer and the bound on writes
%% waiting at it.
-opaque rec() :: {chappe_audio_rec, pid(), pos_integer()}.

%% ---- backend callbacks ----

%% Start a recording; the writer process calls this and holds the handle.
-callback open(meta(), Config :: map()) ->
    {ok, Handle :: term()} | {error, term()}.
-callback write(Handle :: term(), iodata()) ->
    {ok, Handle :: term()} | {error, term()}.
%% Finish it: from here on it is listed.
-callback close(Handle :: term(), Extra :: map()) ->
    {ok, binary()} | {error, term()}.
%% Give it up (the feeder asked for nothing to be kept).
-callback abort(Handle :: term()) -> ok.
-callback adopt(file:filename_all(), meta(), Config :: map()) ->
    {ok, binary()} | {error, term()}.
-callback find(binary(), Config :: map()) -> [recording()].
-callback get(binary(), Config :: map()) ->
    {ok, recording()} | {error, not_found}.
-callback read(binary(), {non_neg_integer(), pos_integer()}, Config :: map()) ->
    {ok, binary()} | eof | {error, term()}.
-callback delete(binary(), Config :: map()) -> ok | {error, not_found}.
%% Remove what retention_days says is old, and partial files left by
%% writers that died; returns how many recordings went.
-callback sweep(Config :: map()) -> {ok, non_neg_integer()}.

-define(TIMEOUT, 5000).

%% ---- writing ----

%% Start a writer for one recording on this node, owned by the caller
%% unless Opts names an `owner'. max_queue (default 500) bounds the
%% writes waiting at it: past it, write/2 drops and says so.
-spec open(meta(), #{owner => pid(), max_queue => pos_integer()}) ->
    {ok, rec()} | {error, term()}.
open(#{call_ref := Ref} = Meta, Opts) when is_binary(Ref), is_map(Opts) ->
    case meta_ok(Meta) of
        true ->
            Owner = maps:get(owner, Opts, self()),
            Max = maps:get(max_queue, Opts, 500),
            case
                supervisor:start_child(chappe_audio_writer_sup, [Meta, Owner])
            of
                {ok, Pid} -> {ok, {chappe_audio_rec, Pid, Max}};
                {error, _} = Err -> Err
            end;
        false ->
            {error, badarg}
    end;
open(_Meta, _Opts) ->
    {error, badarg}.

%% Hand the writer audio (16-bit PCM at the recording's format).
-spec write(rec(), iodata()) -> ok | dropped.
write({chappe_audio_rec, Pid, Max}, Pcm) ->
    chappe_audio_lib:send(Pid, {write, Pcm}, Max).

%% Finish the recording; Extra adds parties to its sidecar.
-spec close(rec(), map()) -> {ok, binary()} | {error, term()}.
close({chappe_audio_rec, Pid, _}, Extra) when is_map(Extra) ->
    chappe_audio_writer:close(Pid, Extra).

%% The writer process, to monitor.
-spec writer(rec()) -> pid().
writer({chappe_audio_rec, Pid, _}) ->
    Pid.

%% Take in a finished file at Path, moved into the store (copied when it
%% is on another file system, and the source then removed) under
%% CallRef, with Meta's source and parties. A WAVE file's format and
%% length are read from it; another file keeps its extension and the
%% format Meta gives.
-spec adopt(file:filename_all(), binary(), map()) ->
    {ok, binary()} | {error, term()}.
adopt(Path, CallRef, Meta) when is_binary(CallRef), is_map(Meta) ->
    M = Meta#{call_ref => CallRef},
    case meta_ok(M) of
        true -> call_local({adopt, Path, M});
        false -> {error, badarg}
    end;
adopt(_Path, _CallRef, _Meta) ->
    {error, badarg}.

%% ---- reading ----

%% Every recording of a call, from the store of every node.
-spec find(binary()) -> [recording()].
find(CallRef) when is_binary(CallRef) ->
    Replies = multi({find, CallRef}),
    lists:sort(
        fun(A, B) -> maps:get(start, A, <<>>) =< maps:get(start, B, <<>>) end,
        lists:append([L || {ok, L} <- Replies])
    ).

-spec get(binary()) -> {ok, recording()} | {error, not_found}.
get(Id) when is_binary(Id) ->
    first({get, Id}).

%% Bytes of a recording's file, from Offset, at most Length: playback
%% over HTTP with Range requests.
-spec read(binary(), {non_neg_integer(), pos_integer()}) ->
    {ok, binary()} | eof | {error, term()}.
read(Id, {Off, Len} = Range) when
    is_binary(Id), is_integer(Off), Off >= 0, is_integer(Len), Len > 0
->
    first({read, Id, Range});
read(_Id, _Range) ->
    {error, badarg}.

-spec delete(binary()) -> ok | {error, not_found}.
delete(Id) when is_binary(Id) ->
    first({delete, Id}).

%% Run this node's sweep now (it also runs every sweep_interval).
-spec sweep() -> {ok, non_neg_integer()}.
sweep() ->
    call_local(sweep).

%% Replace this node's storage config (see config/0 for the keys).
-spec configure(map()) -> ok | {error, term()}.
configure(Config) when is_map(Config) ->
    call_local({configure, Config});
configure(_) ->
    {error, badarg}.

%% This node's storage config: backend (file, or a module), dir,
%% retention_days, sweep_interval (ms).
-spec config() -> map().
config() ->
    call_local(config).

%% ---- internal ----

meta_ok(M) ->
    lists:all(fun({K, V}) -> meta_ok(K, V) end, maps:to_list(M)).

meta_ok(call_ref, R) -> is_binary(R) andalso byte_size(R) > 0;
meta_ok(source, S) -> is_atom(S) orelse is_binary(S);
meta_ok(parties, P) -> is_list(P) andalso json_ok(P);
%% adopt/3 only: when the file's audio started (ms since the epoch), and
%% whether to copy it rather than move it
meta_ok(start, T) -> is_integer(T) andalso T >= 0;
meta_ok(keep, K) -> is_boolean(K);
meta_ok(format, #{} = F) -> format_ok(F);
meta_ok(_, _) -> false.

json_ok(T) ->
    try json:encode(T) of
        _ -> true
    catch
        error:_ -> false
    end.

format_ok(F) ->
    Rate = maps:get(rate, F, 8000),
    Ch = maps:get(channels, F, 1),
    is_integer(Rate) andalso Rate > 0 andalso is_integer(Ch) andalso Ch > 0.

call_local(Req) ->
    gen_server:call(chappe_audio_store_srv, Req, ?TIMEOUT).

stores() ->
    pg:get_members(chappe_audio_lib:scope(), chappe_audio_store).

%% Ask every node's store, at most TIMEOUT for all of them.
multi(Req) ->
    Pending = [gen_server:send_request(P, Req) || P <- stores()],
    Deadline = erlang:monotonic_time(millisecond) + ?TIMEOUT,
    [
        R
     || P <- Pending,
        {reply, R} <- [
            gen_server:receive_response(
                P, {abs, Deadline}
            )
        ]
    ].

%% This node first, then the others: the first that has it answers.
first(Req) ->
    case call_local(Req) of
        {error, not_found} ->
            Others = [P || P <- stores(), node(P) =/= node()],
            Pending = [gen_server:send_request(P, Req) || P <- Others],
            Deadline = erlang:monotonic_time(millisecond) + ?TIMEOUT,
            pick(Pending, Deadline);
        Found ->
            Found
    end.

pick([], _Deadline) ->
    {error, not_found};
pick([P | T], Deadline) ->
    case gen_server:receive_response(P, {abs, Deadline}) of
        {reply, {error, not_found}} ->
            pick(T, Deadline);
        {reply, R} ->
            %% the others are abandoned: their replies are dropped
            _ = [gen_server:receive_response(Q, 0) || Q <- T],
            R;
        _ ->
            pick(T, Deadline)
    end.
