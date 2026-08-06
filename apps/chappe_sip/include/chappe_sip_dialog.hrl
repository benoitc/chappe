%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Dialog handle shared between chappe_sip_dialog and chappe_sip_dialog_fsm.
-record(dialog, {pid :: pid(), id :: non_neg_integer()}).
