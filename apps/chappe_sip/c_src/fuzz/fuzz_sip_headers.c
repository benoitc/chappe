/* Copyright 2026 Benoit Chesneau
 * SPDX-License-Identifier: Apache-2.0
 *
 * libFuzzer target: the header and body strings Erlang passes to respond,
 * reliable_respond and cancel. The NIF copies them NUL-terminated and hands
 * them to nta as SIPTAG_HEADER_STR and SIPTAG_PAYLOAD_STR, which parse them
 * into the outgoing message with sip_add_tl. The input is split at the first
 * NUL: headers before, body after. */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <sofia-sip/su_alloc.h>
#include <sofia-sip/msg.h>
#include <sofia-sip/sip.h>
#include <sofia-sip/sip_header.h>
#include <sofia-sip/sip_tag.h>

#define MAX_INPUT 262144

static const char base[] =
    "SIP/2.0 200 OK\r\n"
    "Via: SIP/2.0/UDP 127.0.0.1:5070;branch=z9hG4bKfuzz\r\n"
    "From: <sip:a@127.0.0.1>;tag=a\r\n"
    "To: <sip:b@127.0.0.1>;tag=b\r\n"
    "Call-ID: fuzz@127.0.0.1\r\n"
    "CSeq: 1 INVITE\r\n"
    "Content-Length: 0\r\n"
    "\r\n";

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size > MAX_INPUT) return 0;
    char *buf = malloc(size + 1);
    if (!buf) return 0;
    memcpy(buf, data, size);
    buf[size] = '\0';
    size_t hlen = strlen(buf);
    const char *body = hlen < size ? buf + hlen + 1 : NULL;

    msg_t *m = msg_make(sip_default_mclass(), 0, base, (ssize_t)strlen(base));
    if (m && !msg_has_error(m)) {
        sip_t *sip = sip_object(m);
        if (sip_add_tl(m, sip, TAG_IF(hlen, SIPTAG_HEADER_STR(buf)),
                       TAG_IF(body, SIPTAG_PAYLOAD_STR(body)),
                       TAG_END()) == 0 &&
            msg_serialize(m, (msg_pub_t *)sip) == 0 &&
            msg_prepare(m) > 0) {
            su_home_t *home = su_home_new(sizeof(su_home_t));
            size_t len = 0;
            char *s = msg_as_string(home, m, NULL, 0, &len);
            if (s) su_free(home, s);
            su_home_unref(home);
        }
    }
    if (m) msg_destroy(m);
    free(buf);
    return 0;
}
