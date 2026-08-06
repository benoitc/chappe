# Third party licenses

## sofia-sip (LGPL-2.1)

`c_src/sofia-sip` is a git submodule of
https://github.com/freeswitch/sofia-sip, licensed under the GNU Lesser
General Public License 2.1. It is built as a static library and linked
into `priv/lib/chappe_sip_engine_nif.so`, which the Erlang VM loads
dynamically. No sofia-sip code is copied outside the submodule.

### Distribution procedure for binary artifacts

Source-only distribution of this repository is compliant as is. Any
artifact that contains the built `chappe_sip_engine_nif.so` (release
tarballs, container images) must:

1. Embed a `SOURCE_MANIFEST` file recording the sofia-sip submodule URL
   and commit SHA, the `c_src/build.sh` version, and the configure flags
   used. This is sufficient to rebuild and relink the shared object from
   source, satisfying LGPL section 6.
2. Keep the referenced sources publicly available for as long as the
   artifact is distributed.

## livery (Apache-2.0)

The SIP-over-WebSocket transport uses livery
(https://github.com/benoitc/livery) and its bundled `ws` (erlang_ws)
library. livery is a rebar3 git dependency (not vendored) and is started
lazily, only when a WS listener is configured. Its dependency tree is
pure Erlang except `instrument`, which builds two NIFs with cmake.

## drachtio (MIT)

The application API design follows drachtio-srf and the layering of
drachtio-server (https://github.com/drachtio). They are design references;
no drachtio code is included in this repository.
