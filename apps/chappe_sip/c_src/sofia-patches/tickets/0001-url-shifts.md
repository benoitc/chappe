# url.c: shift by more than 31 bits in IS_SYN33, signed shift in IS_EXCLUDED

Hi,

While fuzzing the SIP parser with UBSan we hit two undefined shifts in
`libsofia-sip-ua/url/url.c`. Both sit in the character class macros used by
`url_canonize2()`, so any URL with an escape (`%xx`) goes through them.

**What happens**

- `IS_SYN33(syn33, c)` computes `1U << (c - 33)` for every byte of the
  component. The mask only has bits for the characters 33 to 64, so for a
  lowercase letter the shift is 64 or more, for a byte below 33 it is
  negative. Both are undefined in C. On x86 the CPU keeps only the low 5
  bits of the count, so the macro reads a random bit of the mask: a byte
  that should be refused (a raw 0x80+ byte for example) can be taken as a
  "syntax" character and skip the `IS_EXCLUDED` check. On another compiler
  or CPU the result can be different again.
- `IS_EXCLUDED` shifts a signed `1`: `1 << (63 - u)` with `u == 32` gives
  `1 << 31`, which overflows `int`.

**How to reproduce**

Build sofia-sip with UBSan, then run a 10 line program:

```sh
./configure --disable-shared CC=clang \
  CFLAGS="-O1 -g -fsanitize=undefined -fno-sanitize-recover=undefined"
make -C libsofia-sip-ua
```

```c
#include <stdio.h>
#include <sofia-sip/url.h>

int main(void)
{
  char buf[] = "sip:%61lice@example.com";   /* the escape forces canonize */
  url_t url[1];
  printf("%d %s\n", url_d(url, buf), url->url_user);
  return 0;
}
```

```
url.c:361:12: runtime error: shift exponent 75 is too large for 32-bit type 'unsigned int'
```

(75 is `'l' - 33`.)

**The patch**

- `IS_SYN33` only tests the mask when `c` is between 33 and 64, the range the
  mask covers. Outside it, the answer is "no", which is what the code means.
- `IS_EXCLUDED` shifts `1U` instead of `1`.

Nothing changes for valid input: the same characters are accepted and the
same are escaped. The only difference is for bytes that were judged by a
random mask bit before: they now always go through the exclusion check, as
RFC 3261 wants.

The patch is attached (`0001-url-shifts.patch`). Happy to open a pull
request if you prefer.

Thanks for sofia-sip!
