#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Makes the lab's throwaway TLS material in DIR (default /certs): a CA, a
# certificate for svcs.lab that the SIPp TLS listener presents, and the
# node's agent.pem. The node trusts the CA through cafile.pem.
set -eu

DIR="${1:-/certs}"
cd "$DIR"
[ -f agent.pem ] && [ -f sipp.pem ] && exit 0
openssl req -x509 -newkey rsa:2048 -keyout ca.key -out ca.pem -days 3650 \
    -nodes -subj '/CN=chappe conformance lab CA' 2>/dev/null
cp ca.pem cafile.pem
sign() {
    printf 'subjectAltName=%s\n' "$2" > "$1.ext"
    openssl req -newkey rsa:2048 -keyout "$1.key" -out "$1.csr" -nodes \
        -subj "/CN=$3" 2>/dev/null
    openssl x509 -req -in "$1.csr" -CA ca.pem -CAkey ca.key \
        -CAcreateserial -out "$1.pem" -days 3650 -extfile "$1.ext" 2>/dev/null
}
sign sipp "DNS:svcs.lab,URI:sip:svcs.lab,DNS:tls.svcs.lab" svcs.lab
sign node "IP:10.253.7.10" 10.253.7.10
# sofia reads the key and the certificate from one agent.pem
cat node.key node.pem > agent.pem
chmod 644 ./*.pem ./*.key
