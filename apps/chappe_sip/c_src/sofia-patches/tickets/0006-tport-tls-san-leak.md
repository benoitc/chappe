# tport_tls.c: subjectAltName decoded on every TLS handshake and never freed

Hi,

Running our SIP-over-TLS tests under LeakSanitizer, every outbound TLS
connection to a peer whose certificate has a subjectAltName leaks the
decoded extension.

**What happens**

`tls_post_connection_check()` (`libsofia-sip-ua/tport/tport_tls.c`) walks
the certificate's extensions and, for subjectAltName, does:

```c
d2i = X509V3_EXT_d2i(ext);
values = vp->i2v(vp, d2i, NULL);
```

then copies each DNS, IP and URI name into `tls->subjects`. Neither `d2i`
(the `GENERAL_NAMES`) nor `values` (the `STACK_OF(CONF_VALUE)`) is freed,
so each handshake loses a few hundred bytes per name in the certificate.
A server that opens TLS connections all day grows without bound.

LeakSanitizer reports it at the `X509V3_EXT_d2i` and `i2v` lines, under
`tls_connect`:

```
Direct leak of ... byte(s) in ... object(s) allocated from:
    #0 malloc
    #1 CRYPTO_malloc
    ...
    #5 i2v_GENERAL_NAMES
    #6 tls_post_connection_check tport/tport_tls.c:711
    #7 tls_connect tport/tport_tls.c:1078
```

**How to reproduce**

The function is static and runs after a real handshake, so the repro is a
client connection: link a program with sofia under `-fsanitize=address`,
start an agent with a TLS transport and a CA that signed the peer's
certificate (with at least one subjectAltName), send one request to a TLS
listener with that certificate (`openssl s_server` does), and exit.
LeakSanitizer reports the stack above. In chappe,
`make asan SUITES=apps/chappe_sip/test/chappe_sip_tls_SUITE` shows it.

**The fix**

Free both once the names are copied, as OpenSSL's own `X509V3_EXT_print`
does: `sk_CONF_VALUE_pop_free(values, X509V3_conf_free)`, then
`ASN1_item_free(d2i, ASN1_ITEM_ptr(vp->it))`, or `vp->ext_free(d2i)` for a
method without an item. The patch is `0006-tport-tls-san-leak.patch`.
