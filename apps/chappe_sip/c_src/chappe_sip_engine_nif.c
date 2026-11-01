/*
 * chappe_sip_engine_nif.c - thin NIF shim over sofia-sip nta.
 *
 * Copyright 2026 Benoit Chesneau
 * SPDX-License-Identifier: Apache-2.0
 *
 * Design (see doc/design/engine.md and the project plan):
 * - Global su_init once at NIF load; su_deinit at unload. Per-engine
 *   lifecycle is only su_root + nta_agent, so stop/start cycles never
 *   re-run global init.
 * - ONE engine thread runs su_root_run. Every nta call happens on that
 *   thread; NIF calls enqueue operations via su_msg (safe from foreign
 *   threads) and return immediately.
 * - Startup readiness barrier: the stack thread performs all sofia setup
 *   and flips an atomic to READY or FAILED; start() polls boundedly.
 * - Shutdown is cooperative: erl_nif has no timed join, so the stack
 *   thread sets an atomic EXITED flag right before returning and stop()
 *   polls it (50ms steps, 5s cap) before calling enif_thread_join.
 * - Singleton: one engine at a time, guarded by g_engine_state, so
 *   detach/stop/reattach are strictly serialized.
 */

#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <ctype.h>
#include <dirent.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>

#include <erl_nif.h>

#include <sofia-sip/su.h>
#include <sofia-sip/su_wait.h>
#include <sofia-sip/su_log.h>
#include <sofia-sip/nta.h>
#include <sofia-sip/nta_stateless.h>
#include <sofia-sip/nta_tport.h>
#include <sofia-sip/tport.h>
#include <sofia-sip/tport_tag.h>
#include <sofia-sip/sip.h>
#include <sofia-sip/sip_header.h>
#include <sofia-sip/sip_tag.h>
#include <sofia-sip/sip_status.h>
#include <sofia-sip/sip_util.h>
#include <sofia-sip/msg.h>
#include <sofia-sip/msg_addr.h>
#include <sofia-sip/url.h>

/* ---------- safety helpers ----------
 *
 * Checked arithmetic for every computed size: C23 <stdckdint.h> when the
 * compiler has it (and defines ckd_add in this language mode), else the
 * gcc/clang builtins it is specified after. Both return true on overflow
 * and store the wrapped result. */
#if defined(__has_include)
#if __has_include(<stdckdint.h>)
#include <stdckdint.h>
#endif
#endif
#if defined(ckd_add) && defined(ckd_mul)
#define chk_add(r, a, b) ckd_add((r), (a), (b))
#define chk_mul(r, a, b) ckd_mul((r), (a), (b))
#else
#define chk_add(r, a, b) __builtin_add_overflow((a), (b), (r))
#define chk_mul(r, a, b) __builtin_mul_overflow((a), (b), (r))
#endif

/* Under ThreadSanitizer only: ERTS frees and hands out resource memory
 * with its own allocator, which is not instrumented, so TSan does not see
 * that a resource destructor happens before the next allocation at the
 * same address and reports the reuse as a race. The destructor releases
 * the object and the allocation acquires it, which is the order the
 * allocator already guarantees. No-ops in every other build. */
#if defined(__SANITIZE_THREAD__)
#define CHAPPE_TSAN 1
#elif defined(__has_feature)
#if __has_feature(thread_sanitizer)
#define CHAPPE_TSAN 1
#endif
#endif
#ifdef CHAPPE_TSAN
#include <sanitizer/tsan_interface.h>
#define TSAN_RELEASE(p) __tsan_release(p)
#define TSAN_ACQUIRE(p) __tsan_acquire(p)
#else
#define TSAN_RELEASE(p) ((void)(p))
#define TSAN_ACQUIRE(p) ((void)(p))
#endif

/* A status a caller must look at: C23 [[nodiscard]] in C23 mode, else the
 * gcc/clang attribute (which a (void) cast does not silence). */
#if defined(__STDC_VERSION__) && __STDC_VERSION__ > 201710L
#define NODISCARD [[nodiscard]]
#elif defined(__GNUC__)
#define NODISCARD __attribute__((warn_unused_result))
#else
#define NODISCARD
#endif

#define ENGINE_START_WAIT_MS 10000
#define ENGINE_STOP_WAIT_MS 5000
#define POLL_STEP_MS 50
#define MAX_CONTACT 512
/* listen addresses per kind (plain, TLS) after the first; an ident names
 * the address a transport is bound to (TPTAG_IDENT) */
#define MAX_BINDS 8
#define MAX_IDENT 64
#define DEFAULT_MAX_MSG_SIZE 262144
/* max_message_size bounds: under 1 KiB no INVITE with SDP fits, over
 * 64 MiB one message could hold the stack thread and its memory */
#define MIN_MSG_SIZE 1024
#define MAX_MSG_SIZE ((size_t)64 * 1024 * 1024)
/* the reason phrase and To-tag a response carries (op_t) */
#define MAX_REASON 80
#define MAX_TAG 80
/* a Via branch (op_t, obj_ctx px_branch) */
#define MAX_BRANCH 96
/* a dialog leg's Call-ID, local and remote address */
#define MAX_LEG_FIELD 8192
/* the length of an IP literal as su_inet_ntop writes it, with its NUL */
#define MAX_IP 64
/* handle table buckets (power of two) */
#define HBUCKETS 4096

/* engine states */
enum { ST_INIT = 0, ST_READY, ST_FAILED, ST_STOPPING, ST_EXITED };

/* global singleton guard */
enum { G_NONE = 0, G_RUNNING, G_STOPPING };
static _Atomic int g_engine_state = G_NONE;

/* handle table entry kinds */
enum { H_INCOMING = 1, H_LEG, H_OUTGOING, H_FLOW };

/* flow table buckets, keyed by tport (power of two) */
#define FBUCKETS 1024

typedef struct hent {
    uint64_t id;
    int kind;
    void *ptr;
    void *ctx; /* per-object magic (leg_ctx/irq ctx), freed on removal */
    struct hent *next;
} hent_t;

/* per-leg / per-txn callback magic */
typedef struct obj_ctx {
    struct engine *e;
    uint64_t h;
    /* incoming INVITE only: the dialog leg it arrived on (0 out of dialog),
     * and set once a 2xx to an in-dialog INVITE is sent, while the
     * transaction is kept for its ACK */
    uint64_t leg;
    int await_ack;
    /* incoming INVITE only: a proxy owns it, so a CANCEL is relayed to its
     * branches and the downstream final goes upstream; nta's own 487 is
     * off for every transaction and sent here only when this is 0 */
    int proxied;
    /* incoming INVITE only: a reliable 1xx was sent, so its PRACK callback
     * holds this ctx as magic. nta keeps the transaction (and calls that
     * callback for a late PRACK) after our final response and destroy, so
     * the ctx outlives the handle as an orphan until nta is surely done. */
    int rel;
    /* the RSeq of the last reliable 1xx PRACKed (RFC 3262 3: a PRACK for
     * one already acknowledged matches nothing unacknowledged) */
    uint32_t rel_acked;
    /* offerless INVITE only (RFC 3262 5): 1 once a reliable 1xx carried
     * our offer, 2 once a PRACK brought the answer */
    int rel_offer;
    uint64_t orphan_ms;
    struct obj_ctx *next_orphan;
    /* outgoing proxy INVITE branch only: the Via branch nta gave it, and
     * the links of the engine's branch list. nta ends a client transaction
     * on a reliable transport at its first 2xx, so a later 2xx of the same
     * branch (a downstream fork) matches no transaction and reaches
     * stray_cb, which finds the branch here (RFC 6026). */
    int px;
    char px_branch[MAX_BRANCH];
    struct obj_ctx *px_prev, *px_next;
} obj_ctx_t;

/* An RFC 5626 flow: a TCP/TLS connection a request arrived on. The engine
 * holds a tport reference, so the pointer stays valid, and a pending entry
 * on it, so tport reports the close (flow_err_cb). */
typedef struct flow {
    struct engine *e;
    uint64_t id;
    tport_t *tp;
    int pendd;
    struct flow *next;
} flow_t;

/* nta gives up on an unacknowledged reliable 1xx after 64*T1 (32 s with
 * the default T1); an orphan ctx is freed well after that */
#define ORPHAN_TTL_MS 70000

