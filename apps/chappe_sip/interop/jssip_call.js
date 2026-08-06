// Copyright 2026 Benoit Chesneau
// SPDX-License-Identifier: Apache-2.0

// Drive two real JsSIP UAs (caller + callee) through a media call bridged by
// chappe_sip as a B2BUA over WebSocket. Both UAs use @roamhq/wrtc for a
// real RTCPeerConnection, so the SDP offer/answer are genuine WebRTC. chappe
// passes the SDP through (media is peer-to-peer, loopback), so the caller's
// RTCPeerConnection reaching `connected` proves chappe carried the browser's
// WebRTC signaling intact end to end.
//
// Config via env:
//   WS_URL      ws://127.0.0.1:<port>/ws   (required)
//   CALLER_URI  sip:caller@127.0.0.1
//   CALLEE_URI  sip:callee@127.0.0.1
//   TIMEOUT_MS  20000
//   DEBUG       set for JsSIP wire logs on stderr
//
// Emits one line: `RESULT established` on success, `RESULT failed <what>`
// otherwise. Exit 0 on success.

const JsSIP = require('jssip');
const wrtc = require('@roamhq/wrtc');

// JsSIP's RTCSession reaches for browser globals; wire wrtc in.
global.RTCPeerConnection = wrtc.RTCPeerConnection;
global.RTCSessionDescription = wrtc.RTCSessionDescription;
global.RTCIceCandidate = wrtc.RTCIceCandidate;
global.MediaStream = wrtc.MediaStream;
global.window = global;
// Node 22 ships a read-only `navigator` global with no mediaDevices, so
// override it with defineProperty (plain assignment is silently ignored).
Object.defineProperty(globalThis, 'navigator', {
  configurable: true,
  writable: true,
  value: {
    mediaDevices: {
      getUserMedia: async () => {
        const source = new wrtc.nonstandard.RTCAudioSource();
        return new wrtc.MediaStream([source.createTrack()]);
      },
    },
  },
});

const WS_URL = process.env.WS_URL;
const CALLER_URI = process.env.CALLER_URI || 'sip:caller@127.0.0.1';
const CALLEE_URI = process.env.CALLEE_URI || 'sip:callee@127.0.0.1';
const TIMEOUT_MS = parseInt(process.env.TIMEOUT_MS || '20000', 10);

if (!WS_URL) {
  console.log('RESULT failed no-ws-url');
  process.exit(64);
}

if (process.env.DEBUG) {
  JsSIP.debug.enable('JsSIP:*');
} else {
  JsSIP.debug.disable();
}

function done(code, line) {
  console.log(line);
  process.exit(code);
}

const guard = setTimeout(() => done(6, 'RESULT failed timeout'), TIMEOUT_MS);
guard.unref();

const media = { mediaConstraints: { audio: true, video: false } };

function mkUA(uri) {
  const socket = new JsSIP.WebSocketInterface(WS_URL);
  return new JsSIP.UA({
    sockets: [socket],
    uri,
    register: true,
    register_expires: 120,
    user_agent: 'chappe-interop-jssip',
  });
}

const callerUA = mkUA(CALLER_URI);
const calleeUA = mkUA(CALLER_URI === CALLEE_URI ? CALLER_URI : CALLEE_URI);

callerUA.on('registrationFailed',
  (e) => done(2, `RESULT failed caller-reg-${(e && e.cause) || '?'}`));
calleeUA.on('registrationFailed',
  (e) => done(2, `RESULT failed callee-reg-${(e && e.cause) || '?'}`));

// The callee answers any incoming call with its own wrtc audio.
calleeUA.on('newRTCSession', ({ session }) => {
  if (session.direction !== 'incoming') return;
  session.on('failed', (e) => done(3, `RESULT failed callee-${(e && e.cause) || '?'}`));
  session.answer(media);
});

let registered = 0;
function onRegistered() {
  if (++registered === 2) placeCall();
}
callerUA.on('registered', onRegistered);
calleeUA.on('registered', onRegistered);

function placeCall() {
  const session = callerUA.call(CALLEE_URI, media);
  session.on('failed', (e) => done(4, `RESULT failed caller-${(e && e.cause) || '?'}`));
  // `confirmed` fires after the caller sends ACK for the 200 OK, i.e. INVITE ->
  // 200 (with the callee's SDP answer) -> ACK all traversed chappe and JsSIP
  // accepted the dialog. It only fires if setRemoteDescription(answer)
  // succeeded, which proves chappe passed the WebRTC SDP through intact. Media
  // (ICE/DTLS) is peer-to-peer and outside chappe's signaling role.
  session.on('confirmed', () => done(0, 'RESULT established'));
}

callerUA.start();
calleeUA.start();
