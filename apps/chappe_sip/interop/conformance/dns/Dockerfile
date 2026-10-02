# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0

# The lab's DNS server: dnsmasq serving the NAPTR, SRV and A records of
# dnsmasq.conf, authoritative for .lab and forwarding nothing.
FROM alpine:3.20
RUN apk add --no-cache dnsmasq
COPY dnsmasq.conf /etc/dnsmasq.conf
ENTRYPOINT ["dnsmasq", "-k", "--conf-file=/etc/dnsmasq.conf"]
