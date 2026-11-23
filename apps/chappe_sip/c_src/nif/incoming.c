/*
 * incoming.c - the sofia callbacks for what arrives.
 *
 * Copyright 2026 Benoit Chesneau
 * SPDX-License-Identifier: Apache-2.0
 *
 * request_in takes a request no dialog leg took, deliver_request hands
 * any request to Erlang, and the transaction callbacks report ACK,
 * CANCEL, PRACK, responses and stray 2xx. Stack thread only. See "Shape"
 * and the Request intake and Stray 2xx rows of "Risky regions" in
 * docs/design/engine.md.
 */

#include "engine.h"

/* PRACK arrived for a reliable provisional. Notify Erlang (routed by the
 * INVITE handle). Without a body nta answers it 200 on our return; with
 * one (an offer, RFC 3262 5) the answer is the app's, so the PRACK gets a
 * handle and its 2xx goes out through OP_RESPOND. nta still matches a
 * PRACK for a response it already saw PRACKed: that one gets 481 (3). */
int prack_cb(nta_reliable_magic_t *magic, nta_reliable_t *rel,
                    nta_incoming_t *prack, sip_t const *sip) {
    (void)rel;
    obj_ctx_t *ctx = (obj_ctx_t *)magic;
    engine_t *e = ctx->e;
    if (prack && sip && sip->sip_rack) {
        uint32_t rseq = sip->sip_rack->ra_response;
        if (ctx->rel_acked && rseq <= ctx->rel_acked) {
            nta_incoming_treply(prack, SIP_481_NO_TRANSACTION, TAG_END());
            return 0;
        }
        ctx->rel_acked = rseq;
    }
    uint64_t ph = 0;
    int body = prack && sip && sip->sip_payload && sip->sip_payload->pl_len > 0;
    if (body && ctx->rel_offer == 1) {
        /* the answer to the offer our reliable 1xx made: nta says 200 */
        ctx->rel_offer = 2;
    } else if (body) {
        ph = tab_put(e, H_INCOMING, prack, NULL);
        if (ph == 0) {
            nta_incoming_treply(prack, SIP_500_INTERNAL_SERVER_ERROR,
                                TAG_END());
            return 0;
        }
    }
    char *raw = NULL;
    size_t raw_len = 0;
    msg_t *req = prack ? nta_incoming_getrequest(prack) : NULL;
    if (req) {
        raw = msg_as_string(e->home, req, NULL, 0, &raw_len);
        msg_destroy(req);
    }
    struct prack_ev p = {ctx->h, ph, raw, raw_len};
    send_event(e, mk_prack_ev, &p);
    if (raw) su_free(e->home, raw);
    /* 0 keeps the PRACK transaction for the app's answer; 200 has nta
     * answer it and destroy its incoming txn */
    return ph ? 0 : 200;
}

/* ---------- incoming requests (stack thread) ---------- */

/* the ACK or CANCEL the callback is running for, as text (caller frees) */
static char *ackcancel_raw(engine_t *e, nta_incoming_t *irq, size_t *len) {
    char *raw = NULL;
    msg_t *m = nta_incoming_getrequest_ackcancel(irq);
    *len = 0;
    if (m) {
        raw = msg_as_string(e->home, m, NULL, 0, len);
        msg_destroy(m);
    }
    return raw;
}

