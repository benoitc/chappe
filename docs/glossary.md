# Glossary

This page defines the words the chappe documentation uses without
explaining them, one entry per term, in alphabetical order. Come here when a
guide or a record uses a word you do not know. Each entry says what the word
means in this codebase, where it lives, and which page owns it. For how the
pieces fit, read [Concepts](concepts.md) first.

## Terms

### A leg and B leg

A B2BUA call has two dialogs. A is the caller's side: the incoming INVITE,
answered by chappe as a UAS. B is the callee's side: the INVITE chappe sends
as a UAC. `create_b2bua/4` returns them as `#{uas := A, uac := B}`, and
events name the side with `a` or `b`.

Where it lives: `chappe_sip_b2b`, `chappe_sip_b2b_relay`. Guide:
[B2BUA](../apps/chappe_sip/docs/guides/b2bua.md).

### Anchor and direct media

With direct media the SDP passes through unchanged and RTP flows between
the two endpoints. With anchored media chappe rewrites the SDP through
rtpengine, so RTP flows through rtpengine, which can then transcode, record,
play prompts, terminate SRTP and DTLS, or move one side to another callee.
`replace_b/3` needs an anchored call, because the caller keeps talking to
rtpengine while B changes.

Where it lives: `chappe_sip_b2b_media`, `chappe_sip_media`,
`chappe_sip_media_rtpengine`. Guides:
[B2BUA re-INVITE and media](../apps/chappe_sip/docs/guides/b2bua-reinvite.md),
[SBC](../apps/chappe_sip/docs/guides/sbc.md).

### B2BUA

A back-to-back user agent: chappe answers the caller and calls the callee
itself, so it holds both dialogs and can change anything between them
(headers, SDP, media anchoring, the callee). After `create_b2bua/4`, the
relay loop (`chappe_sip_b2b:relay/1,2`, or `relay_async/2` in a process of
its own) carries re-INVITEs, UPDATEs and BYEs from one leg to the other.

Where it lives: `apps/chappe_sip/src/b2b/chappe_sip_b2b*.erl`. Guide:
[B2BUA](../apps/chappe_sip/docs/guides/b2bua.md).

### Binding and AOR

An address of record (AOR) is the public SIP URI of a user, such as
`sip:alice@example.com`. A binding maps an AOR to one contact where the user
can be reached, with an expiry, and in chappe also its flow, Path and
transport. The registrar writes bindings; `chappe_sip:location/1` reads them.

Where it lives: `chappe_sip_registrar`, `chappe_sip_registry`. Guide:
[Registrar](../apps/chappe_sip/docs/guides/registrar.md).

### call_ref

