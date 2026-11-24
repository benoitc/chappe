---
name: chappe-erlang-patterns
description: The OTP rules every chappe change follows so apps built on it are fully distributable Erlang: supervision, process isolation, the owner model, no process dictionary state, cross-node handles and pg lookups, bounded mailboxes. Use when writing, planning or reviewing any chappe code that adds or changes a process, a message, an event or a lookup.
---

# Erlang patterns in chappe

chappe exists so that you can build a SIP or voice application entirely in Erlang, and
run it on one node or across many. Everything it adds must keep that true. Check each
item when you write the code, when you plan it, and when you review it.

## Rules

1. **Supervised.** A process that lives longer than one function call runs under a
   supervisor of its app: a call, a stream, a session, a transfer, a recording writer, a
   room. Use `simple_one_for_one` (or a dynamic supervisor) with `temporary` children for
   per-call work, and decide its restart on purpose. Never a bare `spawn` or
   `spawn_link` for anything that holds state or talks to a peer. A short helper whose
   result returns through `spawn_monitor` and an exit reason is fine when its owner
   monitors it and fails its caller on `'DOWN'`.
2. **Isolated.** One process per call, stream, session or room. A crash in one never
   touches another, and a crash in a stream or a recording never touches the call it
   serves. Shared state is an ETS table owned by a supervised process; nothing is kept in
   the process dictionary. Request data travels in the request value, not in the process.
3. **Owned.** Every such process has an owner. It monitors the owner (monitor, not link,
   across a call's boundary), sends its events to the owner as tagged messages
   (`{App, Handle, Event}`), and cleans up when the owner dies: it stops what it started
   on peers (forks, recordings, legs) and releases what it holds. The owner can be
   changed explicitly (`set_owner/2`), never implicitly.
4. **Distributable.** An app on one node can drive a call on another.
   - Handles are pids, references or opaque terms that carry them, so they work across
     nodes. No API needs the caller to be on the same node.
   - Cluster-wide lookups go through `pg`, in a scope named after the app that owns
     the lookup (`chappe_sip`, `chappe_audio`, ...) and started by that app's own
     supervisor. No app starts or restarts another app's scope, and no scope is shared,
     so each app owns its lookups and stops cleanly. A process joins the group while it
     serves the thing and leaves when it stops. A node-local ETS index is fine as a
     cache next to it, never instead of it.
   - Nothing on an API path depends on a locally registered name, a local file another
     node cannot see, or `node()` being the caller's node.
   - A fun given as an option runs on the node that holds the call; say so in the doc.
   - Anything that needs exactly one owner in a cluster sits behind one function, so the
     Raft ownership app, `chappe_cluster`, can take it over (see decision
     [0010](../../../docs/decisions/0010-cluster-ownership.md)).
5. **Bounded.** A process that receives media, events or requests from outside has a
   bound on what it queues, and documents what happens past it (drop, close, slow the
   sender). `chappe_sip_config:get(ws_transport_max_mailbox)` is the model.
6. **One message shape per event.** An app's messages keep the same form whatever
   options were passed: `{App, Handle, Event}`. Context such as the call's `call_ref`
   is read from the handle (`info/1`, `ref/1`), never added to the message only when an
   option asks for it, so a `receive` written once matches every message. A new field
   goes inside `Event` or behind the handle, not as an extra tuple element.
7. **Dispatch by pattern.** `handle_call`, `handle_cast`, `handle_info` and `receive`
   match message shapes, never a variable tested with `element/2` or a guard on a list of
   atoms (`AGENTS.md`).
8. **Fail loudly, at the edge.** Validate arguments in the caller's process and return
   `{error, badarg}` there, so a bad argument never crashes a live call's process.
   Unexpected messages are logged once, not crashed on.

## Tests every new process needs

- **Owner death:** kill the owner and assert the cleanup the rule promises (the peer sees
  the stop, the leg is hung up, nothing is left registered or in `pg`).
- **Its own crash:** kill the process and assert the call it serves goes on, and its
  owner hears `{App, Handle, down}` or the documented equivalent.
- **From another node:** a `peer` node in Common Test calls the API, receives the
  events, and finds the process through `pg`.
- **Bound:** flood it past its bound and assert the documented behaviour, with memory
  that stays flat.

## In a review

State for each new or changed process: its supervisor, its owner and what it cleans up,
its `pg` group if any, its bound, and the four tests above. A missing item is a finding.
