/*
 * table.c - the handle table and RFC 5626 flows.
 *
 * Copyright 2026 Benoit Chesneau
 * SPDX-License-Identifier: Apache-2.0
 *
 * Handle ids to nta objects, by kind, with the orphan list and the proxy
 * branch list, and the flows a TCP or TLS request arrived on. Stack
 * thread only, except reserve_id. See "Threads", "Flows (RFC 5626)" and
 * the Handle table and Flows rows of "Risky regions" in
 * docs/design/engine.md.
 */

#include "engine.h"

/* ---------- handle table (stack thread only) ---------- */

/* Fibonacci hashing of the id onto the bucket array: ids are sequential,
 * the multiply spreads them over all buckets */
static unsigned tab_slot(uint64_t id) {
    return (unsigned)((id * 0x9E3779B97F4A7C15ULL) >> 52) & (HBUCKETS - 1);
}

NODISCARD int tab_put_id(engine_t *e, uint64_t id, int kind, void *ptr,
                      void *ctx) {
    hent_t *h = enif_alloc(sizeof(hent_t));
    if (!h) return -1;
    if (kind == H_INCOMING) atomic_fetch_add(&g_incoming, 1);
    unsigned slot = tab_slot(id);
    h->id = id;
    h->kind = kind;
    h->ptr = ptr;
    h->ctx = ctx;
    h->next = e->handles[slot];
    e->handles[slot] = h;
    return 0;
}

/* forward: single id space shared with caller-reserved ids */
uint64_t reserve_id(void);

NODISCARD uint64_t tab_put(engine_t *e, int kind, void *ptr,
                                  void *ctx) {
    uint64_t id = reserve_id();
    if (tab_put_id(e, id, kind, ptr, ctx) != 0) return 0;
    return id;
}

void *tab_get(engine_t *e, uint64_t id, int kind) {
    for (hent_t *h = e->handles[tab_slot(id)]; h; h = h->next)
        if (h->id == id && h->kind == kind) return h->ptr;
    return NULL;
}

void *tab_get_ctx(engine_t *e, uint64_t id, int kind) {
    for (hent_t *h = e->handles[tab_slot(id)]; h; h = h->next)
        if (h->id == id && h->kind == kind) return h->ctx;
    return NULL;
}

/* Free the orphans nta can no longer call back (all of them once the agent
 * is gone). */
void orphans_sweep(engine_t *e, int all) {
    uint64_t now = now_ms();
    obj_ctx_t **p = &e->orphans;
    while (*p) {
        obj_ctx_t *o = *p;
        if (all || now - o->orphan_ms > ORPHAN_TTL_MS) {
            *p = o->next_orphan;
            enif_free(o);
        } else {
            p = &o->next_orphan;
        }
    }
}

/* off the list of proxy INVITE branches stray_cb searches */
static void px_unlink(engine_t *e, obj_ctx_t *c) {
    if (!c->px) return;
    if (c->px_prev) c->px_prev->px_next = c->px_next;
    else e->px_head = c->px_next;
    if (c->px_next) c->px_next->px_prev = c->px_prev;
    c->px = 0;
    c->px_prev = c->px_next = NULL;
}

/* the handle is gone; its ctx too, unless a PRACK callback may still use it */
static void ctx_release(engine_t *e, int kind, void *ctx) {
    if (!ctx) return;
    obj_ctx_t *c = ctx;
    if (kind == H_OUTGOING) px_unlink(e, c);
    if (kind == H_INCOMING && c->rel) {
        c->orphan_ms = now_ms();
        c->next_orphan = e->orphans;
        e->orphans = c;
    } else {
        enif_free(ctx);
    }
}

void tab_del(engine_t *e, uint64_t id) {
    hent_t **p = &e->handles[tab_slot(id)];
    while (*p) {
        if ((*p)->id == id) {
            hent_t *dead = *p;
            *p = dead->next;
            if (dead->kind == H_INCOMING) atomic_fetch_sub(&g_incoming, 1);
            ctx_release(e, dead->kind, dead->ctx);
            enif_free(dead);
            return;
        }
        p = &(*p)->next;
    }
}

/* ---------- RFC 5626 flows (stack thread only) ---------- */

static unsigned flow_slot(const tport_t *tp) {
    return (unsigned)((((uintptr_t)tp >> 4) * 0x9E3779B97F4A7C15ULL) >> 54) &
           (FBUCKETS - 1);
}

static flow_t *flow_by_tport(engine_t *e, const tport_t *tp) {
    for (flow_t *f = e->flows[flow_slot(tp)]; f; f = f->next)
        if (f->tp == tp) return f;
    return NULL;
}

