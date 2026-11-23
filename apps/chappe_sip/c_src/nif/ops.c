/*
 * ops.c - the op queue and the NIFs that feed it.
 *
 * Copyright 2026 Benoit Chesneau
 * SPDX-License-Identifier: Apache-2.0
 *
 * A NIF checks its arguments, copies them into an op and enqueues it
 * (enqueue, under the root read lock); op_cb runs it on the stack thread.
 * See "Threads" and the op dispatcher and NIF boundary rows of "Risky
 * regions" in docs/design/engine.md.
 */

#include "engine.h"

/* the request carries a body (for an INVITE: an offer) */
static int request_has_body(nta_incoming_t *irq) {
    msg_t *m = nta_incoming_getrequest(irq);
    sip_t const *sip = sip_object(m);
    int ok = sip && sip->sip_payload && sip->sip_payload->pl_len > 0;
    if (m) msg_destroy(m);
    return ok;
}

/* the request supports or requires 100rel (RFC 3262 3) */
static int peer_rel100(nta_incoming_t *irq) {
    msg_t *m = nta_incoming_getrequest(irq);
    sip_t const *sip = sip_object(m);
    int ok = sip && ((sip->sip_require &&
                      sip_has_feature(sip->sip_require, "100rel")) ||
                     (sip->sip_supported &&
                      sip_has_feature(sip->sip_supported, "100rel")));
    if (m) msg_destroy(m);
    return ok;
}

/* ---------- op execution (stack thread) ---------- */

static void op_free_payload(op_t *op);

/* The op's raw bytes as a parsed message, NULL when they do not parse.
 * raw_len is capped by max_message_size (at most MAX_MSG_SIZE), so it fits
 * the ssize_t msg_make takes. */
static msg_t *op_msg(const op_t *op) {
    msg_t *m = msg_make(sip_default_mclass(), 0, op->raw,
                        (ssize_t)op->raw_len);
    if (m && msg_has_error(m)) {
        msg_destroy(m);
        return NULL;
    }
    return m;
}

/* Set the local tag of a server transaction (the To-tag of a
 * dialog-forming response). A failure is logged: the response still goes
 * out, as it did before the tag was asked for. */
static void op_tag(engine_t *e, nta_incoming_t *irq, const op_t *op) {
    if (op->to_tag[0] && !nta_incoming_tag(irq, op->to_tag))
        shim_warn(e, "nta_incoming_tag failed for transaction %llu",
                  (unsigned long long)op->h);
}

static void op_reliable_1xx(engine_t *e, const op_t *op) {
    /* send a reliable provisional (100rel). nta owns RSeq/RAck,
     * retransmit and PRACK matching; prack_cb fires when the PRACK
     * arrives. The incoming handle must survive to the final. */
    nta_incoming_t *irq = tab_get(e, op->h, H_INCOMING);
    obj_ctx_t *ctx = tab_get_ctx(e, op->h, H_INCOMING);
    if (!irq || !ctx) {
        send_op_failed(e, op->h, "unknown transaction");
        return;
    }
    op_tag(e, irq, op);
    if (!peer_rel100(irq)) {
        /* RFC 3261 8.2.4: the caller did not offer 100rel, so the
         * provisional goes out on baseline SIP, unreliably */
        if (nta_incoming_treply(
                irq, op->status, op->reason[0] ? op->reason : NULL,
                TAG_IF(op->headers, SIPTAG_HEADER_STR(op->headers)),
                TAG_IF(op->body, SIPTAG_PAYLOAD_STR(op->body)),
                TAG_END()) < 0)
            send_op_failed(e, op->h, "treply failed");
        return;
    }
    int has_body = op->body && op->body[0];
    int offerless = ctx->rel_offer == 0 && !request_has_body(irq);
    if (offerless && !has_body) {
        /* RFC 3262 5: the first reliable 1xx to an INVITE without an
         * offer carries one */
        send_op_failed(e, op->h, "reliable 1xx needs the offer");
        return;
    }
    nta_reliable_t *rel = nta_reliable_treply(
        irq, prack_cb, (nta_reliable_magic_t *)ctx,
        op->status, op->reason[0] ? op->reason : NULL,
        TAG_IF(op->headers, SIPTAG_HEADER_STR(op->headers)),
        TAG_IF(op->body, SIPTAG_PAYLOAD_STR(op->body)), TAG_END());
    if (!rel) {
        send_op_failed(e, op->h, "nta_reliable_treply failed");
    } else {
        ctx->rel = 1;
        if (offerless) ctx->rel_offer = 1;
    }
}

