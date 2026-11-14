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
app; any module with its `open/2`, `write/2` and `close/2` works. To take
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

- Modules: `chappe_sip_siprec` (the client), `chappe_sip_siprec_meta`
  (metadata), `chappe_sip_siprec_srs` and `chappe_sip_siprec_rtp` (the
  server side), `chappe_sip_multipart`.
- Tests: `chappe_sip_siprec_SUITE`, `chappe_sip_siprec_meta_tests`,
  `chappe_sip_siprec_live_SUITE` (`make interop`).
- Specs: RFC 7866 (updated by RFC 9806), RFC 7865, RFC 6341.
