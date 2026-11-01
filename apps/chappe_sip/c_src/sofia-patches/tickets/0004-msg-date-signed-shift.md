# msg_date.c: month_d() shifts a negative char

Hi,

While fuzzing the SIP parser under UBSan on x86 we hit an undefined shift in
`month_d()` (`libsofia-sip-ua/msg/msg_date.c`).

**What happens**

`month_d()` builds a number from the three letters of the month with
`s[0] << 16`. `s` is a `char const *`, so where `char` is signed a byte above
0x7f is negative, and shifting a negative value left is undefined. The bytes
come from the network: a Date or Expires header with such a
byte in the month name gets there. In practice the month just does not match,
so we saw no misbehaviour, only the UBSan report:

```
msg_date.c:106:7: runtime error: left shift of negative value -122
```

**How to reproduce**

Build sofia with `CFLAGS="-fsanitize=undefined -fsigned-char"`, then compile
and run this small program against it:

```c
#include <stdio.h>
#include <sofia-sip/msg_date.h>

int main(void)
{
  char const *s = "Sun, 01 \xe9" "an 2026 10:00:00 GMT";
  msg_time_t t = 0;
  int rc = msg_date_d(&s, &t);
  printf("msg_date_d: %d\n", rc);
  return rc >= 0;
}
```

Without the patch UBSan prints the error above. With it, the date is simply
refused, with no report.

**The patch**

`MONTH_V` converts each letter to `unsigned char` and then to `unsigned`
before the shift. Plain ASCII month names give the same value as before.

The patch is attached (`0004-msg-date-signed-shift.patch`). Happy to open a
pull request if you prefer.

Thanks for sofia-sip!
