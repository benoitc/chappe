# chappe_mrf

`chappe_mrf` is a media resource function for chappe, in the style of
drachtio-fsmrf. It answers a caller with a FreeSWITCH endpoint you drive
from Erlang (play, collect digits, record, fork audio), moves the caller
between endpoints and SIP targets without a re-INVITE, and runs
conferences on chappe_mix (native) or on FreeSWITCH mod_conference. Use it
when your app needs an IVR, a voicemail, a bridge to a media server or a
conference room.

chappe_mrf is the controller. FreeSWITCH, rtpengine and chappe_mix carry
the media. It builds on `chappe_sip` (B2BUA, `replace_b/3`,
`relay_async/2`), `chappe_esl` (the node registry and `chappe_esl_call`)
and `chappe_sip_media`.

## Set it up

Start chappe_sip with rtpengine (and chappe_mix for native rooms), the
FreeSWITCH nodes in chappe_esl, then chappe_mrf:

```erlang
ok = chappe_sip:start(#{
    contact => <<"sip:10.0.0.5:5060">>,
    media => #{
        rtpengine => #{nodes => [#{name => rtpe1, host => "10.0.0.7", port => 22222}]},
        mix => #{ip => {0, 0, 0, 0}, advertise => "10.0.0.5"}
    }
}),
ok = chappe_esl:node_add(fs1, #{host => "10.0.0.8", port => 8021,
                                sip_uri => <<"sip:10.0.0.8:5080">>}),
ok = chappe_mrf:start(#{esl_port => 8084}).
```

Each FreeSWITCH node hands the calls chappe_mrf sends it back to the
listener, with one dialplan extension:

```xml
<extension name="mrf">
  <condition field="destination_number" expression="^mrf$">
    <action application="socket" data="10.0.0.5:8084 async full"/>
  </condition>
</extension>
```

## Guides

- [Answer a caller with a menu](docs/guides/ivr-menu.md)
- [Bridge a caller](docs/guides/bridge.md)
- [Run a conference (native or FreeSWITCH)](docs/guides/conference.md)
- [drachtio to chappe](docs/drachtio-mapping.md)

## Test it

```sh
rebar3 ct --dir apps/chappe_mrf/test --suite chappe_mrf_SUITE   # on fakes
make interop-mrf                                                # real FreeSWITCH and rtpengine
```

The lab is `interop/`: rtpengine and two FreeSWITCH nodes with the `mrf`
extension, mod_sndfile, tones, mod_conference and mod_audio_fork. The demo
SBC (`make demo`, `demo/sbc/README.md`) has an IVR on `2000`.

## Notes

- `say` and `speak` are out of scope: text to speech needs FreeSWITCH
  modules the lab does not load. Where your nodes have them, run them with
  `chappe_mrf:execute/3`.
- An endpoint's channel is killed when its owner exits; audio forks and
  session recordings are stopped first.
- Native conferences bring callers in with a loopback INVITE that
  `chappe_mrf:start/1` intercepts as an INVITE middleware: the app needs an
  INVITE handler (`chappe_sip:invite/1`) for chappe_sip to run it.
