/*
 * events.c - what the shim sends to the owner.
 *
 * Copyright 2026 Benoit Chesneau
 * SPDX-License-Identifier: Apache-2.0
 *
 * send_event is the one enif_send path; the mk_*_ev constructors build
 * each event term, send_op_ok and send_op_failed answer an op. Also the
 * stats counters, the shim's warnings and sofia's log redirect. See "The
 * event contract" in docs/design/engine.md.
 */

#include "engine.h"

/* ---------- counters (stats/0) ---------- */

/* The server transactions we hold (H_INCOMING handles), the requests the
 * source blocklist discarded, the events that never reached the owner (no
 * env, or enif_send refused: a dead owner), and the event terms whose
 * binary could not be allocated. */
_Atomic uint64_t g_incoming = 0;
_Atomic uint64_t g_blk_drops = 0;
_Atomic uint64_t g_events_dropped = 0;
_Atomic uint64_t g_alloc_failed = 0;
/* the last time a dropped event was written to stderr (ms, monotonic) */
static _Atomic uint64_t g_drop_logged_ms = 0;
#define DROP_LOG_WINDOW_MS 10000

/* ---------- small helpers ----------
 *
 * A (void) cast on snprintf or fprintf marks a result the code does not
 * need: the copy fits by construction (the source is bounded by a buffer
 * of at most the target's size, checked where it was taken in), or the
 * write is best-effort diagnostics on stderr. An early wake of msleep
 * only shortens one poll step of a bounded wait. */

void msleep(unsigned ms) {
    struct timespec ts = {(time_t)(ms / 1000), (long)(ms % 1000) * 1000000L};
    (void)nanosleep(&ts, NULL);
}

/* CLOCK_MONOTONIC cannot fail on the platforms we build for; if it ever
 * did, the last time read stands in, so time never runs backwards (an
 * orphan sweep would wrap a difference and free a live ctx) */
static _Atomic uint64_t g_last_ms = 0;

uint64_t now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return atomic_load(&g_last_ms);
    uint64_t ms = (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
    atomic_store(&g_last_ms, ms);
    return ms;
}

/* A binary term of s; the atom alloc_failed (counted) when there is no
 * memory for it. */
ERL_NIF_TERM mkbin(ErlNifEnv *env, const char *s, size_t len) {
    ErlNifBinary b;
    if (!enif_alloc_binary(len, &b)) {
        atomic_fetch_add(&g_alloc_failed, 1);
        return enif_make_atom(env, "alloc_failed");
    }
    if (len) memcpy(b.data, s, len);
    return enif_make_binary(env, &b);
}

/* An event did not reach the owner: count it, and say so on stderr at
 * most once per window (the event channel is what failed, so a log event
 * cannot carry it). */
static void event_dropped(void) {
    uint64_t n = atomic_fetch_add(&g_events_dropped, 1) + 1;
    uint64_t now = now_ms();
    uint64_t last = atomic_load(&g_drop_logged_ms);
    if ((last == 0 || now - last >= DROP_LOG_WINDOW_MS) &&
        atomic_compare_exchange_strong(&g_drop_logged_ms, &last, now))
        (void)fprintf(stderr, "chappe_sip_engine: event dropped (%llu so far)\n",
                (unsigned long long)n);
}

/* Send {chappe_sip_engine, EngineRef, Event} to the owner. Safe from the stack
 * thread. */
void send_event(engine_t *e, ERL_NIF_TERM (*mk)(ErlNifEnv *, engine_t *, void *),
                       void *arg) {
    ErlNifEnv *env = enif_alloc_env();
    if (!env) {
        event_dropped();
        return;
    }
    ERL_NIF_TERM ref = enif_make_resource(env, e);
    ERL_NIF_TERM ev = mk(env, e, arg);
    ERL_NIF_TERM msg = enif_make_tuple3(env, am_chappe_sip_engine, ref, ev);
    if (!enif_send(NULL, &e->owner, env, msg)) event_dropped();
    enif_free_env(env);
}

/* A {log, Level, Text} event: the shim's own warnings (level 4) */
struct log_ev {
    int level;
    const char *text;
};

static ERL_NIF_TERM mk_log_ev(ErlNifEnv *env, engine_t *e, void *arg);

__attribute__((format(printf, 2, 3)))
void shim_warn(engine_t *e, const char *fmt, ...) {
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n <= 0) return;
    struct log_ev l = {4 /* warning */, buf};
    send_event(e, mk_log_ev, &l);
}

/* ---------- event constructors ---------- */

ERL_NIF_TERM mk_request_ev(ErlNifEnv *env, engine_t *e, void *arg) {
    (void)e;
    struct req_ev *r = arg;
    ERL_NIF_TERM meta = enif_make_new_map(env);
    enif_make_map_put(env, meta, am_method,
                      mkbin(env, r->method, r->method_len), &meta);
    enif_make_map_put(env, meta, am_source_ip,
                      mkbin(env, r->src_ip, strlen(r->src_ip)), &meta);
    enif_make_map_put(env, meta, am_source_port,
                      enif_make_int(env, r->src_port), &meta);
    if (r->transport[0])
        enif_make_map_put(env, meta, am_transport,
                          mkbin(env, r->transport, strlen(r->transport)),
                          &meta);
    if (r->flow)
        enif_make_map_put(env, meta, am_conn, enif_make_uint64(env, r->flow),
                          &meta);
    if (r->local_ip[0]) {
        enif_make_map_put(env, meta, am_local_ip,
                          mkbin(env, r->local_ip, strlen(r->local_ip)), &meta);
        enif_make_map_put(env, meta, am_local_port,
                          enif_make_int(env, r->local_port), &meta);
    }
    if (r->local[0])
        enif_make_map_put(env, meta, am_local,
                          mkbin(env, r->local, strlen(r->local)), &meta);
    ERL_NIF_TERM raw = r->raw ? mkbin(env, r->raw, r->raw_len)
                              : mkbin(env, "", 0);
    ERL_NIF_TERM leg = r->leg ? enif_make_uint64(env, r->leg) : am_undefined;
    return enif_make_tuple5(env, am_request, enif_make_uint64(env, r->h),
                            leg, meta, raw);
}

