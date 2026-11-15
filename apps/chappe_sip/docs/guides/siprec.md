# Record a call with SIPREC

SIPREC (RFC 7866) sends a call's audio to a recording server: chappe, as
the session recording client (SRC), opens a recording session (RS) to the
server (SRS) with one stream per party and metadata (RFC 7865) that says who
is on the call. You need it when the recordings live in a recorder of
their own (enki_vox, a vendor recorder), or when chappe itself is that
recorder and writes each stream to the recording store.

## Record an anchored call

The call's media must go through rtpengine (`media => anchor`), since each
party is tapped there. Start the recording with the call's handle:

```erlang
chappe_sip:invite(fun(Req, Res) ->
    {ok, #{b2b := B2b} = Legs} =
        chappe_sip:create_b2bua(Req, Res, <<"sip:bob@10.0.0.20">>, #{media => anchor}),
    {ok, Rec} = chappe_sip_siprec:start(B2b, <<"sip:srs@10.0.0.30">>, #{}),
    chappe_sip_b2b:relay(Legs)
end).
```

`start/3` returns once the recording runs; the SRS answers later. The
caller of `start/3` owns the recording and gets every step:

```erlang
receive
    {chappe_sip_siprec, Rec, {started, #{call_ref := Ref, srs := Srs}}} -> ok;
    {chappe_sip_siprec, Rec, {stopped, #{reason := Why}}} -> {error, Why}
end.
```

Give `default` instead of a URI to use the `siprec_srs` setting.

## What the recording server gets

- An INVITE with `Contact: <...>;+sip.src` and `Require: siprec`.
- A `multipart/mixed` body: an SDP offer with one `a=sendonly` m-line per
  party, each with its `a=label` (the caller is `1`, the callee `2`), and an
  `application/rs-metadata+xml` part with `Content-Disposition:
  recording-session`.
- Metadata naming the call as one session, carrying chappe's `call_ref`
  (element `call-ref` in the namespace
  `https://github.com/benoitc/chappe/ns/recording`), the participants
  (leg A's From, leg B's To) and who sends and receives each stream.

A recorder built on RFC 7866 alone may only know the media type
`application/rs-metadata`. Send it that name:

```erlang
{ok, Rec} = chappe_sip_siprec:start(B2b, Srs, #{legacy_content_type => true}).
```

## Pause, resume, stop

```erlang
ok = chappe_sip_siprec:pause(Rec),   %% re-INVITE, every stream a=inactive
ok = chappe_sip_siprec:resume(Rec),  %% re-INVITE, a=sendonly again
ok = chappe_sip_siprec:stop(Rec).    %% BYE, then stopped
```

While paused, the taps are removed from rtpengine, so no media leaves.
The recording also ends, with a BYE, when the call ends (`call_ended`),
when the owner exits, or when the SRS sends BYE (`srs_bye`).

## Party changes

When the call's leg B is replaced (`chappe_sip_b2b:replace_b/3`, a
transfer), the recording taps the new party on the same stream and
re-INVITEs the SRS with metadata where the old callee has its
`disassociate-time` and the new one is associated. The owner gets
`updated`. Call `chappe_sip_siprec:update/1` to check the parties again
yourself.

An UPDATE from the SRS asking for a snapshot is answered 200 and followed
by a re-INVITE with a full snapshot; the owner gets `snapshot`.

## Keep metadata back

RFC 7865 lets the SRC limit what it sends. Name the parties as you want
them recorded, and drop what the recorder must not see:

```erlang
{ok, Rec} = chappe_sip_siprec:start(B2b, Srs, #{
    participants => #{a => #{aor => <<"sip:agent-7@example.com">>, name => <<"Agent">>}},
    metadata => #{names => false, call_ref => false}
}).
```

`aors => false` sends `sip:anonymous@anonymous.invalid` for every party.

## Record a conference room

A chappe_mix room is recorded as one participant whose one stream is the
whole mix:

```erlang
{ok, Rec} = chappe_sip_siprec:start({room, <<"room-42">>}, Srs,
                                    #{call_ref => RoomRef}).
```

