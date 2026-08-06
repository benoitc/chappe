%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Public shared records.

%% A non-2xx final response to a UAC request, delivered as {error, ...}.
-record(chappe_sip_error, {
    status :: 100..699,
    reason :: binary(),
    response :: chappe_sip_msg:msg() | undefined
}).
