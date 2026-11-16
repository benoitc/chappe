# tport.c: --disable-nth no longer links (tport_wss_create_ssl_ctx)

Hi,

Since the WSS certificate reload was added to `tport_reload_tls()`,
sofia-sip configured with `--disable-nth` does not link anything that
pulls in `tport.o`.

**What happens**

With nth disabled, `tport/Makefile.am` leaves `tport_type_ws.c` and `ws.c`
out of the build (`HTTP_SRC` is under `HAVE_NTH`), and `tport.c` registers
the ws vtables only under `#if HAVE_SOFIA_NTH`. `tport_reload_tls()`
(`libsofia-sip-ua/tport/tport.c`) calls `tport_wss_create_ssl_ctx()`, which
lives in `tport_type_ws.c`, outside any guard. The library builds, and the
first program linked against it fails:

```
Undefined symbols for architecture arm64:
  "_tport_wss_create_ssl_ctx", referenced from:
      _tport_reload_tls in libsofia-sip-ua.a(tport.o)
```

(`undefined reference to 'tport_wss_create_ssl_ctx'` with GNU ld.)

**How to reproduce**

From a clean tree:

```sh
sh autogen.sh
./configure --disable-shared --enable-static --disable-nth
make
```

`make` stops in `utils/` linking `sip-options` with the error above.

**What the patch changes**

It puts the WSS branch of the loop in `tport_reload_tls()` under
`#if HAVE_SOFIA_NTH`, as the ws vtables already are. With nth, nothing
changes; without it, the loop reloads the TLS transports only, which are
the only ones there.

We build sofia without nth because we serve WebSocket ourselves and want
none of sofia's WebSocket code linked in.
