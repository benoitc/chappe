# Session timers

Session timers (RFC 4028) keep a call from outliving a peer that vanished:
one side refreshes the session with a re-INVITE or UPDATE at half an agreed
interval, and either side sends BYE when no refresh arrives in time. Read this
when you need calls to be cleaned up after a crash, a NAT timeout, or a lost
BYE, or when a peer or proxy insists on a timer.

## When to use it

- A carrier or SBC in the path sends `Session-Expires` and expects refreshes.
- You bill or hold resources per call and want stale calls torn down.
- A peer sends `Require: timer` (chappe_sip accepts it; no 420).

## What you get without configuring anything

- Every request chappe_sip sends (except ACK) carries `Supported: timer`.
- An INVITE that asks for a timer gets it: the 2xx copies `Session-Expires`
  with a `refresher` param, plus `Require: timer` when the caller supports
  timers. An interval below 90 s from a caller that supports timers gets
  `422` with `Min-SE: 90`.
- A 2xx to your INVITE that sets up a timer is honored.
- Your side never asks for a timer.

## Ask for a timer on the calls you answer

```erlang
ok = chappe_sip:invite(fun(Req, Res) ->
    {ok, Dialog} = chappe_sip:create_uas(Req, Res, #{
        local_sdp         => Answer,
        session_expires   => 1800,  %% ask when the caller supports timers
        session_refresher => uac    %% who refreshes when you pick
    }),
    chappe_sip_dialog:wait(Dialog)
end).
```

The 2xx never raises the caller's interval, and may lower it to yours, not
below the caller's `Min-SE`.

## Ask for a timer on the calls you place

```erlang
{ok, Dialog} = chappe_sip:create_uac(<<"sip:bob@10.0.0.2">>, #{
    local_sdp       => Offer,
    session_expires => 1800
}).
```

The INVITE carries `Session-Expires: 1800` without a refresher, so the far
end picks. On a `422` the INVITE is retried with the `Min-SE` it names (same
Call-ID, next CSeq). If the 2xx has no `Session-Expires`, your side
refreshes at the interval it asked for.

## Set it for the whole stack

```erlang
%% sys.config
{chappe_sip, [
    {session_expires, 1800},
    {session_min_se, 90},
    {session_refresher, uac}
]}
```

Call opts (`session_expires`, `min_se`, `session_refresher`) override these.

## What happens during the call

- The refresher sends an UPDATE with no body when the peer listed UPDATE in
  `Allow`, else a re-INVITE with the unchanged SDP, at half the interval.
- A refresh the peer sends is answered with `Session-Expires` (and
  `Require: timer`), whether your code or the dialog answers it.
- With no refresh by `interval - min(32, interval / 3)` seconds, the dialog
  sends BYE and the owner gets
  `{chappe_sip_dialog, Dialog, destroy, session_expired}`.
- A refresh answered `408` or `481` ends the call the same way, with reason
  `{refresh_failed, Status}`. A `422` is retried with the larger interval, a
  `491` after 2.1 to 4 s.

## Notes

- `min_se` below 90 breaks RFC 4028 section 5; use it only in tests.
- 1800 s is the interval RFC 4028 recommends.
- A B2BUA runs a timer on each leg on its own: see the [B2BUA](b2bua.md)
  guide.

## Where it lives

- Modules: `chappe_sip_session_timer` (negotiation), `chappe_sip_dialog_fsm`
  (refresh and expiry).
- Tests: `chappe_sip_session_timer_SUITE`.
- Lab: `make interop-sbc` (a refresh through the SBC).
