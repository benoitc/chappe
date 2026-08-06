# Playback, recording, DTMF and ducking

This guide covers the media features you build IVRs, voicemail, call recording and voice interpretation with: playing prompts, injecting synthesized audio, recording, DTMF in both directions, and silencing one direction while a clip plays. You need an rtpengine built with transcoding support for playback, silencing and DTMF injection; minimal builds reply "Unrecognized command".

## Play a prompt or inject TTS audio

Media commands run against an established session with its identity injected:

```erlang
{ok, _} = chappe_rtpengine_session:play_media(Sess, #{file => <<"/prompts/welcome.wav">>}),
{ok, _} = chappe_rtpengine_session:stop_media(Sess).
```

Pick the leg with `party => caller | callee | all` (default is the caller). Provide the audio as `file`, `blob` (raw bytes of the media file), `blob64` (base64) or `db_id`, and loop with `repeat_times`. The reply carries `duration` in ms when rtpengine can determine it:

```erlang
{ok, _} = chappe_rtpengine_session:play_media(Sess, #{
    blob => TTSClip,
    party => callee
}).
```

Blobs travel inside the NG message. Over UDP that limits them to roughly one MTU; send larger clips through a node added with `transport => tcp`, or reference them by `file`/`db_id`.

## Duck a direction

For duck-and-replace (an interpreter speaking a translation over one party), silence or block one direction while the clip plays. Silencing keeps the party's packets flowing but replaces the audio with silence; blocking stops the packets entirely:

```erlang
{ok, _} = chappe_rtpengine_session:silence_media(Sess, #{party => caller}),
{ok, _} = chappe_rtpengine_session:play_media(Sess, #{blob => Translation, party => callee}),
%% when the clip is done
{ok, _} = chappe_rtpengine_session:unsilence_media(Sess, #{party => caller}).
```

With no options the whole call is affected (`block_media(Sess)` mutes everything). `party => caller | callee` targets one direction: the party's tag goes out as from-tag together with the `directional` flag, which rtpengine requires for per-party media control. Raw NG keys (`label`, `address`, `to_tag`, `flags`) pass through for finer selection.

## Record the call

```erlang
{ok, _} = chappe_rtpengine_session:start_recording(Sess),
{ok, _} = chappe_rtpengine_session:stop_recording(Sess).
```

Recording output is configured on the rtpengine side (`--recording-dir`, `--recording-method`).

## Send and block DTMF

```erlang
{ok, _} = chappe_rtpengine_session:play_dtmf(Sess, #{code => 5, duration => 100}),
{ok, _} = chappe_rtpengine_session:block_dtmf(Sess),
{ok, _} = chappe_rtpengine_session:unblock_dtmf(Sess).
```

## Receive DTMF events

rtpengine reports detected digits as JSON datagrams to `--dtmf-log-dest`. Open the listener and point rtpengine at it:

```erlang
{ok, _Port} = chappe_rtpengine_dtmf:open(2225).
%% rtpengine: --dtmf-log-dest=YOUR_HOST:2225
```

Or set `{dtmf_listen, 2225}` in the application environment. Then start sessions with `dtmf => true` and read digits from the owner mailbox:

```erlang
{ok, Sess} = chappe_rtpengine:start_session(#{call_id => CallId, dtmf => true}),
receive
    {chappe_rtpengine_session, Sess, {dtmf, #{digit := Digit}}} ->
        handle_digit(Digit)
end.
```

`digit` is the ASCII character (`$0`..`$9`, `$*`, `$#`, `$A`..`$D`); the event also carries `code`, `duration`, `volume`, `source_tag` and the raw JSON object. Without sessions, subscribe directly:

```erlang
ok = chappe_rtpengine_dtmf:subscribe(CallId),
receive {chappe_rtpengine_dtmf, CallId, Event} -> ... end.
```

Notes:

- An IVR is a receive loop: `play_media` a prompt, react to `{dtmf, ...}` messages, play the next prompt.
- Any NG command not wrapped by a helper is reachable with `chappe_rtpengine_session:cmd(Sess, Command, Params)` or `chappe_rtpengine:cmd(Node, Command, Params)`.
