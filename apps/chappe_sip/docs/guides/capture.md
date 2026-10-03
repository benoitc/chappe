# SIP capture (HEP)

chappe_sip can send a copy of every SIP message it sends and receives to a
capture server in HEPv3, the format Homer and heplify-server read. Use it to
trace calls on a running node without tcpdump or a span port.

## When to use it

- You run Homer (heplify-server) and want this node's calls in it.
- You debug TLS or WebSocket traffic, which a packet capture shows encrypted
  or framed.

## Turn it on

Give `chappe_sip:start/1` a `hep` option:

```erlang
ok = chappe_sip:start(#{
    contact => <<"sip:0.0.0.0:5060">>,
    hep => #{host => "10.0.0.5", port => 9060, capture_id => 2001}
}).
```

Or set it once in `sys.config`, for every start without one:

```erlang
[{chappe_sip, [
    {hep, #{host => <<"homer.example.net">>, port => 9060}}
]}].
```

- `host`: an address or a name, resolved once at start.
- `port`: the collector's UDP port, 1024 or more.
- `capture_id`: the agent id Homer shows (default 200).
- `version`: 3, the only one.

A bad option fails the start with `{error, {hep, Why}}`. Capture is off
without the option, and `chappe_sip:stop/0` turns it off.

## What is captured

- UDP, TCP and TLS: sofia captures each message as it goes on or comes off
  the wire, its retransmissions and the responses the stack sends on its own
  (100 Trying, 487) included. A TLS message is captured in clear text.
- WebSocket: chappe_sip captures each message the WS transport sends and
  receives, keepalives left out. These packets also carry the Call-ID in
  the correlation chunk.

## Check it

```sh
# on the Homer host: the node's packets arrive
tcpdump -ni any udp port 9060
```

Then search the Call-ID of a test call in Homer.

## Notes

- Capture runs over UDP and never blocks SIP: a capture server that is down
  or slow only loses captures. WebSocket captures queue in one process and
  are dropped past 10000 waiting.
- The native transports name their bound address as our end; a wildcard
  listener (`0.0.0.0`) shows as `0.0.0.0`. WebSocket captures show the
  listener port with the unspecified address.
- Native captures of IPv6 traffic carry wrong addresses: the encoder in the
  vendored sofia-sip copies 4 bytes of an IPv6 address. Capture IPv4 traffic,
  or use the WebSocket transport, for correct IPv6 addresses.