/* The listen address a send names, as the engine's own copy of its ident.
 * nta keeps the TPTAG_IDENT pointer in the transaction (orq_tpn) and uses
 * it again, after this op is freed, to send the ACK of a non-2xx final
 * and a CANCEL: the op's buffer would dangle and the ACK find no
 * transport (RFC 3261 17.1.1.3). The engine's idents live as long as the
 * agent. NULL with *unknown = 0: none asked for, or a single address;
 * NULL with *unknown = 1: no listen address has that ident. */
static const char *op_ident(const engine_t *e, const op_t *op,
                            int *unknown) {
    *unknown = 0;
    if (!op->ident[0] || !e->has_idents) return NULL;
    if (strcmp(op->ident, e->ident) == 0) return e->ident;
    for (int i = 0; i < e->nx; i++)
        if (strcmp(op->ident, e->xident[i]) == 0) return e->xident[i];
    if (strcmp(op->ident, e->tls_ident) == 0) return e->tls_ident;
    for (int i = 0; i < e->ntlsx; i++)
        if (strcmp(op->ident, e->tls_xident[i]) == 0) return e->tls_xident[i];
    *unknown = 1;
    return NULL;
}

static void op_request(engine_t *e, const op_t *op) {
    msg_t *m = op_msg(op);
    if (!m) {
        send_op_failed(e, op->h, "unparseable request");
        return;
    }
    obj_ctx_t *ctx = enif_alloc(sizeof *ctx);
    if (!ctx) {
        msg_destroy(m);
        send_op_failed(e, op->h, "alloc failed");
        return;
    }
    memset(ctx, 0, sizeof *ctx);
    ctx->e = e;
    ctx->h = op->h;
    url_string_t *route =
        op->route ? URL_STRING_MAKE(op->route) : NULL;
    /* RFC 5626 5.3: a request for a flow goes over that connection */
    tport_t *ftp = NULL;
    if (op->flow) {
        flow_t *f = tab_get(e, op->flow, H_FLOW);
        if (!f) {
            msg_destroy(m);
            enif_free(ctx);
            send_op_failed(e, op->h, "unknown flow");
            return;
        }
        ftp = f->tp;
    }
    int unknown;
    const char *ident = op_ident(e, op, &unknown);
    if (unknown) {
        msg_destroy(m);
        enif_free(ctx);
        send_op_failed(e, op->h, "unknown local address");
        return;
    }
    /* A proxy branch (one with our loop-detection branch) of an INVITE
     * is created outside UA mode: a UA client transaction ACKs and BYEs
     * a second 2xx with another To-tag itself, while a proxy forwards
     * every 2xx upstream (RFC 3261 16.7 step 10, RFC 6026). The agent
     * flag is read once, at creation, and only this thread touches it. */
    sip_t const *rsip = sip_object(m);
    int proxy_inv = op->branch[0] && rsip && rsip->sip_request &&
                    rsip->sip_request->rq_method == sip_method_invite;
    if (proxy_inv &&
        nta_agent_set_params(e->agent, NTATAG_UA(0), TAG_END()) < 0)
        shim_warn(e, "nta_agent_set_params(UA 0) failed");
    nta_outgoing_t *orq = nta_outgoing_mcreate(
        e->agent, outgoing_response_cb, (nta_outgoing_magic_t *)ctx,
        route, m, TAG_IF(op->branch[0], NTATAG_BRANCH_KEY(op->branch)),
        TAG_IF(ftp, NTATAG_TPORT(ftp)), TAG_IF(ident, TPTAG_IDENT(ident)),
        TAG_END());
    if (proxy_inv &&
        nta_agent_set_params(e->agent, NTATAG_UA(1), TAG_END()) < 0)
        shim_warn(e, "nta_agent_set_params(UA 1) failed");
    if (!orq) {
        /* nta owns/destroys msg only on success */
        msg_destroy(m);
        enif_free(ctx);
        send_op_failed(e, op->h, "nta_outgoing_mcreate failed");
        return;
    }
    if (tab_put_id(e, op->h, H_OUTGOING, orq, ctx) != 0) {
        nta_outgoing_destroy(orq);
        enif_free(ctx);
        send_op_failed(e, op->h, "alloc failed");
        return;
    }
    const char *br = proxy_inv ? nta_outgoing_branch(orq) : NULL;
    size_t brl = br ? strlen(br) : 0;
    if (br && brl >= sizeof ctx->px_branch)
        shim_warn(e, "proxy branch of %llu too long to track",
                  (unsigned long long)op->h);
    if (br && brl < sizeof ctx->px_branch) {
        /* a proxy INVITE branch: a later 2xx of it may match no
         * transaction (stray_cb) */
        memcpy(ctx->px_branch, br, brl + 1);
        ctx->px = 1;
        ctx->px_next = e->px_head;
        if (e->px_head) e->px_head->px_prev = ctx;
        e->px_head = ctx;
    }
    send_op_ok(e, op->h);
}

