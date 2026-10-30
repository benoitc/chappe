# Debug a call through the system

A call crosses several processes and up to three external daemons: the SIP
stack, rtpengine, FreeSWITCH, the mixer. This page shows how to see each hop:
the SIP messages, the call records, the media session and the FreeSWITCH
channel, and which process owns what. Use it when a call fails, hangs, has no
audio, or leaves state behind.

## Before you start

- [concepts.md: Owner and notify process](../concepts.md#owner-and-notify-process)
  and [A leg and B leg](../concepts.md#a-leg-and-b-leg).
- [architecture.md](../architecture.md): the main flows.
- The guides [capture.md](../../apps/chappe_sip/docs/guides/capture.md) and
  [call-records.md](../../apps/chappe_sip/docs/guides/call-records.md).

## Where to look

| Hop | Tool | Module |
|---|---|---|
| SIP on the wire | HEPv3 capture to Homer or heplify-server | `chappe_sip_hep` (WS), sofia (UDP, TCP, TLS) |
| SIP in a lab | SIPp `-trace_msg` output | `apps/chappe_sip/interop/sipp/run.sh`, `interop/sbc/sipp.sh` |
| Call lifecycle | CDR events | `chappe_sip_cdr` |
| B2BUA state | `chappe_sip_b2b:info/1` | `chappe_sip_b2b`, `chappe_sip_b2b_relay` |
| rtpengine | NG `query` | `chappe_rtpengine:query/2`, `chappe_sip_media:info/1` |
| FreeSWITCH | `fs_cli`, ESL `api` | `chappe_esl:node_api/2` |
| Mixer, conference | `chappe_sip_media:info/1`, `chappe_mrf_conf:members/1` | `chappe_sip_media_mix`, `chappe_mrf_conf` |

## Which process owns what

| Thing | Owner | When the owner exits |
|---|---|---|
| An inbound out-of-dialog request | one `chappe_sip_request_worker` per request; it runs the middleware and the handler | the worker ends; a dialog it owned is torn down |
| A dialog | the `owner` given to `create_uas/3` or `create_uac/2` (default the caller) | the dialog is torn down (a confirmed one sends BYE); its CDR reason is `owner_down` |
| A B2BUA call | the process running `chappe_sip_b2b:relay/1,2`, or the one `relay_async/2` started | both legs are torn down |
| A media session | the process that called `chappe_sip_media:session/2` | the rtpengine session is deleted, the mixer leg leaves |
| A conference (chappe_mrf) | its `chappe_mrf_conf` process; the `owner` option, if any | every member is dropped |

A call that "stays up" after a crash usually has an owner that did not exit.
A call that drops at once usually has an owner that exited early.

## Steps

1. Capture the SIP. Start the node with a `hep` option, or in the conformance
   lab start heplify-server and restart the node:

   ```sh
   apps/chappe_sip/interop/conformance/lab.sh hep up
   CHAPPE_HEP=10.253.7.40:9060 apps/chappe_sip/interop/conformance/lab.sh up
   ```

   In the SBC lab, the SIPp output of each call is in the CT log of the case
   (`_build/test/logs`).

2. Follow the call's records. In a shell on the node:

   ```erlang
   ok = chappe_sip_cdr:subscribe(self()),
   flush().
   ```

   Each attempt gets `attempt`, maybe `start`, then exactly one `stop` with a
   `reason`. `chappe_sip_cdr:open_records()` lists the attempts not stopped
   yet: a record that stays open names a driver that never finished.

3. Look at the B2BUA. `chappe_sip_b2b:info(B2b)` returns the media mode, the
   hold state of each leg, the Call-ID, the media session and whether an
   offer is pending. In the SBC lab:

   ```sh
   apps/chappe_sip/interop/sbc/lab.sh ctl calls
   apps/chappe_sip/interop/sbc/lab.sh ctl events '["my-call@lab"]'
   ```

4. Look at rtpengine. Query the call by Call-ID on the node that holds it:

   ```erlang
   chappe_rtpengine:query(Node, #{call_id => <<"my-call@lab">>}).
   ```

   No packets on one side means the SDP pointed the endpoint at the wrong
   address: compare the `c=` lines in the capture with rtpengine's interfaces.
   In the SBC lab, `lab.sh ctl query '["my-call@lab"]'` returns the relayed
   packet count.

5. Look at FreeSWITCH:

   ```sh
   apps/chappe_sip/interop/sbc/lab.sh fs 1 'show channels'
   docker compose -p chappe-mrf -f apps/chappe_mrf/interop/docker-compose.yml \
       exec fs1 /usr/local/freeswitch/bin/fs_cli -x 'show channels'
   ```

   From the node, `chappe_esl:node_api(fs1, <<"show channels">>)` does the
   same through ESL.

6. Look at a conference. `chappe_mrf_conf:members(Conf)` lists the members
   with their flags; `chappe_mrf_conf:info(Conf)` gives the backend and the
   node.

## Tests to add or run

- Turn the failing call into a CT case before you fix it, with the fake that
  covers the hop: see [add-tests.md](add-tests.md).
- If it needs a real daemon, add a case to the lab of that area:
  [add-interop-lab.md](add-interop-lab.md).

## How to know it works

- The new case fails on the old code and passes on the fix.
- `make check`, then the lab you touched (`make interop-sbc`,
  `make interop-mrf`, ...).

## Notes

- HEP never blocks SIP: a capture server that is down loses packets, not
  calls.
- A TLS message is captured in clear text; a WebSocket one carries the
  Call-ID in the correlation chunk.
- Keep a lab up after a failing run with its `*_KEEP` variable
  ([labs.md](labs.md)), then inspect it.

## Related

- [labs.md](labs.md)
- [change-b2bua.md](change-b2bua.md)
- [apps/chappe_sip/docs/guides/capture.md](../../apps/chappe_sip/docs/guides/capture.md)
- [apps/chappe_sip/docs/guides/call-records.md](../../apps/chappe_sip/docs/guides/call-records.md)
