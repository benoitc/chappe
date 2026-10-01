# Architecture overview

chappe_sip is drachtio's model on the BEAM: sofia-sip's transaction
layer runs inside the VM through a thin NIF, and every transaction-user
decision (dialogs, UAC/UAS orchestration, B2BUA, proxy, digest,
middleware) is Erlang. This page is the map; read `docs/design/engine.md`
for the NIF and thread model.

## Layers

```
 SIP peers  --UDP/TCP-->  sofia nta (C, in the VM)
                              |  enif_send events / su_msg calls
                         chappe_sip_engine  (singleton gen_server)
                              |  routes, dispatch, handle table
   +--------------------------+--------------------------+
   |               |                |                    |
 request        dialog fsm       uac fsm             proxy loop
 workers        (gen_statem)     (gen_statem)        (in worker)
   |               |                |                    |
   +--- middleware, handlers, B2BUA, application code ---+
```

- **The NIF shim** (`c_src/chappe_sip_engine_nif.c`) owns one sofia stack
  thread. It delivers inbound SIP as messages and accepts enqueue-only
  operations. It has no SIP logic: raw messages cross the boundary as
  binaries.
- **chappe_sip_engine** is the one process that talks to the NIF. It holds the
  route table and a handle table mapping engine handles (transactions,
  legs) to the Erlang processes that own them, and it dispatches inbound
  events.
- **A call is a process.** Each inbound out-of-dialog request runs in its
  own `chappe_sip_request_worker`. Each dialog is a `chappe_sip_dialog_fsm`; each
  outbound transaction a `chappe_sip_uac_fsm`.

## Supervision

```
chappe_sip_sup (one_for_one)
|-- chappe_sip_registry_keeper         location-store ETS owner
|-- chappe_sip_registry                location store
|-- chappe_sip_ws_sup                  WS transport
|-- chappe_sip_media_sup               media control plane
|   `-- chappe_sip_media_mix           conference rooms (when `mix` is configured)
`-- chappe_sip_stack_sup (rest_for_one)   engine crash tears down call state
    |-- chappe_sip_engine                 NIF owner + dispatcher
    |-- chappe_sip_request_sup            per-request workers
    |-- chappe_sip_dialog_sup             dialog fsms
    `-- chappe_sip_uac_sup                uac fsms
```

`rest_for_one` means an engine failure restarts the whole call-state
subtree. A NIF-level crash takes the node; run the release under heart or
systemd (see `docs/design/engine.md`).

## Message contracts

- Inbound request to a handler: the worker runs middleware then the
  method handler `fun(Req, Res)`.
- Dialog events to the owner process:
  `{chappe_sip_dialog, Dialog, Event, Req, Res}` for claimed events and `ack`,
  `{chappe_sip_dialog, Dialog, {auto_answered, Event}, Req}` for unclaimed,
  `{chappe_sip_dialog, Dialog, destroy, ReqOrReason}` at the end.
- UAC events to the notify pid:
  `{chappe_sip_uac, Ref, {request_sent|provisional|ok|response|error, _}}`.

## Testing

Every milestone ships a `chappe_sip_mN_SUITE`. Suites use a `fake` engine
backend (`chappe_sip_engine_fake`, no C) for TU logic and error paths, and a
`live` group driving real SIP over `gen_udp`. Pure modules (parser,
codecs, digest) are covered by eunit.