/* fire-and-forget send (ACK to a 2xx). Create the outgoing transaction to
 * put the message on the wire, then destroy it immediately: an ACK gets no
 * response. mcreate queues the message on the transport before returning. */
static void op_send(engine_t *e, const op_t *op) {
    msg_t *m = op_msg(op);
    if (!m) {
        send_op_failed(e, op->h, "unparseable message");
        return;
    }
    url_string_t *route = op->route ? URL_STRING_MAKE(op->route) : NULL;
    flow_t *f = op->flow ? tab_get(e, op->flow, H_FLOW) : NULL;
    if (op->flow && !f) {
        msg_destroy(m);
        send_op_failed(e, op->h, "unknown flow");
        return;
    }
    int unknown;
    const char *ident = op_ident(e, op, &unknown);
    if (unknown) {
        msg_destroy(m);
        send_op_failed(e, op->h, "unknown local address");
        return;
    }
    nta_outgoing_t *orq = nta_outgoing_mcreate(
        e->agent, NULL, NULL, route, m,
        TAG_IF(f, NTATAG_TPORT(f ? f->tp : NULL)),
        TAG_IF(ident, TPTAG_IDENT(ident)), TAG_END());
    if (!orq) {
        msg_destroy(m);
        send_op_failed(e, op->h, "nta_outgoing_mcreate (send) failed");
        return;
    }
    nta_outgoing_destroy(orq);
    send_op_ok(e, op->h);
}

