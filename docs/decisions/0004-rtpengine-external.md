# 0004: rtpengine stays an external daemon

This record explains why chappe controls rtpengine over its NG protocol
instead of relaying RTP itself, and why no SIP process ever touches RTP.
Read it before you propose media handling in Erlang beyond the mixer, or a
feature that needs SRTP, DTLS, ICE or transcoding.

## Status

Proposed, to confirm by the maintainer.

## Context

What the repository shows:

- "The SIP processes never touch RTP: it stays in rtpengine and in the
  chappe_mix conference processes"
  ([media.md](../../apps/chappe_sip/docs/design/media.md)), repeated as a
  non-goal in [features.md](../../apps/chappe_sip/docs/features.md)
  ("chappe_sip is not a media relay or a media server itself").
- chappe_rtpengine is a client of the NG protocol only
  (`apps/chappe_rtpengine/README.md`); `chappe_sip_media` routes `anchor`,
  `relay`, `transcode`, `play`, `record`, `dtmf`, `subscribe` and `duck` to
  rtpengine by default (`default_backend/1` in
  `apps/chappe_sip/src/media/chappe_sip_media.erl`).
- chappe_mix is G.711 only and expects rtpengine in front "for SRTP, DTLS
  and every other codec" (moduledoc of `apps/chappe_mix/src/chappe_mix.erl`).
- rtpengine runs in docker in every lab that needs media
  (`apps/chappe_rtpengine/interop/`, `apps/chappe_sip/interop/sbc/`,
  `demo/sbc/docker-compose.yml`).

## Decision

rtpengine is an external daemon that chappe drives through
chappe_rtpengine. Every RTP feature it offers (anchoring, SRTP and DTLS,
ICE, transcoding, recording, playback, forks) is used from there, not
reimplemented in Erlang.

## Consequences

- A deployment that anchors media runs rtpengine next to the Erlang node,
  and operates it.
- chappe only depends on the NG protocol, so a newer rtpengine brings new
  codecs without a chappe change; an older one limits what is possible (see
  the rtpengine 11.5 findings in `apps/chappe_mix/test/audit/ATTEMPTS.md`,
  "rtpengine as the mixer: not on Ubuntu 24.04").
- An rtpengine session is per call and bound to its owner process
  ([0002](0002-one-process-per-call.md)); losing the node is handled by the
  pool's health and pinning (`chappe_rtpengine_pool`).

## Open questions

- Confirm: SRTP/DTLS/ICE and transcoding are out of scope for Erlang?
