/*
 * main.c - the NIF module of the thin NIF shim over sofia-sip nta.
 *
 * Copyright 2026 Benoit Chesneau
 * SPDX-License-Identifier: Apache-2.0
 *
 * The shim is the files of c_src/nif/, with engine.h their private
 * header. This one holds the atoms, load, upgrade and unload, and the
 * singleton slot NIFs (see "Upgrading the NIF" in the engine design).
 *
 * Design (see docs/design/engine.md and the project plan):
 * - Global su_init once at NIF load; su_deinit at unload. Per-engine
 *   lifecycle is only su_root + nta_agent, so stop/start cycles never
 *   re-run global init. An in-place upgrade is always refused (see
 *   upgrade()): the library is replaced by purge, then load.
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

#include "engine.h"

/* The statics below are shared by every module instance that loaded this
 * image (the same file loaded again while an old instance is still alive).
 * Once the last resource of a purged instance goes, ERTS runs its unload
 * as scheduler aux work holding the code modification permission
 * (erl_nif.c, close_dynlib_aux); a new instance's load runs in its on_load
 * process without it (erts_load_nif). The two can overlap, so g_lib_lock
 * orders them. It is statically initialised and
 * never destroyed, so it is valid for every instance. */
static pthread_mutex_t g_lib_lock = PTHREAD_MUTEX_INITIALIZER;
/* module instances that loaded this image, under g_lib_lock: the first sets
 * the image up, the last to go tears it down */
static int g_loads = 0;

/* atoms */
ERL_NIF_TERM am_ok, am_error, am_undefined, am_chappe_sip_engine, am_request,
    am_health_ok, am_started, am_log, am_method, am_not_ready, am_not_found,
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

/* engine_state() -> none | running | stopping: the singleton, after joining
 * a stack thread that is done and nobody waited for */
static ERL_NIF_TERM nif_engine_state(ErlNifEnv *env, int argc,
                                     const ERL_NIF_TERM argv[]) {
    (void)env;
    (void)argc;
    (void)argv;
    reap_thread();
    switch (atomic_load(&g_engine_state)) {
    case G_NONE: return am_none;
    case G_RUNNING: return am_running;
    case G_RESERVED: return am_replacing;
    default: return am_stopping;
    }
}

/* reserve_slot() -> ok | {error, running | stopping | replacing}: take the
 * free singleton slot for a replace, so no engine starts on this image
 * until the replace is done. Released by release_slot/0 while the module
 * is still current, else by the next load of the image (see load). */
static ERL_NIF_TERM nif_reserve_slot(ErlNifEnv *env, int argc,
                                     const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    reap_thread();
    int expect = G_NONE;
    if (!atomic_compare_exchange_strong(&g_engine_state, &expect, G_RESERVED))
        return enif_make_tuple2(env, am_error,
                                expect == G_RUNNING ? am_running
                                                    : slot_taken(expect));
    return am_ok;
}

/* release_slot() -> ok | {error, not_reserved} */
static ERL_NIF_TERM nif_release_slot(ErlNifEnv *env, int argc,
                                     const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    int expect = G_RESERVED;
    if (!atomic_compare_exchange_strong(&g_engine_state, &expect, G_NONE))
        return enif_make_tuple2(env, am_error, am_not_reserved);
    return am_ok;
}

/* instances() -> N: the module instances sharing this image (g_loads) */
static ERL_NIF_TERM nif_instances(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    pthread_mutex_lock(&g_lib_lock);
    int n = g_loads;
    pthread_mutex_unlock(&g_lib_lock);
    return enif_make_int(env, n);
}

/* ---------- module lifecycle ----------
 *
 * The library is loaded with no other instance of chappe_sip_nif holding
 * it: replacing it means stopping the stack, deleting and purging the
 * module (unload), then loading the new one (load). See upgrade(). */

/* The first instance of the image sets up what the instances share: the
 * locks and sofia's globals. Under g_lib_lock. */