static void op_cb(su_root_magic_t *magic, su_msg_r msg, su_msg_arg_t *arg) {
    (void)magic;
    (void)msg;
    op_t *op = (op_t *)arg;
    engine_t *e = op->e;

    switch (op->kind) {
    case OP_HEALTH: {
        orphans_sweep(e, 0);
        flows_sweep(e);
        uint64_t seq = ++e->health_seq;
        send_event(e, mk_health_ev, &seq);
        break;
    }
    case OP_RESPOND: {
        nta_incoming_t *irq = tab_get(e, op->h, H_INCOMING);
        if (!irq) {
            send_op_failed(e, op->h, "unknown transaction");
            break;
        }
        op_tag(e, irq, op);
        int rc = nta_incoming_treply(
            irq, op->status, op->reason[0] ? op->reason : NULL,
            TAG_IF(op->headers, SIPTAG_HEADER_STR(op->headers)),
            TAG_IF(op->body, SIPTAG_PAYLOAD_STR(op->body)), TAG_END());
        if (rc < 0) send_op_failed(e, op->h, "treply failed");
        if (op->status >= 200) {
            obj_ctx_t *ictx = tab_get_ctx(e, op->h, H_INCOMING);
            if (rc >= 0 && op->status < 300 && ictx) {
                /* a 2xx to an INVITE: keep the transaction, its ACK (or
                 * Timer H) reaches the dialog through invite_ack_cancel_cb:
                 * the callee sends no BYE before it (RFC 3261 15) */
                ictx->await_ack = 1;
            } else {
                nta_incoming_destroy(irq);
                tab_del(e, op->h);
            }
        }
        break;
    }
    case OP_RELIABLE_1XX:
        op_reliable_1xx(e, op);
        break;
    case OP_REQUEST:
        op_request(e, op);
        break;
    case OP_LEG_CREATE: {
        obj_ctx_t *ctx = enif_alloc(sizeof *ctx);
        if (!ctx) {
            send_op_failed(e, op->h, "alloc failed");
            break;
        }
        memset(ctx, 0, sizeof *ctx);
        ctx->e = e;
        ctx->h = op->h;
        /* raw = call-id, headers = local (From w/ tag),
         * body = remote (To w/ tag) */
        nta_leg_t *leg = nta_leg_tcreate(
            e->agent, leg_request_cb, (nta_leg_magic_t *)ctx,
            SIPTAG_CALL_ID_STR(op->raw), SIPTAG_FROM_STR(op->headers),
            SIPTAG_TO_STR(op->body), TAG_END());
        if (!leg) {
            enif_free(ctx);
            send_op_failed(e, op->h, "nta_leg_tcreate failed");
            break;
        }
        if (tab_put_id(e, op->h, H_LEG, leg, ctx) != 0) {
            nta_leg_destroy(leg);
            enif_free(ctx);
            send_op_failed(e, op->h, "alloc failed");
            break;
        }
        send_op_ok(e, op->h);
        break;
    }
    case OP_LEG_DESTROY: {
        nta_leg_t *leg = tab_get(e, op->h, H_LEG);
        if (leg) {
            nta_leg_destroy(leg);
            tab_del(e, op->h);
        }
        break;
    }
    case OP_SEND:
        op_send(e, op);
        break;
    case OP_CANCEL: {
        nta_outgoing_t *orq = tab_get(e, op->h, H_OUTGOING);
        if (orq) {
            /* extra headers (a Reason, RFC 3326) ride on the CANCEL */
            nta_outgoing_t *cancel = nta_outgoing_tcancel(
                orq, NULL, NULL,
                TAG_IF(op->headers, SIPTAG_HEADER_STR(op->headers)),
                TAG_END());
            if (cancel) nta_outgoing_destroy(cancel);
        }
        break;
    }
    case OP_DISCARD: {
        /* a request the guard drops: no 100 Trying for its retransmissions
         * while it waits for the silent 408 that ends it */
        nta_incoming_t *irq = tab_get(e, op->h, H_INCOMING);
        if (irq &&
            nta_incoming_set_params(irq, NTATAG_EXTRA_100(0), TAG_END()) < 0)
            shim_warn(e, "nta_incoming_set_params failed for %llu",
                      (unsigned long long)op->h);
        break;
    }
    case OP_TXN_DONE: {
        nta_outgoing_t *orq = tab_get(e, op->h, H_OUTGOING);
        if (orq) {
            nta_outgoing_destroy(orq);
            tab_del(e, op->h);
        }
        break;
    }
    case OP_RELAY: {
        /* proxy: relay a complete downstream response upstream on the
         * server transaction (Via already stripped by the Erlang side) */
        nta_incoming_t *irq = tab_get(e, op->h, H_INCOMING);
        if (!irq) {
            send_op_failed(e, op->h, "unknown transaction");
            break;
        }
        msg_t *m = op_msg(op);
        if (!m) {
            send_op_failed(e, op->h, "unparseable response");
            break;
        }
        int status = op->status;
        if (nta_incoming_mreply(irq, m) < 0)
            send_op_failed(e, op->h, "nta_incoming_mreply failed");
        if (status >= 200) {
            nta_incoming_destroy(irq);
            tab_del(e, op->h);
        }
        break;
    }
    case OP_MSG_TSEND: {
        /* proxy: forward a response statelessly upstream (a forked second
         * 2xx after the server transaction was completed by the first).
         * nta_msg_tsend strips the top Via itself and routes by the next,
         * so the raw MUST still carry the proxy's own top Via. The msg is
         * consumed by nta_msg_tsend even on failure. No op_ok follows; a
         * failure is reported as op_failed. */
        msg_t *m = op_msg(op);
        if (!m) {
            send_op_failed(e, op->h, "unparseable response");
            break;
        }
        /* a response only: for a request nta_msg_tsend makes a stateless
         * transaction and leaks the message when that fails */
        sip_t const *rsip = sip_object(m);
        if (!rsip || !rsip->sip_status) {
            msg_destroy(m);
            send_op_failed(e, op->h, "not a response");
            break;
        }
        /* send_response/2 names no handle, so the log says it too */
        if (nta_msg_tsend(e->agent, m, NULL, TAG_END()) < 0) {
            shim_warn(e, "nta_msg_tsend failed");
            send_op_failed(e, op->h, "nta_msg_tsend failed");
        }
        break;
    }
    case OP_PROXY_MARK: {
        obj_ctx_t *ictx = tab_get_ctx(e, op->h, H_INCOMING);
        if (ictx) ictx->proxied = 1;
        break;
    }
    case OP_STOP:
        su_root_break(e->root);
        break;
    default:
        /* every NIF builds a known kind; one that is not is refused, and
         * its payload is still freed below */
        send_op_failed(e, op->h, "unknown op");
        break;
    }
    op_free_payload(op);
    engine_unref(e);
}

/* Post an op to the stack thread. Caller MUST hold root_lock (read) and have
 * checked e->root != NULL, so su_root_task cannot race a root destroy. */
NODISCARD int enqueue_locked(engine_t *e, const op_t *tpl) {
    su_msg_r msg = SU_MSG_R_INIT;
    if (su_msg_create(msg, su_root_task(e->root), su_task_null, op_cb,
                      sizeof(op_t)) != 0)
        return -1;
    op_t *op = (op_t *)su_msg_data(msg);
    *op = *tpl;
    op->e = e;
    enif_keep_resource(e);
    if (su_msg_send(msg) != 0) {
        engine_unref(e);
        su_msg_destroy(msg);
        return -1;
    }
    return 0;
}

/* Foreign-op enqueue: only while the engine is READY and its root is alive.
 * The read lock blocks the stack thread's root destroy until we are done, and
 * re-checking state under the lock closes the window where an op queued behind
 * OP_STOP would be dropped (leaking its payload + kept ref). */
NODISCARD static int enqueue(engine_t *e, const op_t *tpl) {
    int rc = -1;
    enif_rwlock_rlock(e->root_lock);
    if (e->root != NULL && atomic_load(&e->state) == ST_READY)
        rc = enqueue_locked(e, tpl);
    enif_rwlock_runlock(e->root_lock);
    return rc;
}

