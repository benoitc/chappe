# Deployment

This guide builds a production release and runs it under systemd, so the OS
restarts the node if the SIP engine wedges. Read it when you move from `rebar3
shell` to a real host. A ready-made unit and env file live in `deploy/`.

## When to use it

- You run chappe_sip as a service, not from an interactive shell.
- You want the node restarted automatically when the sofia stack hangs.

## Build the release

```sh
rebar3 as prod release
# _build/prod/rel/chappe_sip/
```

`include_erts` is on in the `prod` profile, so the release is self-contained.
Copy `_build/prod/rel/chappe_sip` to the host (for example
`/opt/chappe_sip`).

## Set the distribution cookie

The node refuses to boot with the placeholder cookie. Put a real secret in an
env file, not in the unit:

```sh
sudo install -d /etc/chappe
sudo cp deploy/chappe_sip.env.example /etc/chappe/chappe_sip.env
sudo sed -i "s/CHANGE_ME_SET_NODE_COOKIE/$(openssl rand -hex 32)/" \
  /etc/chappe/chappe_sip.env
sudo chown chappe:chappe /etc/chappe/chappe_sip.env
sudo chmod 600 /etc/chappe/chappe_sip.env
```

Distribution is bound to loopback (`config/vm.args.src`). Expose it only behind
a firewall, or comment out `-name`/`-setcookie` to run with no distribution.

## Keep epmd on loopback

epmd, the port mapper the node registers with, listens on every interface
unless `ERL_EPMD_ADDRESS` says otherwise. `config/vm.args.src` sets it with
`-env`, but an epmd started earlier (by the release script's ping, or by
another node on the host) never reads that file, so set it in the
environment too. The env file does:

```sh
ERL_EPMD_ADDRESS=127.0.0.1
```

Check with `ss -ltnp | grep 4369`: epmd must show `127.0.0.1:4369`. If an
epmd is already bound to all interfaces, stop it (`epmd -kill`) before the
node starts.

## Install the systemd unit

```sh
sudo cp deploy/chappe_sip.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now chappe_sip
```

The unit runs `bin/chappe_sip foreground`, so systemd is the supervisor:

```ini
ExecStart=/opt/chappe_sip/bin/chappe_sip foreground
Restart=on-failure
RestartSec=2
```

## How restart works

The engine runs sofia-sip on one thread inside the VM. If that thread stops
servicing its loop, the health check declares it hung after
`health_miss_limit` misses and applies `engine_failure_action`:

- `halt` (default): `erlang:halt(1)`. The foreground process exits non-zero and
  systemd restarts it (a fresh VM rebinds the ports).
- `degrade`: SIP stays down, the node stays up (for operators with external
  monitoring).

An engine-process crash (not a wedge) is handled inside the node: the restarted
`chappe_sip_engine` re-establishes the native stack from its persisted config, so SIP
recovers without a full restart.

Set the action in `config/sys.config`:

```erlang
[{chappe_sip, [{engine_failure_action, halt}]}].
```

## Optional: heart

`halt` + systemd covers a wedged engine because the BEAM stays responsive and
exits on purpose. To also catch an unresponsive BEAM, enable Erlang `heart`:
add `-heart` to `config/vm.args.src`. The release start script sets
`HEART_COMMAND` to restart the node. Do not combine `-heart` with `foreground`
under systemd (both would try to restart); use it with the daemonized
`bin/chappe_sip start` instead.

## Listen on several addresses

A host with a public and a private address, or with IPv4 and IPv6, can
take SIP on each. Give `contact` (and the TLS `contact`) a list:

```erlang
ok = chappe_sip:start(#{
    contact => [<<"sip:203.0.113.10:5060">>, <<"sip:10.0.0.10:5060">>,
                <<"sip:[2001:db8::10]:5060">>],
    tls => #{contact => [<<"sips:203.0.113.10:5061;transport=tls">>,
                         <<"sips:10.0.0.10:5061;transport=tls">>],
             cert_dir => <<"/etc/chappe/certs">>}
}).
```

- A request is answered and record-routed with the address it came to, and
  the dialog it forms sends from there.
- A request you originate leaves from the address you name, else from the
  first one of the target's address family:

```erlang
{ok, Ref} = chappe_sip:request(<<"sip:trunk@10.0.0.50">>,
                               #{method => <<"OPTIONS">>,
                                 local => <<"10.0.0.10">>}).
```

- List addresses, not `0.0.0.0`: a wildcard listener cannot say which
  address a request reached.
- A UDP binding learned on one address is reached from that address
  (`{udp, Ip, Port, Local}` in its flow).

## Run behind 1:1 NAT

A cloud host often has only a private address on its interface, and a
public one the provider maps to it. Give the contact as a map: the stack
binds `uri`, and advertises `public` in its Via and Contact.

```erlang
ok = chappe_sip:start(#{
    contact => #{uri => <<"sip:10.0.0.5:5060">>,
                 public => <<"203.0.113.7">>,
                 local_nets => [<<"10.0.0.0/8">>]}
}).
```

- A peer inside `local_nets` gets the local address in the Contact (on the
  answers you send it and the requests you originate to it), so that
  traffic stays inside the private network. Everyone else gets `public`.
- The Via always names `public`. A peer on the private network still
  answers to the address the request came from (RFC 3581 `rport`).
