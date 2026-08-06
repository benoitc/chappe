// Copyright 2026 Benoit Chesneau
// SPDX-License-Identifier: Apache-2.0

// Drive a real JsSIP UA through a REGISTER against enki_sipserver over
// WebSocket (RFC 7118). Proves the WS transport, subprotocol negotiation, and
// registrar accept a real browser stack's output.
//
// Node 22's global WebSocket (undici) implements the DOM API JsSIP's built-in
// WebSocketInterface expects (binaryType, on* handlers, the `sip` subprotocol
// argument), so no native websocket adapter is needed.
//
// Config via env:
//   WS_URL     ws://127.0.0.1:<port>/ws   (required)
//   SIP_URI    sip:alice@127.0.0.1        (AOR to register)
//   EXPIRES    60                         (registration expiry, seconds)
//   HOLD_MS    2000                        (stay connected after registering)
//   TIMEOUT_MS 8000                        (overall guard)
//   DEBUG      set to any value for JsSIP wire logs on stderr
//
// Emits one machine-readable line on stdout: `RESULT registered <contact>` or
// `RESULT failed <cause>`. Exit code 0 on success, non-zero otherwise. After
// registering it holds the connection open for HOLD_MS so the caller can
// observe the binding (the flow drop on exit purges it, RFC 5626), then exits
// without unregistering.

const JsSIP = require('jssip');

const WS_URL = process.env.WS_URL;
const SIP_URI = process.env.SIP_URI || 'sip:alice@127.0.0.1';
const EXPIRES = parseInt(process.env.EXPIRES || '60', 10);
const HOLD_MS = parseInt(process.env.HOLD_MS || '2000', 10);
const TIMEOUT_MS = parseInt(process.env.TIMEOUT_MS || '8000', 10);

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

const guard = setTimeout(() => done(4, 'RESULT failed timeout'), TIMEOUT_MS);
guard.unref();

const socket = new JsSIP.WebSocketInterface(WS_URL);
const ua = new JsSIP.UA({
  sockets: [socket],
  uri: SIP_URI,
  register: true,
  register_expires: EXPIRES,
  // enki's registrar does not challenge; a placeholder keeps JsSIP happy if it
  // ever does, without failing an unchallenged flow.
  authorization_user: 'interop',
  password: 'interop',
  user_agent: 'enki-interop-jssip',
});

ua.on('registered', (e) => {
  const contact = e && e.response ? e.response.getHeader('Contact') : '';
  console.log(`RESULT registered ${contact || ''}`.trim());
  // hold the connection so the registrar binding can be observed, then exit
  setTimeout(() => process.exit(0), HOLD_MS);
});

ua.on('registrationFailed', (e) => {
  done(2, `RESULT failed ${(e && e.cause) || 'unknown'}`);
});

ua.on('disconnected', (e) => {
  const reason = e && e.error ? (e.reason || 'error') : 'closed';
  done(3, `RESULT failed disconnected-${reason}`);
});

ua.start();