/* ACK or CANCEL hitting a bound INVITE server transaction */
static int invite_ack_cancel_cb(nta_incoming_magic_t *magic,
                                nta_incoming_t *irq, sip_t const *sip) {
    obj_ctx_t *ctx = (obj_ctx_t *)magic;
    engine_t *e = ctx->e;
    if (!sip) {
        /* timer H: a 2xx we kept for its ACK was never acknowledged; the
         * dialog ends the session (RFC 3261 13.3.1.4, 14.2) */
        if (ctx->await_ack) {
            uint64_t h = ctx->h;
            /* named like the ACK would be: the leg, or this transaction */
            uint64_t target = ctx->leg ? ctx->leg : h;
            send_event(e, mk_ack_timeout_ev, &target);
            nta_incoming_destroy(irq);
            tab_del(e, h);
        }
        return 0;
    }
    if (sip->sip_request &&
        sip->sip_request->rq_method == sip_method_cancel) {
        /* the CANCEL itself goes up too: its Reason (RFC 3326) is the app's */
        struct cancel_ev c = {ctx->h, NULL, 0};
        c.raw = ackcancel_raw(e, irq, &c.raw_len);
        send_event(e, mk_cancel_ev, &c);
        if (c.raw) su_free(e->home, c.raw);
        /* nta's automatic 487 is off (NTATAG_CANCEL_487(0)): a UAS answers
         * the INVITE 487 here, as nta would on our return; a proxied INVITE
         * waits for its branches (RFC 3261 16.10), whose 487, or a 2xx that
         * crossed the CANCEL, is relayed upstream */
        if (!ctx->proxied)
            nta_incoming_treply(irq, SIP_487_REQUEST_CANCELLED, TAG_END());
    } else if (sip->sip_request &&
               sip->sip_request->rq_method == sip_method_ack &&
               ctx->await_ack) {
        /* UA mode matches the 2xx ACK to its INVITE transaction; hand it
         * to the dialog (it may carry the SDP answer) and release the
         * transaction. A re-INVITE names its dialog leg; the leg of a
         * dialog-forming INVITE is made later, from Erlang, which maps
         * this transaction to the dialog instead. The ctx is freed by
         * tab_del, so read it first. */
        uint64_t h = ctx->h;
        struct ack_ev a = {ctx->leg ? ctx->leg : h, NULL, 0};
        a.raw = ackcancel_raw(e, irq, &a.raw_len);
        send_event(e, mk_ack_ev, &a);
        if (a.raw) su_free(e->home, a.raw);
        nta_incoming_destroy(irq);
        tab_del(e, h);
    }
    /* ACK for a non-2xx final is absorbed here; nothing to tell Erlang.
     * Returning 0 lets nta do its default handling. */
    return 0;
}

/* shared for the default leg (dialog_leg_h == 0) and dialog legs */
static int deliver_request(engine_t *e, uint64_t leg_h, nta_incoming_t *irq,
                           sip_t const *sip) {
    if (atomic_load(&e->state) != ST_READY) return 503;
    if (!sip || !sip->sip_request) return 400;

    sip_method_t method = sip->sip_request->rq_method;
    if (method == sip_method_ack) {
        /* 2xx ACK reaches a dialog leg without a server transaction */
        char *raw = NULL;
        size_t raw_len = 0;
        msg_t *req = irq ? nta_incoming_getrequest(irq) : NULL;
        if (req) {
            raw = msg_as_string(e->home, req, NULL, 0, &raw_len);
            msg_destroy(req);
        }
        struct ack_ev a = {leg_h, raw, raw_len};
        send_event(e, mk_ack_ev, &a);
        if (raw) su_free(e->home, raw);
        return 0;
    }

    obj_ctx_t *ictx = NULL;
    if (method == sip_method_invite) {
        ictx = enif_alloc(sizeof *ictx);
        if (!ictx) return 503;
        memset(ictx, 0, sizeof *ictx);
    }

    uint64_t h = tab_put(e, H_INCOMING, irq, ictx);
    if (h == 0) {
        if (ictx) enif_free(ictx);
        return 503;
    }

    if (ictx) {
        ictx->e = e;
        ictx->h = h;
        ictx->leg = leg_h;
        ictx->await_ack = 0;
        ictx->proxied = 0;
        ictx->rel = 0;
        ictx->rel_acked = 0;
        ictx->rel_offer = 0;
        ictx->next_orphan = NULL;
        nta_incoming_bind(irq, invite_ack_cancel_cb,
                          (nta_incoming_magic_t *)ictx);
        /* RFC 3261 17.2.1: 100 Trying unless the TU answers within 200 ms.
         * The TU is an Erlang process we cannot time, and over UDP nta only
         * sends it on a retransmission, so send it now. */
        nta_incoming_treply(irq, SIP_100_TRYING, TAG_END());
    }

    char *raw = NULL;
    size_t raw_len = 0;
    char src_ip[MAX_IP] = {0};
    int src_port = 0;
    msg_t *req = nta_incoming_getrequest(irq);
    if (req) {
        raw = msg_as_string(e->home, req, NULL, 0, &raw_len);
        /* peer address the request was received from (the trust anchor for an
         * SBC ACL); the Via sent-by is spoofable, this is the wire source.
         * An address su_inet_ntop cannot print is "" (unknown), never a
         * partly written buffer. */
        su_addrinfo_t *ai = msg_addrinfo(req);
        if (ai && ai->ai_addr && ai->ai_addrlen) {
            su_sockaddr_t *su = (su_sockaddr_t *)ai->ai_addr;
            if (!su_inet_ntop(su->su_family, SU_ADDR(su), src_ip,
                              sizeof(src_ip)))
                src_ip[0] = 0;
            if (su->su_family == AF_INET6)
                src_port = ntohs(su->su_sin6.sin6_port);
            else
                src_port = ntohs(su->su_sin.sin_port);
        }
        msg_destroy(req);
    }
    /* the transport it came over: a TLS request is record-routed and
     * answered with our sips contact (RFC 5630) */
    char transport[16] = {0};
    uint64_t flow = 0;
    char local_ip[MAX_IP] = {0};
    int local_port = 0;
    char local[MAX_IDENT] = {0};
    {
        tport_t *tp = nta_incoming_transport(e->agent, irq, NULL);
        /* the listen address it arrived on: the bound address of the
         * primary transport (a connection's parent), and its ident */
        tport_t *pri = tp ? tport_parent(tp) : NULL;
        su_addrinfo_t const *la = pri ? tport_get_address(pri) : NULL;
        if (la && la->ai_addr) {
            su_sockaddr_t const *su = (su_sockaddr_t const *)la->ai_addr;
            if (!su_inet_ntop(su->su_family, SU_ADDR(su), local_ip,
                              sizeof local_ip))
                local_ip[0] = 0;
            local_port = ntohs(su->su_port);
        }
        char const *id = tp ? tport_ident(tp) : NULL;
        if (id) (void)snprintf(local, sizeof local, "%s", id);
        /* the connection it came over, as an RFC 5626 flow a later
         * request can be sent back on */
        flow = flow_of(e, tp);
        tp_name_t const *tpn = tp ? tport_name(tp) : NULL;
        if (tpn && tpn->tpn_proto) {
            size_t i;
            for (i = 0; i + 1 < sizeof transport && tpn->tpn_proto[i]; i++)
                transport[i] = (char)tolower((unsigned char)tpn->tpn_proto[i]);
            transport[i] = 0;
        }
        if (tp) tport_unref(tp);
    }

    struct req_ev r = {
        .h = h,
        .leg = leg_h,
        .method = sip->sip_request->rq_method_name,
        .method_len = strlen(sip->sip_request->rq_method_name),
        .raw = raw,
        .raw_len = raw_len,
        .src_port = src_port,
        .flow = flow,
    };
    (void)snprintf(r.src_ip, sizeof(r.src_ip), "%s", src_ip);
    (void)snprintf(r.transport, sizeof(r.transport), "%s", transport);
    (void)snprintf(r.local_ip, sizeof(r.local_ip), "%s", local_ip);
    r.local_port = local_port;
    (void)snprintf(r.local, sizeof(r.local), "%s", local);
    send_event(e, mk_request_ev, &r);
    if (raw) su_free(e->home, raw);
    return 0; /* we own irq now; reply comes via OP_RESPOND */
}

