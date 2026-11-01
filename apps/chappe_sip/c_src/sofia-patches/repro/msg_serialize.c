#include <stdio.h>
#include <string.h>
#include <sofia-sip/msg.h>
#include <sofia-sip/sip.h>
#include <sofia-sip/sip_header.h>

int main(void)
{
  /* a message parsed without its empty line has no separator header */
  char const req[] =
    "OPTIONS sip:b@example.com SIP/2.0\r\n"
    "Via: SIP/2.0/UDP 192.0.2.1;branch=z9hG4bK1\r\n"
    "From: <sip:a@example.com>;tag=1\r\n"
    "To: <sip:b@example.com>\r\n"
    "Call-ID: 1\r\n"
    "CSeq: 1 OPTIONS\r\n";
  msg_t *msg = msg_make(sip_default_mclass(), 0, req, sizeof req - 1);
  if (!msg) { printf("no message\n"); return 1; }
  sip_t *sip = sip_object(msg);
  printf("separator=%p\n", (void *)sip->sip_separator);
  printf("serialize: %d\n", msg_serialize(msg, (msg_pub_t *)sip));
  msg_destroy(msg);
  return 0;
}
