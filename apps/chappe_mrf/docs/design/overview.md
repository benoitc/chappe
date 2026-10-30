# Design overview

This page explains how chappe_mrf is built: who controls the media and who
carries it, how a FreeSWITCH channel is found and attached, how
conferences work on two backends, and what happens when something fails.
Read it before you change endpoint or conference code, or add a backend.

## Scope: controller and processors

chappe_mrf is a media resource function controller (MRFC) in the style of
drachtio-fsmrf. It holds no media. The media processors (MRFP) are:

- **FreeSWITCH**, through chappe_esl: playback, digit collection,
  recording, audio forks, mod_conference rooms;
- **rtpengine**, through `chappe_sip_media`: anchoring, transcoding,
  prompts played on a caller's leg;
- **chappe_mix**, through `chappe_sip_media`: native conference rooms.

chappe_mrf is an orchestration app: it depends on chappe_sip and chappe_esl
and reaches rtpengine and chappe_mix only through `chappe_sip_media`. The
leaf apps never depend on it.

## Processes

```
chappe_mrf_sup (one_for_one)
|-- chappe_mrf_registry   one gen_server, owns the correlation ETS table
|-- chappe_mrf_ep_sup     simple_one_for_one, temporary
|   `-- chappe_mrf_endpoint   one gen_statem per FreeSWITCH channel
`-- chappe_mrf_conf_sup   simple_one_for_one, temporary
    `-- chappe_mrf_conf       one gen_server per conference
