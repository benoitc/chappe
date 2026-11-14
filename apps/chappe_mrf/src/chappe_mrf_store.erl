%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% FreeSWITCH recordings into the recording store (chappe_audio_store).
%%
%% FreeSWITCH writes a recording into a folder it shares with chappe;
%% once the file is done chappe adopts it into the store under the call's
%% call_ref, so the app finds it with chappe_audio_store:find/1 whatever
%% wrote it. The `shared_dir' env maps the folder as FreeSWITCH sees it to
%% the folder as this node sees it, #{freeswitch => "/media", local =>
%% "/srv/fs-media"}; unset, both are the same path (FreeSWITCH on this
%% host).
-module(chappe_mrf_store).

-export([wanted/1, local_path/1, adopt/3, recorded/3]).
-export([record_session/4, record_session_stop/3]).

%% how long a file may take to stop growing once FreeSWITCH is done
-define(SETTLE_MS, 3000).
-define(POLL_MS, 100).

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
%% stopped growing. Meta: source (default freeswitch) and parties.
-spec adopt(iodata(), binary(), map()) -> {ok, binary()} | {error, term()}.
adopt(FsPath, CallRef, Meta) ->
    case local_path(FsPath) of
        {ok, Local} ->
            settle(Local, -1, ?SETTLE_MS div ?POLL_MS),
            M = maps:merge(
                #{source => freeswitch}, maps:with([source, parties], Meta)
            ),
            chappe_audio_store:adopt(Local, CallRef, M);
        {error, _} = Err ->
            Err
    end.

%% chappe_mrf:record/3 finished: with store => default, the file goes to
%% the store under ref, else the endpoint's call_ref, else its id.
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
        ok ?= chappe_esl_call:record_session(Call, P),
        case wanted(Opts) of
            true ->
                chappe_mrf_endpoint:track_recording(Ep, P, ref(Ep, Opts), Opts);
            false ->
                ok
        end
    end.

%% chappe_mrf:record_session_stop/2: a tracked recording is adopted now.
-spec record_session_stop(pid(), pid(), iodata()) ->
    ok | {ok, binary()} | {error, term()}.
record_session_stop(Call, Ep, Path) ->
    P = iolist_to_binary(Path),
    maybe
        ok ?= chappe_esl_call:record_session_stop(Call, P),
        case chappe_mrf_endpoint:take_recording(Ep, P) of
            {ok, {Ref, Meta}} -> adopt(P, Ref, Meta);
            error -> ok
        end
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

%% Wait for the size to hold for one poll (FreeSWITCH writes the header
%% sizes when it closes the file).
settle(_Path, _Last, 0) ->
    ok;
settle(Path, Last, N) ->
    case filelib:file_size(Path) of
        Last when Last > 0 ->
            ok;
        Size ->
            timer:sleep(?POLL_MS),
            settle(Path, Size, N - 1)
    end.
