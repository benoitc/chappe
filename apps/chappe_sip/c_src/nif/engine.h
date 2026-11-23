/*
 * engine.h - the private header of the NIF shim.
 *
 * Copyright 2026 Benoit Chesneau
 * SPDX-License-Identifier: Apache-2.0
 *
 * What more than one file of c_src/nif/ needs: the safety macros, the
 * limits, the engine, handle, flow and op types and the invariants they
 * keep, the event payloads, the shared globals (each defined once, in the
 * file named next to it) and a prototype of every function another file
 * calls. Everything else stays static in its file. See "Safety rules" in
 * docs/design/engine.md.
 */

#ifndef CHAPPE_SIP_ENGINE_H
#define CHAPPE_SIP_ENGINE_H

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
#include <strings.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <pthread.h>

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
/* RFC 3261 17 timers (ms): T1 may be smaller on a closed network, or
 * larger on a slow link; T2 caps the retransmit interval and is never
 * below T1; T4 is how long a message stays in the network */
#define MIN_SIP_T 10
#define MAX_SIP_T1 60000
#define MAX_SIP_T2 600000
#define MAX_SIP_T4 600000
/* udp_mtu: above it a request goes over TCP (RFC 3261 18.1.1); 576 is
 * the IPv4 datagram every host takes, 65535 the UDP limit */
#define MIN_UDP_MTU 576
#define MAX_UDP_MTU 65535
/* tcp_keepalive_ms: the CRLF ping interval on TCP (RFC 5626 4.4.1) */
#define MIN_KEEPALIVE_MS 1000
#define MAX_KEEPALIVE_MS 3600000
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

/* global singleton guard; G_RESERVED holds the slot for a replace of the
 * library (nif_reserve_slot), so no start runs on the image being replaced */
enum { G_NONE = 0, G_RUNNING, G_STOPPING, G_RESERVED };

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

    /* optional agent settings, 0 / "" for nta's default: the RFC 3261
     * timers, the UDP MTU, the CRLF keep-alive interval of TCP
     * connections, and the outbound proxy a request with no route of its
     * own goes to (NTATAG_DEFAULT_PROXY) */
    unsigned sip_t1, sip_t2, sip_t4;
    unsigned udp_mtu;
    unsigned tcp_keepalive;
    char outbound_proxy[MAX_CONTACT];

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
    /* 1 while this engine holds the singleton slot; whoever exchanges it to
     * 0 releases the slot, so a second stop of a stopped engine cannot free
     * the slot of the engine started after it */
    _Atomic int holds_slot;
    /* set by the stack thread as it returns; the joiner may then join it */
    _Atomic int thread_done;
} engine_t;

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

/* the source blocklist (blocklist.c) */
#define BLK_SLOTS 4096
#define BLK_PROBE 8
#define BLK_ADDR 64

typedef struct {
    char addr[BLK_ADDR];
    uint64_t until_ms;
} blk_ent_t;

/* event payloads (events.c builds the terms) */
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

struct resp_ev {
    uint64_t h;
    int status;
    char *raw;
    size_t raw_len;
};

struct ack_ev {
    uint64_t leg;
    char *raw;
    size_t raw_len;
};

struct cancel_ev {
    uint64_t h; /* the INVITE server-transaction handle */
    char *raw;  /* the CANCEL request */
    size_t raw_len;
};

struct prack_ev {
    uint64_t h; /* the INVITE server-transaction handle */
    uint64_t ph; /* the PRACK's own handle when the app answers it, else 0 */
    char *raw;
    size_t raw_len;
};

/* shared globals */
extern _Atomic int g_engine_state; /* lifecycle.c */
extern ErlNifResourceType *ENGINE_RT; /* lifecycle.c */
extern ErlNifMutex *g_life_lock; /* lifecycle.c */
extern _Atomic uint64_t g_incoming; /* events.c */
extern _Atomic uint64_t g_blk_drops; /* events.c */
extern _Atomic uint64_t g_events_dropped; /* events.c */
extern _Atomic uint64_t g_alloc_failed; /* events.c */
extern _Atomic(engine_t *) g_log_engine; /* events.c */
extern blk_ent_t g_blk[BLK_SLOTS]; /* blocklist.c */
extern ErlNifMutex *g_blk_lock; /* blocklist.c */
/* the atoms (main.c) */
extern ERL_NIF_TERM am_ok, am_error, am_undefined, am_chappe_sip_engine,
    am_request, am_health_ok, am_started, am_log, am_method, am_not_ready, am_not_found,
    am_stopping, am_already_started, am_hung, am_badarg, am_contact,
    am_max_message_size, am_engine_start, am_op_ok, am_op_failed, am_response,
    am_ack, am_cancel, am_status, am_tls, am_cert_dir, am_passphrase, am_verify,
    am_peer, am_ciphers, am_prack, am_source_ip, am_source_port,
    am_ack_timeout, am_transport, am_verify_clients, am_true, am_conn,
    am_flow_closed, am_capture, am_ident, am_contacts, am_local,
    am_local_ip, am_local_port, am_false, am_none, am_enomem, am_incoming,
    am_discarded, am_events_dropped, am_alloc_failed, am_sip_t1, am_sip_t2,
    am_sip_t4, am_udp_mtu, am_tcp_keepalive_ms, am_outbound_proxy, am_running,
    am_replacing, am_not_reserved;

