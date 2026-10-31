# Add a chappe_mrf conference backend

A chappe_mrf conference is one `chappe_mrf_conf` process per room. The process
holds the public API (`join/3`, `mute/2`, `kick/2`, `members/1`, ...), the
member table and the event listeners; a backend module does the media work.
Two backends exist: `native` (a chappe_mix room behind rtpengine) and `fs`
(a FreeSWITCH mod_conference room). Use this page when you add a third, or
change one of the two.

The contract between the conference process and its backends is implicit
today: it is not an Erlang behaviour, the backend is picked by a `case` on
the `backend` option, and calls run both ways. This page documents it as the
code has it. Finding M16 of the
[documentation plan](../plans/documentation-and-maintainability.md) proposes a
`chappe_mrf_conf_backend` behaviour; until it lands, a new backend means
editing `chappe_mrf_conf` itself.

## Before you start

- [concepts.md: Media resource function](../concepts.md#media-resource-function).
- [apps/chappe_mrf/docs/design/overview.md](../../apps/chappe_mrf/docs/design/overview.md):
  endpoints, correlation, the loopback middleware.
- The user guide [conference.md](../../apps/chappe_mrf/docs/guides/conference.md).

## Where to look

All in `apps/chappe_mrf/src/`:

| Module | Role |
|---|---|
| `chappe_mrf_conf.erl` | the gen_server, the public API, the members, events and focus |
| `chappe_mrf_conf.hrl` | `#state{}`, shared with the backends (an elvis exception says so) |
| `chappe_mrf_conf_native.erl` | the native backend |
| `chappe_mrf_conf_fs.erl` | the fs backend |
| `chappe_mrf.erl` | `conference/2`, `conferences/0`, the INVITE middleware that hands a loopback INVITE to `chappe_mrf_conf:loop_invite/4` |

## The contract as it is

### What `chappe_mrf_conf` calls in a backend

| Trigger | native | fs |
|---|---|---|
| `init/1`, by `backend` option | nothing more (`focus` setup) | resolve the node: `node` option or `chappe_esl:node_select/1` |
| `join/3` with a call | `handle_call({join, B2b, Opts})` -> `chappe_mrf_conf_native:join/4` | in the caller: `chappe_mrf_conf_fs:join/5`, which then calls `{fs_join, ...}` -> `start_join/5` |
| `join/3` with an endpoint | `{join_ep, Ep, Opts}` -> `join_endpoint/3` | same path as a call (`join/5`) |
| a loopback INVITE | `{loop_offer, Token, Offer}` -> `offer/3`; then casts `loop_dialog` -> `complete/3` | n/a |
| `replace_b` result | `{join_result, Token, Result}` -> `result/4` | n/a |
| FreeSWITCH events | n/a | `{chappe_mrf_endpoint, Ep, {event, Ev}}` -> `event/3` |
| an endpoint hung up | n/a | `{chappe_mrf_endpoint, Ep, hangup}` or `{chappe_mrf, Ep, {hangup, _}}` -> `gone_ep/2` |
| a join timed out | n/a | `{fs_join_timeout, Ep}` handled in `chappe_mrf_conf` |
| `mute`, `deaf`, `kick`, `lock`, `play` | `chappe_sip_media` on the member's session; `play_leg/2` | `api/3`, `lock_cmd/1`: `conference <room> ...` api commands |
| `relate/4` | `chappe_sip_media:relate/3` | `{error, {unsupported, fs}}` |

The backend functions take and return the conference's `#state{}`, or a
`gen_server` reply tuple when they run inside `handle_call/3`
(`{reply, R, S}` or `{noreply, S}` with the `From` kept in `pending`).

### What a backend calls back in `chappe_mrf_conf`

Exported "for the backends":

| Function | Use |
|---|---|
| `member(Opts, Id, Base)` | build a member map: `Base` (its media: `b2b`, `dialog`, `session`, `rtpe`, `ep`, `owned`) plus `name`, `mute`, `deaf`, `moderator`, `talking` |
| `public(Id, Member)` | the map listeners and `members/1` see |
| `emit(Event, S)` | send `{chappe_mrf_conf, Conf, Event}` to every listener |
| `publish(S)` | push the member list to the RFC 4575 focus, if any |
| `gone(Id, S)`, `gone(Id, Reason, S)` | remove a member, release its media, emit `{left, Id, Reason}` |
| `talking(Id, Bool, S)` | record and emit `{talking, Id, Bool}` |
| `call(Conf, Req, Timeout)` | call the conference process from the caller side (fs `join/5`) |

### What a backend must do

1. Reply to the joiner exactly once: `{ok, MemberId}` or `{error, _}`.
2. Put the member in `#state.members` under its id, then
   `emit({joined, Id, public(Id, Mb)}, S)` and `publish/1`.
3. Call `gone/3` when the member's media ends, with `departed`, `kicked` or
   `hangup`.
4. Leave nothing behind on `terminate/2`: `chappe_mrf_conf` hangs each member
   up through the keys of its member map (`rtpe`, `dialog`, `ep`), so a new
   backend either reuses those keys or adds a clause there.

## Steps

1. Add the atom to the `backend` field type in `chappe_mrf_conf.hrl` and to the
   options documented on `chappe_mrf_conf:start/2`.
2. Write `chappe_mrf_conf_<name>.erl` including `chappe_mrf_conf.hrl`.
3. Add its clauses to `chappe_mrf_conf`: `init_backend/3`, `join/3`,
   `handle_call/3` and `handle_info/2` for its messages, `apply_flag/5`,
   `play_to/3`, `hangup_member/3` and `gone/3`.
4. Add it to the module list of the `state_record_and_type` ignore in
   `elvis.config` only if it keeps its own state record.
5. Document the option in the conference guide.

## Tests to add or run

- `apps/chappe_mrf/test/chappe_mrf_SUITE.erl` runs without docker on
  `chappe_mrf_fake` (a fake FreeSWITCH SIP side and event socket, a fake
  rtpengine, a UDP caller). Add cases next to `native_conference`,
  `fs_conference_pin` and `conf_edges`, and claim the `MRF-` rows they prove.
- `apps/chappe_mrf/test/chappe_mrf_live_SUITE.erl` runs the same flows on real
  FreeSWITCH and rtpengine: add a case next to `native_conference` and
  `fs_conference`.

```sh
rebar3 ct --suite apps/chappe_mrf/test/chappe_mrf_SUITE
make interop-mrf
```

## How to know it works

- `make check` passes.
- `make interop-mrf` passes ([lab README](../../apps/chappe_mrf/interop/README.md)).
- `make compliance GATE=demo` passes, with the new `MRF-` rows `pass` in
  `apps/chappe_mrf/docs/compliance.md`.

## Related

- [add-media-backend.md](add-media-backend.md)
- [compliance.md](compliance.md)
- [add-interop-lab.md](add-interop-lab.md)
