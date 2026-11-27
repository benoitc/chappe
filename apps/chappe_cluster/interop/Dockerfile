# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0

# One node of the cluster lab: OTP 29, chappe_cluster and its deps built
# from this tree (the build context is apps/chappe_cluster), the lab client
# from test/lab, and the tools for the faults the controller injects:
# iproute2 (tc netem delay), iptables (a split between two sides) and
# libfaketime (a node's wall clock moved while it runs). faketime is
# optional: without it the lab skips clock skew. The cookie comes from
# CLB_COOKIE at start (node/run.sh), never from the image.
FROM erlang:29.1.2

# apt as scripts/ci_apt.sh runs it: a stalled mirror or a stale index fails
# one bounded attempt, and the next one fetches the index again
RUN printf 'Acquire::Retries "3";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' \
        > /etc/apt/apt.conf.d/80-retries \
    && for i in 1 2 3; do \
        timeout 300 apt-get update \
        && timeout 900 apt-get install -y --no-install-recommends \
            iproute2 iptables \
        && break; \
        [ "$i" -lt 3 ] || exit 1; sleep $((i * 15)); \
    done \
    && (timeout 900 apt-get install -y --no-install-recommends libfaketime \
        || true) \
    && rm -rf /var/lib/apt/lists/*

COPY . /lab/app
WORKDIR /lab/app
RUN if [ -f rebar.config ] && [ -d src ]; then \
        for i in 1 2 3 4; do rebar3 get-deps && break; \
            rebar3 update || true; sleep $((i * 10)); done; \
        rebar3 compile && cp -r _build/default/lib /lab/lib; \
    else \
        mkdir -p /lab/lib; \
    fi \
    && mkdir -p /lab/ebin \
    && erlc -o /lab/ebin test/lab/*.erl

COPY interop/node/run.sh /usr/local/bin/clb-node
ENV PATH=/usr/local/lib/erlang/bin:$PATH
WORKDIR /lab
ENTRYPOINT ["/usr/local/bin/clb-node"]
