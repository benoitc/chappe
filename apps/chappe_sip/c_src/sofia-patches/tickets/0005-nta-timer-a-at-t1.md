# nta.c: Timer A/E never starts below 1 second over UDP

Hi,

We set `NTATAG_SIP_T1()` below 1000 ms on an agent and noticed that the
first retransmission of a request over UDP still comes a full second after
the original, whatever T1 is.

**What happens**

In `outgoing_send()` (`libsofia-sip-ua/nta/nta.c`) the unreliable branch
starts Timer A/E like this:

```c
/* race condition on initial t1 timer timeout, set minimum initial timeout to 1000ms */
unsigned t1_timer = agent->sa_t1;
if (t1_timer < 1000) t1_timer = 1000;
outgoing_set_timer(orq, t1_timer); /* Timer A/E */
```

So with the default T1 of 500 ms the first retransmission goes at 1 s, and
with a smaller T1 (allowed on closed networks) it also goes at 1 s. The
following ones double from that value, so the whole retransmission
schedule is shifted. RFC 3261 says "the client transaction MUST start
timer A with a value of T1" (17.1.1.2) and "the client transaction MUST
set timer E to fire in T1 seconds" (17.1.2.2). Timer B/F (64*T1) is not
affected, so a request gets fewer retransmissions than the RFC expects
before it times out.

We could not find what race the comment refers to: the timer is set after
the message was handed to the transport, as for the reliable case.

**How to reproduce**

`repro/nta_timer_a.c` creates an agent on 127.0.0.1 with
`NTATAG_SIP_T1(100)`, sends an OPTIONS to a UDP socket that never answers,
and prints the time between the first two copies:

```
timer A: first retransmission after 1001 ms (T1 = 100 ms)
```

With the patch:

```
timer A: first retransmission after 101 ms (T1 = 100 ms)
```

**The patch**

Timer A/E starts at T1, as before the minimum was added. Agents that keep
the default T1 now retransmit first at 500 ms instead of 1000 ms, which is
the RFC schedule.

The patch is attached (`0005-nta-timer-a-at-t1.patch`). If the minimum
works around a real problem somewhere, we would be glad to hear about it,
and could instead make it opt-in with a tag.

Thanks for sofia-sip!