/* functions another file calls, by the file that defines them */

/* lifecycle.c */
void engine_unref(engine_t *e);
void reap_thread(void);
void engine_dtor(ErlNifEnv *env, void *obj);
void engine_down(ErlNifEnv *env, void *obj, ErlNifPid *pid,
                 ErlNifMonitor *mon);
int has_nul(const ErlNifBinary *b);
NODISCARD int bin_cstr(const ErlNifBinary *b, char *out,
                       size_t outlen);
ERL_NIF_TERM slot_taken(int st);
ERL_NIF_TERM nif_start(ErlNifEnv *env, int argc,
                       const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_stop(ErlNifEnv *env, int argc,
                      const ERL_NIF_TERM argv[]);

/* stack.c */
int capture_port(const char *url);
void *stack_main(void *arg);

/* events.c */
void msleep(unsigned ms);
uint64_t now_ms(void);
ERL_NIF_TERM mkbin(ErlNifEnv *env, const char *s, size_t len);
void send_event(engine_t *e, ERL_NIF_TERM (*mk)(ErlNifEnv *, engine_t *, void *),
                void *arg);
__attribute__((format(printf, 2, 3)))
void shim_warn(engine_t *e, const char *fmt, ...);
ERL_NIF_TERM mk_request_ev(ErlNifEnv *env, engine_t *e, void *arg);
ERL_NIF_TERM mk_health_ev(ErlNifEnv *env, engine_t *e, void *arg);
ERL_NIF_TERM mk_started_ev(ErlNifEnv *env, engine_t *e, void *arg);
void send_op_ok(engine_t *e, uint64_t h);
void send_op_failed(engine_t *e, uint64_t h, const char *why);
ERL_NIF_TERM mk_response_ev(ErlNifEnv *env, engine_t *e, void *arg);
ERL_NIF_TERM mk_ack_ev(ErlNifEnv *env, engine_t *e, void *arg);
ERL_NIF_TERM mk_ack_timeout_ev(ErlNifEnv *env, engine_t *e,
                               void *arg);
ERL_NIF_TERM mk_cancel_ev(ErlNifEnv *env, engine_t *e, void *arg);
ERL_NIF_TERM mk_prack_ev(ErlNifEnv *env, engine_t *e, void *arg);
__attribute__((format(printf, 2, 0)))
void log_cb(void *stream, char const *fmt, va_list ap);

/* incoming.c */
int prack_cb(nta_reliable_magic_t *magic, nta_reliable_t *rel,
             nta_incoming_t *prack, sip_t const *sip);
int leg_request_cb(nta_leg_magic_t *magic, nta_leg_t *leg,
                   nta_incoming_t *irq, sip_t const *sip);
int outgoing_response_cb(nta_outgoing_magic_t *magic,
                         nta_outgoing_t *orq, sip_t const *sip);
int stray_cb(nta_agent_magic_t *magic, nta_agent_t *agent,
             msg_t *msg, sip_t *sip);

/* ops.c */
NODISCARD int enqueue_locked(engine_t *e, const op_t *tpl);
ERL_NIF_TERM nif_respond(ErlNifEnv *env, int argc,
                         const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_request(ErlNifEnv *env, int argc,
                         const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_reliable_respond(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_send(ErlNifEnv *env, int argc,
                      const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_relay(ErlNifEnv *env, int argc,
                       const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_send_response(ErlNifEnv *env, int argc,
                               const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_cancel(ErlNifEnv *env, int argc,
                        const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_proxy_mark(ErlNifEnv *env, int argc,
                            const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_txn_done(ErlNifEnv *env, int argc,
                          const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_discard(ErlNifEnv *env, int argc,
                         const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_block(ErlNifEnv *env, int argc,
                       const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_stats(ErlNifEnv *env, int argc,
                       const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_leg_create(ErlNifEnv *env, int argc,
                            const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_leg_destroy(ErlNifEnv *env, int argc,
                             const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_health(ErlNifEnv *env, int argc,
                        const ERL_NIF_TERM argv[]);

/* table.c */
NODISCARD int tab_put_id(engine_t *e, uint64_t id, int kind, void *ptr,
               void *ctx);
NODISCARD uint64_t tab_put(engine_t *e, int kind, void *ptr,
                           void *ctx);
void *tab_get(engine_t *e, uint64_t id, int kind);
void *tab_get_ctx(engine_t *e, uint64_t id, int kind);
void orphans_sweep(engine_t *e, int all);
void tab_del(engine_t *e, uint64_t id);
uint64_t flow_of(engine_t *e, tport_t *tp);
void flows_sweep(engine_t *e);
void tab_drain(engine_t *e);
uint64_t reserve_id(void);

/* blocklist.c */
void blk_put(const char *addr, uint64_t ttl_ms);
int blk_msg(msg_t *msg);

#endif