/* A binary into an enif_alloc'd NUL-terminated string in *out (NULL for
 * an empty binary). -1 when there is no memory: the caller fails the call
 * rather than send the op without the field. */
NODISCARD static int bin_dup(const ErlNifBinary *b, char **out) {
    size_t n;
    *out = NULL;
    if (b->size == 0) return 0;
    if (chk_add(&n, b->size, (size_t)1)) return -1;
    char *s = enif_alloc(n);
    if (!s) return -1;
    memcpy(s, b->data, b->size);
    s[b->size] = 0;
    *out = s;
    return 0;
}

/* The raw bytes of a message into the op (op->raw, op->raw_len); -1 when
 * there is no memory. An empty message still gets a buffer, which
 * msg_make then refuses. */
NODISCARD static int raw_dup(const ErlNifBinary *b, op_t *op) {
    op->raw = enif_alloc(b->size ? b->size : 1);
    if (!op->raw) return -1;
    if (b->size) memcpy(op->raw, b->data, b->size);
    op->raw_len = b->size;
    return 0;
}

/* free what an op owns; op_cb does it once the op ran, a NIF when the op
 * was never queued */
static void op_free_payload(op_t *op) {
    if (op->headers) enif_free(op->headers);
    if (op->body) enif_free(op->body);
    if (op->raw) enif_free(op->raw);
    if (op->route) enif_free(op->route);
    op->headers = op->body = op->raw = op->route = NULL;
}

/* queue an op that owns a payload: ok, or {error, not_ready} with the
 * payload freed */
static ERL_NIF_TERM enqueue_owned(ErlNifEnv *env, engine_t *e, op_t *op,
                                  ERL_NIF_TERM ok) {
    if (enqueue(e, op) != 0) {
        op_free_payload(op);
        return enif_make_tuple2(env, am_error, am_not_ready);
    }
    return ok;
}

static ERL_NIF_TERM error_enomem(ErlNifEnv *env, op_t *op) {
    op_free_payload(op);
    return enif_make_tuple2(env, am_error, am_enomem);
}

static ERL_NIF_TERM error_too_large(ErlNifEnv *env) {
    return enif_make_tuple2(env, am_error, enif_make_atom(env, "too_large"));
}

/* respond/7 and reliable_respond/7: (Engine, TxnH, Status, Reason,
 * Headers, Body, ToTag) with Status in lo..hi. ToTag (<<>> for none) sets
 * the local dialog tag on a dialog-forming response so the leg the app
 * creates matches subsequent requests. A reason longer than the op holds
 * is cut to fit (it is only text); a to-tag that does not fit is refused,
 * since a cut one would name another dialog. */
static ERL_NIF_TERM nif_reply(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[], int kind,
                              unsigned lo, unsigned hi) {
    engine_t *e;
    ErlNifUInt64 h;
    unsigned status;
    ErlNifBinary reason, headers, body, totag;
    if (argc != 7 || !enif_get_resource(env, argv[0], ENGINE_RT, (void **)&e) ||
        !enif_get_uint64(env, argv[1], &h) ||
        !enif_get_uint(env, argv[2], &status) || status < lo || status > hi ||
        !enif_inspect_binary(env, argv[3], &reason) ||
        !enif_inspect_binary(env, argv[4], &headers) ||
        !enif_inspect_binary(env, argv[5], &body) ||
        !enif_inspect_binary(env, argv[6], &totag) || has_nul(&reason) ||
        has_nul(&headers) || has_nul(&body) || has_nul(&totag) ||
        totag.size >= MAX_TAG)
        return enif_make_badarg(env);

    if (atomic_load(&e->state) != ST_READY)
        return enif_make_tuple2(env, am_error, am_not_ready);

    /* send-side size cap, before any copy */
    if (headers.size > e->max_msg_size ||
        body.size > e->max_msg_size - headers.size)
        return error_too_large(env);

    op_t op = {.kind = kind, .h = h, .status = (int)status};
    size_t rl = reason.size < sizeof op.reason - 1 ? reason.size
                                                   : sizeof op.reason - 1;
    if (rl) memcpy(op.reason, reason.data, rl);
    op.reason[rl] = 0;
    if (bin_cstr(&totag, op.to_tag, sizeof op.to_tag) != 0)
        return enif_make_badarg(env);
    if (bin_dup(&headers, &op.headers) != 0 || bin_dup(&body, &op.body) != 0)
        return error_enomem(env, &op);
    return enqueue_owned(env, e, &op, am_ok);
}

/* respond(Engine, TxnH, Status, Reason, Headers, Body, ToTag) -> ok */
ERL_NIF_TERM nif_respond(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
    return nif_reply(env, argc, argv, OP_RESPOND, 100, 699);
}