```

Endpoints and conferences are not restarted: their owner hears they are
gone and decides. The outbound ESL listener is a chappe_esl listener
(`chappe_esl:start_listener/3`) with `chappe_mrf_esl` as handler; it runs
under chappe_esl's supervisor.

| Module | Role |
|---|---|
| `chappe_mrf` | Public API: setup, `connect_caller/3`, `create_endpoint/1`, `bridge/2,3`, endpoint commands, `conference/2`. Also holds the loopback middleware and node candidate selection. |
| `chappe_mrf_endpoint` | One channel under control: waits for its socket, answers, relays events to the owner. |
| `chappe_mrf_esl` | The `chappe_esl_handler` for outbound sockets: finds the endpoint by correlation id. |
| `chappe_mrf_registry` | Who waits for what: `{call, Id}`, `{loop, Token}`, `{conf, Name}`. |
| `chappe_mrf_conf` | Public conference API and the conference process. |
| `chappe_mrf_conf_native`, `chappe_mrf_conf_fs` | The two backends. |
| `chappe_mrf_lib` | Small shared helpers (ids, `api` reply checks). |

## Endpoint lifecycle

An endpoint is one FreeSWITCH channel you drive from Erlang.

1. **Waiting.** `connect_caller/3` or `create_endpoint/1` starts a
   `chappe_mrf_endpoint` with a fresh correlation id and registers it as
   `{call, Id}`. Then an INVITE goes to a FreeSWITCH node: a B2BUA leg
   anchored in rtpengine (`connect_caller/3`) or a plain UAC dialog with an
   inactive SDP (`create_endpoint/1`).
2. **Attach.** The node's dialplan runs `socket Host:Port async full`, which
   opens an outbound event socket to chappe_mrf. `chappe_mrf_esl` reads the
   correlation id from the channel data, looks up `{call, Id}` and calls
   `chappe_mrf_endpoint:attach/3`. The endpoint starts a `chappe_esl_call`
   on the connection, removes its registry entry and subscribes to the
   node's up and down notices.
3. **Ready.** The endpoint answers the channel and enters `ready`. The
   caller of `await/2` (inside `connect_caller/3`) gets the channel uuid.
   Commands (`play/2`, `play_collect/2`, `record/3`, ...) run in the
   caller's process on the `chappe_esl_call`, so a long playback blocks the
   caller, not the endpoint: DTMF keeps flowing to the owner meanwhile.
4. **Gone.** On hangup the owner gets `{chappe_mrf, Ep, {hangup, Cause}}`
   and the endpoint lingers 30 s (so a late `node_down` still reaches the
   owner), then stops.

`attach_timeout` (10 s) bounds step 2. When it runs out, the B2BUA leg is
hung up and the endpoint destroyed.

An endpoint made by `create_endpoint/1` owns its INVITE dialog until
`bridge/2` hands it to a call (`chappe_mrf_endpoint:handed/1`). The caller
then sees no re-INVITE: `chappe_sip_b2b:replace_b/3` swaps the B leg.

## Correlation: X-Chappe-Call

The INVITE to FreeSWITCH carries `X-Chappe-Call: <id>`. FreeSWITCH exposes
it on the channel as `variable_sip_h_X-Chappe-Call`, which the outbound
socket's channel data includes. That is the only link between the SIP leg
and the ESL connection. A channel with no id, or an id nobody waits for, is
hung up with `UNALLOCATED_NUMBER` (`chappe_mrf_esl:refuse/1`).

With several candidate nodes, `chappe_mrf_endpoint` finds which one the
INVITE landed on by matching `variable_sip_req_host` and `_port` against
the candidates' SIP URIs.

## Node choice and failover

`connect_caller/3` and `create_endpoint/1` build a candidate list:

- `targets => [{Node, SipUri}]`: used as given;
- `node => Name`: that node only, no failover;
- otherwise `chappe_esl:node_select/1` (with `select` options) picks the
  first, and every other up node follows in turn.

For `connect_caller/3`, the list becomes the B2BUA's serial target list, so
a 408, a 503 or a transport error moves to the next node.
`create_endpoint/1` tries the candidates one INVITE at a time.

## The registry

`chappe_mrf_registry` owns a protected ETS table with `read_concurrency`.
Readers (`lookup/1`, `select/1`) read it directly; the gen_server
serializes writes and monitors each process that put a key, so an entry
goes with its process. `put/2` refuses a key that names a live process
(`{error, exists}`), which is how two `conference/2` calls with one name
end on the same process.

## Native conferences and the loopback middleware

A native room is a chappe_mix room behind rtpengine. The conference process
owns the room (`persist => true`, so it stays up between callers) and every
member's media session.

To bring an anchored call in without a re-INVITE towards the caller:

1. The conference registers a token as `{loop, Token}` and runs
   `chappe_sip_b2b:replace_b(B2b, LoopUri, ...)`, where `LoopUri` is this
   node's own SIP address with user `mrf-mix-<Token>`
   (`chappe_mrf:loop_target/1`).
2. The INVITE comes back to this node. `chappe_mrf:start/1` installed an
   INVITE middleware (`chappe_mrf:install/0`) that recognises the
   `mrf-mix-` user, finds the conference and calls
   `chappe_mrf_conf:loop_invite/4`. Other INVITEs go on to your handler.
3. The conference joins the mixer with rtpengine's offer as the SDP
   (`chappe_sip_media:conference/3` with `talk_events` and
   `talk_tag => Token`), answers the loopback INVITE with the mixer's
   answer, and owns the resulting dialog.
4. Once both the `replace_b` result and the dialog are in, the member is
   added and the receivers get `{joined, Member, Info}`.

rtpengine stays in front of the mixer, so it transcodes and terminates
SRTP for the caller. Prompts to a native room play on each caller's
rtpengine leg (`chappe_sip_media:play/2`).

An endpoint of `create_endpoint/1` joins the other way: the mixer offers,
rtpengine carries the offer to the endpoint's node in a re-INVITE of the
endpoint's dialog, and the node's answer comes back through rtpengine.

The middleware only runs when chappe_sip runs a request through its chain,
so your app needs an INVITE handler (`chappe_sip:invite/1`).

## FreeSWITCH conferences

A `fs` room is a mod_conference room on one node. A call joining is first
bridged into a new endpoint on that node; the endpoint runs the
`conference` application (`chappe_esl_call:conference/3`). The member id
comes from the `conference::maintenance` events the endpoint relays to the
conference process (`add-member`, `del-member`, `start-talking`,
`stop-talking`). Mute, deaf, kick, lock and play are
`conference <name> ...` api commands. A `pin` option has the member enter
a PIN with `play_collect/2` before joining.

## The backend contract (not yet a behaviour)

The conference process (`chappe_mrf_conf`) and its two backends call each
other in both directions. There is no `-behaviour` for it yet (plan
finding M16); this is the contract the code follows today.

`chappe_mrf_conf` calls into the backends:

| Backend | Called for |
|---|---|
| `chappe_mrf_conf_native:join/4`, `join_endpoint/3` | a call or an endpoint joins |
| `chappe_mrf_conf_native:offer/3` | the loopback INVITE's offer reached the mixer |
| `chappe_mrf_conf_native:result/4`, `complete/3` | the `replace_b` result and the loopback dialog |
| `chappe_mrf_conf_native:play_leg/2` | play to one member |
| `chappe_mrf_conf_fs:join/5` | a join, run in the caller's process (endpoint, PIN) |
| `chappe_mrf_conf_fs:start_join/5` | the same join, inside the conference process |
| `chappe_mrf_conf_fs:event/3`, `gone_ep/2` | an endpoint's event or hangup |
| `chappe_mrf_conf_fs:api/3`, `lock_cmd/1` | mod_conference api commands |

The backends call back into `chappe_mrf_conf` (exported "for the backends"):

| Callback | What it does |
|---|---|
| `call/3` | a call to the conference process with a timeout, `{error, timeout \| noproc}` on failure |
| `emit/2` | send `{chappe_mrf_conf, Conf, Event}` to every receiver |
| `publish/1` | push the member list to the RFC 4575 focus, when there is one |
| `gone/2`, `gone/3` | a member left; release its media, emit `left` |
| `talking/3` | a member started or stopped talking |
| `member/3` | build a member map from join options |
| `public/2` | the member as `members/1` and events show it |

Backends share the conference state through `chappe_mrf_conf.hrl`. A third
backend would implement the first table and use the second.

## Failure handling

| Failure | Behaviour |
|---|---|
| No candidate node | `connect_caller/3` answers 503 and returns `{error, no_node}` |
| Outbound socket never arrives | after `attach_timeout`, the call is hung up and the endpoint destroyed |
| Unknown channel on the socket | hung up with `UNALLOCATED_NUMBER` |
| Node goes down | the endpoint's owner gets `{chappe_mrf, Ep, {node_down, Node}}` |
| Endpoint owner exits | `chappe_esl_call` stops the forks and recordings it started and kills the channel; a dialog still owned is torn down |
| Conference owner exits | the conference stops and every member is hung up (an app's endpoint leaves the room and keeps its channel) |
| `bridge/2` fails | the endpoint takes its dialog back |
| fs member never shows up | after `join_timeout` (15 s), `{error, timeout}`; an endpoint made for the join is destroyed |

## Where it lives

- Code: `apps/chappe_mrf/src/`
- Tests: `chappe_mrf_SUITE` (on fakes, claims the compliance rows),
  `chappe_mrf_live_SUITE` (FreeSWITCH and rtpengine)
- Lab: `make interop-mrf` (`apps/chappe_mrf/interop/`: rtpengine and two
  FreeSWITCH nodes)
