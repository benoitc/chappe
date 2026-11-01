#include <stdio.h>
#include <sofia-sip/url.h>

int main(void)
{
  /* an escape in the user part makes url_d() canonize the bytes after it */
  char buf[] = "sip:%61lice@example.com";
  url_t url[1];
  int rv = url_d(url, buf);
  printf("url_d: %d user=%s\n", rv, url->url_user ? url->url_user : "(null)");
  return 0;
}