A `call_ref` is the opaque binary that names one call across its legs and
nodes. It is made when the call's first request arrives (12 random bytes in
hex, `chappe_sip_call:new_ref/0`) or given by your app with the `call_ref`
option of `create_b2bua/4`, `create_uas/3` and `create_uac/2`. It goes on
every leg as `X-Chappe-Call` and in every call record and recording, and
each process that serves the call joins a [pg](#pg-scope) group named after
it, so `chappe_sip:calls/1` finds the call from any node. A call is found
this way, never owned. See
[follow a call](../apps/chappe_sip/docs/guides/follow-a-call.md) and
[0013](decisions/0013-call-ref-lookup.md).

### CDR and HEP

A CDR (call detail record) is one record per INVITE attempt and role,
delivered to subscribers at attempt, start and stop. HEP is the capture
protocol of Homer: chappe can send a copy of every SIP message to a capture
server.

Where it lives: `chappe_sip_cdr`, `chappe_sip_hep`. Guides:
[Call records](../apps/chappe_sip/docs/guides/call-records.md),
[Capture](../apps/chappe_sip/docs/guides/capture.md).

### Cluster node

A cluster node is an Erlang node that runs chappe_cluster in a
[region](#region). Its `region` setting names the region and `voters` the
region's Ra members at boot; a voter also runs a member of the region's Ra
group, and `chappe_cluster:join/1` adds a node to the voters. Each cluster
node has one agent, `chappe_cluster_node`, that renews its liveness. See
[run a cluster](../apps/chappe_cluster/docs/guides/cluster.md) and
[0010](decisions/0010-cluster-ownership.md).

### Compliance row

One normative statement of an RFC (a MUST, SHOULD or MAY), one line of an
app's `docs/compliance/requirements.tsv` with an id, an actor and a tier. A
CT case or an EUnit test claims rows with a `%% req:` comment above it.
`make compliance` joins rows, claims, the newest CT run and the EUnit
surefire reports into the app's `docs/compliance.md`. A row passes only
when every test claiming it passed; a skipped or missing result leaves it
untested. Rows of tier `deviation` are listed, with their reason, in the
Deviations section at the top of the matrix. `GATE=demo` fails on a
required row that is not passing, and `make compliance CHECK=1`
(`--check-against`) fails when the committed matrix claims a pass this run
does not prove; the reverse drift is only a notice.

Where it lives: `apps/*/docs/compliance/`, `scripts/compliance.escript`,
`scripts/compliance/chappe_sip_compliance.erl`. Workflow:
[compliance](contributing/compliance.md).

### Dialog

A SIP dialog (RFC 3261 12): the peer-to-peer relationship an INVITE or a
SUBSCRIBE creates, identified by Call-ID and the two tags. In chappe a dialog
is a process, a `chappe_sip_dialog_fsm`, and you hold an opaque handle to it.
It answers in-dialog requests it does not hand to you, runs session timers,
and sends you `{chappe_sip_dialog, Dialog, Event, Req, Res}` messages.

Where it lives: `apps/chappe_sip/src/dialog/`. Guide:
[Answer calls](../apps/chappe_sip/docs/guides/answer-calls.md).

### Directory

The directory tells you in which [region](#region) a key lives:
`chappe_cluster_directory:publish/3` records its home region with some
info, and `resolve/1` reads it back. It is a behaviour picked with the
`directory` env; this release ships the `local` backend
(`chappe_cluster_directory_local`), which keeps the entries in the region's
KV, and a later plan puts barrel_p2p behind it between regions. It says
where a resource lives and never decides who owns it. See [0010](decisions/0010-cluster-ownership.md).

### Early media

Audio the callee sends before it answers: a ringback tone or an
announcement, offered in the SDP of a provisional response (183). A B2BUA
passes it to A, and with a fork plays whichever branch sent the last
provisional with SDP.

Where it lives: `chappe_sip_b2b`, `chappe_sip_b2b_early` (UPDATE in early
dialogs). Guide:
[Reliable provisionals](../apps/chappe_sip/docs/guides/reliable-provisionals.md).

### Edge route

An edge route is the Route a registrar node hands out for a binding whose
[flow](#flow) it holds (an RFC 5626 flow, a WebSocket connection, a UDP
source behind a NAT), so a request from another node of the cluster goes
through that node and never uses its connection directly.
`chappe_sip_flow:edge_route/4` makes it: it names the node and the flow,
carries `edge=<transport>` and a MAC under the node's secret, and expires
with the binding. When the flow is gone, the proxy answers 430 Flow Failed
and removes the bindings on it. See the
[registrar design](../apps/chappe_sip/docs/design/registrar.md#flows-and-edge-routes)
and [0015](decisions/0015-location-behaviour.md).

### Endpoint

A chappe_mrf endpoint is one FreeSWITCH channel you drive from Erlang: a
process that holds the channel's outbound socket and the SIP dialog to the
node. You play, collect digits, record and bridge through it. Its owner gets
`{chappe_mrf, Ep, Event}` and the channel is hung up when the owner dies.

Where it lives: `chappe_mrf_endpoint`, `chappe_mrf:connect_caller/3`,
`chappe_mrf:create_endpoint/1`.

### Engine and nta

nta is sofia-sip's transaction layer. The engine is nta compiled into a
plain-C NIF with one stack thread, plus the one Erlang process that talks to
it, `chappe_sip_engine`. The engine forwards every request to Erlang;
routing, dialogs and the proxy are all Erlang.

Where it lives: `apps/chappe_sip/c_src/`, `chappe_sip_nif`,
`chappe_sip_engine`. Design: [engine](../apps/chappe_sip/docs/design/engine.md).
Decision: [0001](decisions/0001-sofia-nta-nif.md).

### Epoch

An epoch is one node's period of liveness in its [region](#region), kept
by `chappe_cluster_machine`. The node renews one liveness record every
`renew_ms` (2000 ms by default), and every [lease](#lease) it holds is valid
while its epoch is, so a node with a thousand leases writes one renewal per
period. The leader ends an epoch `lease_ms` (6000 ms) after the last renewal
it applied, on its own monotonic clock; the node gives its leases up
before that, on its own. A restart of the app takes a new epoch, which ends
the old one's leases. See [0010](decisions/0010-cluster-ownership.md).

### ESC

The event state compositor (RFC 3903) keeps the state that PUBLISH
requests set, per resource and event package. `chappe_sip:publish/1`
registers its handler; the `chappe_sip_esc` process applies the PUBLISHes
of a resource one by one, gives each 2xx a new SIP-ETag, removes a
publication not refreshed in time, and tells the processes that called
`watch/2` when the state changed. By default an authenticated user may
publish only its own address of record. See
[presence](../apps/chappe_sip/docs/guides/presence.md).

### ESL inbound and outbound

FreeSWITCH's Event Socket has two modes. Inbound: you connect to FreeSWITCH
and run commands or receive events (`chappe_esl:connect/1`). Outbound:
FreeSWITCH's dialplan `socket` application connects to you, one connection
per call, and you control that call (`chappe_esl:start_listener/3`).
chappe_mrf uses both: inbound to watch nodes, outbound to take a call.

Where it lives: `chappe_esl_conn`, `chappe_esl_inbound`,
`chappe_esl_listener`, `chappe_esl_call`. Guides:
[inbound](../apps/chappe_esl/docs/guides/inbound.md),
[outbound](../apps/chappe_esl/docs/guides/outbound.md).

### Fence

A fence is the `{Region, NodeEpoch, Seq}` a [lease](#lease) carries, read
with `chappe_cluster:fence/1`, or `singleton_fence/1` for a
[singleton](#singleton)'s child. Seq grows strictly per key, so you put the
fence on each side effect and the receiver refuses an older owner; the
region in it refuses a stale owner from another region. Compare fences by
Seq: the epoch of a takeover can be lower than the previous holder's. See
[claim and fence](../apps/chappe_cluster/docs/guides/cluster.md#claim-and-fence) and [0010](decisions/0010-cluster-ownership.md).

### Flow

A transport connection (or UDP source address) that a request arrived on,
and that later requests to that UA must reuse to cross its NAT. chappe
records the flow of a registration (RFC 5626 outbound, or the `received`
address of a NATed UA) and sends to it rather than to the private Contact.
A WebSocket connection is always a flow.

Where it lives: `chappe_sip_flow` (`received_flow/1`, `flow_route/1`),
`chappe_sip_route` (`next_flow/2`), `chappe_sip_engine` (the `flow()` type),
`chappe_sip_registry`.

### Focus

A conference focus (RFC 4579): the SIP user agent that hosts a conference
and serves its state (RFC 4575 conference-info) to subscribers.
`chappe_sip_focus` holds the state and the subscriptions; chappe_mrf serves
it with `focus => true`.

Where it lives: `chappe_sip_focus`, `chappe_sip_confinfo`. Guide:
[Conference focus](../apps/chappe_sip/docs/guides/conference-focus.md).

### Fork (audio)

An audio fork sends a copy of a call's audio out of the call while the call
goes on. rtpengine forks a party's RTP to a listener you name
(`chappe_sip_media:subscribe/2`), for example a chappe_audio RTP receiver.
FreeSWITCH forks a channel's audio over WebSocket with `mod_audio_fork` or
`mod_audio_stream` (`chappe_mrf:fork_audio_start/3`) to a chappe_audio
[stream](#stream). See
[take audio from a fork](../apps/chappe_audio/docs/guides/fork.md) and
[media](../apps/chappe_sip/docs/guides/media.md#tap-a-call-to-an-external-consumer-rtpengine).

### Fork (B2BUA)

A B2BUA fork calls several B legs for one A leg. A `{parallel, Dests}`
target starts one UAC per destination, all relayed to A under one To-tag.
The first 2xx wins and the other branches are CANCELled; when every branch
fails, A gets the best final response (RFC 3261 16.7), and a 6xx ends the
fork at once. Timer C runs on every branch. The branches live in
`chappe_sip_b2b_fork`. See
[B2BUA forking](../apps/chappe_sip/docs/guides/b2bua-forking.md).

### FreeSWITCH and rtpengine node

A FreeSWITCH or rtpengine node is a media server chappe controls: a
FreeSWITCH node registered with `chappe_esl:node_add/2`, or an rtpengine node
registered with `chappe_rtpengine:add_node/2`. Each has health and is picked
per call. Not to be confused with a [cluster node](#cluster-node), which is an
Erlang node. The pools live in `chappe_esl_nodes` and
`chappe_rtpengine_pool`. See
[chappe_esl nodes](../apps/chappe_esl/docs/guides/nodes.md) and
[chappe_rtpengine nodes](../apps/chappe_rtpengine/docs/guides/nodes.md).

### HLC

A hybrid logical clock stamps events so that they order across nodes even
when the wall clocks disagree. Each node keeps one: chappe_cluster's
(`chappe_cluster:now/0`, the `chappe_cluster_hlc` process) when it runs,
else chappe_sip's own (`chappe_sip_hlc`). A stamp the node receives moves
its clock forward, but no more than `hlc_max_offset_ms` (10 s) past its own
wall clock. Claims, KV writes and the message-waiting updates of
`chappe_sip_mwi` carry a stamp; no lease or ownership decision depends on
it. See [0010](decisions/0010-cluster-ownership.md).

### Late offer and 3PCC

A late offer is an INVITE without SDP: the callee makes the offer in its 2xx
and the caller answers in the ACK. Third party call control (3PCC, RFC 3725)
uses it to connect two parties from a controller: you hold the ACK of a 2xx
(`no_ack`) and send it later with `chappe_sip_dialog:ack/2`. A B2BUA bridges a
late offer as one, and the relay loop uses an offerless re-INVITE to move a
live call between direct and anchored media.

Where it lives: `chappe_sip_b2b`, `chappe_sip_b2b_relay`,
`chappe_sip_dialog:ack/2`, the `delayed_ack_3pcc` case of
`chappe_sip_core_uac_SUITE`. Guide:
[B2BUA re-INVITE](../apps/chappe_sip/docs/guides/b2bua-reinvite.md).

### Lease

A lease gives one key one holder in a [region](#region).
`chappe_cluster:claim/2` takes it for a process on the claiming node, and it
holds until the holder releases it, dies, or its node's [epoch](#epoch)
lapses. The holder gets `{chappe_cluster, Lease, lost}` when its node lapses
or another node takes the key over, and checks `chappe_cluster:valid/1`
before each side effect. Without a [quorum](#quorum) a claim returns
`{error, no_quorum}`. chappe_mrf takes one lease per conference room name.
See [claim and fence](../apps/chappe_cluster/docs/guides/cluster.md#claim-and-fence),
the [cluster design](../apps/chappe_cluster/docs/design/overview.md) and
[0010](decisions/0010-cluster-ownership.md).

### Leg

"Leg" means three things in this repository, and the context tells you
which. In the engine, a leg is sofia's `nta_leg_t`: the dialog-matching
object a request arrives on, known to Erlang as a leg handle. In the B2BUA,
a leg is one of the two sides of a bridged call (see
[A leg and B leg](#a-leg-and-b-leg)). In chappe_mix, a leg is one participant
of a conference room: an RTP session with its own socket.

Where it lives: engine legs in `apps/chappe_sip/c_src/chappe_sip_engine_nif.c`
and the handle table of `chappe_sip_engine`; B2BUA legs in
`chappe_sip_b2b`; mixer legs in `chappe_mix:add_leg/2` and `chappe_mix_leg`.

### Location backend

A location backend holds the registrar's bindings behind the
`chappe_sip_location` behaviour, so `chappe_sip_registry` never names one.
The `cluster` setting picks it: `chappe_sip_location_ets`, a node-local
table, by default; `chappe_sip_location_cluster` with
`cluster => chappe_cluster`, one value per AOR in the region's KV, written
with compare-and-swap and read from the local replica. The backend also says
how it is written (`serialized` or `cas`), swept, and shown from another
node, where a binding reached over a flow carries an
[edge route](#edge-route). See the
[registrar design](../apps/chappe_sip/docs/design/registrar.md) and
[0015](decisions/0015-location-behaviour.md).

### Media resource function

The MRF of IMS: a controller (MRFC) tells media processors (MRFP) to play,
record, collect digits or mix. In chappe, chappe_mrf is the controller and
FreeSWITCH, rtpengine and chappe_mix are the processors.

Where it lives: `apps/chappe_mrf/`. App: [chappe_mrf](../apps/chappe_mrf/README.md).
Decision: [0006](decisions/0006-mrf-orchestration-app.md).

### Middleware and handler

A handler is the `fun(Req, Res)` you register for a method
(`chappe_sip:handle/2`, `invite/1`, ...). A middleware is a
`fun(Req, Res, Next)` registered with `chappe_sip:use/1,2` that runs before
the handler and either calls `Next()` or answers the request itself. The
guard and chappe_mrf's loopback hook are middlewares.

```erlang
ok = chappe_sip:use(fun(Req, Res, Next) ->
    logger:info("~s ~s", [chappe_sip_req:method(Req), chappe_sip_req:uri(Req)]),
    Next()
end).
```

A middleware hands data to the ones after it and to the handler in the
request value itself (request locals), by returning `{next, Req1}`:

```erlang
ok = chappe_sip:use(fun(Req, _Res, _Next) ->
    {next, chappe_sip_req:set_local(tenant, <<"acme">>, Req)}
end).
```

Where it lives: `chappe_sip_middleware`, `chappe_sip_request_worker`,
`chappe_sip_handler` (a behaviour for dialog handlers).

### NG protocol

rtpengine's control protocol: bencoded dictionaries over UDP, TCP or
WebSocket, with commands such as `offer`, `answer`, `delete`, `play media`
and `subscribe request`. chappe_rtpengine is a client for it.

Where it lives: `chappe_rtpengine_ng`, `chappe_rtpengine_bencode`,
`chappe_rtpengine_client`. App:
[chappe_rtpengine](../apps/chappe_rtpengine/README.md).

### Optional sibling app

An optional sibling is an app of the umbrella that chappe_sip or chappe_mrf
uses when it is there, without a hard dependency. chappe_audio is an
optional application of chappe_sip: without it, SIPREC recording sessions
are refused with 488 and the rest runs as before. chappe_cluster is in no
`applications` list: the app that uses it starts it in `start/2`, only when
its `cluster` setting asks, so it stops after that app, and a release that
runs a cluster lists it as `{chappe_cluster, load}`. See
[0014](decisions/0014-optional-siblings.md).

### Owner and notify process

The owner of a dialog, a call or a media session is the process that
receives its events and whose death ends it (a dialog may be told to
`continue` instead). The notify process only receives events, for example
the provisional responses of a UAC or the events of a B2BUA call, and its
death ends nothing. When you hand a call to another process, change the
owner with `chappe_sip_dialog:set_owner/2`.

Where it lives: `chappe_sip_dialog` (moduledoc), `chappe_sip_b2b`
(`notify`), `chappe_sip_media` (the session is bound to its owner),
`chappe_mix:start/1` (`owner`), `chappe_mrf` (`owner`, `notify`).

### Peer

A peer is a SIP destination (a trunk, a gateway, a FreeSWITCH node seen from
SIP) registered with `chappe_sip:peer_add/2`, kept alive with OPTIONS, and
used as a `{peer_group, G}` target. The demo's FreeSWITCH nodes are both a
[FreeSWITCH node](#freeswitch-and-rtpengine-node) and a peer. Peers live in
`chappe_sip_peers` and `chappe_sip_peer`. See the
[SBC guide](../apps/chappe_sip/docs/guides/sbc.md).

### pg scope

A pg scope is one instance of OTP's `pg` process groups; chappe uses them
to find things across nodes, never to own them. Each app starts its own
scopes and never another app's. `chappe_sip` (`chappe_sip_call:scope/0`,
started by `chappe_sip_sup`) holds, among others, the group of each
[`call_ref`](#call_ref), the dialog index, the event notifiers and the
message-waiting subscribers; chappe_sip also runs a `chappe_sip_regc`
scope for its outbound registrations. `chappe_audio` (`chappe_audio_pg`) holds a call's
[streams](#stream) and the stores of the cluster. `chappe_cluster` holds its
watchers and running singletons. pg is eventually consistent, so a lookup
can be stale for a moment. See
[0013](decisions/0013-call-ref-lookup.md).

### Proxy

A SIP proxy (RFC 3261 16) forwards a request without becoming a party to
the dialog. `chappe_sip:proxy_request/3` forwards one, sequentially or in
parallel, with or without Record-Route.

Where it lives: `apps/chappe_sip/src/proxy/`. Guide:
[Proxy](../apps/chappe_sip/docs/guides/proxy.md).

### Quorum

A quorum is a majority of a [region](#region)'s voters. Every write to the
region (a claim, a KV write, a renewal) is committed by it, so a region needs
a majority of its voters up to take new leases. Without one, a claim or a
KV write returns `{error, no_quorum}` after `command_timeout` (5 s by
default), reads from the local replica still answer, possibly stale, and a
REGISTER on a clustered registrar fails with 503. A lost quorum stops new
claims, never the calls already up. See
[what a lost quorum does](decisions/0010-cluster-ownership.md#what-a-lost-quorum-does).

### Region

A region is the set of nodes that share one Ra group of chappe_cluster,
on one low-latency network. The group holds each node's liveness, the
[leases](#lease) and a small KV with versions (`chappe_cluster_machine`). A
node names its region in the `region` setting (`default` by default) and the
group's members at boot in `voters`: three nodes, or two plus a small node
that runs only chappe_cluster. Several regions are several groups, joined
later by the [directory](#directory), not one stretched group. See
[run a cluster](../apps/chappe_cluster/docs/guides/cluster.md) and [0010](decisions/0010-cluster-ownership.md).

### Room, relation and talker

A room is one chappe_mix conference: a process that owns a socket per leg
and mixes every 20 ms. A relation says whether one leg hears another
(`chappe_mix:relate/4`, `hear` or `nohear`), on top of the default N-1 mix. A
talker event `{talking, Leg, true | false}` tells a subscriber that a leg
started or stopped speaking.

Where it lives: `chappe_mix`, `chappe_mix_conf`, `chappe_mix_room`.
In chappe_mrf: `chappe_mrf_conf` (members, mute, deaf, talker events).

### Singleton

A singleton is a child that runs on one node of a [region](#region) at a
time. Every node that may run it calls `chappe_cluster:singleton/2`; the
node that holds the lease `{chappe_cluster_singleton, Name}` starts the
child, and another node takes over when it stops. On `lost` the child is
killed, not shut down, so it checks `chappe_cluster:singleton_valid/1`
before each side effect and carries `singleton_fence/1` on it. The
registrar's sweep and the peers with `probe => singleton` run this way. See
[run a singleton](../apps/chappe_cluster/docs/guides/cluster.md#run-a-singleton) and [0010](decisions/0010-cluster-ownership.md).

### SIPREC, SRC and SRS

SIPREC (RFC 7866) records a call by sending its media to a session
recording server (SRS). chappe's session recording client (SRC) is
`chappe_sip_siprec`: `start/3` taps each party of an anchored B2BUA call in
rtpengine and sends the SRS an INVITE with one sendonly stream per party and
the metadata (RFC 7865). chappe's own SRS is
`chappe_sip_siprec_srs:serve/3`, run in your INVITE handler: its SIP side
stays in chappe_sip, and each recorded stream is received by a chappe_audio
RTP receiver, never by a SIP process. See
[record a call with SIPREC](../apps/chappe_sip/docs/guides/siprec.md), the
[SIPREC design](../apps/chappe_sip/docs/design/siprec.md) and
[0012](decisions/0012-siprec-srs.md).

### Store and sweep

The store is where chappe_audio keeps a call's recordings, found by their
[`call_ref`](#call_ref): a module that implements the `chappe_audio_store`
behaviour, set by your app (the `storage` env); the default is the file
backend in a `recordings` folder. `chappe_audio_store:find/1` asks the
store of every node through pg. The sweep runs on each node every
`sweep_interval` (hourly by default): the file backend removes partial
files no live writer owns and, with `retention_days`, older recordings. A
`sweep_guard` that is true on one node only, such as a chappe_cluster
singleton's lease, makes one node sweep a shared store. See
[record a call](../apps/chappe_audio/docs/guides/record.md) and
[0011](decisions/0011-chappe-audio-leaf.md).

### Stream

A stream is chappe_audio's process for one source of a call's audio. A
`chappe_audio_stream` is fed by one FreeSWITCH fork over WebSocket:
`chappe_audio:open/2` gives you a URL with its own path and token, and the
audio comes to the owner as `{chappe_audio, Stream, {frame, Pcm}}`. A
`chappe_audio_rtp` receiver, started with `chappe_audio:rtp_receiver/1` as
the SIPREC server does, takes one RTP stream (G.711, SRTP with SDES keys)
and hands the audio to a store recording or a process. Both stop with the
process that owns them, and `chappe_audio:streams/1` finds a call's
WebSocket streams on every node. See
[take audio from a fork](../apps/chappe_audio/docs/guides/fork.md) and
[0011](decisions/0011-chappe-audio-leaf.md).

### Timer C

The proxy timer of RFC 3261 16.6: how long an INVITE branch may ring before
it is CANCELled. chappe applies it to proxied INVITEs and to B2BUA calls,
including every branch of a parallel fork. The default is the `timer_c_ms`
setting.

Where it lives: `chappe_sip_config` (`timer_c_ms`, `ws_timer_c_ms`),
`chappe_sip_b2b:timer_c/1`, `chappe_sip_proxy`.

### Transaction

A SIP transaction (RFC 3261 17): one request and its responses, with the
retransmission timers. Over UDP, TCP and TLS the transactions live in
sofia's `nta`; Erlang sees them as handles. Over WebSocket they live in
`chappe_sip_ws_transport`.

Where it lives: `apps/chappe_sip/c_src/`, `chappe_sip_nif`,
`chappe_sip_ws_transport`. Design: [engine](../apps/chappe_sip/docs/design/engine.md).

### UAS and UAC

A user agent server answers requests; a user agent client sends them. In
chappe, `chappe_sip:create_uas/3` answers an incoming dialog-forming request
and `chappe_sip:create_uac/2` sends one. A B2BUA is a UAS on A and a UAC on
B.

Where it lives: `chappe_sip_dialog:create_uas/3`, `chappe_sip_uac`,
`chappe_sip_uac_fsm`. Guides:
[Answer calls](../apps/chappe_sip/docs/guides/answer-calls.md),
[Originate calls](../apps/chappe_sip/docs/guides/originate-calls.md).
