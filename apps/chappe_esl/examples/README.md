# Node registry example

This starts two FreeSWITCH nodes in docker and an Erlang shell where
chappe_esl monitors them. Use it to try the node registry by hand: watch
nodes go up and down, read their load, drain one, and see selection follow.

## When to use it

- You want to see the registry against real FreeSWITCH before using it.
- You are changing `chappe_esl_node` or `chappe_esl_nodes` and want to poke
  at it.

## Start it

From the umbrella root:

```sh
make demo-esl
```

It brings up `fs1` (ESL on 127.0.0.1:18021) and `fs2` (18022) from
`apps/chappe_esl/interop/docker-compose.yml`, then opens a shell with the nodes
of `examples/nodes.config`. Quitting the shell (`q().`) stops the nodes.

## Walk through it

1. List the nodes. Both show `up` within a second or two:

   ```erlang
   1> chappe_esl:nodes().
   [{fs1,up},{fs2,up}]
   ```

2. Read one node's load (HEARTBEAT every second, probes every two):

   ```erlang
   2> chappe_esl:node_status(fs1).
   {ok,#{state => up,load => #{sessions => 0,max_sessions => 200,
         idle_cpu => 99.7,calls => 0,...},...}}
   ```

3. Select a node, drain it, select again:

   ```erlang
   3> chappe_esl:node_select(#{}).
   {ok,fs1}
   4> chappe_esl:node_drain(fs1).
   ok
   5> chappe_esl:nodes().
   [{fs1,draining},{fs2,up}]
   6> chappe_esl:node_select(#{}).
   {ok,fs2}
   7> chappe_esl:node_resume(fs1).
   ok
   ```

4. Place a call from fs1 to fs2 and watch the session counts:

   ```erlang
   8> chappe_esl:node_bgapi(fs1, "originate {sip_h_X-Chappe-Call=demo1}sofia/esl/sip:park@fs2:5080 &park").
   9> chappe_esl:node_status(fs2).
   ```

   Hang it up with `chappe_esl:node_api(fs1, "hupall")`.

5. Subscribe, then stop fs1 from another terminal:

   ```erlang
   10> chappe_esl:node_subscribe(all).
   ok
   ```

   ```sh
   docker compose -p chappe-esl-demo -f apps/chappe_esl/interop/docker-compose.yml stop fs1
   ```

   The shell logs `chappe_esl_node fs1 down: ...` (a failed `sofia status`
   probe while FreeSWITCH shuts down, or the closed socket), and:

   ```erlang
   11> chappe_esl:nodes().
   [{fs1,down},{fs2,up}]
   12> chappe_esl:node_select(#{}).
   {ok,fs2}
   ```

6. Start fs1 again (`... start fs1`). After a few seconds the shell logs
   `chappe_esl_node fs1 up`; `flush().` shows the `down`, `up` and `{load, _}`
   notices you received.

## Notes

- `ESL_PROJECT` changes the compose project name (default `chappe-esl-demo`).
- The FreeSWITCH configuration is test-only: allow-all ESL ACL and an
  unauthenticated SIP profile (see `interop/conf/freeswitch.xml`).
