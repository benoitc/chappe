# Add a chappe_mrf conference backend

A chappe_mrf conference is one `chappe_mrf_conf` process per room. The room
keeps the public API (`join/3`, `mute/2`, `kick/2`, `members/1`, ...), the
members, the event receivers, the REFERs and the cluster lease; a backend
module carries the media. Two backends ship: `native` (a chappe_mix room
behind rtpengine, `chappe_mrf_conf_native`) and `fs` (a FreeSWITCH
mod_conference room, `chappe_mrf_conf_fs`). Use this page when you write a
third one, in chappe_mrf or in your own app, or change one of the two.

## Before you start

- [glossary.md: Media resource function](../glossary.md#media-resource-function).
- [apps/chappe_mrf/docs/design/overview.md](../../apps/chappe_mrf/docs/design/overview.md).
- The contract itself: the moduledoc of
  `apps/chappe_mrf/src/chappe_mrf_conf_backend.erl`.
- A minimal backend to copy:
  `apps/chappe_mrf/test/chappe_mrf_conf_fake_backend.erl`.

## Where to look

| Module | Role |
|---|---|
| `chappe_mrf_conf` | the room process and its public API |
| `chappe_mrf_conf_backend` | the behaviour, and the room API a backend calls |
| `chappe_mrf_conf_native`, `chappe_mrf_conf_fs` | the two backends |
| `chappe_mrf_conf_transfer` | `transfer/3`: the caller side and the room's steps |
| `chappe_mrf_conf_refer` | REFERs to the room and from its members |
| `chappe_mrf_conf_cluster` | the cluster start and the lease decisions |
| `chappe_mrf_conf_focus` | RFC 4575 conference-info for a focus room |

## Steps

1. Write a module with `-behaviour(chappe_mrf_conf_backend)`. Implement the
   required callbacks: `join/4` (in the caller), and `init/2`, `info/1`,
   `admit/3`, `set_flag/5`, `hangup/3`, `left/2`, `play/3`, `portable/0`
   (in the room).
2. Keep your state in the room with `bstate/1` and `bstate/2`. A backend
   outside chappe_mrf never reads the room's record: it uses the room API.
   A join sends `{join, Req}` from the caller; the room checks its lease,
   lock and member limit, then calls your `admit/3`:

   ```erlang
   join(Conf, _Info, Target, Opts) ->
       chappe_mrf_conf:call(Conf, {join, {mine, Target, Opts}}, 5000).

   admit({mine, Target, Opts}, _From, Room) ->
       Id = integer_to_binary(erlang:unique_integer([positive])),
       Mb = chappe_mrf_conf_backend:member(Opts, Id, #{mine => Target}),
       {reply, {ok, Id}, chappe_mrf_conf_backend:joined(Id, Mb, Room)}.
   ```

3. Turn your media events into room events with the room API:

   ```erlang
   handle_info({my_talk, Id, Talking}, Room) ->
       {noreply, chappe_mrf_conf_backend:talking(Id, Talking, Room)};
   handle_info({my_hangup, Id}, Room) ->
       {noreply, chappe_mrf_conf_backend:gone(Id, hangup, Room)};
   handle_info(_Msg, _Room) ->
       ignore.
   ```

   Return `ignore` for a message that is not yours: the room's focus may
   take it. Your own calls and casts come as `{backend, Req}`, to
   `handle_call/3` and `handle_cast/2`.
4. Leave out the optional callbacks your media cannot do (`relate/4`,
   `record/3`, `stop_record/1`, `handover/1`, `dial/4`, ...). The room
   answers `{error, {unsupported, Backend}}` for them. For a flag you cannot
   set, return `{error, unsupported}` from `set_flag/5`.
5. To bring in the parties a REFER to the room asks for, export `dial/4`.
   The room calls it, in its own process, once the REFER was decided and
   answered: `dial(Target, Key, Cfg, Room)`, with `Key` the REFER's op and
   `Cfg` the room's dial options plus `replaces`, `referred_by` and
   `dial_string` (dial that string: it is what the room's policy saw).
   Return `{ok, Room}` once the dial is under way, `{{error, Why}, Room}`
   if it cannot start (the referrer hears 503). Report what happens, in
   the room, with `chappe_mrf_conf_backend:refer_progress/3` (180, 183)
   and `refer_final/3`; add the party as a member with `joined/3` only
   once it answered, then report 200:

   ```erlang
   dial(Target, Key, Cfg, Room) ->
       ok = my_media:call(Target, maps:get(dial_string, Cfg), Key),
       {ok, Room}.

   handle_info({my_answered, Key, Id, Mb}, Room) ->
       Room1 = chappe_mrf_conf_backend:joined(Id, Mb, Room),
       {noreply, chappe_mrf_conf_backend:refer_final(Key, 200, Room1)};
   handle_info({my_failed, Key, Status}, Room) ->
       {noreply, chappe_mrf_conf_backend:refer_final(Key, Status, Room)}.
   ```
6. Start a room on it by module name:

   ```erlang
   {ok, Conf} = chappe_mrf_conf:start(<<"room1">>, #{backend => my_backend}).
   ```

   Inside chappe_mrf, also add an atom for it to
   `chappe_mrf_conf_backend:module/1` and document the option on
   `chappe_mrf_conf:start/2`.

Notes:

- `left/2` gets `transferred` for a member that moved to another room: keep
  its call.
- `portable/0` says whether a cluster room can move its members to a room
  on another node (native: yes, fs: no).
- The room reads which optional callbacks you export once, when it starts.

## Tests to add or run

- `apps/chappe_mrf/test/chappe_mrf_conf_backend_SUITE.erl` runs a room on the
  fake backend alone: copy it for yours.
- `apps/chappe_mrf/test/chappe_mrf_SUITE.erl` runs the two backends without
  docker on `chappe_mrf_fake`; `chappe_mrf_live_SUITE.erl` on real FreeSWITCH
  and rtpengine.

```sh
rebar3 ct --suite apps/chappe_mrf/test/chappe_mrf_conf_backend_SUITE
rebar3 ct --suite apps/chappe_mrf/test/chappe_mrf_SUITE
make interop-mrf
```

## How to know it works

- `make check` passes.
- `make interop-mrf` passes ([lab README](../../apps/chappe_mrf/interop/README.md)).
- `make compliance GATE=demo` passes, with your `MRF-` rows `pass` in
  `apps/chappe_mrf/docs/compliance.md`.

## Related

- [add-media-backend.md](add-media-backend.md)
- [compliance.md](compliance.md)
- [add-interop-lab.md](add-interop-lab.md)