/* The route argument of request and send: a URI (no NUL), undefined, or
 * an RFC 5626 flow id. -1 for anything else. */
NODISCARD static int get_route(ErlNifEnv *env, ERL_NIF_TERM t,
                               ErlNifBinary *route, ErlNifUInt64 *flow) {
    route->size = 0;
    *flow = 0;
    if (enif_inspect_binary(env, t, route)) return has_nul(route) ? -1 : 0;
    if (enif_is_identical(t, am_undefined)) return 0;
    if (enif_get_uint64(env, t, flow) && *flow > 0) return 0;
    return -1;
}

/* An ident argument (<<>>: any listen address) into op->ident */
NODISCARD static int get_ident(ErlNifEnv *env, ERL_NIF_TERM t, op_t *op) {
    ErlNifBinary ident;
    return enif_inspect_binary(env, t, &ident) &&
                   bin_cstr(&ident, op->ident, sizeof op->ident) == 0
               ? 0
               : -1;
}

/* request(Engine, Route|FlowId|undefined, Raw[, Branch[, Ident]]) and
 * send(Engine, Route|FlowId|undefined, Raw[, Ident]): a complete
 * Erlang-built message, over the RFC 5626 flow when a flow id is given.
 * {ok, H}; op_ok/op_failed follows. */
static ERL_NIF_TERM send_raw(ErlNifEnv *env, const ERL_NIF_TERM argv[],
                             op_t *op) {
    engine_t *e;
    ErlNifBinary route, raw;
    ErlNifUInt64 flow;
    if (!enif_get_resource(env, argv[0], ENGINE_RT, (void **)&e) ||
        get_route(env, argv[1], &route, &flow) != 0 ||
        !enif_inspect_binary(env, argv[2], &raw))
        return enif_make_badarg(env);
    op->flow = flow;
    if (atomic_load(&e->state) != ST_READY)
        return enif_make_tuple2(env, am_error, am_not_ready);
    if (raw.size > e->max_msg_size) return error_too_large(env);

    op->h = reserve_id();
    /* fail rather than send without the caller's route: dropping it would
     * send the request direct instead of via the route */
    if (raw_dup(&raw, op) != 0 || bin_dup(&route, &op->route) != 0)
        return error_enomem(env, op);
    return enqueue_owned(env, e, op,
                         enif_make_tuple2(env, am_ok,
                                          enif_make_uint64(env, op->h)));
}

/* request/4 takes the Via branch (without NULs, shorter than op.branch);
 * request/5 takes <<>> for none, then the ident of the listen address to
 * send from (<<>>: any) */
ERL_NIF_TERM nif_request(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
    op_t op = {.kind = OP_REQUEST};
    ErlNifBinary branch;
    if (argc < 3 || argc > 5) return enif_make_badarg(env);
    if (argc >= 4 && (!enif_inspect_binary(env, argv[3], &branch) ||
                      (branch.size == 0 && argc == 4) ||
                      bin_cstr(&branch, op.branch, sizeof op.branch) != 0))
        return enif_make_badarg(env);
    if (argc == 5 && get_ident(env, argv[4], &op) != 0)
        return enif_make_badarg(env);
    return send_raw(env, argv, &op);
}

/* reliable_respond(Engine, TxnH, Status, Reason, Headers, Body, ToTag) -> ok
 * Send a reliable provisional (100rel). Status must be 101..199. */
ERL_NIF_TERM nif_reliable_respond(ErlNifEnv *env, int argc,
                                         const ERL_NIF_TERM argv[]) {
    return nif_reply(env, argc, argv, OP_RELIABLE_1XX, 101, 199);
}

/* send(Engine, Route|FlowId|undefined, Raw[, Ident]) -> {ok, OpH}
 * Stateless fire-and-forget send (ACK to a 2xx). op_ok/op_failed follows;
 * no response is delivered. */
ERL_NIF_TERM nif_send(ErlNifEnv *env, int argc,
                             const ERL_NIF_TERM argv[]) {
    op_t op = {.kind = OP_SEND};
    if (argc != 3 && argc != 4) return enif_make_badarg(env);
    if (argc == 4 && get_ident(env, argv[3], &op) != 0)
        return enif_make_badarg(env);
    return send_raw(env, argv, &op);
}

/* relay(Engine, ServerTxnH, Status, Raw) -> ok
 * Proxy: relay a complete downstream response upstream. Status >= 200
 * releases the server transaction. */
