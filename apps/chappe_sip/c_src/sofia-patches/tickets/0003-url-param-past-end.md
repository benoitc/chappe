# url.c: url_param() reads past the end of the parameter string

Hi,

While fuzzing the start options of an nta agent under AddressSanitizer we
hit a heap overread in `url_param()` (`libsofia-sip-ua/url/url.c`).

**What happens**

`url_param()` walks the `;`-separated parameters with
`p += n + 1`, and checks for the end of the string with `if (!p[n]) break;`
at the bottom of the loop. When a parameter starts with the name looked up
but is followed by something other than `=` (for example `maddrx` when
looking up `maddr`), the code takes `continue` before that check. If that
parameter is the last one, `p` moves one byte past the terminating NUL and
the loop goes on reading whatever memory follows.

`url_hdup()` puts the parameters at the end of one heap block, so the read
leaves the block. ASan reports it from `nta_agent_add_tport()`, which calls
`url_param()` for `transport`, `maddr` and `comp` on the bind URL:

```
ERROR: AddressSanitizer: heap-buffer-overflow ... READ of size 3
    #0 strcspn
    #1 url_param url/url.c:1324
    #2 nta_agent_add_tport nta/nta.c:2271
    #3 nta_agent_create nta/nta.c:992
```

Other callers pass URL parameters that come from the network, such as the
`lr` check on a Route taken from a Record-Route (nta.c) and the `maddr`
check in sip_basic.c. When the following bytes hold another parameter, it
is returned as if it were in the URL.

**How to reproduce**

```c
#include <stdio.h>
#include <sofia-sip/url.h>

int main(void)
{
  static const char buf[] = "transport=udp;maddrx\0maddr=10.0.0.66";
  char value[64] = "";
  int n = (int)url_param(buf, "maddr", value, sizeof value);
  printf("url_param: %d \"%s\"\n", n, value);
  return n != 0;
}
```

Without the patch it prints `url_param: 10 "10.0.0.66"`, a value read from
past the string's NUL. With it, `url_param: 0 ""`.

**The patch**

The `continue` taken when the name matches but no `=` follows now checks
for the end of the string first, as the other branches of the loop do.
Nothing changes for a parameter list that is well formed.

The patch is attached (`0003-url-param-past-end.patch`). Happy to open a
pull request if you prefer.

Thanks for sofia-sip!