- `local_nets` needs a concrete `uri` address, not `0.0.0.0`.
- A list of contacts may mix plain URIs and maps; the TLS `contact` takes
  maps too.
- An invalid `public`, `local_nets` or a `uri` that already has `maddr`
  fails the start with `{error, {contact, bad_public}}` or
  `{error, {contact, bad_local_nets}}`.
- A proxy between the two sides record-routes twice (RFC 5658), public for
  the outside one and local for the inside one.
- The Contact a B2BUA puts on what it sends the A leg names `public`.

## Keep connections open through NAT

A NAT or a firewall drops an idle TCP mapping after a few minutes. Ask the
stack to send a CRLFCRLF ping (RFC 5626 4.4.1) on every TCP connection
that has been idle for a while:

```erlang
ok = chappe_sip:start(#{contact => <<"sip:10.0.0.5:5060">>,
                        tcp_keepalive_ms => 30000}).
```

- TCP only. sofia's TLS transport has no connection timer, and adding one
  is not a small change: a ping has to go through `SSL_write`, and sofia's
  `tls_write` asserts that a write that blocked is retried with the same
  buffer, so a blocked ping would break the next message. On TLS, the
  client keeps its flow alive (RFC 5626 makes the UA send keep-alives, at
  the `registrar_flow_timer` interval).
- UDP never gets it: RFC 5626 4.4.1 forbids the CRLF keep-alive there.

## Capture to Homer

To see the node's calls in Homer, point it at your heplify-server in
`config/sys.config`; see [SIP capture](capture.md):

```erlang
[{chappe_sip, [{hep, #{host => <<"10.0.0.5">>, port => 9060}}]}].
```

## What survives a crash

- A call is not bounded by the handler deadline: once a worker owns a dialog
  (or forks as a proxy) its deadline is disarmed, so long calls are not torn
  down. The deadline still catches a handler that never responds.
- WS state survives an engine restart: the transport tolerates a briefly-absent
  engine. If the WS transport process itself restarts, its connections close
  and their bindings are dropped; the UAs reconnect and register again.
- Registrations survive a registry-process crash (the ETS is held by a separate
  keeper), and a WS binding is dropped when its connection closes (RFC 5626).
- Handle and C-object cleanup on crash paths (UAC/dialog/proxy), WS transaction
  timers (no sofia timers over WS; a server transaction the app never answers
  gets 408 or 500), and Timer C on proxy and b2bua INVITE branches bound
  resource use. A worker that sends an INVITE (a b2bua B leg) owns the call, so
  a callee ringing past the handler deadline is not cut. The C engine
  start/stop/restart lifecycle is use-after-free-free
  (an RWLock guards the sofia root, CAS transitions guard start/abandon, and the
  stack thread holds its own resource ref so the destructor never frees under
  it) validated under AddressSanitizer via the `chappe_sip_engine_lifecycle` stress
  suite in `test/asan/`, with LeakSanitizer reporting any leak on a NIF call
  path (`test/asan/lsan.supp` covers only stacks without a NIF frame).
- A crash of the engine process re-establishes the native stack and its
  handlers from a config snapshot (held in the keeper's ETS), so SIP recovers
  without a manual restart; a controlled restart also fails in-flight UAC/dialog
  work cleanly.

## Security defaults

- The Record-Route marker and WS flow tokens are HMAC-authenticated (per-node
  secret, at least 16 bytes when configured) and carry a signed expiry, so a
  crafted or replayed Route cannot turn the proxy into an open relay or target
  another WS leg. The registrar requires a digest/callback auth hook; running
  without one takes an explicit `allow_unauthenticated => true`.
- Resource ceilings: dialogs, UAC transactions, WS connections, the WS transport
  mailbox, and registrar AORs/bindings are all bounded.
- Refuses the default distribution cookie at boot; distribution and epmd bind
  to loopback. TLS floors at 1.2, verifies outbound peers by default, and
  rejects an invalid verify value; `verify => none` needs `allow_insecure`. The WS
  upgrade honours an optional Origin allowlist.
- Digest (RFC 2617, RFC 7616, RFC 8760: MD5, MD5-sess, SHA-256,
  SHA-256-sess) does not replay credentials across a redirect to another
  scheme, host or port, and refuses an unsupported qop instead of
  downgrading. The server side refuses a replayed nonce count (stale), an
  answer without the qop it offered, and a digest uri that is not the
  Request-URI; `chappe_sip_digest:challenges/2` offers SHA-256 and MD5. The
  registrar checks the AOR's user and domain against the credentials.

## Behaviour changes

- `chappe_sip:stop/0`, an engine restart and an engine degrade tear the
  dialogs down: owners get `destroy` with reason `engine_restart`, and a
  UAC still ringing gets `{error, engine_restart}`.

## Notes

- Binding 5060/5061 needs `CAP_NET_BIND_SERVICE` (in the unit) or a high port.
- `LimitNOFILE` should be high; each UDP/TCP/WS peer costs descriptors.
- Roll config changes with `systemctl restart chappe_sip`.

## Where it lives

- Modules: `chappe_sip_app` (cookie check), `chappe_sip_engine` (health,
  restart, hang policy), `chappe_sip_binds` (several addresses), `config/`
  and `deploy/`.
- Tests: `chappe_sip_engine_lifecycle_SUITE`,
  `chappe_sip_engine_smoke_SUITE`, `chappe_sip_multihome_SUITE`.
- Lab: `make asan`.
