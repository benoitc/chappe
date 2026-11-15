# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0

# One node of the cluster lab: OTP 29, chappe_cluster and its deps built
# from this tree (the build context is apps/chappe_cluster), the lab client
# from test/lab, and the tools for the faults the controller injects:
# iproute2 (tc netem delay), iptables (a split between two sides) and
# libfaketime (a node's wall clock moved while it runs). faketime is
# optional: without it the lab skips clock skew. The cookie comes from
# CLB_COOKIE at start (node/run.sh), never from the image.
FROM erlang:29

RUN apt-get update && apt-get install -y --no-install-recommends \
    iproute2 iptables \
    && (apt-get install -y --no-install-recommends libfaketime || true) \
    && rm -rf /var/lib/apt/lists/*

COPY . /lab/app
WORKDIR /lab/app
RUN if [ -f rebar.config ] && [ -d src ]; then \
        rebar3 compile && cp -r _build/default/lib /lab/lib; \
    else \
        mkdir -p /lab/lib; \
    fi \
    && mkdir -p /lab/ebin \
    && erlc -o /lab/ebin \
        test/lab/chappe_cluster_lab_node.erl \
        test/lab/chappe_cluster_lab_client.erl \
        test/lab/chappe_cluster_lab_log.erl \
        test/lab/chappe_cluster_lab_worker.erl \
        test/lab/chappe_cluster_lab_single.erl

COPY interop/node/run.sh /usr/local/bin/clb-node
ENV PATH=/usr/local/lib/erlang/bin:$PATH
WORKDIR /lab
ENTRYPOINT ["/usr/local/bin/clb-node"]