int leg_request_cb(nta_leg_magic_t *magic, nta_leg_t *leg,
                          nta_incoming_t *irq, sip_t const *sip);

/* default leg: out-of-dialog requests.
 * nta never matches a SUBSCRIBE to a dialog leg (it leaves that to nua,
 * which we do not use), so an in-dialog SUBSCRIBE (refresh/unsubscribe,
 * RFC 6665) lands here: hand it to its subscription dialog's leg. */
static int request_cb(nta_leg_magic_t *magic, nta_leg_t *leg,
                      nta_incoming_t *irq, sip_t const *sip) {
    engine_t *e = (engine_t *)magic;
    (void)leg;
    if (sip && sip->sip_request &&
        sip->sip_request->rq_method == sip_method_subscribe &&
        sip->sip_call_id && sip->sip_from && sip->sip_to &&
        sip->sip_to->a_tag) {
        nta_leg_t *dl = nta_leg_by_dialog(e->agent, NULL, sip->sip_call_id,
                                          sip->sip_from->a_tag, NULL,
                                          sip->sip_to->a_tag, NULL);
        obj_ctx_t *ctx = (obj_ctx_t *)nta_leg_magic(dl, leg_request_cb);
        if (ctx) return deliver_request(ctx->e, ctx->h, irq, sip);
    }
    return deliver_request(e, 0, irq, sip);
}

/* dialog legs: in-dialog requests, magic is the per-leg obj_ctx */
int leg_request_cb(nta_leg_magic_t *magic, nta_leg_t *leg,
                          nta_incoming_t *irq, sip_t const *sip) {
    obj_ctx_t *ctx = (obj_ctx_t *)magic;
    (void)leg;
    return deliver_request(ctx->e, ctx->h, irq, sip);
}