static int setup_image(void) {
    g_blk_lock = enif_mutex_create("chappe_sip_blocklist");
    g_life_lock = enif_mutex_create("chappe_sip_life");
    if (!g_blk_lock || !g_life_lock) {
        if (g_blk_lock) enif_mutex_destroy(g_blk_lock);
        if (g_life_lock) enif_mutex_destroy(g_life_lock);
        g_blk_lock = NULL;
        g_life_lock = NULL;
        return -1;
    }
    /* su_init() installs SIG_IGN for SIGPIPE process-wide; save BEAM's
     * disposition and restore it so the VM's signal handling is
     * preserved (sofia's own socket writes use SO_NOSIGPIPE/MSG_NOSIGNAL). */
    struct sigaction old_pipe;
    int saved = (sigaction(SIGPIPE, NULL, &old_pipe) == 0);
    su_init();
    if (saved) sigaction(SIGPIPE, &old_pipe, NULL);
    su_log_redirect(NULL, log_cb, NULL);
    return 0;
}

/* The last instance of the image goes: no engine of any instance is left
 * (ERTS unloads an instance only once its resources are gone). Under
 * g_lib_lock. The blocklist is emptied, so a later load starts with none. */
static void teardown_image(void) {
    su_deinit();
    enif_mutex_destroy(g_blk_lock);
    g_blk_lock = NULL;
    enif_mutex_destroy(g_life_lock);
    g_life_lock = NULL;
    memset(g_blk, 0, sizeof g_blk);
}

static int load_locked(ErlNifEnv *env) {
    ErlNifResourceTypeInit init = {
        .dtor = engine_dtor,
        .stop = NULL,
        .down = engine_down,
    };
    ENGINE_RT = enif_open_resource_type_x(env, "chappe_sip_engine", &init,
                                          ERL_NIF_RT_CREATE, NULL);
    if (!ENGINE_RT) return -1;
    if (g_loads == 0 && setup_image() != 0) return -1;

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
    am_sip_t1 = enif_make_atom(env, "sip_t1");
    am_sip_t2 = enif_make_atom(env, "sip_t2");
    am_sip_t4 = enif_make_atom(env, "sip_t4");
    am_udp_mtu = enif_make_atom(env, "udp_mtu");
    am_tcp_keepalive_ms = enif_make_atom(env, "tcp_keepalive_ms");
    am_outbound_proxy = enif_make_atom(env, "outbound_proxy");
    am_running = enif_make_atom(env, "running");
    am_replacing = enif_make_atom(env, "replacing");
    am_not_reserved = enif_make_atom(env, "not_reserved");
    g_loads++;
    /* A replace reserved the slot before it deleted the old module, which
     * then had no current code left to release it from. On the same image
     * the reservation is still here: this instance is set up, so a start
     * may now run on it. A different image starts at G_NONE. */
    int expect = G_RESERVED;
    (void)atomic_compare_exchange_strong(&g_engine_state, &expect, G_NONE);
    return 0;
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    (void)priv;
    (void)info;
    pthread_mutex_lock(&g_lib_lock);
    int rc = load_locked(env);
    pthread_mutex_unlock(&g_lib_lock);
    return rc;
}

/* An in-place upgrade (old code of the module still holds a library) is
 * always refused, whether or not an engine runs. A new library copy has its
 * own statics and its own sofia: taking over the old engines would run its
 * code on objects the old library made, with a layout it cannot know, and
 * no check of the old singleton can stop an old start racing the purge
 * that closes the old library. The load fails with on_load_failure and
 * the old code stays. */
static int upgrade(ErlNifEnv *env, void **priv, void **old_priv,
                   ERL_NIF_TERM info) {
    (void)env;
    (void)priv;
    (void)old_priv;
    (void)info;
    return -1;
}

/* A module instance goes. ERTS calls this only once every engine resource
 * of the instance is gone, so no stack thread of it runs. The same file
 * loaded again while one was alive is the same image, with its statics
 * shared by both instances: they go with the last one, under g_lib_lock,
 * so a load running at the same time either sees them torn down and sets
 * them up again, or keeps them. */
static void unload(ErlNifEnv *env, void *priv) {
    (void)env;
    (void)priv;
    pthread_mutex_lock(&g_lib_lock);
    if (--g_loads == 0) teardown_image();
    pthread_mutex_unlock(&g_lib_lock);
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
    {"engine_state", 0, nif_engine_state, 0},
    {"reserve_slot", 0, nif_reserve_slot, 0},
    {"release_slot", 0, nif_release_slot, 0},
    {"instances", 0, nif_instances, 0},
};

ERL_NIF_INIT(chappe_sip_nif, nif_funcs, load, NULL, upgrade, unload)
