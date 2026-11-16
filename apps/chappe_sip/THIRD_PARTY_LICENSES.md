# Third party licenses

## sofia-sip (LGPL-2.1-or-later)

`c_src/sofia-sip` is a vendored copy of
https://github.com/freeswitch/sofia-sip at tag `v1.13.19`, commit
`6dce59d35535e6dd3945c7b0f76dbf1ba884202d`, licensed under the GNU Lesser
General Public License, version 2.1 or (at your option) any later version
(`c_src/sofia-sip/COPYING` and `COPYRIGHTS`). The tree is the tag as
upstream ships it, without its `.gitignore`, plus the autotools output
(`configure`, `Makefile.in` and the like) generated from it, so it builds
without autotools.

At build time `c_src/prepare_sofia.sh` copies the tree and applies the
patches in `c_src/sofia-patches` (each with its ticket in `tickets/`), so
the library linked is a modified sofia-sip, as the LGPL permits. sofia-sip
is built as a static library and linked into
`priv/lib/chappe_sip_engine_nif.so`, which the Erlang VM loads
dynamically. No sofia-sip code is copied outside `c_src/sofia-sip`.

The exact source of the library you link is this repository at the commit
you build: the vendored tree, the patches, `c_src/prepare_sofia.sh` and
`c_src/build.sh` (which holds the configure flags). The hex package of
chappe_sip carries `c_src` with the same files.

### Distribution procedure for binary artifacts

Source-only distribution of this repository is compliant as is. Any
artifact that contains the built `chappe_sip_engine_nif.so` (release
tarballs, container images) must:

1. Embed a `SOURCE_MANIFEST` file recording the chappe commit or the
   chappe_sip version it was built from, the sofia-sip tag and commit
   above, the patches applied, and the configure flags of `c_src/build.sh`.
   This is enough to rebuild and relink the shared object from source,
   satisfying LGPL section 6.
2. Keep the referenced sources publicly available for as long as the
   artifact is distributed.

## livery (Apache-2.0)

The SIP-over-WebSocket transport uses livery
(https://github.com/benoitc/livery) and the `ws` (erlang_ws) library.
livery is a rebar3 git dependency (not vendored) and is started lazily,
only when a WS listener is configured. Its dependency tree is pure Erlang
except `instrument`, below.

## instrument (MIT)

The metrics registry (`chappe_sip_metrics`) is the `instrument` hex
package, a dependency fetched at build time; it builds two NIFs with
cmake.

## drachtio (MIT)

The application API design follows drachtio-srf and the layering of
drachtio-server (https://github.com/drachtio). They are design references;
no drachtio code is included in this repository.