/* A request no dialog leg took: out-of-dialog, or for a dialog we do not
 * know. With no default leg nta hands it to the agent callback before any
 * server transaction exists, so a request from a blocked address is
 * discarded for nothing. Any other gets its transaction here and goes the
 * way nta's leg_recv takes a request to a default leg. */
static int request_in(engine_t *e, nta_agent_t *agent, msg_t *msg,
                      sip_t *sip) {
    if (!sip || !sip->sip_request) {
        /* stray_cb checks this; a request without its request line is
         * dropped here too, never read */
        nta_msg_discard(agent, msg);
        return 0;
    }
    if (blk_msg(msg)) {
        atomic_fetch_add(&g_blk_drops, 1);
        nta_msg_discard(agent, msg);
        return 0;
    }
    sip_method_t method = sip->sip_request->rq_method;
    if (method == sip_method_prack) {
        /* RFC 3262 3: a PRACK matching no reliable response */
        nta_msg_treply(agent, msg, 481, "No such response", TAG_END());
        return 0;
    }
    nta_incoming_t *irq = nta_incoming_create(agent, NULL, msg, sip, TAG_END());
    if (!irq) return 0; /* nta took msg */
    int status = request_cb((nta_leg_magic_t *)e, NULL, irq, sip);
    if (status == 0) return 0;
    if (status < 100 || status > 699 ||
        (method == sip_method_invite && status >= 200 && status < 300))
        status = 500;
    if (nta_incoming_status(irq) < 200)
        nta_incoming_treply(irq, status, NULL, TAG_END());
    if (status >= 200) nta_incoming_destroy(irq);
    return 0;
}

/* responses to app-originated requests (nta_outgoing_mcreate) */
int outgoing_response_cb(nta_outgoing_magic_t *magic,
                                nta_outgoing_t *orq, sip_t const *sip) {
    obj_ctx_t *ctx = (obj_ctx_t *)magic;
    engine_t *e = ctx->e;
    int status = nta_outgoing_status(orq);

    char *raw = NULL;
    size_t raw_len = 0;
    if (sip) {
        msg_t *m = nta_outgoing_getresponse(orq);
        if (m) {
            raw = msg_as_string(e->home, m, NULL, 0, &raw_len);
            msg_destroy(m);
        }
    }
    struct resp_ev r = {ctx->h, status, raw, raw_len};
    send_event(e, mk_response_ev, &r);
    if (raw) su_free(e->home, raw);

    /* The transaction handle is NOT destroyed here: for a forking INVITE
     * more than one final (2xx) may arrive, and the Erlang UAC fsm needs
     * the handle to cancel or to signal completion. The fsm calls
     * txn_done (OP_TXN_DONE) when it is finished with the transaction.
     * nta keeps the handle valid until then (absorbing 2xx retransmits,
     * auto-ACKing non-2xx in UA mode). */
    return 0;
}

/* A response that matched no client transaction (the agent message
 * callback). nta ends an INVITE client transaction on a reliable transport
 * at its first final response, so a further 2xx of a proxy branch (another
 * To-tag: a fork downstream) lands here instead of being dropped. While
 * the proxy is in the RFC 6026 Accepted state it still holds that branch's
 * handle: the 2xx goes to it, matched by the Via branch nta gave the
 * branch. Anything else is dropped, as nta would (RFC 6026 6). */
int stray_cb(nta_agent_magic_t *magic, nta_agent_t *agent,
                    msg_t *msg, sip_t *sip) {
    engine_t *e = (engine_t *)magic;
    if (sip && sip->sip_request) return request_in(e, agent, msg, sip);
    if (atomic_load(&e->state) == ST_READY && sip && sip->sip_status &&
        sip->sip_status->st_status >= 200 &&
        sip->sip_status->st_status < 300 && sip->sip_cseq &&
        sip->sip_cseq->cs_method == sip_method_invite && sip->sip_via &&
        sip->sip_via->v_branch) {
        for (obj_ctx_t *c = e->px_head; c; c = c->px_next) {
            if (!su_casematch(c->px_branch, sip->sip_via->v_branch)) continue;
            size_t raw_len = 0;
            char *raw = msg_as_string(e->home, msg, NULL, 0, &raw_len);
            struct resp_ev r = {c->h, sip->sip_status->st_status, raw,
                                raw_len};
            send_event(e, mk_response_ev, &r);
            if (raw) su_free(e->home, raw);
            break;
        }
    }
    msg_destroy(msg);
    return 0;
}
