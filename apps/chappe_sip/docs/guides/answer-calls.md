# Answer calls (UAS)

You answer an inbound dialog-forming request by creating a UAS dialog. The
dialog is a process that is the source of truth for the call; it delivers
in-dialog events (ACK, re-INVITE, INFO, BYE) to your handler as messages. Read
this to accept calls and handle what happens during them.

## When to use it

- You terminate the call in chappe_sip (you are the endpoint), not bridging or
  proxying it elsewhere.
- You want to answer, then react to re-INVITE (hold), INFO, or the peer's BYE.

## Create the dialog

```erlang
ok = chappe_sip:invite(fun(Req, Res) ->
    {ok, Dialog} = chappe_sip:create_uas(Req, Res, #{local_sdp => my_answer_sdp()}),
    run(Dialog)
end).
```

`create_uas/3` sends the dialog-forming 2xx (with the local tag, and a Contact
it adds for you) and returns once the leg is up. Opts: `local_sdp`, `status`
(default 200), `reason`, `headers`, `handled_events`, `owner`, `on_owner_exit`.

## Handle in-dialog events

The dialog sends the owner messages. The simplest loop waits for teardown:

```erlang
run(Dialog) ->
    {destroyed, _ReqOrReason} = chappe_sip_dialog:wait(Dialog).
```

To act on events, receive them directly:

```erlang
run(Dialog) ->
    receive
        {chappe_sip_dialog, Dialog, ack, _Req} ->
            run(Dialog);
        {chappe_sip_dialog, Dialog, {auto_answered, info}, _Req} ->
            run(Dialog);
        {chappe_sip_dialog, Dialog, destroy, _} ->
            {destroyed, byed}
    end.
```

A peer BYE arrives as `destroy` with the BYE request, so you can read its
`Reason` (RFC 3326) with `chappe_sip_req:get(<<"reason">>, Req)`.

In-dialog requests you did not claim with `handled_events` are answered by
the dialog and reported as `{auto_answered, Event}`:

| Request | Answer |
|---|---|
| re-INVITE or UPDATE with an SDP offer | 200 with your current local SDP (the session is unchanged); 488 if the dialog has no local SDP |
| re-INVITE without SDP | 200 with your local SDP as the offer; the answer in the ACK becomes the remote SDP |
| UPDATE without SDP, INFO, NOTIFY, MESSAGE | 200 |
| OPTIONS | 200 with Allow, Accept and Supported |
| REFER | 603 |
| REGISTER, PUBLISH | 405 with Allow |
| any other method | 501 with Allow |