ERL_NIF_TERM nif_relay(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
    engine_t *e;
    ErlNifUInt64 h;
    unsigned status;
    ErlNifBinary raw;
    if (argc != 4 || !enif_get_resource(env, argv[0], ENGINE_RT, (void **)&e) ||
        !enif_get_uint64(env, argv[1], &h) ||
        !enif_get_uint(env, argv[2], &status) || status < 100 || status > 699 ||
        !enif_inspect_binary(env, argv[3], &raw))
        return enif_make_badarg(env);
    if (atomic_load(&e->state) != ST_READY)
        return enif_make_tuple2(env, am_error, am_not_ready);
    if (raw.size > e->max_msg_size) return error_too_large(env);

    op_t op = {.kind = OP_RELAY, .h = h, .status = (int)status};
    if (raw_dup(&raw, &op) != 0) return error_enomem(env, &op);
    return enqueue_owned(env, e, &op, am_ok);
}

/* send_response(Engine, Raw) -> ok
 * Statelessly forward a response upstream (forked second 2xx). The raw
 * bytes MUST still carry the proxy's own top Via: nta_msg_tsend strips the
 * top Via itself and routes by the next. Fire-and-forget. */
ERL_NIF_TERM nif_send_response(ErlNifEnv *env, int argc,
                                      const ERL_NIF_TERM argv[]) {
    engine_t *e;
    ErlNifBinary raw;
    if (argc != 2 || !enif_get_resource(env, argv[0], ENGINE_RT, (void **)&e) ||
        !enif_inspect_binary(env, argv[1], &raw))
        return enif_make_badarg(env);
    if (atomic_load(&e->state) != ST_READY)
        return enif_make_tuple2(env, am_error, am_not_ready);
    if (raw.size > e->max_msg_size) return error_too_large(env);

    op_t op = {.kind = OP_MSG_TSEND};
    if (raw_dup(&raw, &op) != 0) return error_enomem(env, &op);
    return enqueue_owned(env, e, &op, am_ok);
}

/* cancel(Engine, TxnH[, Headers]) -> ok  (CANCEL an outstanding INVITE
 * client txn; Headers is a CRLF-joined blob added to the CANCEL) */
ERL_NIF_TERM nif_cancel(ErlNifEnv *env, int argc,
                               const ERL_NIF_TERM argv[]) {
    engine_t *e;
    ErlNifUInt64 h;
    ErlNifBinary headers = {0};
    if ((argc != 2 && argc != 3) ||
        !enif_get_resource(env, argv[0], ENGINE_RT, (void **)&e) ||
        !enif_get_uint64(env, argv[1], &h) ||
        (argc == 3 && (!enif_inspect_binary(env, argv[2], &headers) ||
                       has_nul(&headers))))
        return enif_make_badarg(env);
    if (atomic_load(&e->state) != ST_READY)
        return enif_make_tuple2(env, am_error, am_not_ready);
    if (headers.size > e->max_msg_size) return error_too_large(env);
    op_t op = {.kind = OP_CANCEL, .h = h};
    if (bin_dup(&headers, &op.headers) != 0) return error_enomem(env, &op);
    return enqueue_owned(env, e, &op, am_ok);
}

/* proxy_mark(Engine, TxnH) -> ok  (a proxy owns this INVITE server txn:
 * a CANCEL of it gets no automatic 487) */
ERL_NIF_TERM nif_proxy_mark(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    engine_t *e;
    ErlNifUInt64 h;
    if (argc != 2 || !enif_get_resource(env, argv[0], ENGINE_RT, (void **)&e) ||
        !enif_get_uint64(env, argv[1], &h))
        return enif_make_badarg(env);
    if (atomic_load(&e->state) != ST_READY)
        return enif_make_tuple2(env, am_error, am_not_ready);
    op_t op = {.kind = OP_PROXY_MARK, .h = h};
    if (enqueue(e, &op) != 0)
        return enif_make_tuple2(env, am_error, am_not_ready);
    return am_ok;
}

/* txn_done(Engine, TxnH) -> ok  (release a client transaction handle) */
ERL_NIF_TERM nif_txn_done(ErlNifEnv *env, int argc,
                                 const ERL_NIF_TERM argv[]) {
    engine_t *e;
    ErlNifUInt64 h;
    if (argc != 2 || !enif_get_resource(env, argv[0], ENGINE_RT, (void **)&e) ||
        !enif_get_uint64(env, argv[1], &h))
        return enif_make_badarg(env);
    if (atomic_load(&e->state) != ST_READY)
        return enif_make_tuple2(env, am_error, am_not_ready);
    op_t op = {.kind = OP_TXN_DONE, .h = h};
    if (enqueue(e, &op) != 0)
        return enif_make_tuple2(env, am_error, am_not_ready);
    return am_ok;
}

/* discard(Engine, TxnH) -> ok  (a request the guard drops) */
ERL_NIF_TERM nif_discard(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
    engine_t *e;
    ErlNifUInt64 h;
    if (argc != 2 || !enif_get_resource(env, argv[0], ENGINE_RT, (void **)&e) ||
        !enif_get_uint64(env, argv[1], &h))
        return enif_make_badarg(env);
    if (atomic_load(&e->state) != ST_READY)
        return enif_make_tuple2(env, am_error, am_not_ready);
    op_t op = {.kind = OP_DISCARD, .h = h};
    if (enqueue(e, &op) != 0)
        return enif_make_tuple2(env, am_error, am_not_ready);
    return am_ok;
}