typedef struct engine {
    ErlNifTid tid;
    /* Atomic so the join is claimed exactly once: stop_wait_join and
     * engine_dtor both atomic_exchange it to 0 and only the winner joins,
     * so the two stop paths can never double-join the same tid. */
    _Atomic int tid_valid;
    ErlNifPid owner;
    ErlNifMonitor owner_mon;
    char contact[MAX_CONTACT];
    size_t max_msg_size;
    /* more listen addresses (nta_agent_add_tport each) and the ident of
     * every one; idents are set for all transports or for none, since tport
     * compares a requested ident with each primary's (strcmp, no NULL
     * check). has_idents: a send may then name one. */
    char ident[MAX_IDENT];
    char xcontact[MAX_BINDS][MAX_CONTACT];
    char xident[MAX_BINDS][MAX_IDENT];
    int nx;
    int has_idents;

    /* optional TLS transport, bound on its own port after the agent */
    char tls_contact[MAX_CONTACT];
    char tls_ident[MAX_IDENT];
    char tls_xcontact[MAX_BINDS][MAX_CONTACT];
    char tls_xident[MAX_BINDS][MAX_IDENT];
    int ntlsx;
    char tls_cert_dir[512];
    char tls_passphrase[128];
    char tls_ciphers[256];
    /* verify the server certificate of outbound TLS connections (with the
     * RFC 5922 subject check), and the client certificate of inbound ones */
    int tls_verify_peer;
    int tls_verify_clients;

    /* HEP capture URL for sofia's tport (TPTAG_CAPT), "" when off, and the
     * capture socket sofia opened for it (-1: none). tport never closes
     * that socket, so the shim closes it after the agent is destroyed. */
    char capture[MAX_CONTACT];
    int capt_fd;

    /* stack-thread-only state */
    su_root_t *root;
    nta_agent_t *agent;
    su_home_t home[1];
    /* handle table: chained hash buckets keyed by handle id */
    hent_t *handles[HBUCKETS];
    obj_ctx_t *orphans;
    /* live proxy INVITE branches (obj_ctx px list) */
    obj_ctx_t *px_head;
    /* RFC 5626 flows by tport (each is also a H_FLOW handle by id) */
    flow_t *flows[FBUCKETS];
    uint64_t health_seq;

    _Atomic int state;
    /* Guards e->root against use-after-free across threads: foreign ops take
     * the read side around enqueue (and re-check state); the stack thread
     * takes the write side to destroy root, so an op can never touch a freed
     * root. */
    ErlNifRWLock *root_lock;
    char errbuf[256];
} engine_t;

static ErlNifResourceType *ENGINE_RT = NULL;

/* atoms */
static ERL_NIF_TERM am_ok, am_error, am_undefined, am_chappe_sip_engine, am_request,
    am_health_ok, am_started, am_log, am_method, am_not_ready, am_not_found,
    am_stopping, am_already_started, am_hung, am_badarg, am_contact,
    am_max_message_size, am_engine_start, am_op_ok, am_op_failed, am_response,
    am_ack, am_cancel, am_status, am_tls, am_cert_dir, am_passphrase, am_verify,
    am_peer, am_ciphers, am_prack, am_source_ip, am_source_port,
    am_ack_timeout, am_transport, am_verify_clients, am_true, am_conn,
    am_flow_closed, am_capture, am_ident, am_contacts, am_local,
    am_local_ip, am_local_port, am_false, am_none, am_enomem, am_incoming,
    am_discarded, am_events_dropped, am_alloc_failed;

/* operations enqueued to the stack thread */
enum { OP_RESPOND = 1, OP_HEALTH, OP_STOP, OP_REQUEST, OP_LEG_CREATE,
       OP_LEG_DESTROY, OP_SEND, OP_CANCEL, OP_TXN_DONE, OP_RELAY,
       OP_MSG_TSEND, OP_RELIABLE_1XX, OP_PROXY_MARK, OP_DISCARD };

typedef struct op {
    int kind;
    engine_t *e;
    uint64_t h;
    int status;
    char reason[MAX_REASON];
    char to_tag[MAX_TAG];
    /* OP_REQUEST: the Via branch to use ("" lets nta pick one) */
    char branch[MAX_BRANCH];
    /* optional payloads owned by the op, enif_alloc'd, freed in op_cb:
     * headers = extra headers / leg local address (From w/ tag)
     * body    = body / leg remote address (To w/ tag)
     * raw     = complete outgoing message / leg call-id
     * route   = outbound route url */
    char *headers;
    char *body;
    char *raw;
    size_t raw_len;
    char *route;
    /* OP_REQUEST / OP_SEND: send over this RFC 5626 flow (0: none) */
    uint64_t flow;
    /* OP_REQUEST / OP_SEND: send from the listen address with this ident
     * ("" lets tport pick one by protocol and address family) */
    char ident[MAX_IDENT];
} op_t;

/* The invariants the code below relies on. */
/* tab_slot keeps the top 12 bits of the hash, flow_slot the top 10 */
static_assert(HBUCKETS == 1 << 12, "tab_slot shifts by 52");
static_assert(FBUCKETS == 1 << 10, "flow_slot shifts by 54");
static_assert((HBUCKETS & (HBUCKETS - 1)) == 0, "HBUCKETS power of two");
static_assert((FBUCKETS & (FBUCKETS - 1)) == 0, "FBUCKETS power of two");
/* op_cb copies a branch nta gave into an obj_ctx of the same size */
static_assert(sizeof(((obj_ctx_t *)0)->px_branch) == MAX_BRANCH,
              "px_branch holds a branch");
static_assert(sizeof(((op_t *)0)->branch) == MAX_BRANCH, "op branch");
static_assert(sizeof(((op_t *)0)->reason) == MAX_REASON, "op reason");
static_assert(sizeof(((op_t *)0)->to_tag) == MAX_TAG, "op to_tag");
static_assert(sizeof(((op_t *)0)->ident) == MAX_IDENT, "op ident");
/* an IPv6 literal (INET6_ADDRSTRLEN, 46) fits every address buffer */
static_assert(MAX_IP >= 46, "MAX_IP holds an IPv6 literal");
static_assert(MIN_MSG_SIZE <= DEFAULT_MAX_MSG_SIZE &&
                  DEFAULT_MAX_MSG_SIZE <= MAX_MSG_SIZE,
              "the default cap is in bounds");
/* a capped leg field or option fits a size_t sum with its NUL */
static_assert(MAX_MSG_SIZE < SIZE_MAX / 2, "size sums cannot wrap");
/* NTATAG_MAXSIZE takes a usize_t (32 bits); a raw_len fits ssize_t */
static_assert(MAX_MSG_SIZE <= UINT_MAX, "the cap fits usize_t");
static_assert(MAX_MSG_SIZE <= SSIZE_MAX, "a message length fits ssize_t");

/* ---------- counters (stats/0) ---------- */

/* The server transactions we hold (H_INCOMING handles), the requests the
 * source blocklist discarded, the events that never reached the owner (no
 * env, or enif_send refused: a dead owner), and the event terms whose
 * binary could not be allocated. */
static _Atomic uint64_t g_incoming = 0;
static _Atomic uint64_t g_blk_drops = 0;
static _Atomic uint64_t g_events_dropped = 0;
static _Atomic uint64_t g_alloc_failed = 0;
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

static void msleep(unsigned ms) {
    struct timespec ts = {(time_t)(ms / 1000), (long)(ms % 1000) * 1000000L};
    (void)nanosleep(&ts, NULL);
}

/* CLOCK_MONOTONIC cannot fail on the platforms we build for; if it ever
 * did, the last time read stands in, so time never runs backwards (an
 * orphan sweep would wrap a difference and free a live ctx) */
static _Atomic uint64_t g_last_ms = 0;

static uint64_t now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return atomic_load(&g_last_ms);
    uint64_t ms = (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
    atomic_store(&g_last_ms, ms);
    return ms;
}

/* A binary term of s; the atom alloc_failed (counted) when there is no
 * memory for it. */
