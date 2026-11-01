# sofia-sip patches

`c_src/sofia-sip` is the vendored freeswitch/sofia-sip tree, kept exactly as
upstream ships it. The few fixes we need before upstream takes them live
here as patches, applied to a copy of the tree at build time. You need this
page when a sanitizer or a fuzzer finds a bug inside sofia, or when you
update the vendored version.

## How it works

`../prepare_sofia.sh DEST` copies the vendored tree to `DEST`, applies every
`*.patch` in this folder in name order (`patch -p1 --forward --batch`; a
hunk that does not apply fails the build) and pins the autotools mtimes of
the copy. `build.sh` calls it with `c_src/build/sofia-src` and builds sofia
from that copy; the fuzz build calls it with its own directory.
`prepare_sofia.sh --key` prints the vendored tree's hash and the patches'
checksum, which is part of sofia's build stamp, so adding or changing a
patch rebuilds sofia and relinks the NIF. The vendored tree in git never
changes.

## The patches

| Patch | What it fixes | Upstream ticket |
|---|---|---|
| `0001-url-shifts.patch` | undefined shifts in `url.c` (`IS_SYN33`, `IS_EXCLUDED`); a high byte could skip the URL exclusion check | [`tickets/0001-url-shifts.md`](tickets/0001-url-shifts.md), not filed yet |
| `0002-msg-serialize-null-separator.patch` | member access through a NULL separator in `msg_serialize()` | [`tickets/0002-msg-serialize-null-separator.md`](tickets/0002-msg-serialize-null-separator.md), not filed yet |
| `0003-url-param-past-end.patch` | `url_param()` read past the end of the parameter string when the last parameter starts with the name looked up but has no `=` | [`tickets/0003-url-param-past-end.md`](tickets/0003-url-param-past-end.md), not filed yet |

0001 and 0002 were found by the libFuzzer targets in `../fuzz` under
UBSan, 0003 by the NIF fuzz suite (`chappe_sip_nif_fuzz_SUITE`) under ASan.

## Reproduce a bug

`repro/` holds a tiny program per patch. Build sofia with UBSan, then, from
`apps/chappe_sip/c_src` after a build (`build/dist` holds sofia's headers
and static library):

```sh
clang -g -fsanitize=undefined -Ibuild/dist/include/sofia-sip-1.13 \
  sofia-patches/repro/url_canonize.c \
  build/dist/lib/libsofia-sip-ua.a -lssl -lcrypto -o repro_url
./repro_url
```

Without the patch UBSan reports the line named in the ticket; with it the
program prints its result and exits cleanly.

## Add a patch

1. Fix the bug in a copy of the vendored tree and make the patch from the
   sofia-sip root: `diff -u` with `a/` and `b/` paths.
2. Name it `NNNN-short-name.patch` and add a ticket in `tickets/` written
   for upstream: what happens, how to reproduce, what the patch changes.
3. Add a repro program in `repro/` and a row in the table above.
4. Remove the matching suppression from `../fuzz/ubsan.supp`, if there is
   one, and run `make fuzz`.

## Drop a patch

When upstream merges the fix and we update the vendored tree, delete the
patch, its ticket and its repro, and its row here.
