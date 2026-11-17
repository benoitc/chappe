# Concepts

This page gives you the mental model of chappe: the few ideas the code is
built on. Read it before your first guide if SIP, rtpengine or FreeSWITCH are
new to you. The words the rest of the documentation uses without explaining
them are defined in the [Glossary](glossary.md).

## Start here

- [Mental model](#mental-model): five ideas the code is built on.
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

## Glossary

Every term is defined in the [Glossary](glossary.md), one paragraph per word,
in alphabetical order, with a link to the page that owns it.

## Read this next

- [Glossary](glossary.md): the words these ideas use.
- [Architecture](architecture.md): the flows these words take part in.
- [Navigation](navigation.md): from a concept to its modules and tests.
