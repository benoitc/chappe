#include <stdio.h>
#include <sofia-sip/msg_date.h>

int main(void)
{
  /* The month name has a byte above 0x7f. Where char is signed, month_d()
   * shifts its negative value left, which is undefined. */
  char const *s = "Sun, 01 \xe9" "an 2026 10:00:00 GMT";
  msg_time_t t = 0;
  int rc = msg_date_d(&s, &t);
  printf("msg_date_d: %d\n", rc);
  return rc >= 0;
}
