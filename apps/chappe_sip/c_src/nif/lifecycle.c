/*
 * lifecycle.c - the engine singleton and its stack thread handoff.
 *
 * Copyright 2026 Benoit Chesneau
 * SPDX-License-Identifier: Apache-2.0
 *
 * The singleton slot (g_engine_state), the engine resource and its
 * destructor and owner-down callbacks, the join of the stack thread
 * (request_stop, claim_thread, reap_thread, stop_wait_join), the start
 * option checks and the start and stop NIFs. "Lifecycle protocols" and
 * the State CAS and Engine destructor rows of "Risky regions" in
 * docs/design/engine.md explain it.
 */

#include "engine.h"

_Atomic int g_engine_state = G_NONE;

ErlNifResourceType *ENGINE_RT = NULL;

/* Drop one engine ref. Under TSan the release orders what this thread did
 * to e before the destructor, which may run on another thread once ERTS's
 * (uninstrumented) refcount reaches 0, and acquires there. */
void engine_unref(engine_t *e) {
    TSAN_RELEASE(e);
    enif_release_resource(e);
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

/* The engine whose stack thread nobody joined yet; it holds the thread's
 * resource ref. At most one: an engine keeps the singleton slot until its
 * destructor, which cannot run before that ref goes. Under g_life_lock. */
ErlNifMutex *g_life_lock = NULL;
static engine_t *g_unjoined = NULL;

/* Join e's stack thread and drop the ref it held, off the stack thread. The
 * join returns once the thread has left the library's code, so the release
 * (perhaps the last, running the destructor) can never unmap code under
 * it. The caller claimed e from g_unjoined. */
static void join_thread(engine_t *e) {
    if (atomic_exchange(&e->tid_valid, 0)) enif_thread_join(e->tid, NULL);
    engine_unref(e);
}

/* claim e's thread for joining: 1 when the caller must join_thread it */
static int claim_thread(engine_t *e) {
    enif_mutex_lock(g_life_lock);
    int own = (g_unjoined == e);
    if (own) g_unjoined = NULL;
    enif_mutex_unlock(g_life_lock);
    return own;
}

/* Join a stack thread no one waits for (an owner-death stop, an abandoned
 * start, a stop that timed out) once it is done, so its engine can go and
 * free the slot. Called from start and engine_state. */
void reap_thread(void) {
    enif_mutex_lock(g_life_lock);
    engine_t *e = g_unjoined;
    if (e && atomic_load(&e->thread_done))
        g_unjoined = NULL;
    else
        e = NULL;
    enif_mutex_unlock(g_life_lock);
    if (e) join_thread(e);
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
    if (claim_thread(e)) join_thread(e);
    return 1;
}

/* release the singleton slot if this engine still holds it */
static void release_slot(engine_t *e) {
    if (atomic_exchange(&e->holds_slot, 0))
        atomic_store(&g_engine_state, G_NONE);
}

void engine_dtor(ErlNifEnv *env, void *obj) {
    (void)env;
    engine_t *e = obj;
    TSAN_ACQUIRE(e);   /* every engine_unref happened before */
    /* The stack thread's ref goes only once the thread is joined
     * (join_thread), so reaching refcount 0 here means the thread is gone (or
     * never existed): no stop, wait or join is needed, memory is never freed
     * under a running (or stuck) thread, and this never runs on the stack
     * thread. */
    if (e->root_lock) {
        enif_rwlock_destroy(e->root_lock);
        e->root_lock = NULL;
    }
    /* Release the singleton only if this engine still holds it (an abandoned
     * or hung start, or an owner-death stop, all at G_STOPPING). A clean
     * nif_stop already released it, after which a new engine may hold
     * G_RUNNING; storing G_NONE here would clobber that successor and break
     * the one-engine invariant during stop/start churn. */
    release_slot(e);
    TSAN_RELEASE(e);
}

void engine_down(ErlNifEnv *env, void *obj, ErlNifPid *pid,
                        ErlNifMonitor *mon) {
    (void)env;
    (void)pid;
    (void)mon;
    /* Owner died without stopping: initiate async stop; the restarted
     * owner retries start against the {error, stopping} guard, and that
     * start joins the thread once it is done. */
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
int has_nul(const ErlNifBinary *b) {
    return b->size > 0 && memchr(b->data, 0, b->size) != NULL;
}

/* b as a C string into out (outlen bytes); -1 when it has a NUL or does
 * not fit with its terminator */
NODISCARD int bin_cstr(const ErlNifBinary *b, char *out,
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

/* key => an integer in lo..hi into *out (left alone when absent) */
NODISCARD static int get_opt_uint(ErlNifEnv *env, ERL_NIF_TERM map,
                                  ERL_NIF_TERM key, unsigned lo, unsigned hi,
                                  unsigned *out) {
    ERL_NIF_TERM v;
    unsigned u;
    if (!enif_get_map_value(env, map, key, &v)) return OPT_ABSENT;
    if (!enif_get_uint(env, v, &u) || u < lo || u > hi) return OPT_BAD;
    *out = u;
    return OPT_SET;
}

/* the agent settings: sip_t1, sip_t2, sip_t4 (ms; T2 never below the
 * T1 in effect), udp_mtu, tcp_keepalive_ms, and outbound_proxy, a sip: or
 * sips: URI */
static int get_agent_opts(ErlNifEnv *env, ERL_NIF_TERM opts, engine_t *e) {
    if (get_opt_uint(env, opts, am_sip_t1, MIN_SIP_T, MAX_SIP_T1,
                     &e->sip_t1) == OPT_BAD ||
        get_opt_uint(env, opts, am_sip_t2, MIN_SIP_T, MAX_SIP_T2,
                     &e->sip_t2) == OPT_BAD ||
        get_opt_uint(env, opts, am_sip_t4, MIN_SIP_T, MAX_SIP_T4,
                     &e->sip_t4) == OPT_BAD ||
        get_opt_uint(env, opts, am_udp_mtu, MIN_UDP_MTU, MAX_UDP_MTU,
                     &e->udp_mtu) == OPT_BAD ||
        get_opt_uint(env, opts, am_tcp_keepalive_ms, MIN_KEEPALIVE_MS,
                     MAX_KEEPALIVE_MS, &e->tcp_keepalive) == OPT_BAD)
        return 0;
    /* T2 is checked against the T1 in effect, nta's default when unset */
    unsigned t1 = e->sip_t1 ? e->sip_t1 : (unsigned)NTA_SIP_T1;
    unsigned t2 = e->sip_t2 ? e->sip_t2 : (unsigned)NTA_SIP_T2;
    if (t2 < t1) return 0;
    switch (get_opt_bin(env, opts, am_outbound_proxy, e->outbound_proxy,
                        sizeof e->outbound_proxy)) {
    case OPT_BAD:
        return 0;
    case OPT_SET:
        /* nta takes sip:, sips: and urn: and ignores anything else
         * without a word; refuse it here instead */
        return strncasecmp(e->outbound_proxy, "sip:", 4) == 0 ||
               strncasecmp(e->outbound_proxy, "sips:", 5) == 0;
    default:
        return 1;
    }
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

/* why the singleton slot, in state st, is not free */
ERL_NIF_TERM slot_taken(int st) {
    switch (st) {
    case G_STOPPING: return am_stopping;
    case G_RESERVED: return am_replacing;
    default: return am_already_started;
    }
}

/* a start that never got its thread: free the singleton and the engine */
static ERL_NIF_TERM start_refused(ErlNifEnv *env, engine_t *e) {
    release_slot(e);
    engine_unref(e);
    return enif_make_tuple2(env, am_error, am_badarg);
}

ERL_NIF_TERM nif_start(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
    if (argc != 2 || !enif_is_map(env, argv[0]))
        return enif_make_badarg(env);

    ErlNifPid owner;
    if (!enif_get_local_pid(env, argv[1], &owner))
        return enif_make_badarg(env);

    /* a thread left to stop on its own frees the slot once joined */
    reap_thread();

    /* singleton guard, serializes detach/stop/reattach */
    int expect = G_NONE;
    if (!atomic_compare_exchange_strong(&g_engine_state, &expect, G_RUNNING))
        return enif_make_tuple2(env, am_error, slot_taken(expect));

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
    atomic_init(&e->holds_slot, 1);

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
        !get_agent_opts(env, argv[0], e) || !get_tls(env, argv[0], e))
        return start_refused(env, e);

    /* a send may name an ident only when every transport has one: tport
     * compares it with each primary's ident without a NULL check. More
     * than one address needs idents throughout. */
    e->has_idents = e->ident[0] && (!e->tls_contact[0] || e->tls_ident[0]);
    if ((e->nx > 0 || e->ntlsx > 0) && !e->has_idents)
        return start_refused(env, e);

    /* the stack thread holds its own resource ref until it is joined
     * (join_thread), so e outlives the thread and the destructor never frees
     * under it. Take it before create; undo it if create fails. Once the tid
     * is set, e goes in g_unjoined (empty: the slot we hold means no other
     * engine is unjoined), where a stop or a reaper claims the join. */
    enif_keep_resource(e);
    if (enif_thread_create("chappe_sip_stack", &e->tid, stack_main, e, NULL) != 0) {
        engine_unref(e);   /* the thread ref (thread never ran) */
        release_slot(e);
        engine_unref(e);   /* the start ref */
        return enif_make_tuple2(env, am_error,
                                mkbin(env, "thread_create failed", 20));
    }
    e->tid_valid = 1;
    enif_mutex_lock(g_life_lock);
    g_unjoined = e;
    enif_mutex_unlock(g_life_lock);

    /* readiness barrier */
    int waited = 0;
    for (;;) {
        int st = atomic_load(&e->state);
        if (st == ST_READY) break;
        if (st == ST_FAILED) {
            if (claim_thread(e)) join_thread(e);
            release_slot(e);
            ERL_NIF_TERM why = mkbin(env, e->errbuf, strlen(e->errbuf));
            engine_unref(e);
            return enif_make_tuple2(
                env, am_error, enif_make_tuple2(env, am_engine_start, why));
        }
        if (waited >= ENGINE_START_WAIT_MS) {
            /* Thread stuck in init and not yet in its loop, so it cannot be
             * broken and joining would block a scheduler. Abandon it by winning
             * the INIT->STOPPING transition: the thread, if it unblocks, then
             * fails its INIT->READY CAS and tears down; the next start or
             * engine_state joins it and drops its ref (which frees e and resets
             * the singleton). Drop only the start ref here; the thread's ref
             * keeps e alive. If the CAS loses, the thread just
             * reached READY/FAILED - loop to handle it normally. */
            int einit = ST_INIT;
            if (atomic_compare_exchange_strong(&e->state, &einit, ST_STOPPING)) {
                atomic_store(&g_engine_state, G_STOPPING);
                engine_unref(e);   /* the start ref */
                return enif_make_tuple2(env, am_error, am_hung);
            }
            continue;
        }
        msleep(POLL_STEP_MS);
        waited += POLL_STEP_MS;
    }

    if (enif_monitor_process(env, e, &owner, &e->owner_mon) != 0) {
        /* owner already dead: the thread is READY, so stop and join it before
         * dropping the base ref (never free e under the running thread). A
         * thread that did not stop in the bound keeps the slot at
         * G_STOPPING; its ref keeps e alive, and the destructor releases the
         * slot once it exits. */
        if (stop_wait_join(e)) release_slot(e);
        engine_unref(e);
        return enif_make_tuple2(env, am_error, am_badarg);
    }

    ERL_NIF_TERM ref = enif_make_resource(env, e);
    engine_unref(e); /* term holds it now */
    return enif_make_tuple2(env, am_ok, ref);
}

ERL_NIF_TERM nif_stop(ErlNifEnv *env, int argc,
                             const ERL_NIF_TERM argv[]) {
    engine_t *e;
    if (argc != 1 || !enif_get_resource(env, argv[0], ENGINE_RT, (void **)&e))
        return enif_make_badarg(env);

    if (!stop_wait_join(e)) {
        /* The thread did not stop in the bound. Do NOT join or free here: the
         * thread still holds its resource ref, so e stays alive and the
         * destructor cannot run under it (F1). If it ever unblocks it tears
         * down, and the next start or engine_state joins it, drops its ref and
         * resets the singleton; g_engine_state stays STOPPING until then, so
         * heart/systemd can restart the node. */
        return enif_make_tuple2(env, am_error, am_hung);
    }
    enif_demonitor_process(env, e, &e->owner_mon);
    release_slot(e);
    return am_ok;
}
