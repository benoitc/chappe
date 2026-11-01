# msg_serialize: member access through a NULL separator

Hi,

Another one from our UBSan fuzzing, this time in
`libsofia-sip-ua/msg/msg_parser.c`, function `msg_serialize()`.

**What happens**

After serializing the headers, the code checks where the payload goes:

```c
if (ptail != &(*separator)->sh_prev)
```

When the message has no separator, `*separator` is NULL and the expression
takes the address of a member through a NULL pointer. The address is only
compared, never read, so in practice it "works", but it is undefined
behaviour and UBSan stops on it. A message gets there easily: one parsed
without the empty line at the end, or one built by hand before it is
completed.

**How to reproduce**

With sofia-sip built under UBSan (same configure line as for the url.c
ticket):

```c
#include <stdio.h>
#include <sofia-sip/msg.h>
#include <sofia-sip/sip.h>
#include <sofia-sip/sip_header.h>

int main(void)
{
  char const req[] =                 /* no empty line: no separator */
    "OPTIONS sip:b@example.com SIP/2.0\r\n"
    "Via: SIP/2.0/UDP 192.0.2.1;branch=z9hG4bK1\r\n"
    "From: <sip:a@example.com>;tag=1\r\n"
    "To: <sip:b@example.com>\r\n"
    "Call-ID: 1\r\n"
    "CSeq: 1 OPTIONS\r\n";
  msg_t *msg = msg_make(sip_default_mclass(), 0, req, sizeof req - 1);
  sip_t *sip = sip_object(msg);
  printf("%d\n", msg_serialize(msg, (msg_pub_t *)sip));
  msg_destroy(msg);
  return 0;
}
```

```
msg_parser.c:1967:31: runtime error: member access within null pointer of type 'msg_header_t'
```

**The patch**

One line: test `*separator` first.

```c
if (!*separator || ptail != &(*separator)->sh_prev)
```

With no separator the old comparison was always true (no real pointer
equals that bogus address), so the code took the first, empty branch. The
new test takes the same branch, so the behaviour does not change, only the
undefined part goes away.

The patch is attached (`0002-msg-serialize-null-separator.patch`).

Thanks!
