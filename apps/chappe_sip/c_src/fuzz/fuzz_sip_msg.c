/* Copyright 2026 Benoit Chesneau
 * SPDX-License-Identifier: Apache-2.0
 *
 * libFuzzer target: a complete SIP message, through the calls the engine
 * makes on it. msg_make is how the NIF parses the raw requests and responses
 * Erlang hands it (request, send, relay, send_response); msg_as_string is
 * how it turns a parsed message back into the bytes it gives Erlang;
 * msg_serialize and msg_prepare are what nta does before a message goes on
 * the wire. */
#include <stddef.h>
#include <stdint.h>

#include <sofia-sip/su_alloc.h>
#include <sofia-sip/msg.h>
#include <sofia-sip/sip.h>
#include <sofia-sip/sip_header.h>

/* the engine's default max_message_size (DEFAULT_MAX_MSG_SIZE) */
#define MAX_INPUT 262144

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size == 0 || size > MAX_INPUT) return 0;
    msg_t *m = msg_make(sip_default_mclass(), 0, data, (ssize_t)size);
    if (!m) return 0;
    if (!msg_has_error(m)) {
        su_home_t *home = su_home_new(sizeof(su_home_t));
        sip_t *sip = sip_object(m);
        size_t len = 0;
        char *s = msg_as_string(home, m, NULL, 0, &len);
        if (s) su_free(home, s);
        if (sip && msg_serialize(m, (msg_pub_t *)sip) == 0)
            (void)msg_prepare(m);
        su_home_unref(home);
    }
    msg_destroy(m);
    return 0;
}
