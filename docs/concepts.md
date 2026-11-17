# Concepts

This page gives you the mental model of chappe and the words the rest of the
documentation uses without explaining them. Read it before your first guide
if SIP, rtpengine or FreeSWITCH are new to you, or come back to an entry when
a page uses a word you do not know. Each entry says what the word means in
this codebase and where it lives.

## Start here

- [Mental model](#mental-model): five ideas the code is built on.
- [Glossary](#glossary): one paragraph per word.
- [Architecture](architecture.md): how the apps fit, with the main flows.

## Mental model

**Signalling in Erlang, media elsewhere.** chappe_sip runs SIP in your
Erlang node. RTP never flows through a SIP process: it stays in rtpengine, in
a chappe_mix conference process, or in FreeSWITCH. chappe_sip only tells
those engines what to do.

**A call is a process.** Every inbound out-of-dialog request runs in its own
request worker, every dialog is a `chappe_sip_dialog_fsm`, every outbound
transaction a `chappe_sip_uac_fsm`. Your handler runs in the worker and may
block for the life of the call. Every API that takes an `owner` or a
`notify` pid is about which process hears what, and what dies with what.

**The transaction layer is sofia-sip.** UDP, TCP and TLS go through
sofia-sip's `nta`, compiled into a C NIF that one Erlang process drives.
WebSocket has its own Erlang transaction layer that speaks the same event
contract, so everything above it does not care which one carried a request.

**Leaf apps know nothing of SIP.** Each leaf app
([0003](decisions/0003-leaf-apps.md)) has one concern and is usable alone.
chappe_sip uses chappe_rtpengine and chappe_mix through its media facade. chappe_mrf sits on top and ties SIP to
FreeSWITCH.

**Every claim has a test.** RFC requirements are rows in a TSV file, tests
claim rows, and a gate fails when a required row is not passing.

## Glossary

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

### A leg and B leg

A B2BUA call has two dialogs. A is the caller's side: the incoming INVITE,
answered by chappe as a UAS. B is the callee's side: the INVITE chappe sends
as a UAC. `create_b2bua/4` returns them as `#{uas := A, uac := B}`, and
events name the side with `a` or `b`.

Where it lives: `chappe_sip_b2b`, `chappe_sip_b2b_relay`. Guide:
[B2BUA](../apps/chappe_sip/docs/guides/b2bua.md).

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

### Dialog

A SIP dialog (RFC 3261 12): the peer-to-peer relationship an INVITE or a
SUBSCRIBE creates, identified by Call-ID and the two tags. In chappe a dialog
is a process, a `chappe_sip_dialog_fsm`, and you hold an opaque handle to it.
It answers in-dialog requests it does not hand to you, runs session timers,
and sends you `{chappe_sip_dialog, Dialog, Event, Req, Res}` messages.

Where it lives: `apps/chappe_sip/src/dialog/`. Guide:
[Answer calls](../apps/chappe_sip/docs/guides/answer-calls.md).

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

### B2BUA

A back-to-back user agent: chappe answers the caller and calls the callee
itself, so it holds both dialogs and can change anything between them
(headers, SDP, media anchoring, the callee). After `create_b2bua/4`, the
relay loop (`chappe_sip_b2b:relay/1,2`, or `relay_async/2` in a process of
its own) carries re-INVITEs, UPDATEs and BYEs from one leg to the other.

Where it lives: `apps/chappe_sip/src/b2b/chappe_sip_b2b*.erl`. Guide:
[B2BUA](../apps/chappe_sip/docs/guides/b2bua.md).

### Proxy

A SIP proxy (RFC 3261 16) forwards a request without becoming a party to
the dialog. `chappe_sip:proxy_request/3` forwards one, sequentially or in
parallel, with or without Record-Route.

Where it lives: `apps/chappe_sip/src/proxy/`. Guide:
[Proxy](../apps/chappe_sip/docs/guides/proxy.md).

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

### Flow

A transport connection (or UDP source address) that a request arrived on,
and that later requests to that UA must reuse to cross its NAT. chappe
records the flow of a registration (RFC 5626 outbound, or the `received`
address of a NATed UA) and sends to it rather than to the private Contact.
A WebSocket connection is always a flow.

Where it lives: `chappe_sip_route` (`received_flow/1`, `next_flow/2`,
`flow_route/1`), `chappe_sip_engine` (the `flow()` type),
`chappe_sip_registry`.

### Binding and AOR

An address of record (AOR) is the public SIP URI of a user, such as
`sip:alice@example.com`. A binding maps an AOR to one contact where the user
can be reached, with an expiry, and in chappe also its flow, Path and
transport. The registrar writes bindings; `chappe_sip:location/1` reads them.

Where it lives: `chappe_sip_registrar`, `chappe_sip_registry`. Guide:
[Registrar](../apps/chappe_sip/docs/guides/registrar.md).

### Timer C

The proxy timer of RFC 3261 16.6: how long an INVITE branch may ring before
it is CANCELled. chappe applies it to proxied INVITEs and to B2BUA calls,
including every branch of a parallel fork. The default is the `timer_c_ms`
setting.

Where it lives: `chappe_sip_config` (`timer_c_ms`, `ws_timer_c_ms`),
`chappe_sip_b2b:timer_c/1`, `chappe_sip_proxy`.

### Early media

Audio the callee sends before it answers: a ringback tone or an
announcement, offered in the SDP of a provisional response (183). A B2BUA
passes it to A, and with a fork plays whichever branch sent the last
provisional with SDP.

Where it lives: `chappe_sip_b2b`, `chappe_sip_b2b_early` (UPDATE in early
dialogs). Guide:
[Reliable provisionals](../apps/chappe_sip/docs/guides/reliable-provisionals.md).

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

### Engine and nta

nta is sofia-sip's transaction layer. The engine is nta compiled into a
plain-C NIF with one stack thread, plus the one Erlang process that talks to
it, `chappe_sip_engine`. The engine forwards every request to Erlang;
routing, dialogs and the proxy are all Erlang.

Where it lives: `apps/chappe_sip/c_src/`, `chappe_sip_nif`,
`chappe_sip_engine`. Design: [engine](../apps/chappe_sip/docs/design/engine.md).
Decision: [0001](decisions/0001-sofia-nta-nif.md).

### NG protocol

rtpengine's control protocol: bencoded dictionaries over UDP, TCP or
WebSocket, with commands such as `offer`, `answer`, `delete`, `play media`
and `subscribe request`. chappe_rtpengine is a client for it.

Where it lives: `chappe_rtpengine_ng`, `chappe_rtpengine_bencode`,
`chappe_rtpengine_client`. App:
[chappe_rtpengine](../apps/chappe_rtpengine/README.md).

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

### Media resource function

The MRF of IMS: a controller (MRFC) tells media processors (MRFP) to play,
record, collect digits or mix. In chappe, chappe_mrf is the controller and
FreeSWITCH, rtpengine and chappe_mix are the processors.

Where it lives: `apps/chappe_mrf/`. App: [chappe_mrf](../apps/chappe_mrf/README.md).
Decision: [0006](decisions/0006-mrf-orchestration-app.md).

### Endpoint

A chappe_mrf endpoint is one FreeSWITCH channel you drive from Erlang: a
process that holds the channel's outbound socket and the SIP dialog to the
node. You play, collect digits, record and bridge through it. Its owner gets
`{chappe_mrf, Ep, Event}` and the channel is hung up when the owner dies.

Where it lives: `chappe_mrf_endpoint`, `chappe_mrf:connect_caller/3`,
`chappe_mrf:create_endpoint/1`.

### Node and peer

A node is a media server chappe controls: a FreeSWITCH node registered with
`chappe_esl:node_add/2`, or an rtpengine node registered with
`chappe_rtpengine:add_node/2`. Each has health and is picked per call. A peer
is a SIP destination (a trunk, a gateway, a FreeSWITCH node seen from SIP)
registered with `chappe_sip:peer_add/2`, kept alive with OPTIONS, and used as
a `{peer_group, G}` target. The demo's FreeSWITCH nodes are both. An Erlang
node is called an Erlang node.

Where it lives: `chappe_esl_nodes`, `chappe_rtpengine_pool`,
`chappe_sip_peers`, `chappe_sip_peer`.

### Room, relation and talker

A room is one chappe_mix conference: a process that owns a socket per leg
and mixes every 20 ms. A relation says whether one leg hears another
(`chappe_mix:relate/4`, `hear` or `nohear`), on top of the default N-1 mix. A
talker event `{talking, Leg, true | false}` tells a subscriber that a leg
started or stopped speaking.

Where it lives: `chappe_mix`, `chappe_mix_conf`, `chappe_mix_room`.
In chappe_mrf: `chappe_mrf_conf` (members, mute, deaf, talker events).

### Focus

A conference focus (RFC 4579): the SIP user agent that hosts a conference
and serves its state (RFC 4575 conference-info) to subscribers.
`chappe_sip_focus` holds the state and the subscriptions; chappe_mrf serves
it with `focus => true`.

Where it lives: `chappe_sip_focus`, `chappe_sip_confinfo`. Guide:
[Conference focus](../apps/chappe_sip/docs/guides/conference-focus.md).

### CDR and HEP

A CDR (call detail record) is one record per INVITE attempt and role,
delivered to subscribers at attempt, start and stop. HEP is the capture
protocol of Homer: chappe can send a copy of every SIP message to a capture
server.

Where it lives: `chappe_sip_cdr`, `chappe_sip_hep`. Guides:
[Call records](../apps/chappe_sip/docs/guides/call-records.md),
[Capture](../apps/chappe_sip/docs/guides/capture.md).

### Compliance row

One normative statement of an RFC (a MUST, SHOULD or MAY), one line of an
app's `docs/compliance/requirements.tsv` with an id, an actor and a tier. A
test claims rows with a `%% req:` comment; `make compliance` joins rows,
claims and the last CT results into the app's `docs/compliance.md`, and
`GATE=demo` fails on a required row that is not passing.

Where it lives: `apps/*/docs/compliance/`, `scripts/compliance.escript`,
`scripts/compliance/chappe_sip_compliance.erl`. Workflow:
[compliance](contributing/compliance.md).

## Read this next

- [Architecture](architecture.md): the flows these words take part in.
- [Navigation](navigation.md): from a concept to its modules and tests.
