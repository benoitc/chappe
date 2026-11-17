%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% A binding of the location store (chappe_sip_registry), as the store
%% backends (chappe_sip_location) keep it.
-record(binding, {
    contact :: binary(),
    % absolute epoch seconds
    expiry :: non_neg_integer(),
    callid :: binary() | undefined,
    cseq :: non_neg_integer(),
    q :: binary() | undefined,
    % transport flow: the WS conn of a WS binding, the direct TCP/TLS or
    % UDP flow of an RFC 5626 one, undefined otherwise
    flow :: term(),
    % RFC 3327 Path values, in order: the route set toward the contact
    path = [] :: [binary()],
    % RFC 5626 +sip.instance and reg-id when the binding is an outbound flow
    instance :: binary() | undefined,
    reg_id :: binary() | undefined,
    % every Contact header parameter as received (RFC 5626 6)
    params = #{} :: map(),
    % the flow the REGISTER came on (RFC 3581): where a UA behind a NAT
    % is reached when its Contact is not
    received :: term(),
    % the transport the REGISTER came over (udp, tcp, tls), when known
    transport :: binary() | undefined,
    % the node that took the REGISTER and holds its flow
    node :: node() | undefined,
    % that node's boot (chappe_sip_flow:boot/0): a connection or WS flow
    % of an earlier boot is gone
    boot :: term(),
    % cluster mode: the Route to that node for this flow (RFC 5626 5.3),
    % undefined when the contact is reached directly
    edge :: binary() | undefined
}).
