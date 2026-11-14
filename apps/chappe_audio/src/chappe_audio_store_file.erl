%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The default store backend: recordings in a folder.
%%
%% Layout, under `dir' (default "recordings"):
%%
%%   YYYY/MM/DD/<call_ref>/<id>.wav    the audio (or the adopted file's
%%                                     extension)
%%   YYYY/MM/DD/<call_ref>/<id>.json   its sidecar: id, call_ref, parties,
%%                                     source, start, duration_ms, format,
%%                                     bytes, file
%%
%% The date is the recording's start in UTC. A call_ref that is not a
%% plain name (letters, digits, `.', `_', `-', at most 128, starting with
%% a letter or a digit) is stored under `x-' and the hex of its SHA-256,
%% so nothing a call_ref holds can climb out of the folder; the sidecar
%% keeps the call_ref itself. The id is `YYYYMMDD-' and 32 hex digits.
%%
%% Both files are written under a `.part' name and renamed when they are
%% done, the audio first and the sidecar last, and find/2 lists sidecars:
%% a recording in progress is never listed. A writer that dies leaves its
%% `.part' file, which the sweep removes once it is an hour old.
-module(chappe_audio_store_file).
-behaviour(chappe_audio_store).

-export([open/2, write/2, close/2, abort/1, adopt/3]).
-export([find/2, get/2, read/3, delete/2, sweep/1]).
-export([ref_dir/1]).

-include_lib("kernel/include/file.hrl").

%% a .part file untouched this long belongs to a writer that died
-define(STALE_SECS, 3600).

%% ---- writing ----

open(#{call_ref := Ref} = Meta, Config) ->
    Start = os:system_time(millisecond),
    Id = new_id(Start),
    Base = base(Config, Start, Ref),
    #{rate := Rate, channels := Ch} = format(Meta),
    Tmp = filename:join(Base, <<Id/binary, ".wav.part">>),
    maybe
        ok ?= filelib:ensure_path(Base),
        {ok, Fd} ?= file:open(Tmp, [write, raw, binary]),
        ok ?= file:write(Fd, chappe_audio_wav:header(Rate, Ch, 0)),
        {ok, #{
            fd => Fd,
            tmp => Tmp,
            base => Base,
            id => Id,
            meta => Meta,
            start => Start,
            bytes => 0
        }}
    end.

write(#{fd := Fd, bytes := N} = H, Pcm) ->
    case file:write(Fd, Pcm) of
        ok -> {ok, H#{bytes => N + iolist_size(Pcm)}};
        {error, _} = Err -> Err
    end.

close(#{fd := Fd, tmp := Tmp, base := Base, id := Id, bytes := N} = H, Extra) ->
    Wav = filename:join(Base, <<Id/binary, ".wav">>),
    maybe
        ok ?= file:pwrite(Fd, chappe_audio_wav:size_patches(N)),
        ok ?= file:close(Fd),
        ok ?= file:rename(Tmp, Wav),
        #{meta := Meta, start := Start} = H,
        Parties = maps:get(parties, Meta, []) ++ maps:get(parties, Extra, []),
        Fmt = format(Meta),
        sidecar(Base, Id, Meta#{parties => Parties}, Start, Fmt, N + 44, Wav)
    end.

abort(#{fd := Fd, tmp := Tmp}) ->
    _ = file:close(Fd),
    _ = file:delete(Tmp),
    ok.

adopt(Path, #{call_ref := Ref} = Meta, Config) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{type = regular, size = Size, mtime = Mtime}} ->
            Probe = probe(Path, Meta, Size),
            Dur = maps:get(duration_ms, Probe, 0),
            Start = maps:get(start, Meta, Mtime * 1000 - Dur),
            Id = new_id(Start),
            Base = base(Config, Start, Ref),
            Ext = ext(Path),
            Dest = filename:join(Base, <<Id/binary, Ext/binary>>),
            maybe
                ok ?= filelib:ensure_path(Base),
                ok ?= move(Path, Dest, maps:get(keep, Meta, false)),
                Fmt = maps:get(format, Probe),
                sidecar(
                    Base, Id, Meta#{duration_ms => Dur}, Start, Fmt, Size, Dest
                )
            end;
        {ok, _} ->
            {error, not_a_file};
        {error, _} = Err ->
            Err
    end.

%% ---- reading ----

find(Ref, Config) ->
    Dir = dir(Config),
    Pattern = "*/*/*/" ++ binary_to_list(ref_dir(Ref)) ++ "/*.json",
    Found = [
        load(filename:join(Dir, P))
     || P <- filelib:wildcard(Pattern, Dir)
    ],
    [R || {ok, #{call_ref := R0} = R} <- Found, R0 =:= Ref].

get(Id, Config) ->
    case parse_id(Id) of
        {ok, {Y, M, D}} ->
            Dir = dir(Config),
            Pattern = lists:flatten(
                io_lib:format("~4..0B/~2..0B/~2..0B/*/~s.json", [Y, M, D, Id])
            ),
            case filelib:wildcard(Pattern, Dir) of
                [P | _] -> load(filename:join(Dir, P));
                [] -> {error, not_found}
            end;
        error ->
            {error, not_found}
    end.

read(Id, {Off, Len}, Config) ->
    case get(Id, Config) of
        {ok, #{path := Path}} ->
            with_file(Path, fun(Fd) -> file:pread(Fd, Off, Len) end);
        {error, _} = Err ->
            Err
    end.

delete(Id, Config) ->
    case get(Id, Config) of
        {ok, #{path := Path, sidecar := Json}} ->
            _ = file:delete(Json),
            _ = file:delete(Path),
            %% the call's folder goes with its last recording
            _ = file:del_dir(filename:dirname(Path)),
            ok;
        {error, _} = Err ->
            Err
    end.

%% Partial files older than an hour; with retention_days, every day
%% folder older than that many days (by the date in its path).
sweep(Config) ->
    Dir = dir(Config),
    Now = os:system_time(second),
    _ = [
        file:delete(F)
     || P <- filelib:wildcard("*/*/*/*/*.part", Dir),
        F <- [filename:join(Dir, P)],
        stale(F, Now)
    ],
    {ok, expire(Dir, maps:get(retention_days, Config, undefined), Now)}.

%% The folder name of a call_ref (see the module doc).
-spec ref_dir(binary()) -> binary().
ref_dir(Ref) ->
    case re:run(Ref, "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", [{capture, none}]) of
        match ->
            Ref;
        nomatch ->
            <<"x-",
                (binary:encode_hex(crypto:hash(sha256, Ref), lowercase))/binary>>
    end.

%% ---- internal ----

dir(Config) ->
    maps:get(dir, Config, "recordings").

%% Fun on the file opened for reading, closed after.
with_file(Path, Fun) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            try
                Fun(Fd)
            after
                file:close(Fd)
            end;
        {error, _} = Err ->
            Err
    end.

ymd(StartMs) ->
    {Date, _} = calendar:system_time_to_universal_time(StartMs, millisecond),
    Date.

base(Config, StartMs, Ref) ->
    {Y, M, D} = ymd(StartMs),
    filename:join([dir(Config), pad(Y, 4), pad(M, 2), pad(D, 2), ref_dir(Ref)]).

pad(N, W) -> string:pad(integer_to_list(N), W, leading, $0).

new_id(StartMs) ->
    {Y, M, D} = ymd(StartMs),
    Date = iolist_to_binary(io_lib:format("~4..0B~2..0B~2..0B", [Y, M, D])),
    <<Date/binary, "-", (chappe_audio_lib:id())/binary>>.

parse_id(<<Y:4/binary, M:2/binary, D:2/binary, "-", Hex:32/binary>>) ->
    try
        Date = {
            binary_to_integer(Y), binary_to_integer(M), binary_to_integer(D)
        },
        true = calendar:valid_date(Date),
        _ = binary:decode_hex(Hex),
        {ok, Date}
    catch
        error:_ -> error
    end;
parse_id(_) ->
    error.

format(Meta) ->
    F = maps:get(format, Meta, #{}),
    #{
        encoding => <<"L16">>,
        rate => maps:get(rate, F, 8000),
        channels => maps:get(channels, F, 1)
    }.

%% What an adopted file is: a WAVE file says its format and length;
%% anything else keeps the format the caller gave.
probe(Path, Meta, Size) ->
    Head =
        case with_file(Path, fun(Fd) -> file:read(Fd, 65536) end) of
            {ok, B} -> B;
            _ -> <<>>
        end,
    case chappe_audio_wav:info(Head) of
        {ok,
            #{rate := R, channels := Ch, bits := Bits, data_offset := Off} = I} ->
            %% a header written while recording may not have its size
            Data = min(maps:get(data_bytes, I), Size - Off),
            Bps = R * Ch * max(1, Bits div 8),
            #{
                format => #{encoding => enc(I), rate => R, channels => Ch},
                duration_ms => Data * 1000 div Bps
            };
        error ->
            #{format => format(Meta)}
    end.

enc(#{encoding := pcm, bits := 16}) ->
    <<"L16">>;
enc(#{encoding := pcm, bits := B}) ->
    iolist_to_binary(["L", integer_to_list(B)]);
enc(#{encoding := 6}) ->
    <<"PCMA">>;
enc(#{encoding := 7}) ->
    <<"PCMU">>;
enc(#{encoding := N}) ->
    integer_to_binary(N).

ext(Path) ->
    case
        string:lowercase(filename:extension(unicode:characters_to_binary(Path)))
    of
        <<>> -> <<".wav">>;
        E -> E
    end.

move(From, To, true) ->
    copy(From, To);
move(From, To, false) ->
    case file:rename(From, To) of
        ok ->
            ok;
        {error, exdev} ->
            %% another file system: copy, then remove the source
            maybe
                ok ?= copy(From, To),
                _ = file:delete(From),
                ok
            end;
        {error, _} = Err ->
            Err
    end.

copy(From, To) ->
    Part = <<(unicode:characters_to_binary(To))/binary, ".part">>,
    case file:copy(From, Part) of
        {ok, _} ->
            file:rename(Part, To);
        {error, _} = Err ->
            _ = file:delete(Part),
            Err
    end.

%% Write the sidecar under .part, then rename: the recording is listed
%% from here on.
sidecar(Base, Id, Meta, StartMs, Fmt, Bytes, Audio) ->
    #{rate := Rate, channels := Ch} = Fmt,
    Dur = maps:get(
        duration_ms,
        Meta,
        case maps:get(encoding, Fmt) of
            <<"L16">> -> max(0, Bytes - 44) * 1000 div (Rate * Ch * 2);
            _ -> 0
        end
    ),
    Doc = (ref_json(maps:get(call_ref, Meta)))#{
        id => Id,
        parties => maps:get(parties, Meta, []),
        source => source(maps:get(source, Meta, unknown)),
        start => list_to_binary(
            calendar:system_time_to_rfc3339(StartMs, [
                {unit, millisecond}, {offset, "Z"}
            ])
        ),
        duration_ms => Dur,
        format => Fmt,
        bytes => Bytes,
        file => filename:basename(unicode:characters_to_binary(Audio))
    },
    Json = filename:join(Base, <<Id/binary, ".json">>),
    Part = <<(unicode:characters_to_binary(Json))/binary, ".part">>,
    maybe
        ok ?= file:write_file(Part, json:encode(Doc)),
        ok ?= file:rename(Part, Json),
        {ok, Id}
    end.

%% The call_ref as a JSON string when it is text, else its hex.
ref_json(Ref) ->
    case unicode:characters_to_binary(Ref) of
        Ref -> #{call_ref => Ref};
        _ -> #{call_ref_hex => binary:encode_hex(Ref, lowercase)}
    end.

source(S) when is_atom(S) -> atom_to_binary(S);
source(S) -> S.

load(JsonPath) ->
    case file:read_file(JsonPath) of
        {ok, Bin} ->
            try json:decode(Bin) of
                #{<<"id">> := Id, <<"file">> := File} = Doc ->
                    Dir = filename:dirname(JsonPath),
                    {ok, #{
                        id => Id,
                        call_ref => call_ref(Doc),
                        node => node(),
                        path => filename:join(Dir, File),
                        sidecar => JsonPath,
                        parties => maps:get(<<"parties">>, Doc, []),
                        source => maps:get(<<"source">>, Doc, null),
                        start => maps:get(<<"start">>, Doc, null),
                        duration_ms => maps:get(<<"duration_ms">>, Doc, null),
                        format => maps:get(<<"format">>, Doc, #{}),
                        bytes => maps:get(<<"bytes">>, Doc, null)
                    }};
                _ ->
                    {error, not_found}
            catch
                error:_ -> {error, not_found}
            end;
        {error, _} ->
            {error, not_found}
    end.

call_ref(#{<<"call_ref">> := R}) -> R;
call_ref(#{<<"call_ref_hex">> := H}) -> binary:decode_hex(H);
call_ref(_) -> <<>>.

stale(File, Now) ->
    case file:read_file_info(File, [{time, posix}]) of
        {ok, #file_info{mtime = M}} -> Now - M > ?STALE_SECS;
        _ -> false
    end.

expire(_Dir, undefined, _Now) ->
    0;
expire(Dir, Days, Now) ->
    {Today, _} = calendar:system_time_to_universal_time(Now, second),
    Cutoff = calendar:date_to_gregorian_days(Today) - Days,
    Old = [
        P
     || P <- filelib:wildcard("*/*/*", Dir),
        {ok, Date} <- [dir_date(P)],
        calendar:date_to_gregorian_days(Date) < Cutoff
    ],
    lists:foldl(
        fun(P, N) ->
            Day = filename:join(Dir, P),
            Count = length(filelib:wildcard("*/*.json", Day)),
            _ = file:del_dir_r(Day),
            N + Count
        end,
        0,
        Old
    ).

dir_date(P) ->
    try
        [Y, M, D] = [list_to_integer(X) || X <- filename:split(P)],
        true = calendar:valid_date(Y, M, D),
        {ok, {Y, M, D}}
    catch
        error:_ -> error
    end.