ERL_NIF_TERM mk_health_ev(ErlNifEnv *env, engine_t *e, void *arg) {
    (void)e;
    uint64_t *seq = arg;
    return enif_make_tuple2(env, am_health_ok, enif_make_uint64(env, *seq));
}

ERL_NIF_TERM mk_started_ev(ErlNifEnv *env, engine_t *e, void *arg) {
    (void)e;
    const char *contact = arg;
    return enif_make_tuple2(env, am_started,
                            mkbin(env, contact, strlen(contact)));
}

static ERL_NIF_TERM mk_log_ev(ErlNifEnv *env, engine_t *e, void *arg) {
    (void)e;
    struct log_ev *l = arg;
    return enif_make_tuple3(env, am_log, enif_make_int(env, l->level),
                            mkbin(env, l->text, strlen(l->text)));
}

struct op_ev {
    uint64_t h;
    const char *reason; /* NULL for op_ok */
};

static ERL_NIF_TERM mk_op_ev(ErlNifEnv *env, engine_t *e, void *arg) {
    (void)e;
    struct op_ev *o = arg;
    if (o->reason == NULL)
        return enif_make_tuple2(env, am_op_ok, enif_make_uint64(env, o->h));
    return enif_make_tuple3(env, am_op_failed, enif_make_uint64(env, o->h),
                            mkbin(env, o->reason, strlen(o->reason)));
}

void send_op_ok(engine_t *e, uint64_t h) {
    struct op_ev o = {h, NULL};
    send_event(e, mk_op_ev, &o);
}

void send_op_failed(engine_t *e, uint64_t h, const char *why) {
    struct op_ev o = {h, why};
    send_event(e, mk_op_ev, &o);
}

ERL_NIF_TERM mk_response_ev(ErlNifEnv *env, engine_t *e, void *arg) {
    (void)e;
    struct resp_ev *r = arg;
    ERL_NIF_TERM meta = enif_make_new_map(env);
    enif_make_map_put(env, meta, am_status, enif_make_int(env, r->status),
                      &meta);
    return enif_make_tuple4(env, am_response, enif_make_uint64(env, r->h),
                            meta,
                            r->raw ? mkbin(env, r->raw, r->raw_len)
                                   : mkbin(env, "", 0));
}

ERL_NIF_TERM mk_ack_ev(ErlNifEnv *env, engine_t *e, void *arg) {
    (void)e;
    struct ack_ev *a = arg;
    return enif_make_tuple3(env, am_ack, enif_make_uint64(env, a->leg),
                            a->raw ? mkbin(env, a->raw, a->raw_len)
                                   : mkbin(env, "", 0));
}

ERL_NIF_TERM mk_ack_timeout_ev(ErlNifEnv *env, engine_t *e,
                                      void *arg) {
    (void)e;
    uint64_t *h = arg;
    return enif_make_tuple2(env, am_ack_timeout, enif_make_uint64(env, *h));
}

ERL_NIF_TERM mk_cancel_ev(ErlNifEnv *env, engine_t *e, void *arg) {
    (void)e;
    struct cancel_ev *c = arg;
    return enif_make_tuple3(env, am_cancel, enif_make_uint64(env, c->h),
                            c->raw ? mkbin(env, c->raw, c->raw_len)
                                   : mkbin(env, "", 0));
}

ERL_NIF_TERM mk_prack_ev(ErlNifEnv *env, engine_t *e, void *arg) {
    (void)e;
    struct prack_ev *p = arg;
    ERL_NIF_TERM raw = p->raw ? mkbin(env, p->raw, p->raw_len)
                              : mkbin(env, "", 0);
    if (p->ph)
        return enif_make_tuple4(env, am_prack, enif_make_uint64(env, p->h),
                                raw, enif_make_uint64(env, p->ph));
    return enif_make_tuple3(env, am_prack, enif_make_uint64(env, p->h), raw);
}

/* ---------- sofia logging bridge ---------- */

/* singleton engine, set on stack thread start; atomic so log_cb (which sofia
 * may in principle call from another thread) reads it safely */
_Atomic(engine_t *) g_log_engine = NULL;

__attribute__((format(printf, 2, 0)))
void log_cb(void *stream, char const *fmt, va_list ap) {
    (void)stream;
    engine_t *e = atomic_load(&g_log_engine);
    char buf[512];
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    if (n <= 0) return;
    if (!e || atomic_load(&e->state) != ST_READY) {
        /* pre-ready and teardown output goes to stderr */
        (void)fprintf(stderr, "chappe_sip_engine: %s", buf);
        return;
    }
    /* strip trailing newline */
    if ((size_t)n < sizeof buf && buf[n - 1] == '\n') buf[n - 1] = 0;
    struct log_ev l = {6 /* info */, buf};
    send_event(e, mk_log_ev, &l);
}
