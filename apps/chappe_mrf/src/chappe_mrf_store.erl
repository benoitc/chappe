%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc FreeSWITCH recordings into the recording store (chappe_audio_store).
%%
%% FreeSWITCH writes a recording into a folder it shares with chappe;
%% once the file is done chappe adopts it into the store under the call's
%% call_ref, so the app finds it with chappe_audio_store:find/1 whatever
%% wrote it. The `shared_dir' env maps the folder as FreeSWITCH sees it to
%% the folder as this node sees it, #{freeswitch => "/media", local =>
%% "/srv/fs-media"}; unset, both are the same path (FreeSWITCH on this
%% host).
-module(chappe_mrf_store).

-export([wanted/1, local_path/1, adopt/3, adopt_async/5]).
-export([recorded/3]).
-export([record_session/4, record_session_stop/3]).

%% how long the file must hold its size before it is taken
-define(SETTLE_MS, 300).
%% how long adopt/3 waits for its job (a copy of a large file)
-define(ADOPT_WAIT, 3600000).

%% Whether record options ask for the store.
-spec wanted(map()) -> boolean().
wanted(#{store := default}) -> true;
wanted(_) -> false.

%% Where a path FreeSWITCH writes is on this node: {ok, Local}, or
%% {error, not_shared} for a path outside the shared folder.
-spec local_path(iodata()) -> {ok, binary()} | {error, not_shared}.
local_path(FsPath) ->
    P = iolist_to_binary(FsPath),
    case application:get_env(chappe_mrf, shared_dir) of
        {ok, #{freeswitch := Fs, local := Local}} ->
            FsDir = iolist_to_binary(Fs),
            N = byte_size(FsDir),
            case P of
                <<FsDir:N/binary, "/", Rest/binary>> ->
                    {ok, filename:join(iolist_to_binary(Local), Rest)};
                _ ->
                    {error, not_shared}
            end;
        _ ->
            {ok, P}
    end.

%% Adopt the file FreeSWITCH wrote at FsPath under CallRef, once it has
%% stopped growing, and wait for it (in the caller: record/3,
%% record_session_stop/2). Meta: source (default freeswitch) and parties.
-spec adopt(iodata(), binary(), map()) -> {ok, binary()} | {error, term()}.
adopt(FsPath, CallRef, Meta) ->
    case adopt_async(FsPath, CallRef, Meta, self()) of
        {ok, Job, Key} ->
            receive
                {chappe_audio_store, Job, {adopted, Key, Result}} -> Result
            after ?ADOPT_WAIT -> {error, timeout}
            end;
        {error, _} = Err ->
            Err
    end.

%% The same in a job of the store (chappe_audio_store:adopt/4), so the
%% endpoint or the room never waits on a copy: Notify (a pid, or
%% undefined) gets {chappe_audio_store, Job, {adopted, Key, Result}}.
%% Asking twice for one file adopts it once.
-spec adopt_async(iodata(), binary(), map(), pid() | undefined) ->
    {ok, pid(), binary()} | {error, term()}.
adopt_async(FsPath, CallRef, Meta, Notify) ->
    adopt_async(FsPath, CallRef, Meta, Notify, #{}).

%% Extra: keep => true copies and never removes the source, for a file
%% FreeSWITCH may still be writing (its close was never seen), with a
%% longer settle.
-spec adopt_async(iodata(), binary(), map(), pid() | undefined, map()) ->
    {ok, pid(), binary()} | {error, term()}.
adopt_async(FsPath, CallRef, Meta, Notify, Extra) ->
    case local_path(FsPath) of
        {ok, Local} ->
            M = maps:merge(
                #{source => freeswitch}, maps:with([source, parties], Meta)
            ),
            Opts = maps:merge(
                maps:merge(#{settle_ms => ?SETTLE_MS}, Extra), notify(Notify)
            ),
            case chappe_audio_store:adopt(Local, CallRef, M, Opts) of
                {ok, Job} ->
                    {ok, Job,
                        unicode:characters_to_binary(filename:absname(Local))};
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

notify(undefined) -> #{};
notify(Pid) -> #{notify => Pid}.

%% chappe_mrf:record/3 finished: with store => default, the file goes to
%% the store under ref, else the endpoint's call_ref, else its id. The
%% record application closes the file before it completes, so it is
%% taken at once.
-spec recorded(pid(), iodata(), map()) -> ok | {ok, binary()} | {error, term()}.
recorded(Ep, Path, Opts) ->
    case wanted(Opts) of
        true -> adopt(Path, ref(Ep, Opts), Opts);
        false -> ok
    end.

%% chappe_mrf:record_session/3 on the endpoint's call: with store =>
%% default the path must be shared, and the endpoint adopts the file
%% when the recording ends.
-spec record_session(pid(), pid(), iodata(), map()) -> ok | {error, term()}.
record_session(Call, Ep, Path, Opts) ->
    P = iolist_to_binary(Path),
    maybe
        ok ?= shared(Opts, P),
        %% the file is adopted when FreeSWITCH says it is closed
        ok ?= record_stop_events(Call, Opts),
        ok ?= chappe_esl_call:record_session(Call, P),
        case wanted(Opts) of
            true ->
                chappe_mrf_endpoint:track_recording(Ep, P, ref(Ep, Opts), Opts);
            false ->
                ok
        end
    end.

%% chappe_mrf:record_session_stop/2: FreeSWITCH closes the file after
%% the media bug goes, and says so with RECORD_STOP; the endpoint adopts
%% a tracked recording then, and its owner gets {recorded, Id}.
-spec record_session_stop(pid(), pid(), iodata()) -> ok | {error, term()}.
record_session_stop(Call, _Ep, Path) ->
    chappe_esl_call:record_session_stop(Call, iolist_to_binary(Path)).

record_stop_events(Call, Opts) ->
    case wanted(Opts) of
        true -> chappe_esl_call:subscribe(Call, [<<"RECORD_STOP">>]);
        false -> ok
    end.

shared(Opts, Path) ->
    case wanted(Opts) andalso local_path(Path) of
        {error, _} = Err -> Err;
        _ -> ok
    end.

ref(_Ep, #{ref := Ref}) when is_binary(Ref) ->
    Ref;
ref(Ep, _Opts) ->
    case chappe_mrf_endpoint:info(Ep) of
        #{call_ref := Ref} when is_binary(Ref) -> Ref;
        #{id := Id} -> Id
    end.
