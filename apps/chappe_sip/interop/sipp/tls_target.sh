#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# The second SRV target of dns_sips_failover (tls.svcs.lab, 5061). socat
# terminates TLS and runs this on the connection: it reads one request
# and answers 200 when it is the OPTIONS to sips:uas@svcs.lab with a TLS
# Via (RFC 3261 8.1.2: alternate destinations of a sips: URI are contacted
# with TLS), 400 otherwise. It logs the request and its answer on stderr;
# run.sh wants "answered 200" there.
CR=$(printf '\r')
IFS= read -r line
line=${line%"$CR"}
echo "request: $line" >&2
via=""
hdrs=""
while IFS= read -r h; do
    h=${h%"$CR"}
    [ -z "$h" ] && break
    echo "  $h" >&2
    case "$h" in
        [Vv]ia:* | v:*)
            [ -z "$via" ] && via="$h"
            hdrs="$hdrs$h$CR
"
            ;;
        [Ff]rom:* | f:* | [Cc]all-[Ii][Dd]:* | i:* | [Cc][Ss]eq:*)
            hdrs="$hdrs$h$CR
"
            ;;
        [Tt]o:* | t:*)
            hdrs="$hdrs$h;tag=tls1$CR
"
            ;;
    esac
done

status="400 Bad Request"
case "$line" in
    "OPTIONS sips:uas@svcs.lab SIP/2.0")
        case "$via" in
            *SIP/2.0/TLS\ *) status="200 OK" ;;
        esac
        ;;
esac
printf 'SIP/2.0 %s\r\n%sContent-Length: 0\r\n\r\n' "$status" "$hdrs"
echo "answered $status" >&2
# keep the connection up while the node reads the answer
sleep 2
