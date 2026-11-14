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
| `uac.destroy({headers})` | `chappe_sip_b2b:hangup(B2b, #{headers, reason})` |
| `dlg.on('refer' / 'info' / 'message')` | `requests => [refer, info, message]`, events `{chappe_sip_b2b, Ref, {request, ...}}` |
| `srf.createUAC(uri, opts)` | `chappe_sip:create_uac(Uri, Opts)` |
| `srf.register(...)` client | `chappe_sip:register_client/2` |
| `srf.use(fn)` middleware | `chappe_sip:use/1,2` |

## drachtio-fsmrf

| drachtio-fsmrf | chappe_mrf |
|----------------|------------|
| `new Mrf(srf)`, `mrf.connect(opts)` | `chappe_esl:node_add/2` per node, `chappe_mrf:start/1` |
| `ms.connectCaller(req, res)` | `chappe_mrf:connect_caller(Req, Res, Opts)` returns `{ok, Ep, B2b}` |
| `ms.createEndpoint()` | `chappe_mrf:create_endpoint(Opts)` |
| `ep.play(file)` | `chappe_mrf:play(Ep, File)`; `play_info/3` for `playbackMs` and the response |
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