/* block(Addr, TtlMs) -> ok: discard requests from Addr (an IP literal as
 * the engine reports source_ip) for TtlMs; 0 lifts the block */
ERL_NIF_TERM nif_block(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
    ErlNifBinary addr;
    ErlNifUInt64 ttl;
    char a[BLK_ADDR];
    if (argc != 2 || !enif_inspect_binary(env, argv[0], &addr) ||
        addr.size == 0 || bin_cstr(&addr, a, sizeof a) != 0 ||
        !enif_get_uint64(env, argv[1], &ttl))
        return enif_make_badarg(env);
    blk_put(a, ttl);
    return am_ok;
}

/* stats() -> #{incoming, discarded, events_dropped, alloc_failed}: the
 * server transactions held, the requests the blocklist discarded, the
 * events that never reached the owner, and the event binaries that could
 * not be allocated */
ERL_NIF_TERM nif_stats(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    ERL_NIF_TERM keys[] = {am_incoming, am_discarded, am_events_dropped,
                           am_alloc_failed};
    ERL_NIF_TERM vals[] = {
        enif_make_uint64(env, atomic_load(&g_incoming)),
        enif_make_uint64(env, atomic_load(&g_blk_drops)),
        enif_make_uint64(env, atomic_load(&g_events_dropped)),
        enif_make_uint64(env, atomic_load(&g_alloc_failed)),
    };
    static_assert(sizeof keys / sizeof keys[0] == sizeof vals / sizeof vals[0],
                  "one value per key");
    ERL_NIF_TERM map;
    if (!enif_make_map_from_arrays(env, keys, vals,
                                   sizeof keys / sizeof keys[0], &map))
        return enif_make_badarg(env);
    return map;
}

/* a dialog leg field: no NUL, under MAX_LEG_FIELD */
static int leg_field_ok(const ErlNifBinary *b) {
    return !has_nul(b) && b->size < MAX_LEG_FIELD;
}

/* leg_create(Engine, CallId, LocalAddr, RemoteAddr) -> {ok, LegH} */
ERL_NIF_TERM nif_leg_create(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    engine_t *e;
    ErlNifBinary cid, local, remote;
    if (argc != 4 || !enif_get_resource(env, argv[0], ENGINE_RT, (void **)&e) ||
        !enif_inspect_binary(env, argv[1], &cid) ||
        !enif_inspect_binary(env, argv[2], &local) ||
        !enif_inspect_binary(env, argv[3], &remote) || !leg_field_ok(&cid) ||
        !leg_field_ok(&local) || !leg_field_ok(&remote))
        return enif_make_badarg(env);
    if (atomic_load(&e->state) != ST_READY)
        return enif_make_tuple2(env, am_error, am_not_ready);

    op_t op = {.kind = OP_LEG_CREATE, .h = reserve_id()};
    if (bin_dup(&cid, &op.raw) != 0 || bin_dup(&local, &op.headers) != 0 ||
        bin_dup(&remote, &op.body) != 0)
        return error_enomem(env, &op);
    return enqueue_owned(env, e, &op,
                         enif_make_tuple2(env, am_ok,
                                          enif_make_uint64(env, op.h)));
}

/* leg_destroy(Engine, LegH) -> ok */
ERL_NIF_TERM nif_leg_destroy(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[]) {
    engine_t *e;
    ErlNifUInt64 h;
    if (argc != 2 || !enif_get_resource(env, argv[0], ENGINE_RT, (void **)&e) ||
        !enif_get_uint64(env, argv[1], &h))
        return enif_make_badarg(env);
    if (atomic_load(&e->state) != ST_READY)
        return enif_make_tuple2(env, am_error, am_not_ready);
    op_t op = {.kind = OP_LEG_DESTROY, .h = h};
    if (enqueue(e, &op) != 0)
        return enif_make_tuple2(env, am_error, am_not_ready);
    return am_ok;
}

ERL_NIF_TERM nif_health(ErlNifEnv *env, int argc,
                               const ERL_NIF_TERM argv[]) {
    engine_t *e;
    if (argc != 1 || !enif_get_resource(env, argv[0], ENGINE_RT, (void **)&e))
        return enif_make_badarg(env);
    if (atomic_load(&e->state) != ST_READY)
        return enif_make_tuple2(env, am_error, am_not_ready);
    op_t op = {.kind = OP_HEALTH};
    if (enqueue(e, &op) != 0)
        return enif_make_tuple2(env, am_error, am_not_ready);
    return am_ok;
}
