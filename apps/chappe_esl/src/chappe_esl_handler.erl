%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Behaviour for outbound (dialplan socket) connections.
%%
%% The outbound listener starts one handler process per accepted channel and
%% calls handle_channel/3 in it with the connection and the initial channel
%% data event. The callback drives the channel with the chappe_esl API (execute,
%% api, subscribe, and so on) and returns when it is done. It runs in its own
%% process, so it may block on chappe_esl:execute/4 and receive {chappe_esl_event, ...}
%% messages. When it returns or exits, the connection closes.
-module(chappe_esl_handler).

-callback handle_channel(
    Conn :: pid(),
    Channel :: chappe_esl_event:event(),
    Args :: term()
) -> term().