/* Forget a flow: off the tport index, its pending entry released and its
 * tport reference dropped. The caller removes its H_FLOW handle. */
static void flow_free(engine_t *e, flow_t *f) {
    flow_t **p = &e->flows[flow_slot(f->tp)];
    while (*p && *p != f) p = &(*p)->next;
    if (*p) *p = f->next;
    if (f->pendd > 0)
        tport_release(f->tp, f->pendd, NULL, NULL, (tp_client_t *)f, 0);
    tport_unref(f->tp);
    enif_free(f);
}

static ERL_NIF_TERM mk_flow_closed_ev(ErlNifEnv *env, engine_t *e,
                                      void *arg) {
    (void)e;
    uint64_t *id = arg;
    return enif_make_tuple2(env, am_flow_closed, enif_make_uint64(env, *id));
}

/* the flow is gone: tell Erlang (which drops its bindings, RFC 5626 7) */
static void flow_closed(engine_t *e, flow_t *f) {
    uint64_t id = f->id;
    flow_free(e, f);
    tab_del(e, id);
    if (atomic_load(&e->state) == ST_READY)
        send_event(e, mk_flow_closed_ev, &id);
}

/* tport reports an error or the close of a connection we hold a flow on */
static void flow_err_cb(tp_stack_t *stack, tp_client_t *client, tport_t *tp,
                        msg_t *msg, int error) {
    (void)stack;
    (void)tp;
    (void)msg;
    (void)error;
    flow_t *f = (flow_t *)client;
    flow_closed(f->e, f);
}

/* The flow id of a connection-oriented transport (TCP, TLS), made on its
 * first request; 0 for a datagram or primary transport. */
uint64_t flow_of(engine_t *e, tport_t *tp) {
    if (!tp || !tport_is_secondary(tp) || !tport_is_reliable(tp) ||
        tport_is_closed(tp))
        return 0;
    flow_t *f = flow_by_tport(e, tp);
    if (f) return f->id;
    f = enif_alloc(sizeof *f);
    if (!f) return 0;
    f->e = e;
    f->tp = tport_ref(tp);
    f->pendd = tport_pend(tp, NULL, flow_err_cb, (tp_client_t *)f);
    f->id = f->pendd > 0 ? tab_put(e, H_FLOW, f, NULL) : 0;
    if (f->id == 0) {
        if (f->pendd > 0)
            tport_release(tp, f->pendd, NULL, NULL, (tp_client_t *)f, 0);
        tport_unref(tp);
        enif_free(f);
        return 0;
    }
    unsigned slot = flow_slot(tp);
    f->next = e->flows[slot];
    e->flows[slot] = f;
    return f->id;
}

/* a closed tport that did not report (a pending entry is reported once) */
void flows_sweep(engine_t *e) {
    for (unsigned slot = 0; slot < FBUCKETS; slot++) {
        flow_t *f = e->flows[slot];
        while (f) {
            flow_t *next = f->next;
            if (tport_is_closed(f->tp)) flow_closed(e, f);
            f = next;
        }
    }
}

void tab_drain(engine_t *e) {
    for (unsigned slot = 0; slot < HBUCKETS; slot++) {
        while (e->handles[slot]) {
            hent_t *h = e->handles[slot];
            e->handles[slot] = h->next;
            switch (h->kind) {
            case H_INCOMING:
                nta_incoming_destroy((nta_incoming_t *)h->ptr);
                atomic_fetch_sub(&g_incoming, 1);
                break;
            case H_LEG:
                nta_leg_destroy((nta_leg_t *)h->ptr);
                break;
            case H_OUTGOING:
                nta_outgoing_destroy((nta_outgoing_t *)h->ptr);
                break;
            case H_FLOW:
                flow_free(e, (flow_t *)h->ptr);
                break;
            default:
                /* no other kind is ever put; say so rather than leak */
                (void)fprintf(stderr, "chappe_sip_engine: drain: handle %llu of "
                        "unknown kind %d\n", (unsigned long long)h->id,
                        h->kind);
                break;
            }
            ctx_release(e, h->kind, h->ctx);
            enif_free(h);
        }
    }
}

/* Single monotonic id space for every handle (incoming txns, legs,
 * outgoing txns), so caller-reserved ids never collide with
 * stack-thread-allocated ones. */
static _Atomic uint64_t g_next_id = 1;

uint64_t reserve_id(void) {
    return atomic_fetch_add(&g_next_id, 1);
}
