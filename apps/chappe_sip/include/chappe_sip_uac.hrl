%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% UAC reference shared between chappe_sip_uac and chappe_sip_uac_fsm. Events are
%% tagged {chappe_sip_uac, #uac_ref{}, Event} so apps match on the same value
%% start/2 returned.
-record(uac_ref, {pid :: pid(), ref :: reference()}).