static ERL_NIF_TERM mkbin(ErlNifEnv *env, const char *s, size_t len) {
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
static void send_event(engine_t *e, ERL_NIF_TERM (*mk)(ErlNifEnv *, engine_t *, void *),
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
static void shim_warn(engine_t *e, const char *fmt, ...) {
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n <= 0) return;
    struct log_ev l = {4 /* warning */, buf};
    send_event(e, mk_log_ev, &l);
}

/* ---------- handle table (stack thread only) ---------- */

/* Fibonacci hashing of the id onto the bucket array: ids are sequential,
 * the multiply spreads them over all buckets */
static unsigned tab_slot(uint64_t id) {
    return (unsigned)((id * 0x9E3779B97F4A7C15ULL) >> 52) & (HBUCKETS - 1);
}

NODISCARD static int tab_put_id(engine_t *e, uint64_t id, int kind, void *ptr,
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
static uint64_t reserve_id(void);

NODISCARD static uint64_t tab_put(engine_t *e, int kind, void *ptr,
                                  void *ctx) {
    uint64_t id = reserve_id();
    if (tab_put_id(e, id, kind, ptr, ctx) != 0) return 0;
    return id;
}

static void *tab_get(engine_t *e, uint64_t id, int kind) {
    for (hent_t *h = e->handles[tab_slot(id)]; h; h = h->next)
        if (h->id == id && h->kind == kind) return h->ptr;
    return NULL;
}

static void *tab_get_ctx(engine_t *e, uint64_t id, int kind) {
    for (hent_t *h = e->handles[tab_slot(id)]; h; h = h->next)
        if (h->id == id && h->kind == kind) return h->ctx;
    return NULL;
}

/* ---------- source blocklist ----------
 *
 * The addresses chappe_sip_guard drops (block/2), each until a deadline.
 * request_in discards a request from one before nta creates a server
 * transaction for it, so a flood from it costs no transaction. The policy
 * is Erlang's; this only enforces it. Open addressing over a fixed table:
 * an address probes BLK_PROBE slots, and when they are all live the one
 * expiring first gives way. Process-wide (the engine is a singleton), so
 * it outlives an engine restart. */
#define BLK_SLOTS 4096
#define BLK_PROBE 8
#define BLK_ADDR 64

typedef struct {
    char addr[BLK_ADDR];
    uint64_t until_ms;
} blk_ent_t;

static blk_ent_t g_blk[BLK_SLOTS];
static ErlNifMutex *g_blk_lock = NULL;

static unsigned blk_hash(const char *a) {
    uint32_t h = 2166136261u;
    for (; *a; a++) h = (h ^ (unsigned char)*a) * 16777619u;
    return h & (BLK_SLOTS - 1);
}

/* ttl_ms 0 lifts the block */
static void blk_put(const char *addr, uint64_t ttl_ms) {
    uint64_t now = now_ms();
    unsigned base = blk_hash(addr);
    enif_mutex_lock(g_blk_lock);
    blk_ent_t *same = NULL, *pick = NULL;
    for (unsigned i = 0; i < BLK_PROBE && !same; i++) {
        blk_ent_t *b = &g_blk[(base + i) & (BLK_SLOTS - 1)];
        if (b->until_ms > now && strcmp(b->addr, addr) == 0)
            same = b;
        else if (!pick || b->until_ms < pick->until_ms)
            pick = b;
    }
    if (ttl_ms == 0) {
        if (same) same->until_ms = 0;
    } else {
        blk_ent_t *b = same ? same : pick;
        (void)snprintf(b->addr, sizeof b->addr, "%s", addr);
        b->until_ms = now + ttl_ms;
    }
    enif_mutex_unlock(g_blk_lock);
}

static int blk_has(const char *addr) {
    uint64_t now = now_ms();
    unsigned base = blk_hash(addr);
    int hit = 0;
    enif_mutex_lock(g_blk_lock);
    for (unsigned i = 0; i < BLK_PROBE && !hit; i++) {
        blk_ent_t *b = &g_blk[(base + i) & (BLK_SLOTS - 1)];
        hit = b->until_ms > now && strcmp(b->addr, addr) == 0;
    }
    enif_mutex_unlock(g_blk_lock);
    return hit;
}

/* the message comes from a blocked address */
static int blk_msg(msg_t *msg) {
    char ip[BLK_ADDR] = {0};
    su_addrinfo_t *ai = msg_addrinfo(msg);
    if (!ai || !ai->ai_addr || !ai->ai_addrlen) return 0;
    su_sockaddr_t *su = (su_sockaddr_t *)ai->ai_addr;
    if (!su_inet_ntop(su->su_family, SU_ADDR(su), ip, sizeof ip)) return 0;
    return blk_has(ip);
}

/* Free the orphans nta can no longer call back (all of them once the agent
 * is gone). */
static void orphans_sweep(engine_t *e, int all) {
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

static void tab_del(engine_t *e, uint64_t id) {
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
static uint64_t flow_of(engine_t *e, tport_t *tp) {
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
static void flows_sweep(engine_t *e) {
    for (unsigned slot = 0; slot < FBUCKETS; slot++) {
        flow_t *f = e->flows[slot];
        while (f) {
            flow_t *next = f->next;
            if (tport_is_closed(f->tp)) flow_closed(e, f);
            f = next;
        }
    }
}

static void tab_drain(engine_t *e) {
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

/* ---------- event constructors ---------- */

struct req_ev {
    uint64_t h;
    uint64_t leg; /* 0 = out-of-dialog */
    const char *method;
    size_t method_len;
    char *raw;
    size_t raw_len;
    char src_ip[MAX_IP]; /* peer address of the received request ("" if unknown) */
    int src_port;
    char transport[16]; /* "udp", "tcp", "tls"... ("" if unknown) */
    uint64_t flow; /* the TCP/TLS connection's flow id (0: none) */
    char local_ip[MAX_IP]; /* the listen address it arrived on ("" if unknown) */
    int local_port;
    char local[MAX_IDENT]; /* that address's ident ("" if none) */
};

static ERL_NIF_TERM mk_request_ev(ErlNifEnv *env, engine_t *e, void *arg) {
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

static ERL_NIF_TERM mk_health_ev(ErlNifEnv *env, engine_t *e, void *arg) {
    (void)e;
    uint64_t *seq = arg;
    return enif_make_tuple2(env, am_health_ok, enif_make_uint64(env, *seq));
}

static ERL_NIF_TERM mk_started_ev(ErlNifEnv *env, engine_t *e, void *arg) {
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

static void send_op_ok(engine_t *e, uint64_t h) {
    struct op_ev o = {h, NULL};
    send_event(e, mk_op_ev, &o);
}

static void send_op_failed(engine_t *e, uint64_t h, const char *why) {
    struct op_ev o = {h, why};
    send_event(e, mk_op_ev, &o);
}

struct resp_ev {
    uint64_t h;
    int status;
    char *raw;
    size_t raw_len;
};

static ERL_NIF_TERM mk_response_ev(ErlNifEnv *env, engine_t *e, void *arg) {
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

struct ack_ev {
    uint64_t leg;
    char *raw;
    size_t raw_len;
};

static ERL_NIF_TERM mk_ack_ev(ErlNifEnv *env, engine_t *e, void *arg) {
    (void)e;
    struct ack_ev *a = arg;
    return enif_make_tuple3(env, am_ack, enif_make_uint64(env, a->leg),
                            a->raw ? mkbin(env, a->raw, a->raw_len)
                                   : mkbin(env, "", 0));
}

struct cancel_ev {
    uint64_t h; /* the INVITE server-transaction handle */
    char *raw;  /* the CANCEL request */
    size_t raw_len;
};

static ERL_NIF_TERM mk_ack_timeout_ev(ErlNifEnv *env, engine_t *e,
                                      void *arg) {
    (void)e;
    uint64_t *h = arg;
    return enif_make_tuple2(env, am_ack_timeout, enif_make_uint64(env, *h));
}

static ERL_NIF_TERM mk_cancel_ev(ErlNifEnv *env, engine_t *e, void *arg) {
    (void)e;
    struct cancel_ev *c = arg;
    return enif_make_tuple3(env, am_cancel, enif_make_uint64(env, c->h),
                            c->raw ? mkbin(env, c->raw, c->raw_len)
                                   : mkbin(env, "", 0));
}

struct prack_ev {
    uint64_t h; /* the INVITE server-transaction handle */
    uint64_t ph; /* the PRACK's own handle when the app answers it, else 0 */
    char *raw;
    size_t raw_len;
};

static ERL_NIF_TERM mk_prack_ev(ErlNifEnv *env, engine_t *e, void *arg) {
    (void)e;
    struct prack_ev *p = arg;
    ERL_NIF_TERM raw = p->raw ? mkbin(env, p->raw, p->raw_len)
                              : mkbin(env, "", 0);
    if (p->ph)
        return enif_make_tuple4(env, am_prack, enif_make_uint64(env, p->h),
                                raw, enif_make_uint64(env, p->ph));
    return enif_make_tuple3(env, am_prack, enif_make_uint64(env, p->h), raw);
}

/* PRACK arrived for a reliable provisional. Notify Erlang (routed by the
 * INVITE handle). Without a body nta answers it 200 on our return; with
 * one (an offer, RFC 3262 5) the answer is the app's, so the PRACK gets a
 * handle and its 2xx goes out through OP_RESPOND. nta still matches a
 * PRACK for a response it already saw PRACKed: that one gets 481 (3). */
static int prack_cb(nta_reliable_magic_t *magic, nta_reliable_t *rel,
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

/* ---------- sofia logging bridge ---------- */

/* singleton engine, set on stack thread start; atomic so log_cb (which sofia
 * may in principle call from another thread) reads it safely */
static _Atomic(engine_t *) g_log_engine = NULL;

__attribute__((format(printf, 2, 0)))
static void log_cb(void *stream, char const *fmt, va_list ap) {
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
    if ((size_t)n < sizeof buf && n > 0 && buf[n - 1] == '\n') buf[n - 1] = 0;
    struct log_ev l = {6 /* info */, buf};
    send_event(e, mk_log_ev, &l);
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

static int leg_request_cb(nta_leg_magic_t *magic, nta_leg_t *leg,
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
static int leg_request_cb(nta_leg_magic_t *magic, nta_leg_t *leg,
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
static int outgoing_response_cb(nta_outgoing_magic_t *magic,
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
static int stray_cb(nta_agent_magic_t *magic, nta_agent_t *agent,
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
    case OP_RELIABLE_1XX: {
        /* send a reliable provisional (100rel). nta owns RSeq/RAck,
         * retransmit and PRACK matching; prack_cb fires when the PRACK
         * arrives. The incoming handle must survive to the final. */
        nta_incoming_t *irq = tab_get(e, op->h, H_INCOMING);
        obj_ctx_t *ctx = tab_get_ctx(e, op->h, H_INCOMING);
        if (!irq || !ctx) {
            send_op_failed(e, op->h, "unknown transaction");
            break;
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
            break;
        }
        int has_body = op->body && op->body[0];
        int offerless = ctx->rel_offer == 0 && !request_has_body(irq);
        if (offerless && !has_body) {
            /* RFC 3262 5: the first reliable 1xx to an INVITE without an
             * offer carries one */
            send_op_failed(e, op->h, "reliable 1xx needs the offer");
            break;
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
        break;
    }
    case OP_REQUEST: {
        msg_t *m = op_msg(op);
        if (!m) {
            send_op_failed(e, op->h, "unparseable request");
            break;
        }
        obj_ctx_t *ctx = enif_alloc(sizeof *ctx);
        if (!ctx) {
            msg_destroy(m);
            send_op_failed(e, op->h, "alloc failed");
            break;
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
                break;
            }
            ftp = f->tp;
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
            TAG_IF(ftp, NTATAG_TPORT(ftp)),
            TAG_IF(op->ident[0] && e->has_idents, TPTAG_IDENT(op->ident)),
            TAG_END());
        if (proxy_inv &&
            nta_agent_set_params(e->agent, NTATAG_UA(1), TAG_END()) < 0)
            shim_warn(e, "nta_agent_set_params(UA 1) failed");
        if (!orq) {
            /* nta owns/destroys msg only on success */
            msg_destroy(m);
            enif_free(ctx);
            send_op_failed(e, op->h, "nta_outgoing_mcreate failed");
            break;
        }
        if (tab_put_id(e, op->h, H_OUTGOING, orq, ctx) != 0) {
            nta_outgoing_destroy(orq);
            enif_free(ctx);
            send_op_failed(e, op->h, "alloc failed");
            break;
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
        break;
    }
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
    case OP_SEND: {
        /* fire-and-forget send (ACK to a 2xx). Create the outgoing
         * transaction to put the message on the wire, then destroy it
         * immediately: an ACK gets no response. mcreate queues the
         * message on the transport before returning. */
        msg_t *m = op_msg(op);
        if (!m) {
            send_op_failed(e, op->h, "unparseable message");
            break;
        }
        url_string_t *route = op->route ? URL_STRING_MAKE(op->route) : NULL;
        flow_t *f = op->flow ? tab_get(e, op->flow, H_FLOW) : NULL;
        if (op->flow && !f) {
            msg_destroy(m);
            send_op_failed(e, op->h, "unknown flow");
            break;
        }
        nta_outgoing_t *orq = nta_outgoing_mcreate(
            e->agent, NULL, NULL, route, m,
            TAG_IF(f, NTATAG_TPORT(f ? f->tp : NULL)),
            TAG_IF(op->ident[0] && e->has_idents, TPTAG_IDENT(op->ident)),
            TAG_END());
        if (!orq) {
            msg_destroy(m);
            send_op_failed(e, op->h, "nta_outgoing_mcreate (send) failed");
            break;
        }
        nta_outgoing_destroy(orq);
        send_op_ok(e, op->h);
        break;
    }
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
    enif_release_resource(e);
}

/* Post an op to the stack thread. Caller MUST hold root_lock (read) and have
 * checked e->root != NULL, so su_root_task cannot race a root destroy. */
NODISCARD static int enqueue_locked(engine_t *e, const op_t *tpl) {
    su_msg_r msg = SU_MSG_R_INIT;
    if (su_msg_create(msg, su_root_task(e->root), su_task_null, op_cb,
                      sizeof(op_t)) != 0)
        return -1;
    op_t *op = (op_t *)su_msg_data(msg);
    *op = *tpl;
    op->e = e;
    enif_keep_resource(e);
    if (su_msg_send(msg) != 0) {
        enif_release_resource(e);
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

/* ---------- stack thread ---------- */

/* Record an init failure. CAS INIT->FAILED so a concurrent nif_start abandon
 * (INIT->STOPPING, taken when start times out) is not clobbered; if the CAS
 * loses, the state stays STOPPING and we exit as abandoned. */
static void set_failed(engine_t *e, const char *why) {
    (void)snprintf(e->errbuf, sizeof e->errbuf, "%s", why);
    int expect = ST_INIT;
    (void)atomic_compare_exchange_strong(&e->state, &expect, ST_FAILED);
}

/* Every stack-thread exit releases the thread's own resource ref (taken before
 * enif_thread_create). The thread never joins itself; a joiner (nif_start /
 * nif_stop) or engine_dtor reclaims the thread handle. Holding this ref for
 * the whole thread lifetime means engine_dtor - which runs only at refcount 0
 * - cannot free e while the thread is still alive; that removes the stop-hung
 * use-after-free (F1) without ever blocking a scheduler in the destructor. */
/* ---------- HEP capture socket (stack thread only) ---------- */

/* The open file descriptors of the process, sorted ascending, into a new
 * array; *n is its length. NULL when /dev/fd cannot be read. The listing's
 * own descriptor is left out: it is closed on return, and the next socket
 * may well reuse it. */
static int fd_cmp(const void *a, const void *b) {
    int x = *(const int *)a, y = *(const int *)b;
    return (x > y) - (x < y);
}

/* A decimal integer in lo..hi, the whole of s: no sign, no blank, no
 * trailing byte. 0 and the value in *out, or -1. */
NODISCARD static int parse_long(const char *s, long lo, long hi, long *out) {
    if (!s || !isdigit((unsigned char)s[0])) return -1;
    char *end = NULL;
    errno = 0;
    long v = strtol(s, &end, 10);
    if (errno != 0 || end == s || *end != 0 || v < lo || v > hi) return -1;
    *out = v;
    return 0;
}

static int *open_fds(size_t *n) {
    *n = 0;
    DIR *d = opendir("/dev/fd");
    if (!d) return NULL;
    size_t cap = 64, bytes = 0;
    int *fds = chk_mul(&bytes, cap, sizeof *fds) ? NULL : enif_alloc(bytes);
    int self = dirfd(d);
    struct dirent *de;
    while (fds && (de = readdir(d)) != NULL) {
        long fd;
        /* ".", ".." and anything that is not a descriptor number */
        if (parse_long(de->d_name, 0, INT_MAX, &fd) != 0) continue;
        if (fd == self) continue;
        if (*n == cap) {
            size_t ncap;
            int *more = NULL;
            if (!chk_mul(&ncap, cap, (size_t)2) &&
                !chk_mul(&bytes, ncap, sizeof *fds))
                more = enif_realloc(fds, bytes);
            if (!more) {
                enif_free(fds);
                fds = NULL;
                break;
            }
            fds = more;
            cap = ncap;
        }
        fds[(*n)++] = (int)fd;
    }
    closedir(d);
    if (fds) qsort(fds, *n, sizeof *fds, fd_cmp);
    return fds;
}

/* the port of a capture URL, "udp:host:port;params"; -1 when there is no
 * port in 1..65535 */
static int capture_port(const char *url) {
    char buf[MAX_CONTACT];
    (void)snprintf(buf, sizeof buf, "%s", url);
    char *semi = strchr(buf, ';');
    if (semi) *semi = 0;
    char *colon = strrchr(buf, ':');
    long port;
    if (!colon || parse_long(colon + 1, 1, 65535, &port) != 0) return -1;
    return (int)port;
}

/* tport opens the capture socket while the agent is created and never
 * closes it (tport_destroy leaves mr_capt_sock open). It is the datagram
 * socket that appeared during the create, connected to the collector's
 * port: find it so teardown can close it. -1 when there is none. */
static int capture_fd(const int *before, size_t nbefore, int port) {
    size_t n;
    int *after = open_fds(&n);
    int found = -1;
    for (size_t i = 0; after && i < n && found < 0; i++) {
        int fd = after[i];
        if (before && bsearch(&fd, before, nbefore, sizeof fd, fd_cmp))
            continue;
        int type = 0;
        socklen_t tl = sizeof type;
        struct sockaddr_storage ss;
        socklen_t sl = sizeof ss;
        if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &tl) != 0 ||
            type != SOCK_DGRAM ||
            getpeername(fd, (struct sockaddr *)&ss, &sl) != 0)
            continue;
        int peer = ss.ss_family == AF_INET6
            ? ntohs(((struct sockaddr_in6 *)&ss)->sin6_port)
            : ntohs(((struct sockaddr_in *)&ss)->sin_port);
        if (peer == port) found = fd;
    }
    if (after) enif_free(after);
    return found;
}

/* the agent is gone: so is the capture, close its socket */
static void agent_destroy(engine_t *e) {
    if (e->agent) {
        nta_agent_destroy(e->agent);
        e->agent = NULL;
    }
    if (e->capt_fd >= 0) {
        close(e->capt_fd);
        e->capt_fd = -1;
    }
}

static void *thread_exit(engine_t *e) {
    enif_release_resource(e);
    return NULL;
}

/* Destroy the sofia objects on the stack thread. The root destroy is under the
 * write lock so no foreign op can be mid-enqueue on the root (F2). */
static void teardown_sofia(engine_t *e) {
    atomic_store(&g_log_engine, NULL);
    tab_drain(e);
    agent_destroy(e);
    orphans_sweep(e, 1);
    /* A request nta could not send is answered through a message nta posts to
     * its own root, which can still be queued when OP_STOP breaks the loop.
     * It holds a reference on the root's port, so the root would never be
     * freed. Deliver it: the transaction is gone, so it only frees itself. */
    if (e->root) (void)su_root_step(e->root, 0);
    enif_rwlock_rwlock(e->root_lock);
    if (e->root) { su_root_destroy(e->root); e->root = NULL; }
    enif_rwlock_rwunlock(e->root_lock);
    su_home_deinit(e->home);
    atomic_store(&e->state, ST_EXITED);
}

static void *stack_main(void *arg) {
    engine_t *e = arg;

    su_home_init(e->home);
    e->root = su_root_create(e);
    if (!e->root) {
        set_failed(e, "su_root_create failed");
        su_home_deinit(e->home);
        return thread_exit(e);
    }

    /* NTATAG_UA(1): act as a UA endpoint so nta absorbs INVITE ACKs for
     * non-2xx and retransmits 2xx until ACK, matching our UAS model.
     * NTATAG_EXTRA_100(1): let nta answer a retransmitted request with 100
     * Trying; the first 100 for an INVITE is ours (deliver_request).
     * NTATAG_MERGE_482(0): merged-request detection (RFC 3261 8.2.2.2) is
     * a UAS duty and runs in Erlang, which knows a proxied transaction: a
     * request spiralling back through the proxy is not merged.
     * NTATAG_CANCEL_487(0): a CANCELled INVITE is answered 487 by
     * invite_ack_cancel_cb unless a proxy owns it (16.10). NTATAG_RPORT(1): an empty rport in the Via of our UDP
     * requests (RFC 3581 3). NTATAG_BAD_REQ_MASK: a malformed header
     * answers 400 only when a UA needs it to process any request (RFC 3261
     * 8.2.2); the nta default also counts the events and publish classes,
     * so a bad Expires on an INVITE would be fatal. TPTAG_PONG2PING(1):
     * answer a CRLFCRLF keepalive ping on a TCP/TLS connection with a CRLF
     * pong (RFC 5626 4.4.1); tport passes it on to the transports.
     * stray_cb gets the responses that match no client transaction: a
     * second 2xx of a proxy branch on TCP/TLS (RFC 6026). TPTAG_CAPT: tport
     * sends a HEP copy of every message it sends and receives to the
     * capture server. */
    size_t nbefore = 0;
    int *before = e->capture[0] ? open_fds(&nbefore) : NULL;
    e->agent = nta_agent_create(
        e->root, URL_STRING_MAKE(e->contact), stray_cb, (nta_agent_magic_t *)e,
        /* max_msg_size is bounded by MAX_MSG_SIZE, which fits usize_t */
        NTATAG_MAXSIZE((usize_t)e->max_msg_size), NTATAG_UA(1),
        NTATAG_EXTRA_100(1), NTATAG_MERGE_482(0), NTATAG_CANCEL_487(0),
        NTATAG_RPORT(1), TPTAG_PONG2PING(1),
        TAG_IF(e->capture[0], TPTAG_CAPT(e->capture)),
        TAG_IF(e->ident[0], TPTAG_IDENT(e->ident)),
        NTATAG_BAD_REQ_MASK(~(unsigned)(sip_mask_response | sip_mask_proxy |
                                        sip_mask_registrar | sip_mask_pref |
                                        sip_mask_privacy | sip_mask_events |
                                        sip_mask_publish)),
        TAG_END());
    if (before)
        e->capt_fd = capture_fd(before, nbefore, capture_port(e->capture));
    if (before) enif_free(before);
    if (!e->agent) {
        set_failed(e, "nta_agent_create failed (bad or busy contact?)");
        agent_destroy(e);
        su_root_destroy(e->root);
        e->root = NULL;
        su_home_deinit(e->home);
        return thread_exit(e);
    }

    /* no default leg: a request no dialog leg takes reaches stray_cb
     * before nta makes a transaction of it (request_in) */

    /* the other listen addresses, each with the ident a send names it by */
    const char *bind_err = NULL;
    for (int i = 0; i < e->nx && !bind_err; i++) {
        if (nta_agent_add_tport(e->agent, URL_STRING_MAKE(e->xcontact[i]),
                                TPTAG_IDENT(e->xident[i]), TPTAG_PONG2PING(1),
                                TAG_END()) < 0)
            bind_err = "nta_agent_add_tport failed (bad or busy contact?)";
    }

    /* optional TLS listeners, each on its own port. Comma-listed
     * transports share one port, so a secure transport needs a separate
     * bind. Certificates live in the cert dir (agent.pem cert+key,
     * cafile.pem). TPTAG_TLS_VERSION must be set explicitly: the default
     * disables modern TLS. */
    if (e->tls_contact[0] && !bind_err) {
        /* TLS 1.2 floor: 1.0/1.1 are deprecated (sofia has no 1.3 constant,
         * so 1.3 is left to the OpenSSL context default). */
        unsigned ver = TPTLS_VERSION_TLSv1_2;
        /* outbound: the server certificate must chain to cafile.pem and
         * name the target host (RFC 5922 7.3, sofia's subject search over
         * subjectAltName and CN); inbound: a client certificate only when
         * asked for */
        unsigned policy =
            (e->tls_verify_peer ? TPTLS_VERIFY_SUBJECTS_OUT : 0) |
            (e->tls_verify_clients ? TPTLS_VERIFY_IN : 0);
        /* sofia requires a cipher list (SSL_CTX_set_cipher_list fails on
         * NULL); provide a sane default when the caller gives none. */
        const char *ciphers = e->tls_ciphers[0]
            ? e->tls_ciphers
            : "HIGH:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK";
        for (int i = -1; i < e->ntlsx && !bind_err; i++) {
            const char *url = i < 0 ? e->tls_contact : e->tls_xcontact[i];
            const char *id = i < 0 ? e->tls_ident : e->tls_xident[i];
            int rc = nta_agent_add_tport(
                e->agent, URL_STRING_MAKE(url),
                TAG_IF(e->tls_cert_dir[0], TPTAG_CERTIFICATE(e->tls_cert_dir)),
                TPTAG_TLS_VERSION(ver),
                TPTAG_TLS_CIPHERS(ciphers),
                TPTAG_TLS_VERIFY_POLICY(policy),
                TPTAG_PONG2PING(1),
                TAG_IF(id[0], TPTAG_IDENT(id)),
                TAG_IF(e->tls_passphrase[0],
                       TPTAG_TLS_PASSPHRASE(e->tls_passphrase)),
                TAG_END());
            if (rc < 0) bind_err = "nta_agent_add_tport (tls) failed (certs?)";
        }
    }
    if (bind_err) {
        set_failed(e, bind_err);
        agent_destroy(e);
        su_root_destroy(e->root);
        e->root = NULL;
        su_home_deinit(e->home);
        return thread_exit(e);
    }

    /* init done: publish READY, unless nif_start abandoned us. The CAS makes
     * the READY transition and the abandon (INIT->STOPPING) mutually
     * exclusive, so a thread the start already gave up on never goes READY and
     * runs orphaned (F12). */
    {
        int expect = ST_INIT;
        if (!atomic_compare_exchange_strong(&e->state, &expect, ST_READY)) {
            teardown_sofia(e);
            return thread_exit(e);
        }
    }

    atomic_store(&g_log_engine, e);

    {
        sip_contact_t *m = nta_agent_contact(e->agent);
        char *s = m ? sip_header_as_string(e->home, (sip_header_t *)m) : NULL;
        send_event(e, mk_started_ev, s ? s : (char *)e->contact);
        if (s) su_free(e->home, s);
    }

    su_root_run(e->root);

    teardown_sofia(e);
    return thread_exit(e);
}

/* ---------- resource callbacks ---------- */

/* Ask a running (READY) stack thread to stop. The OP_STOP op_cb breaks the
 * loop on the stack thread itself, so we do not touch e->root cross-thread. */
static void request_stop(engine_t *e) {
    /* Take the WRITE lock so the state flip + OP_STOP enqueue is mutually
     * exclusive with foreign enqueue(), which holds the READ lock across its
     * state-check AND su_msg_send. That guarantees every foreign op already
     * in flight is queued before OP_STOP, and any enqueue after us sees
     * ST_STOPPING and is rejected. Without this, both post under a shared read
     * lock, so an op could land behind OP_STOP; su_root_break then tears down
     * before its op_cb runs, leaking the op payload + the kept engine ref
     * (refcount never hits 0, wedging the engine at G_STOPPING). */
    enif_rwlock_rwlock(e->root_lock);
    int expect = ST_READY;
    if (atomic_compare_exchange_strong(&e->state, &expect, ST_STOPPING)) {
        /* We hold the READY->STOPPING transition, so su_root_run is still
         * running and root is alive. If enqueue fails (OOM) the loop is not
         * woken and a waiter times out rather than breaking root here. */
        if (e->root != NULL) {
            op_t op = {.kind = OP_STOP};
            if (enqueue_locked(e, &op) != 0)
                (void)fprintf(stderr, "chappe_sip_engine: could not post the stop "
                        "op; the stop waits out its bound\n");
        }
        atomic_store(&g_engine_state, G_STOPPING);
    }
    enif_rwlock_rwunlock(e->root_lock);
}

/* Stop the stack thread and join it. MUST be called off the stack thread.
 * Returns 1 if the thread stopped and was joined, 0 if it did not stop within
 * the bound (then we do NOT join - joining a stuck thread would block). */
static int stop_wait_join(engine_t *e) {
    request_stop(e);
    int waited = 0;
    for (;;) {
        int st = atomic_load(&e->state);
        if (st == ST_EXITED || st == ST_FAILED) break;
        if (waited >= ENGINE_STOP_WAIT_MS) return 0;
        msleep(POLL_STEP_MS);
        waited += POLL_STEP_MS;
    }
    if (atomic_exchange(&e->tid_valid, 0)) {
        enif_thread_join(e->tid, NULL);
    }
    return 1;
}

static void engine_dtor(ErlNifEnv *env, void *obj) {
    (void)env;
    engine_t *e = obj;
    /* The stack thread holds a resource ref for its whole life, so reaching
     * refcount 0 here means it has already exited: no stop or bounded wait is
     * needed, and memory is never freed under a running (or stuck) thread.
     * Reclaim the thread handle unless we ARE the stack thread dropping its own
     * last ref (an abandoned start/stop), where a self-join would deadlock.
     * An engine refused before its thread was created has no tid at all:
     * comparing that unset tid aborts the VM (erl_drv_equal_tids), so
     * tid_valid is read first. */
    if (atomic_load(&e->tid_valid) &&
        !enif_equal_tids(e->tid, enif_thread_self()) &&
        atomic_exchange(&e->tid_valid, 0)) {
        enif_thread_join(e->tid, NULL);
    }
    if (e->root_lock) {
        enif_rwlock_destroy(e->root_lock);
        e->root_lock = NULL;
    }
    /* Release the singleton only if it is still G_STOPPING -- i.e. this engine
     * (abandoned/hung start, or an owner-death stop) still holds the slot and
     * no successor exists (none can start while STOPPING). A clean nif_stop
     * already set G_NONE, after which a new engine may hold G_RUNNING;
     * unconditionally storing G_NONE here would clobber that successor and
     * break the one-engine invariant during stop/start churn. */
    int expect = G_STOPPING;
    atomic_compare_exchange_strong(&g_engine_state, &expect, G_NONE);
    TSAN_RELEASE(e);
}

static void engine_down(ErlNifEnv *env, void *obj, ErlNifPid *pid,
                        ErlNifMonitor *mon) {
    (void)env;
    (void)pid;
    (void)mon;
    /* Owner died without stopping: initiate async stop; the restarted
     * owner retries start against the {error, stopping} guard. */
    engine_t *e = obj;
    request_stop(e);
}

/* ---------- NIFs ---------- */

/* ---------- argument checks ----------
 *
 * sofia takes headers, bodies, routes and option values as C strings: an
 * embedded NUL would cut one short, so every such argument is refused
 * (badarg) when it carries one. Sizes are capped before any copy. */

/* the binary holds a NUL byte */
static int has_nul(const ErlNifBinary *b) {
    return b->size > 0 && memchr(b->data, 0, b->size) != NULL;
}

/* b as a C string into out (outlen bytes); -1 when it has a NUL or does
 * not fit with its terminator */
NODISCARD static int bin_cstr(const ErlNifBinary *b, char *out,
                              size_t outlen) {
    if (has_nul(b) || b->size >= outlen) return -1;
    if (b->size) memcpy(out, b->data, b->size);
    out[b->size] = 0;
    return 0;
}

/* an optional start option: absent, set, or there but invalid */
enum { OPT_BAD = -1, OPT_ABSENT = 0, OPT_SET = 1 };

/* key => binary, as a C string into out */
NODISCARD static int get_opt_bin(ErlNifEnv *env, ERL_NIF_TERM map,
                                 ERL_NIF_TERM key, char *out, size_t outlen) {
    ERL_NIF_TERM v;
    ErlNifBinary b;
    if (!enif_get_map_value(env, map, key, &v)) return OPT_ABSENT;
    if (!enif_inspect_binary(env, v, &b) || bin_cstr(&b, out, outlen) != 0)
        return OPT_BAD;
    return OPT_SET;
}

/* key => true | false into *out (def when absent); -1 for anything else */
NODISCARD static int get_opt_bool(ErlNifEnv *env, ERL_NIF_TERM map,
                                  ERL_NIF_TERM key, int def, int *out) {
    ERL_NIF_TERM v;
    *out = def;
    if (!enif_get_map_value(env, map, key, &v)) return 0;
    if (enif_is_identical(v, am_true)) *out = 1;
    else if (enif_is_identical(v, am_false)) *out = 0;
    else return -1;
    return 0;
}

/* contacts => [{Uri, Ident}]: the listen addresses after the first, into
 * urls/idents; their count in *n. 0 on a malformed or too long list. */
static int get_binds(ErlNifEnv *env, ERL_NIF_TERM map,
                     char urls[][MAX_CONTACT], char idents[][MAX_IDENT],
                     int *n) {
    ERL_NIF_TERM list, head;
    *n = 0;
    if (!enif_get_map_value(env, map, am_contacts, &list)) return 1;
    while (enif_get_list_cell(env, list, &head, &list)) {
        int arity;
        const ERL_NIF_TERM *t;
        ErlNifBinary u, id;
        if (*n >= MAX_BINDS || !enif_get_tuple(env, head, &arity, &t) ||
            arity != 2 || !enif_inspect_binary(env, t[0], &u) ||
            !enif_inspect_binary(env, t[1], &id) || u.size == 0 ||
            id.size == 0 || bin_cstr(&u, urls[*n], MAX_CONTACT) != 0 ||
            bin_cstr(&id, idents[*n], MAX_IDENT) != 0)
            return 0;
        (*n)++;
    }
    return enif_is_empty_list(env, list);
}

/* optional HEP capture: capture => <<"udp:host:port;hep=3;...">>, with a
 * port in 1..65535 (<<>>: off) */
static int get_capture(ErlNifEnv *env, ERL_NIF_TERM opts, engine_t *e) {
    int rc = get_opt_bin(env, opts, am_capture, e->capture, sizeof e->capture);
    return rc != OPT_BAD && (!e->capture[0] || capture_port(e->capture) > 0);
}

/* max_message_size => MIN_MSG_SIZE..MAX_MSG_SIZE (default when absent) */
static int get_max_size(ErlNifEnv *env, ERL_NIF_TERM opts, engine_t *e) {
    ERL_NIF_TERM v;
    unsigned long sz;
    if (!enif_get_map_value(env, opts, am_max_message_size, &v)) return 1;
    if (!enif_get_ulong(env, v, &sz) || sz < MIN_MSG_SIZE ||
        sz > MAX_MSG_SIZE)
        return 0;
    e->max_msg_size = (size_t)sz;
    return 1;
}

/* optional TLS transport: #{tls => #{contact := ..., cert_dir => ...,
 * passphrase => ..., ciphers => ..., verify => none | peer,
 * verify_clients => boolean()}} */
static int get_tls(ErlNifEnv *env, ERL_NIF_TERM opts, engine_t *e) {
    ERL_NIF_TERM tls, vv;
    if (!enif_get_map_value(env, opts, am_tls, &tls)) return 1;
    if (!enif_is_map(env, tls) ||
        get_opt_bin(env, tls, am_contact, e->tls_contact,
                    sizeof e->tls_contact) == OPT_BAD ||
        get_opt_bin(env, tls, am_ident, e->tls_ident,
                    sizeof e->tls_ident) == OPT_BAD ||
        !get_binds(env, tls, e->tls_xcontact, e->tls_xident, &e->ntlsx) ||
        get_opt_bin(env, tls, am_cert_dir, e->tls_cert_dir,
                    sizeof e->tls_cert_dir) == OPT_BAD ||
        get_opt_bin(env, tls, am_passphrase, e->tls_passphrase,
                    sizeof e->tls_passphrase) == OPT_BAD ||
        get_opt_bin(env, tls, am_ciphers, e->tls_ciphers,
                    sizeof e->tls_ciphers) == OPT_BAD ||
        get_opt_bool(env, tls, am_verify_clients, 0,
                     &e->tls_verify_clients) != 0)
        return 0;
    /* verify defaults to peer: only an explicit none (which the Erlang
     * side accepts with allow_insecure only) turns it off */
    e->tls_verify_peer = 1;
    if (enif_get_map_value(env, tls, am_verify, &vv)) {
        if (enif_is_identical(vv, am_none)) e->tls_verify_peer = 0;
        else if (!enif_is_identical(vv, am_peer)) return 0;
    }
    return 1;
}

/* a start that never got its thread: free the singleton and the engine */
static ERL_NIF_TERM start_refused(ErlNifEnv *env, engine_t *e) {
    atomic_store(&g_engine_state, G_NONE);
    enif_release_resource(e);
    return enif_make_tuple2(env, am_error, am_badarg);
}

static ERL_NIF_TERM nif_start(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
    if (argc != 2 || !enif_is_map(env, argv[0]))
        return enif_make_badarg(env);

    ErlNifPid owner;
    if (!enif_get_local_pid(env, argv[1], &owner))
        return enif_make_badarg(env);

    /* singleton guard, serializes detach/stop/reattach */
    int expect = G_NONE;
    if (!atomic_compare_exchange_strong(&g_engine_state, &expect, G_RUNNING)) {
        return enif_make_tuple2(
            env, am_error, expect == G_STOPPING ? am_stopping : am_already_started);
    }

    engine_t *e = enif_alloc_resource(ENGINE_RT, sizeof(engine_t));
    if (!e) {
        atomic_store(&g_engine_state, G_NONE);
        return enif_make_tuple2(env, am_error, am_badarg);
    }
    TSAN_ACQUIRE(e);
    memset(e, 0, sizeof *e);
    e->owner = owner;
    e->max_msg_size = DEFAULT_MAX_MSG_SIZE;
    e->capt_fd = -1;
    atomic_init(&e->state, ST_INIT);

    e->root_lock = enif_rwlock_create("chappe_sip_root");
    if (!e->root_lock) return start_refused(env, e);

    /* every option that is there must be valid: one that is not fails the
     * start rather than being ignored */
    if (get_opt_bin(env, argv[0], am_contact, e->contact,
                    sizeof e->contact) != OPT_SET ||
        !e->contact[0] ||
        !get_binds(env, argv[0], e->xcontact, e->xident, &e->nx) ||
        get_opt_bin(env, argv[0], am_ident, e->ident, sizeof e->ident) ==
            OPT_BAD ||
        !get_capture(env, argv[0], e) || !get_max_size(env, argv[0], e) ||
        !get_tls(env, argv[0], e))
        return start_refused(env, e);

    /* a send may name an ident only when every transport has one: tport
     * compares it with each primary's ident without a NULL check. More
     * than one address needs idents throughout. */
    e->has_idents = e->ident[0] && (!e->tls_contact[0] || e->tls_ident[0]);
    if ((e->nx > 0 || e->ntlsx > 0) && !e->has_idents)
        return start_refused(env, e);

    /* the stack thread holds its own resource ref for its whole life (released
     * in thread_exit), so e outlives the thread and the destructor never frees
     * under it. Take it before create; undo it if create fails. */
    enif_keep_resource(e);
    if (enif_thread_create("chappe_sip_stack", &e->tid, stack_main, e, NULL) != 0) {
        enif_release_resource(e);   /* the thread ref (thread never ran) */
        atomic_store(&g_engine_state, G_NONE);
        enif_release_resource(e);   /* the start ref */
        return enif_make_tuple2(env, am_error,
                                mkbin(env, "thread_create failed", 20));
    }
    e->tid_valid = 1;

    /* readiness barrier */
    int waited = 0;
    for (;;) {
        int st = atomic_load(&e->state);
        if (st == ST_READY) break;
        if (st == ST_FAILED) {
            enif_thread_join(e->tid, NULL);
            e->tid_valid = 0;
            atomic_store(&g_engine_state, G_NONE);
            ERL_NIF_TERM why = mkbin(env, e->errbuf, strlen(e->errbuf));
            enif_release_resource(e);
            return enif_make_tuple2(
                env, am_error, enif_make_tuple2(env, am_engine_start, why));
        }
        if (waited >= ENGINE_START_WAIT_MS) {
            /* Thread stuck in init and not yet in its loop, so it cannot be
             * broken and joining would block a scheduler. Abandon it by winning
             * the INIT->STOPPING transition: the thread, if it unblocks, then
             * fails its INIT->READY CAS, tears down and drops its own ref (which
             * frees e and resets the singleton). Drop only the start ref here;
             * the thread's ref keeps e alive. If the CAS loses, the thread just
             * reached READY/FAILED - loop to handle it normally. */
            int einit = ST_INIT;
            if (atomic_compare_exchange_strong(&e->state, &einit, ST_STOPPING)) {
                atomic_store(&g_engine_state, G_STOPPING);
                enif_release_resource(e);   /* the start ref */
                return enif_make_tuple2(env, am_error, am_hung);
            }
            continue;
        }
        msleep(POLL_STEP_MS);
        waited += POLL_STEP_MS;
    }

    if (enif_monitor_process(env, e, &owner, &e->owner_mon) != 0) {
        /* owner already dead: the thread is READY, so stop and join it before
         * dropping the base ref (never free e under the running thread) */
        stop_wait_join(e);
        atomic_store(&g_engine_state, G_NONE);
        enif_release_resource(e);
        return enif_make_tuple2(env, am_error, am_badarg);
    }

    ERL_NIF_TERM ref = enif_make_resource(env, e);
    enif_release_resource(e); /* term holds it now */
    return enif_make_tuple2(env, am_ok, ref);
}

static ERL_NIF_TERM nif_stop(ErlNifEnv *env, int argc,
                             const ERL_NIF_TERM argv[]) {
    engine_t *e;
    if (argc != 1 || !enif_get_resource(env, argv[0], ENGINE_RT, (void **)&e))
        return enif_make_badarg(env);

    if (!stop_wait_join(e)) {
        /* The thread did not stop in the bound. Do NOT join or free here: the
         * thread still holds its resource ref, so e stays alive and the
         * destructor cannot run under it (F1). If it ever unblocks it tears
         * down, drops its ref, and resets the singleton; g_engine_state stays
         * STOPPING until then, so heart/systemd can restart the node. */
        return enif_make_tuple2(env, am_error, am_hung);
    }
    enif_demonitor_process(env, e, &e->owner_mon);
    atomic_store(&g_engine_state, G_NONE);
    return am_ok;
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
static ERL_NIF_TERM nif_respond(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
    return nif_reply(env, argc, argv, OP_RESPOND, 100, 699);
}

/* Single monotonic id space for every handle (incoming txns, legs,
 * outgoing txns), so caller-reserved ids never collide with
 * stack-thread-allocated ones. */
static _Atomic uint64_t g_next_id = 1;

static uint64_t reserve_id(void) {
    return atomic_fetch_add(&g_next_id, 1);
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
static ERL_NIF_TERM nif_request(ErlNifEnv *env, int argc,
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
static ERL_NIF_TERM nif_reliable_respond(ErlNifEnv *env, int argc,
                                         const ERL_NIF_TERM argv[]) {
    return nif_reply(env, argc, argv, OP_RELIABLE_1XX, 101, 199);
}

/* send(Engine, Route|FlowId|undefined, Raw[, Ident]) -> {ok, OpH}
 * Stateless fire-and-forget send (ACK to a 2xx). op_ok/op_failed follows;
 * no response is delivered. */
static ERL_NIF_TERM nif_send(ErlNifEnv *env, int argc,
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
static ERL_NIF_TERM nif_relay(ErlNifEnv *env, int argc,
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
static ERL_NIF_TERM nif_send_response(ErlNifEnv *env, int argc,
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
static ERL_NIF_TERM nif_cancel(ErlNifEnv *env, int argc,
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
static ERL_NIF_TERM nif_proxy_mark(ErlNifEnv *env, int argc,
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
static ERL_NIF_TERM nif_txn_done(ErlNifEnv *env, int argc,
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
static ERL_NIF_TERM nif_discard(ErlNifEnv *env, int argc,
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
static ERL_NIF_TERM nif_block(ErlNifEnv *env, int argc,
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
static ERL_NIF_TERM nif_stats(ErlNifEnv *env, int argc,
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
static ERL_NIF_TERM nif_leg_create(ErlNifEnv *env, int argc,
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
static ERL_NIF_TERM nif_leg_destroy(ErlNifEnv *env, int argc,
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

static ERL_NIF_TERM nif_health(ErlNifEnv *env, int argc,
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

/* ---------- module lifecycle ---------- */

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    (void)priv;
    (void)info;
    ErlNifResourceTypeInit init = {
        .dtor = engine_dtor,
        .stop = NULL,
        .down = engine_down,
    };
    ENGINE_RT = enif_open_resource_type_x(env, "chappe_sip_engine", &init,
                                          ERL_NIF_RT_CREATE, NULL);
    if (!ENGINE_RT) return -1;
    if (!g_blk_lock) g_blk_lock = enif_mutex_create("chappe_sip_blocklist");
    if (!g_blk_lock) return -1;

    /* su_init() installs SIG_IGN for SIGPIPE process-wide; save BEAM's
     * disposition and restore it so the VM's signal handling is
     * preserved (sofia's own socket writes use SO_NOSIGPIPE/MSG_NOSIGNAL). */
    struct sigaction old_pipe;
    int saved = (sigaction(SIGPIPE, NULL, &old_pipe) == 0);
    su_init();
    if (saved) sigaction(SIGPIPE, &old_pipe, NULL);
    su_log_redirect(NULL, log_cb, NULL);

    am_ok = enif_make_atom(env, "ok");
    am_error = enif_make_atom(env, "error");
    am_undefined = enif_make_atom(env, "undefined");
    am_chappe_sip_engine = enif_make_atom(env, "chappe_sip_engine");
    am_request = enif_make_atom(env, "request");
    am_health_ok = enif_make_atom(env, "health_ok");
    am_started = enif_make_atom(env, "started");
    am_log = enif_make_atom(env, "log");
    am_method = enif_make_atom(env, "method");
    am_source_ip = enif_make_atom(env, "source_ip");
    am_source_port = enif_make_atom(env, "source_port");
    am_ack_timeout = enif_make_atom(env, "ack_timeout");
    am_not_ready = enif_make_atom(env, "not_ready");
    am_not_found = enif_make_atom(env, "not_found");
    am_stopping = enif_make_atom(env, "stopping");
    am_already_started = enif_make_atom(env, "already_started");
    am_hung = enif_make_atom(env, "hung");
    am_badarg = enif_make_atom(env, "badarg");
    am_contact = enif_make_atom(env, "contact");
    am_max_message_size = enif_make_atom(env, "max_message_size");
    am_engine_start = enif_make_atom(env, "engine_start");
    am_op_ok = enif_make_atom(env, "op_ok");
    am_op_failed = enif_make_atom(env, "op_failed");
    am_response = enif_make_atom(env, "response");
    am_ack = enif_make_atom(env, "ack");
    am_cancel = enif_make_atom(env, "cancel");
    am_status = enif_make_atom(env, "status");
    am_tls = enif_make_atom(env, "tls");
    am_cert_dir = enif_make_atom(env, "cert_dir");
    am_passphrase = enif_make_atom(env, "passphrase");
    am_verify = enif_make_atom(env, "verify");
    am_peer = enif_make_atom(env, "peer");
    am_ciphers = enif_make_atom(env, "ciphers");
    am_prack = enif_make_atom(env, "prack");
    am_transport = enif_make_atom(env, "transport");
    am_verify_clients = enif_make_atom(env, "verify_clients");
    am_true = enif_make_atom(env, "true");
    am_conn = enif_make_atom(env, "conn");
    am_flow_closed = enif_make_atom(env, "flow_closed");
    am_capture = enif_make_atom(env, "capture");
    am_ident = enif_make_atom(env, "ident");
    am_contacts = enif_make_atom(env, "contacts");
    am_local = enif_make_atom(env, "local");
    am_local_ip = enif_make_atom(env, "local_ip");
    am_local_port = enif_make_atom(env, "local_port");
    am_false = enif_make_atom(env, "false");
    am_none = enif_make_atom(env, "none");
    am_enomem = enif_make_atom(env, "enomem");
    am_incoming = enif_make_atom(env, "incoming");
    am_discarded = enif_make_atom(env, "discarded");
    am_events_dropped = enif_make_atom(env, "events_dropped");
    am_alloc_failed = enif_make_atom(env, "alloc_failed");
    return 0;
}

static int upgrade(ErlNifEnv *env, void **priv, void **old_priv,
                   ERL_NIF_TERM info) {
    (void)env;
    (void)priv;
    (void)old_priv;
    (void)info;
    /* Refuse hot upgrade while an engine is live; the old module stays. */
    if (atomic_load(&g_engine_state) != G_NONE) return -1;
    return 0;
}

static void unload(ErlNifEnv *env, void *priv) {
    (void)env;
    (void)priv;
    /* upgrade() refused while running, so no engine is live here */
    su_deinit();
}

static ErlNifFunc nif_funcs[] = {
    {"start", 2, nif_start, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"stop", 1, nif_stop, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"respond", 7, nif_respond, 0},
    {"reliable_respond", 7, nif_reliable_respond, 0},
    {"request", 3, nif_request, 0},
    {"request", 4, nif_request, 0},
    {"request", 5, nif_request, 0},
    {"proxy_mark", 2, nif_proxy_mark, 0},
    {"send", 3, nif_send, 0},
    {"send", 4, nif_send, 0},
    {"send_response", 2, nif_send_response, 0},
    {"relay", 4, nif_relay, 0},
    {"cancel", 2, nif_cancel, 0},
    {"cancel", 3, nif_cancel, 0},
    {"txn_done", 2, nif_txn_done, 0},
    {"leg_create", 4, nif_leg_create, 0},
    {"leg_destroy", 2, nif_leg_destroy, 0},
    {"health", 1, nif_health, 0},
    {"discard", 2, nif_discard, 0},
    {"block", 2, nif_block, 0},
    {"stats", 0, nif_stats, 0},
};

ERL_NIF_INIT(chappe_sip_nif, nif_funcs, load, NULL, upgrade, unload)