The room must be up; the recording joins it as a sendonly leg and never
creates it, and that leg does not keep the room up. When the last party
leaves (or the room's owner exits) the room ends, and the recording ends
with it: a BYE to the SRS and `stopped` with reason `room_ended`.

## Be the recording server

On a route that takes `siprec`, `chappe_sip_siprec_srs:serve/3` answers
the RS, receives each stream and writes it to the recording store:

```erlang
ok = chappe_sip:handle(<<"INVITE">>, fun(Req, Res) ->
    case chappe_sip_siprec_srs:serve(Req, Res, #{store => default}) of
        {ok, Srs} -> chappe_sip_siprec_srs:run(Srs);
        {error, not_recording_session} -> chappe_sip_res:send(Res, 403);
        {error, _} -> ok
    end
end, #{option_tags => [<<"siprec">>]}).
```

Each stream becomes one recording of the store, under the `call_ref` from
the metadata, with the stream's senders as its parties. `store => default`
is the `siprec_store` setting, `chappe_audio_store` of the chappe_audio
app, which must run on this node (a stream it cannot open is refused with
port 0); find the recordings with `chappe_audio_store:find(CallRef)`. Any
module with its `open/2`, `write/2` and `close/2` works. To take
the audio yourself, give `sink => Pid` instead: the process gets
`{chappe_sip_siprec_rtp, Stream, {audio, Pcm}}`, 16-bit PCM at 8 kHz.

`run/1` carries the session until the BYE: it answers each re-INVITE and
UPDATE of the client and hands the metadata each carries (a party change,
a pause) to the notify process (`notify => Pid`, else the sink):

```erlang
receive
    {chappe_sip_siprec_srs, Dialog, {metadata, Doc}} ->
        chappe_sip_siprec_meta:senders(Doc);
    {chappe_sip_siprec_srs, Dialog, {stopped, _Why}} ->
        done
end.
```

## Keep the recording as secure as the call

RFC 7866 12 asks the recording session to be at least as secure as the
call. You get that by default:

- A call with a leg over TLS is recorded only to a `sips:` (or
  `;transport=tls`) recording server. A plain one is refused before any
  INVITE leaves:

```erlang
{error, {insecure_srs, tls}} =
    chappe_sip_siprec:start(B2b, <<"sip:srs@10.0.0.30">>, #{}),
{ok, Rec} = chappe_sip_siprec:start(B2b, <<"sips:srs@10.0.0.30">>, #{}).
```

- A call with an SRTP leg has every tap offered as `RTP/SAVP`, with keys
  rtpengine makes for the recording (not the call's). A recording server
  without SRTP refuses the streams and the recording stops. So does
  chappe's own recording server when the keys reach it over plain SIP:
  record SRTP calls to a `sips:` SRS.

When the recording server sits on a network you trust, lift both with
`allow_downgrade => true`.

As the recording server, each stream takes RTP only from the address the
client's SDP gives for it, latched to the first source there; give
`rtp_source => learn` for a client behind a NAT that writes its private
address.

### Take SRTP as the recording server

`serve/3` takes `RTP/SAVP` and `RTP/SAVPF` streams keyed with SDES
(RFC 7866 12.2), and decrypts them itself: no rtpengine is needed on the
receive side. You need nothing in your handler, but the keys must come over
TLS: RFC 4568 8.3 requires the SDP that carries them to be encrypted, so an
SRTP stream offered over UDP or TCP (and not to a `sips:` URI) is rejected
with port 0, and the offer gets 488 when no stream is left. Point your
recording client at a `sips:` URI. On a network you trust, take keys over
plain SIP with `keys_over_tls => false`:

```erlang
{ok, Srs} = chappe_sip_siprec_srs:serve(Req, Res, #{
    store => default,
    keys_over_tls => false
}),
chappe_sip_siprec_srs:run(Srs).
```

For each secure stream the server takes the first `a=crypto` line it
supports, answers it with a line of its own (the same tag and suite, a key
of its own it never uses, since it only receives), and authenticates,
checks for replay and decrypts each packet before it is decoded. A
re-INVITE with a new key gives the stream the new key.

- Taken: `AES_CM_128_HMAC_SHA1_80` and `AES_CM_128_HMAC_SHA1_32`, the
  `inline` key, one master key with or without a lifetime and an MKI,
  `WSH`, `KDR=0`.
- Refused (the stream gets port 0, and the offer 488 when nothing is
  left): F8, AES-256 and AEAD suites, several master keys, a key
  derivation rate, `UNENCRYPTED_SRTP`, `UNENCRYPTED_SRTCP`,
  `UNAUTHENTICATED_SRTP`, `FEC_KEY`, DTLS-SRTP (`UDP/TLS/RTP/SAVP`).
- Dropped and counted, never decoded: a forged packet, a replayed one, one
  past the key's lifetime, a packet of a fifth SSRC. The stream latches to
  its source only once a packet authenticates. The first drop is logged,
  then one line per 10 s; read the counters with
  `chappe_sip_siprec_rtp:stats/1`:

```erlang
#{streams := [#{pid := Stream} | _]} = Srs,
#{packets := _, failed := _, replayed := _} =
    chappe_sip_siprec_rtp:stats(Stream).
```

### What is encrypted where

| Path | Protected by | Notes |
|---|---|---|
| The call's signalling | TLS on each leg that uses it | the recording needs a `sips:` SRS when a leg is TLS |
| The call's media | SRTP, in rtpengine | chappe never touches it |
| The RS signalling, client to server | TLS when the SRS URI is `sips:` | it carries the metadata and, with SRTP, the keys |
| The RS media | SRTP, encrypted by rtpengine with keys of the recording, decrypted by chappe's SRS | a different key from the call's (RFC 7866 12.2) |
| The recording at rest | nothing in chappe | the store module decides |

TLS keeps the SDES keys secret on the way, which is why the server takes
them only over TLS unless you say otherwise. SRTP keeps the audio secret
and authentic between rtpengine and the SRS: a packet nobody keyed is
dropped.

## Run it from another node

The recording runs on the node that holds the call; `start/3` can be
called from any node with the call's `b2b` handle (from
`chappe_sip:calls/1`), and the events reach the caller there.

```erlang
{ok, #{b2b := [B2b]}} = chappe_sip:calls(#{call_ref => Ref}),
{ok, Rec} = chappe_sip_siprec:start(B2b, Srs, #{}),
{ok, #{siprec := [Rec]}} = chappe_sip:calls(#{call_ref => Ref}).
```

## Notes

- A recording server that does not answer within `answer_timeout` (default
  `siprec_answer_timeout_ms`, 10 s) gets a CANCEL, or a BYE when it was a
  re-INVITE, and the owner `stopped` with `{srs, timeout}`.
- One call has at most `siprec_max_per_call` recordings (2); one more is
  `{error, too_many}`.
- A recording that crashes sends no event: monitor `Rec`. Its RS dialog
  sends the BYE, the call's media session removes its rtpengine taps, and
  the call goes on.
- RFC 7866 6.1.2 asks the SRC to tell the parties they are recorded.
  chappe sends no `a=record`: play a prompt (chappe_mrf, rtpengine play) or
  rely on an agreement.
- Each tap is transcoded to PCMU by rtpengine unless `codec` says
  otherwise, which needs an rtpengine built with transcoding.

## Where it lives

- Modules: `chappe_sip_siprec` (the client), `chappe_sip_siprec_peer`
  (what the recording server sends in the client's dialog),
  `chappe_sip_siprec_meta` (metadata), `chappe_sip_siprec_srs` and `chappe_sip_siprec_rtp` (the
  server side), `chappe_sip_srtp` (SRTP decryption), `chappe_sip_sdes`
  (`a=crypto` lines), `chappe_sip_multipart`.
- Tests: `chappe_sip_siprec_SUITE`, `chappe_sip_siprec_meta_tests`,
  `chappe_sip_srtp_tests`, `chappe_sip_sdes_tests`,
  `chappe_sip_siprec_live_SUITE` (`make interop`).
- Specs: RFC 7866 (updated by RFC 9806), RFC 7865, RFC 6341, RFC 3711,
  RFC 4568. Why chappe decrypts SRTP itself here:
  [decision 0009](../../../../docs/decisions/0009-srtp-in-erlang.md).
