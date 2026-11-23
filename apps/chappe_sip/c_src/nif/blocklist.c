/*
 * blocklist.c - the source blocklist.
 *
 * Copyright 2026 Benoit Chesneau
 * SPDX-License-Identifier: Apache-2.0
 *
 * The addresses request_in discards before nta makes a transaction
 * (block/2). See the Request intake row of "Risky regions" in
 * docs/design/engine.md and docs/guides/protect-the-edge.md.
 */

#include "engine.h"

/* ---------- source blocklist ----------
 *
 * The addresses chappe_sip_guard drops (block/2), each until a deadline.
 * request_in discards a request from one before nta creates a server
 * transaction for it, so a flood from it costs no transaction. The policy
 * is Erlang's; this only enforces it. Open addressing over a fixed table:
 * an address probes BLK_PROBE slots, and when they are all live the one
 * expiring first gives way. Process-wide (the engine is a singleton), so
 * it outlives an engine restart. */

blk_ent_t g_blk[BLK_SLOTS];
ErlNifMutex *g_blk_lock = NULL;

static unsigned blk_hash(const char *a) {
    uint32_t h = 2166136261u;
    for (; *a; a++) h = (h ^ (unsigned char)*a) * 16777619u;
    return h & (BLK_SLOTS - 1);
}

/* ttl_ms 0 lifts the block */
void blk_put(const char *addr, uint64_t ttl_ms) {
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
int blk_msg(msg_t *msg) {
    char ip[BLK_ADDR] = {0};
    su_addrinfo_t *ai = msg_addrinfo(msg);
    if (!ai || !ai->ai_addr || !ai->ai_addrlen) return 0;
    su_sockaddr_t *su = (su_sockaddr_t *)ai->ai_addr;
    if (!su_inet_ntop(su->su_family, SU_ADDR(su), ip, sizeof ip)) return 0;
    return blk_has(ip);
}