Whether claimed or not, the dialog keeps `chappe_sip_dialog:remote_sdp/1` (the
peer's SDP) and `chappe_sip_dialog:local_sdp/1` (yours) up to date across
re-INVITE, UPDATE and ACK, and applies the overlap rules of
RFC 3261 14.2 and RFC 3311 5.2: an INVITE arriving while your own re-INVITE is
pending gets 491, and an INVITE or UPDATE arriving before you answered the
previous one gets 500 with Retry-After.

Out of dialog, a method you registered no handler for is answered by the
stack: OPTIONS gets 200 with Allow, Accept, Supported (and Allow-Events when
you gave `chappe_sip:subscribe/2` a package list), a method it knows gets 405
and any other 501, both with Allow. Register `chappe_sip:options/1` to answer
OPTIONS yourself.

## Drive the dialog

```erlang
{ok, RemoteSdp} = chappe_sip_dialog:modify(Dialog, hold),      %% re-INVITE, hold
{ok, RemoteSdp2} = chappe_sip_dialog:modify(Dialog, unhold),
{ok, _Msg} = chappe_sip_dialog:request(Dialog, #{method => <<"INFO">>,
                                           content_type => <<"application/dtmf">>,
                                           body => <<"1">>}),
ok = chappe_sip_dialog:destroy(Dialog).                        %% send BYE
```

Put a Reason (RFC 3326), or any header, on the BYE:

```erlang
ok = chappe_sip_dialog:destroy(Dialog, #{headers => [{<<"Reason">>, <<"Q.850;cause=16">>}]}).
```

The dialog keeps RFC 3261 timing for you:

- `destroy/1` before the caller has ACKed your 200 holds the BYE until the
  ACK arrives (RFC 3261 15). If no ACK comes within 64*T1 (32 s), the dialog
  sends the BYE itself and you get `destroy` with reason `no_ack`.
- `destroy/1` on a dialog you created with a provisional `status` (still
  ringing) answers the INVITE 480 instead of sending a BYE.
- `modify/2` while an INVITE from the peer is still open (unanswered, or
  answered 2xx and not yet ACKed) waits for it to finish (RFC 3261 14.1).
- A 481 or 408 to one of your in-dialog requests ends the dialog: you get
  `destroy` with reason `{request_failed, Status}`.
- A peer BYE while you hold a claimed re-INVITE or UPDATE answers it 487
  first.

If the peer re-INVITEs at the same moment you do, your re-INVITE gets 491.
Ask for the RFC 3261 14.1 retry (once, after 2.1 to 4 s if you placed the call,
0 to 2 s otherwise):

```erlang
{ok, RemoteSdp} = chappe_sip_dialog:modify(Dialog, hold, #{retry_on_glare => true}).
```

Without it, or on a second 491, you get
`{error, #chappe_sip_error{status = 491}}` and the session is unchanged.

## Handle a CANCEL

While your handler has not sent a final response, a CANCEL of the INVITE
arrives as `{chappe_sip_cancel, TxnH, CancelReq}`. `CancelReq` is the CANCEL
request, so its Reason is readable. Answer the INVITE with 487:

```erlang
receive
    {chappe_sip_cancel, _TxnH, CancelReq} ->
        _Reason = chappe_sip_req:get(<<"reason">>, CancelReq),
        chappe_sip_res:send(Res, 487)
end.
```

## Structured handlers

For anything beyond a trivial loop, use the `chappe_sip_handler` behaviour. It maps
dialog events to callbacks.

```erlang
-module(my_call).
-behaviour(chappe_sip_handler).
-export([init/1, handle_dialog/4, terminate/2]).

init(Req) ->
    {answer, #{local_sdp => answer_for(Req)}, #{started => now_ms()}}.

handle_dialog(ack, _Req, _Res, S)  -> {ok, S};
handle_dialog(info, _Req, Res, S)  -> chappe_sip_res:send(Res, 200), {ok, S};
handle_dialog(_Ev, _Req, _Res, S)  -> {ok, S}.

terminate(_Reason, _S) -> ok.
```

Start it from the method handler:

```erlang
ok = chappe_sip:invite(fun(Req, Res) -> chappe_sip_handler:start(my_call, Req, Res) end).
```

`init/1` returns `{answer, Opts, State}`, `{reject, Status, State}`, or
`{ignore, State}`. A `handle_dialog` callback returns `{ok, State}` or
`{stop, State}` (which sends BYE).

## Match an INVITE with Replaces

An INVITE carrying a `Replaces` header (RFC 3891) asks you to swap one of your
dialogs for the new one: attended transfer, call pickup, or a conference bridge
taking over a leg. `chappe_sip:replaces_response/1` finds the dialog it names
and applies the RFC 3891 section 3 rules for you:

```erlang
Auth = #{realm => <<"example.com">>, secret => fun my_users:password/1},
ok = chappe_sip:invite(fun(Req, Res) ->
    case chappe_sip:replaces_response(Req, #{auth => Auth}) of
        no_replaces ->
            {ok, _Dlg} = chappe_sip:create_uas(Req, Res, #{local_sdp => Sdp});
        {reject, Status} ->
            chappe_sip_res:send(Res, Status);
        {reject, 401, Headers} ->
            chappe_sip_res:send(Res, 401, #{headers => Headers});
        {accept, Old, _Info} ->
            {ok, _New} = chappe_sip:create_uas(Req, Res, #{local_sdp => Sdp}),
            ok = chappe_sip_dialog:destroy(Old)
    end
end).
```

It answers 400 for two Replaces headers, a malformed one, one on a request
other than INVITE, or one alongside Join; 481 when no dialog matches or the
match is an early dialog you did not originate; 603 when the dialog is being
torn down; 486 for a confirmed dialog and the `early-only` flag. On `accept`,
`destroy/1` sends a BYE for a confirmed dialog and a CANCEL for your own
ringing call. For the raw match, use `chappe_sip:find_replaced/1`.

RFC 3891 section 8 accepts a replacement only from a peer that is
authenticated and authorized, so a match is refused with `{reject, 403}`
unless you say who may replace. `replaces_response/1` has no policy and
refuses every match. With `auth => #{realm, secret}` (the registrar's digest
options), a Replaces with no or wrong credentials gets
`{reject, 401, Headers}` (the challenge to send), and an authenticated one is
accepted. Checking the sender may replace that particular dialog is your
`authorize` policy; it is asked only when the match would be accepted, after
digest when you use both, and a `false` gives `{reject, 403}` with the old
dialog left alone:

```erlang
Authorize = fun(Old, Req) -> referred_by_peer(Old, Req) end,
case chappe_sip:replaces_response(Req, #{authorize => Authorize}) of
    {reject, Status} -> chappe_sip_res:send(Res, Status);
    Other -> handle(Other)
end.
```

A Referred-By naming the party being replaced, or an authenticated identity
equal to it, are the grounds the RFC gives.

To look a dialog up by identity yourself, use
`chappe_sip:find_dialog(CallId, LocalTag, RemoteTag)`, where `LocalTag` is the
tag you put in the dialog.

To send a Replaces, build the value and add it as a header, or escape it into
a Refer-To URI for a REFER:

```erlang
Value = chappe_sip_hdr:replaces_value(#{call_id => CallId, to_tag => PeerTag,
                                        from_tag => MyTag}),
ReferTo = <<"<sip:bridge@example.org?Replaces=",
            (chappe_sip_hdr:escape(Value))/binary, ">">>.
```

A REFER target read the other way: `chappe_sip_hdr:refer_to_replaces(ReferTo)`.

Notes:

- The recipient's view decides the tags: `to-tag` is the recipient's local
  tag, `from-tag` the recipient's peer. When you send a Replaces, `to_tag` is
  the tag of the UA you send it to.
- Only dialogs chappe_sip created are indexed: UAS dialogs, UAC dialogs, and
  the early dialogs of a UAC call still ringing (one per tagged provisional).
- Your INVITEs and their 2xx carry `Supported: replaces`, and an INVITE with
  `Require: replaces` is accepted.
- Authorize the request (RFC 3891 section 6) before acting on a match.

## Accept an extension in Require

An INVITE (or an in-dialog request) listing an option tag you do not support
in `Require` gets 420 with `Unsupported` before your handler runs (RFC 3261
8.2.2.3). ACK and CANCEL are never refused for it, and `Proxy-Require` is
ignored. The tags taken everywhere are `supported_option_tags` (`100rel`,
`replaces`, `timer`, `tdialog`, `norefersub`). A recording server (SRS) takes
the SRC's `Require: siprec` (RFC 7866 6.1.1) on its own route:

```erlang
ok = chappe_sip:handle(<<"INVITE">>, fun(Req, Res) ->
    {ok, _} = chappe_sip:create_uas(Req, Res, #{local_sdp => Sdp})
end, #{option_tags => [<<"siprec">>]}).
```

The dialog the route creates takes the same tags in its in-dialog requests.
Any method takes the same option, and adding the tag to
`supported_option_tags` accepts it on every route.

## Dialog behaviour in detail

- Dialogs as processes: `chappe_sip_dialog:destroy/1,2` (headers such as a
  Reason on the BYE), `modify/2,3` (re-INVITE, including `hold`/`unhold`, with
  an optional RFC 3261 14.1 retry after 491), `request/2` (INFO/REFER/UPDATE).
  `hold` marks each live stream sendonly (inactive when it was recvonly) and
  `unhold` reverses it, stream by stream, with the next o= version. A
  provisional to our re-INVITE keeps its transaction open until the final.
  An early dialog our 18x formed (`create_uas/3` with a 1xx `status`) takes
  UPDATE both ways, and the caller's BYE in it gets 200 and its INVITE 487.
  Each early dialog of an INVITE we send (a 101..199 with a new To tag) is a
  dialog handle too, reported as `{early_dialog, Dialog}` just before its
  provisional: the callee's UPDATE and INFO in it are delivered or answered
  as in a confirmed dialog, its BYE gets 200 and ends that dialog (the
  INVITE still completes with its final), and `request/2` sends UPDATE or
  INFO in it, sharing the INVITE's CSeq counter with the PRACKs. `destroy/1`
  on it CANCELs the INVITE, `modify/2` returns `{error, early}`. The 2xx
  with its To tag confirms the same handle (route set and remote target
  taken again from the 2xx, RFC 3261 13.2.2.4); the other early dialogs end
  on the INVITE's final, their owner getting `destroy` with reason
  `{early_ended, Status}`.
  Unclaimed in-dialog requests are answered by the dialog: offers in re-INVITE
  and UPDATE with the current local SDP (488 without one), an offerless
  re-INVITE with our SDP as the offer (answer taken from the ACK), REFER 603,
  unknown methods 501 and REGISTER/PUBLISH 405 (both with Allow), OPTIONS 200
  with Allow/Accept/Supported. `remote_sdp/1` and `local_sdp/1` track re-INVITE, UPDATE and ACK.
  Glare gets 491 and overlapping INVITE/UPDATE 500 with Retry-After (RFC 3261
  14.2, RFC 3311 5.2).
- Reason (RFC 3326): on the BYE via `chappe_sip_dialog:destroy/2`, on a
  CANCEL via `chappe_sip_uac:cancel/2`; a received CANCEL reaches the INVITE
  handler as `{chappe_sip_cancel, TxnH, CancelReq}` and a received BYE as the
  `destroy` event's request.

## Behaviour changes

- `chappe_sip:replaces_response/1,2` no longer accepts a Replaces by
  default: a match that would be accepted is `{reject, 403}` unless you
  pass `authorize => fun((Dialog, Req) -> boolean())` or
  `auth => #{realm, secret}` (RFC 3891 section 8). With `auth`, it can also
  return `{reject, 401, Headers}`; send those headers with the 401. To keep
  the old behaviour on a closed network, pass
  `#{authorize => fun(_, _) -> true end}`.
- A CANCEL of an INVITE you answered 1xx with `create_uas/3` ends that
  early dialog: its owner gets `{chappe_sip_dialog, D, destroy, cancel}`.

## Notes

- The dialog fsm monitors its owner; if your handler crashes, the dialog is torn
  down (BYE) by default (`on_owner_exit => destroy`).
- A long call is fine: the worker is not bounded by the handler deadline once it
  owns a dialog. See [Configuration](configuration.md).

## Where it lives

- Modules: `chappe_sip` (`create_uas/3`, `find_replaced/1`,
  `replaces_response/1,2`), `chappe_sip_dialog`, `chappe_sip_dialog_fsm`,
  `chappe_sip_handler`, `chappe_sip_request_worker`, `chappe_sip_res`,
  `chappe_sip_req`, `chappe_sip_dialog_index`.
- Tests: `chappe_sip_core_SUITE`, `chappe_sip_uas_SUITE`,
  `chappe_sip_indialog_SUITE`, `chappe_sip_dialog_ops_SUITE`,
  `chappe_sip_handler_SUITE`, `chappe_sip_replaces_SUITE`,
  `chappe_sip_dialog_fsm_tests`.
- Lab: `make interop-conformance` (`apps/chappe_sip/interop/conformance`).
