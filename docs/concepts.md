# Concepts

This page gives you the mental model of chappe: the few ideas the code is
built on. Read it before your first guide if SIP, rtpengine or FreeSWITCH are
new to you. The words the rest of the documentation uses without explaining
them are defined in the [Glossary](glossary.md).

## Start here

- [Mental model](#mental-model): five ideas the code is built on.
- [Ownership in a cluster](#ownership-in-a-cluster): what is found and what
  is owned across nodes.
- [Recording paths](#recording-paths): the three ways audio leaves a call.
- [Glossary](glossary.md): one paragraph per word.
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

## Ownership in a cluster

**Lookups need no consensus; ownership does.** A call, its audio streams
and the message-waiting subscribers are found through `pg`
([pg scope](glossary.md#pg-scope)): any node asks, a lookup may be stale
for a moment, and nothing decides which node serves a call. Its
[`call_ref`](glossary.md#call_ref) names it everywhere
([0013](decisions/0013-call-ref-lookup.md)). Something that must exist once
in the cluster (a conference room, a registrar binding, a singleton job)
goes through chappe_cluster: one Ra group per
[region](glossary.md#region) holds the [leases](glossary.md#lease)
([0010](decisions/0010-cluster-ownership.md)).

**One renewal keeps every lease of a node.** A node renews one liveness
record, its [epoch](glossary.md#epoch), and each lease it holds is valid
while that epoch is. The holder gives up first, on its own monotonic
clock, before the leader can end the epoch. Before each side effect you
check `chappe_cluster:valid/1` and carry the lease's
[fence](glossary.md#fence), so the receiver can refuse an older owner.

**A lost quorum stops new claims, never calls that are up.** Without a
[quorum](glossary.md#quorum) a claim returns `{error, no_quorum}` and you
fall back to what you do without a cluster; reads from the local replica
still answer. Time comes from one [HLC](glossary.md#hlc) per node, which
orders logs and the [directory](glossary.md#directory); no ownership
decision reads it, nor any wall clock.

With the default `cluster => none`, chappe_cluster does not run, and the
`pg` lookups still work on any connected nodes
([0014](decisions/0014-optional-siblings.md)). To set a cluster up, follow
[run a cluster](../apps/chappe_cluster/docs/guides/cluster.md).

## Recording paths

Audio leaves a call three ways, and no SIP process carries any of it:

- **An rtpengine fork.** `chappe_sip_media:subscribe/2` sends one party's
  RTP from an anchored call to a listener you name.
- **A FreeSWITCH fork.** `mod_audio_fork` or `mod_audio_stream` sends a
  channel's audio over WebSocket to a chappe_audio
  [stream](glossary.md#stream) (`chappe_mrf:fork_audio_start/3`).
- **SIPREC.** `chappe_sip_siprec` records an anchored call to a recording
  server; chappe's own [SRS](glossary.md#siprec-src-and-srs) takes each
  stream in a chappe_audio RTP receiver.

The FreeSWITCH fork and the SRS land in chappe_audio, which can write them
to the [store](glossary.md#store-and-sweep) under the call's `call_ref`; an
rtpengine fork goes to whatever listener you answer it with. So
`chappe_audio_store:find/1` returns a call's recordings whatever made them
([0011](decisions/0011-chappe-audio-leaf.md),
[0012](decisions/0012-siprec-srs.md)).

Which one to choose:

- The call is anchored in rtpengine and you want one party's audio live,
  for example for a transcriber: an rtpengine fork. See
  [media](../apps/chappe_sip/docs/guides/media.md#tap-a-call-to-an-external-consumer-rtpengine).
- The call is on FreeSWITCH (a chappe_mrf endpoint) and you want PCM in an
  Erlang process: a FreeSWITCH fork. See
  [take audio from a fork](../apps/chappe_audio/docs/guides/fork.md).
- You want a recording with its metadata (who is on the call, who sends
  which stream), to a vendor recorder or to chappe's own server: SIPREC.
  See [record a call with SIPREC](../apps/chappe_sip/docs/guides/siprec.md).

Every entry point, and where its audio goes, is in
[record a call](../apps/chappe_audio/docs/guides/record.md).

## Glossary

Every term is defined in the [Glossary](glossary.md), one paragraph per word,
in alphabetical order, with a link to the page that owns it.

## Read this next

- [Glossary](glossary.md): the words these ideas use.
- [Architecture](architecture.md): the flows these words take part in.
- [Navigation](navigation.md): from a concept to its modules and tests.
