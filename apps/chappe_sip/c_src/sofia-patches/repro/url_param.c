#include <stdio.h>
#include <sofia-sip/url.h>

int main(void)
{
  /* The parameter string ends at the first NUL. Its last parameter starts
   * with the name looked up but has no '=', so url_param() steps over the
   * NUL and goes on into whatever follows: here a second string, whose
   * maddr it then returns. In sofia the parameters are the end of a heap
   * block, so the read leaves it (ASan: heap-buffer-overflow in strcspn). */
  static const char buf[] = "transport=udp;maddrx\0maddr=10.0.0.66";
  char value[64] = "";
  int n = (int)url_param(buf, "maddr", value, sizeof value);
  printf("url_param: %d \"%s\"\n", n, value);
  return n != 0;
}
