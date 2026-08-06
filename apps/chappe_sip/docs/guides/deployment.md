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

## Notes

- Binding 5060/5061 needs `CAP_NET_BIND_SERVICE` (in the unit) or a high port.
- `LimitNOFILE` should be high; each UDP/TCP/WS peer costs descriptors.
- Roll config changes with `systemctl restart chappe_sip`.
