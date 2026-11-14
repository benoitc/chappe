# drachtio parity

This page lists what a drachtio app (drachtio-srf, drachtio-server,
drachtio-fsmrf, rtpengine-client) uses and where chappe stands on each item,
from an audit of both code bases on 2026-11-14. Use it before you port a
drachtio app, to see what maps one to one, what works differently and why,
and what is not there yet. The call-by-call mapping is in
[drachtio to chappe](../apps/chappe_mrf/docs/drachtio-mapping.md).

Status:

- **done**: in chappe, with tests and a guide.
- **media PR**: planned in the media work that follows, not in chappe yet.
- **by design**: chappe does it another way, for the reason given.
- **out of scope**: not planned here.

## Call model and B2BUA (drachtio-srf)

| drachtio | chappe | Status |
|---|---|---|
| `createB2BUA` callbacks `cbRequest`, `cbProvisional`, `cbFinalizedUac` | `notify` gets `b_request`, `b_provisional`, `b_early`: B's Call-ID, and CANCEL while it rings | done |
| `responseHeaders` | `a_headers` | done |
| `followRedirects`, `keepUriOnRedirect` | the same options on the B leg and on `create_uac` | done |
| `localSdpB`, `auth` and `createUAS` `localSdp` as functions | funs accepted; a fun runs on the node that holds the call | done |
| `req.locals` | `chappe_sip_req:set_local/3`, handed on with `{next, Req1}` | by design: the request is a value, so locals travel with it instead of living in a shared object |
| `dlg.on('hold' / 'unhold' / 'refresh' / 'publish')` | dialog events to the owner, and `chappe_sip:dialog_events/1` | done |
| one id per call across legs, media and records | `call_ref` on every leg, CDR and HEP, found from any node with `chappe_sip:calls/1` | done |
| `dlg.on('refer')` handled by the app | `transfer => auto` carries out blind and attended transfers, `transfer => notify` lets the app decide | done |
| REFER on a call bridged to FreeSWITCH | handled by chappe, FreeSWITCH never sees it | done |
| REFER to a conference focus (RFC 4579) | add or remove a participant through the app's policy | done |
| a conference member transferring itself out | the member leaves with reason `transferred` | media PR |
| REFER with a list of targets (RFC 5368) | refused with 420 and `Unsupported: multiple-refer` | by design: not supported; the refusal is the standard answer to an extension a server does not have |
| SIPREC client (jambonz siprec-client) | `chappe_sip_siprec:start/3`, with RFC 7865 metadata, pause, resume and party changes | done |
| SIPREC server | `chappe_sip_siprec_srs:serve/3`, with a sink process for the audio | done |
| SIPREC of a native conference room | `chappe_sip_siprec:start({room, Id}, Srs, Opts)`, the mix as one participant | done |
| SIPREC server writing to a store | `store => default` | media PR |
| recording indication to the parties (RFC 7866 6.1.2) | left to the app: a prompt or an agreement | by design: the RFC lets the means vary, and only the app knows which applies |
| a call handled by a process outside the SIP node (the control socket) | none | out of scope: [decision 0008](decisions/0008-remote-app-model.md) |

## Server options (drachtio-server)

| drachtio | chappe | Status |
|---|---|---|
| `external-ip`, `local-net` | `public` and `local_nets` on a contact, for 1:1 NAT | done |
| SIP timers T1, T2, T4 | `sip_timers` | done |
| outbound proxy | `outbound_proxy`, or `outbound_route` as a preloaded Route | done |
| TCP keep-alive | `tcp_keepalive_ms` | done |
| TCP keep-alive on TLS | none | by design: sofia's TLS writer cannot take a ping safely; the client's keep-alives and the registrar's expiry cover TLS flows |
| UDP MTU | `udp_mtu` | done |
| `dns-name` aliases | `aliases` | done |
| `spammers` (User-Agent rules) | guard rules on any header, with an action per transport | done |
| Prometheus listener | `metrics => #{port => P}` | done |
| proxy `followRedirects` | bounded redirect recursion | done |
| proxy `provisionalTimeout`, `finalTimeout` | `provisional_timeout`, `final_timeout` per branch | done |
| Record-Route on a proxy facing two addresses or transports | two Record-Route entries (RFC 5658) | done |
| the server as a separate C++ process | sofia-sip inside the Erlang node, through a NIF | by design: [decision 0001](decisions/0001-sofia-nta-nif.md) |

## Media (drachtio-fsmrf, rtpengine-client)

| drachtio | chappe | Status |
|---|---|---|
| `ep.play` result (`playbackSeconds`, missing file) | `play_info/3`, `{error, not_found}` | media PR |
| `ep.playCollect` full result | `result => full` | media PR |
| playback offset and time limit | play options | media PR |
| `ep.on('playback-start' / 'playback-stop')`, custom and channel events | owner events chosen with `events => [...]` | media PR |
| `ep.mute`, `ep.unmute` | endpoint mute and unmute | media PR |
| `ep.getChannelVariables`, `ep.set(map)`, `ep.export` | endpoint variables, multiset, export | media PR |
| `ep.execute` without waiting | `execute/4` with `wait => false` | media PR |
| `forkAudioStart` bugname, stereo, pause, resume, send text | fork options and calls | media PR |
| `ep.say`, `ep.speak` | `say/3` over mod_say, `speak/3` over a TTS module | media PR |
| tone and fax detection | `detect_tones/2`, `detect_fax/1` | media PR |
| conference recording, member limit, flags, events | room options and events | media PR |
| moving a member between conferences | `transfer/3` | media PR |
| an audio intake for forks | `chappe_audio` | media PR |
| a default recording store | `chappe_audio_store` | media PR |
| rtpengine `list`, `statistics`, `startForwarding`, `stopForwarding` | typed calls in chappe_rtpengine | media PR |
| a conference outside FreeSWITCH | a native room on chappe_mix | done |
| bridging an endpoint re-INVITEs the caller | the leg behind rtpengine moves, the caller sees no re-INVITE | by design: fewer offers to a caller's device, no glare |
