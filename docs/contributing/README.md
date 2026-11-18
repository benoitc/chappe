# Contributor workflows

One page per task you do in this repository. Each names the directories,
modules and tests involved, and the exact make target or lab that tells you the
change works. Start with [CONTRIBUTING.md](../../CONTRIBUTING.md) for the
rules every change follows, and [navigation.md](../navigation.md) to find
where a concept lives.

## Run and debug

| If you want to | Read |
|---|---|
| Run the checks and the docker labs, keep a lab up | [labs.md](labs.md) |
| Follow a call through SIP, rtpengine, FreeSWITCH and the mixer | [debug-a-call.md](debug-a-call.md) |

## Change chappe_sip

| If you want to | Read |
|---|---|
| Change how the B2BUA sets up, relays, anchors or replaces a call | [change-b2bua.md](change-b2bua.md) |
| Support a new header, option tag, method or RFC rule | [add-sip-feature.md](add-sip-feature.md) |
| Serve a new SUBSCRIBE/NOTIFY event package | [add-event-package.md](add-event-package.md) |
| Change the C NIF or the vendored sofia-sip | [change-c-engine.md](change-c-engine.md) |

## Media and orchestration

| If you want to | Read |
|---|---|
| Add a capability or a backend to `chappe_sip_media` | [add-media-backend.md](add-media-backend.md) |
| Add or change a chappe_mrf conference backend | [add-mrf-conference-backend.md](add-mrf-conference-backend.md) |

## Cluster and recording

| If you want to | Read |
|---|---|
| Give something one owner in a region, or find it from any node | [use-the-cluster.md](use-the-cluster.md) |
| Keep the registrar's bindings in another store | [add-location-backend.md](add-location-backend.md) |
| Keep recordings in another store | [add-audio-store.md](add-audio-store.md) |
| Add a cross-region directory backend | [add-directory-backend.md](add-directory-backend.md) |
| Debug a call across nodes | [debug-a-call.md](debug-a-call.md#across-nodes) |

## Across the umbrella

| If you want to | Read |
|---|---|
| Add a new app under `apps/` | [add-app.md](add-app.md) |
| Add a function or an option users call | [extend-public-api.md](extend-public-api.md) |
| Write a test, pick a fake | [add-tests.md](add-tests.md) |
| Add a docker lab or a case to one | [add-interop-lab.md](add-interop-lab.md) |
| Add or update a compliance row | [compliance.md](compliance.md) |
| Write or change a guide | [write-a-guide.md](write-a-guide.md) |

## The labs

Each lab has a README next to its compose file:

- [chappe_sip: JsSIP and Kamailio](../../apps/chappe_sip/interop/README.md)
- [chappe_sip: conformance (SIPp, pjsua, DNS, HEP)](../../apps/chappe_sip/interop/conformance/README.md)
- [chappe_sip: SBC (FreeSWITCH, rtpengine, Kamailio)](../../apps/chappe_sip/interop/sbc/README.md)
- [chappe_rtpengine: rtpengine](../../apps/chappe_rtpengine/interop/README.md)
- [chappe_esl: two FreeSWITCH nodes](../../apps/chappe_esl/interop/README.md)
- [chappe_mix: rtpengine and FreeSWITCH reference](../../apps/chappe_mix/interop/README.md)
- [chappe_mrf: rtpengine and two FreeSWITCH nodes](../../apps/chappe_mrf/interop/README.md)
