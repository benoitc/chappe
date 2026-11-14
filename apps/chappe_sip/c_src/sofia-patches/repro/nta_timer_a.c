/* Timer A of an nta client transaction over UDP (RFC 3261 17.1.2.2: it
 * starts at T1). An agent with T1 = 100 ms sends an OPTIONS to a UDP
 * socket that never answers; the program prints the time between the
 * first two copies. Without patch 0005 it is about 1000 ms, with it
 * about 100 ms. Exits 0 when the gap is under 500 ms. */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <sofia-sip/su.h>
#include <sofia-sip/su_wait.h>
#include <sofia-sip/nta.h>
#include <sofia-sip/sip_tag.h>

static int sink;
static double first, gap = -1;

static double now_ms(void)
{
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

static int on_datagram(su_root_magic_t *m, su_wait_t *w, su_wakeup_arg_t *a)
{
  char buf[4096];
  (void)m; (void)w; (void)a;
  if (recv(sink, buf, sizeof buf, 0) <= 0)
    return 0;
  if (first == 0)
    first = now_ms();
  else if (gap < 0)
    gap = now_ms() - first;
  return 0;
}

static int on_response(nta_outgoing_magic_t *m, nta_outgoing_t *o,
                       sip_t const *sip)
{
  (void)m; (void)o; (void)sip;
  return 0;
}

int main(void)
{
  su_root_t *root;
  nta_agent_t *agent;
  nta_leg_t *leg;
  struct sockaddr_in sa;
  socklen_t len = sizeof sa;
  su_wait_t wait[1];
  char target[64];

  su_init();
  root = su_root_create(NULL);

  sink = socket(AF_INET, SOCK_DGRAM, 0);
  memset(&sa, 0, sizeof sa);
  sa.sin_family = AF_INET;
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  bind(sink, (struct sockaddr *)&sa, sizeof sa);
  getsockname(sink, (struct sockaddr *)&sa, &len);
  snprintf(target, sizeof target, "sip:sink@127.0.0.1:%u;transport=udp",
           ntohs(sa.sin_port));
  su_wait_create(wait, sink, SU_WAIT_IN);
  su_root_register(root, wait, on_datagram, NULL, 0);

  agent = nta_agent_create(root, URL_STRING_MAKE("sip:127.0.0.1:*;transport=udp"),
                           NULL, NULL, NTATAG_SIP_T1(100),
                           NTATAG_SIP_T1X64(6400), TAG_END());
  if (!agent) {
    fprintf(stderr, "nta_agent_create failed\n");
    return 2;
  }
  leg = nta_leg_tcreate(agent, NULL, NULL, NTATAG_NO_DIALOG(1), TAG_END());
  if (!nta_outgoing_tcreate(leg, on_response, NULL, NULL,
                            SIP_METHOD_OPTIONS, URL_STRING_MAKE(target),
                            SIPTAG_TO_STR(target),
                            SIPTAG_FROM_STR("<sip:repro@127.0.0.1>;tag=r1"),
                            TAG_END())) {
    fprintf(stderr, "nta_outgoing_tcreate failed\n");
    return 2;
  }

  for (int i = 0; i < 40 && gap < 0; i++)
    su_root_step(root, 100);

  printf("timer A: first retransmission after %.0f ms (T1 = 100 ms)\n", gap);

  nta_leg_destroy(leg);
  nta_agent_destroy(agent);
  su_root_destroy(root);
  su_deinit();
  return gap >= 0 && gap < 500 ? 0 : 1;
}
