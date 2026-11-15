# drachtio to chappe

This page maps the drachtio-srf and drachtio-fsmrf calls you know to their
chappe equivalents. Use it when you port a drachtio app.

## drachtio-srf

| drachtio-srf | chappe |
|--------------|--------|
| `srf.invite((req, res) => ...)` | `chappe_sip:invite(fun(Req, Res) -> ... end)` |
| `srf.createB2BUA(req, res, uri, opts)` | `chappe_sip_b2b:create_b2bua(Req, Res, Uri, Opts)`, then `relay/2` or `relay_async/2` |
| `createB2BUA` with an array of URIs (serial) | a list target, or `pass_failure => false` and your own loop |
| simultaneous ringing | `{parallel, [Uri]}` target |
| `proxyRequestHeaders`, `proxyResponseHeaders` | `proxy_request_headers`, `proxy_response_headers` |
| `responseHeaders` | `a_headers` |
| `localSdpB`, `localSdpA` (values or functions) | `local_sdp_b`, `local_sdp_a` (values or funs) |
| `auth` (object or function) | `auth` (map, list or fun of the challenge) |
| `followRedirects`, `keepUriOnRedirect` | `follow_redirects`, `keep_uri_on_redirect` (B2BUA and UAC) |
| `cbRequest`, `cbProvisional`, `cbFinalizedUac` | `notify` events `{b_request, Info}`, `{b_provisional, Msg}`, `{b_early, Dialog}` |
| `req.locals`, `next()` | `chappe_sip_req:set_local/3`, `local/2,3`; return `{next, Req1}` from a middleware |
| `dlg.on('hold' / 'unhold' / 'refresh')` | `{chappe_sip_dialog, D, hold \| unhold \| refresh, Req}` |
| `dlg.on('publish')` | `handled_events => [publish]` |
| (none) | `chappe_sip:dialog_events/1`: every dialog's state as it changes |
| (none) | `call_ref`, `chappe_sip:calls/1`: one id per call across legs, records and nodes |
| `uac.destroy({headers})` | `chappe_sip_b2b:hangup(B2b, #{headers, reason})` |
| `dlg.on('refer' / 'info' / 'message')` | `requests => [refer, info, message]`, events `{chappe_sip_b2b, Ref, {request, ...}}` |
| `dlg.on('refer')` carrying out the transfer yourself | `transfer => auto` (blind and attended, under a `policy`), or `transfer => notify` and `{refer, Info}` with `accept/2`, `reject/2` |
| REFER to a conference URI | `chappe_sip_focus:refer/4` |
| a SIPREC client (jambonz) | `chappe_sip_siprec:start(B2b \| {room, Id}, Srs, Opts)`, `pause/1`, `resume/1`, `stop/1` |
| a SIPREC server | `chappe_sip_siprec_srs:serve/3` then `run/1`; metadata with `chappe_sip_siprec_meta` |
| `srf.proxyRequest(req, dest, {followRedirects, provisionalTimeout, finalTimeout})` | `chappe_sip:proxy_request/3` options `follow_redirects`, `provisional_timeout`, `final_timeout` |
| `srf.createUAC(uri, opts)` | `chappe_sip:create_uac(Uri, Opts)` |
| `srf.createUAS(req, res, {localSdp})` | `chappe_sip:create_uas(Req, Res, #{local_sdp => Sdp \| fun(Offer)})` |
| `srf.register(...)` client | `chappe_sip:register_client/2` |
| `srf.use(fn)` middleware | `chappe_sip:use/1,2` |

## drachtio-server

| drachtio-server | chappe_sip |
|-----------------|------------|
| `<contact>` with `external-ip`, `local-net` | `contact => #{uri, public, local_nets}` in `chappe_sip:start/1` |
| `<sip><timers>` T1, T2, T4 | `sip_timers => #{t1, t2, t4}` |
| `<outbound-proxy>` | `outbound_proxy`, or `outbound_route` (a preloaded Route) |
| `<tcp-keepalive-interval>` | `tcp_keepalive_ms` (TCP only, not TLS) |
| `<udp-mtu>` | `udp_mtu` |
| `<dns-names>` | `aliases` |
| `<spammers>` | guard rules on any header, with an action per transport |
| `<prometheus>` | `metrics => #{port => P}` |

## drachtio-fsmrf

| drachtio-fsmrf | chappe_mrf |
|----------------|------------|
| `new Mrf(srf)`, `mrf.connect(opts)` | `chappe_esl:node_add/2` per node, `chappe_mrf:start/1` |
| `ms.connectCaller(req, res)` | `chappe_mrf:connect_caller(Req, Res, Opts)` returns `{ok, Ep, B2b}` |
| `ms.createEndpoint()` | `chappe_mrf:create_endpoint(Opts)` |
| `ep.play(file)` | `chappe_mrf:play(Ep, File)` |
| `ep.playCollect(opts)` | `chappe_mrf:play_collect(Ep, Opts)` |
| `ep.record(file, opts)` | `chappe_mrf:record(Ep, Path, Opts)` |
| `ep.recordSession` | `chappe_mrf:record_session/2`, `record_session_stop/2` |
| `ep.forkAudioStart(opts)` | `chappe_mrf:fork_audio_start(Ep, Url, Opts)` |
| `ep.set(var, val)` | `chappe_mrf:set(Ep, Var, Val)` |
| `ep.api(cmd)` | `chappe_mrf:api(Ep, Cmd)` |
| `ep.execute(app, args)` | `chappe_mrf:execute(Ep, App, Args)` |
| `ep.modify(sdp)` | `chappe_mrf:modify(Ep, Sdp | hold | unhold)` |
| `ep.bridge(other)` | `chappe_mrf:bridge(B2b, Ep | Uri)` |
| `ep.destroy()` | `chappe_mrf:destroy(Ep)` |
| `ep.on('dtmf')`, `ep.on('destroy')` | `{chappe_mrf, Ep, {dtmf, D}}`, `{chappe_mrf, Ep, {hangup, Cause}}` |
| `ep.say`, `ep.speak` | not wrapped: `execute/3` where the node has the modules |
| `ms.createConference(name, opts)` | `chappe_mrf:conference(Name, #{backend => fs})` |
| `ep.joinConference(conf)` | `chappe_mrf_conf:join(Conf, Ep | B2b, Opts)` |
| `conf.mute/kick/lock` | `chappe_mrf_conf:mute/2`, `kick/2`, `lock/1` |
| (none) | `backend => native`: a room on chappe_mix, with `relate/4` |

## Differences to know

- A call is a process: the handler that called `connect_caller/3` owns the
  endpoint, and its exit cleans the channel up.
- Bridging never re-INVITEs the caller: the leg behind rtpengine moves.
- A conference is a process that owns its room; it does not end with its
  first caller.
