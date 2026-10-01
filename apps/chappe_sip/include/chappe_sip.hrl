%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Public shared records.

%% A non-2xx final response to a UAC request, delivered as {error, ...}.
-record(chappe_sip_error, {
    status :: 100..699,
    reason :: binary(),
    response :: chappe_sip_msg:msg() | undefined
}).

%% Option tags we advertise in Supported on INVITE, its 2xx and OPTIONS
%% responses. What a request may list in Require without a 420 (RFC 3261
%% 8.2.2.3) is the `supported_option_tags' setting of chappe_sip_config.
-define(SUPPORTED, <<"replaces, timer">>).
%% The default of supported_option_tags. tdialog (RFC 4538, which RFC 7647 4
%% makes a REFER recipient process) and norefersub (RFC 4488) are REFER's,
%% handled by chappe_sip_refer.
-define(SUPPORTED_TAGS, [
    <<"100rel">>, <<"replaces">>, <<"timer">>, <<"tdialog">>, <<"norefersub">>
]).

%% Body types an INVITE may carry (RFC 3261 8.2.3): the SDP offer, alone or
%% in a multipart with other parts, for Accept on a 415.
-define(ACCEPT, <<"application/sdp, multipart/mixed, multipart/alternative">>).

%% Methods we accept, ACK and CANCEL included (RFC 3261 13.1, 20.5), for
%% Allow on INVITE, its 2xx, OPTIONS responses and 405/501.
-define(ALLOW, <<
    "INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE, REFER, NOTIFY, "
    "SUBSCRIBE, MESSAGE, PRACK"
>>).
