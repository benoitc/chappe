/*
 * stack.c - the stack thread.
 *
 * Copyright 2026 Benoit Chesneau
 * SPDX-License-Identifier: Apache-2.0
 *
 * stack_main creates the su_root and the nta agent with every listen
 * address and TLS transport, runs the loop, and tears sofia down on the
 * stack thread. Also the HEP capture socket tport never closes. See
 * "Threads", "nta settings that differ from a plain UA", "Several listen
 * addresses", "HEP capture" and "TLS" in docs/design/engine.md.
 */

#include "engine.h"

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
int capture_port(const char *url) {
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

/* The stack thread's last act. It does not drop its resource ref: a release
 * here could be the last one, running the destructor on this thread and
 * letting ERTS close a purged library while the thread still returns
 * through it. The thread that joins it drops the ref (join_thread). */
static void *thread_exit(engine_t *e) {
    atomic_store(&e->thread_done, 1);
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

void *stack_main(void *arg) {
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
        /* the agent settings, each only when asked for. nta does not
         * derive Timer B/F/H/J (64*T1) from T1, so T1X64 goes with it;
         * T1 and T2 are bounded (MAX_SIP_T1, MAX_SIP_T2), so the product
         * fits an unsigned. The keep-alive reaches each tport's
         * connections; tport pings TCP only (its TLS vtable has no
         * connection timer). */
        TAG_IF(e->sip_t1, NTATAG_SIP_T1(e->sip_t1)),
        TAG_IF(e->sip_t1, NTATAG_SIP_T1X64(64u * e->sip_t1)),
        TAG_IF(e->sip_t2, NTATAG_SIP_T2(e->sip_t2)),
        TAG_IF(e->sip_t4, NTATAG_SIP_T4(e->sip_t4)),
        TAG_IF(e->udp_mtu, NTATAG_UDP_MTU(e->udp_mtu)),
        TAG_IF(e->tcp_keepalive, TPTAG_KEEPALIVE(e->tcp_keepalive)),
        TAG_IF(e->outbound_proxy[0],
               NTATAG_DEFAULT_PROXY(URL_STRING_MAKE(e->outbound_proxy))),
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

    /* nta_agent_create ignores what agent_set_params refuses: an outbound
     * proxy it could not take is a failed start, not a silent direct
     * send */
    const char *bind_err = NULL;
    if (e->outbound_proxy[0]) {
        url_string_t const *dp = NULL;
        if (nta_agent_get_params(e->agent, NTATAG_DEFAULT_PROXY_REF(dp),
                                 TAG_END()) != 1 ||
            dp == NULL)
            bind_err = "outbound_proxy refused by nta";
    }

    /* no default leg: a request no dialog leg takes reaches stray_cb
     * before nta makes a transaction of it (request_in) */

    /* the other listen addresses, each with the ident a send names it by */
    for (int i = 0; i < e->nx && !bind_err; i++) {
        if (nta_agent_add_tport(e->agent, URL_STRING_MAKE(e->xcontact[i]),
                                TPTAG_IDENT(e->xident[i]), TPTAG_PONG2PING(1),
                                TAG_IF(e->tcp_keepalive,
                                       TPTAG_KEEPALIVE(e->tcp_keepalive)),
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
