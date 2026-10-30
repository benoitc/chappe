%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The outbound socket handler: FreeSWITCH runs the dialplan `socket'
%% application for a call chappe_mrf sent it, and connects here. The
%% channel carries the X-Chappe-Call header of the INVITE as
%% variable_sip_h_X-Chappe-Call; the endpoint registered under that id
%% takes the connection over. A channel nobody waits for is hung up.
-module(chappe_mrf_esl).
-behaviour(chappe_esl_handler).

-export([handle_channel/3, header/0, var/0]).

-define(HEADER, <<"X-Chappe-Call">>).

%% The SIP header that carries the correlation id.
-spec header() -> binary().
header() -> ?HEADER.

%% The channel variable FreeSWITCH puts that header in.
-spec var() -> binary().
var() -> <<"variable_sip_h_", ?HEADER/binary>>.

-spec handle_channel(pid(), chappe_esl_event:event(), term()) -> ok.
handle_channel(Conn, Channel, _Args) ->
    Found =
        case chappe_esl_event:header(var(), Channel) of
            undefined -> error;
            Id -> chappe_mrf_registry:lookup({call, Id})
        end,
    case Found of
        {ok, Ep} ->
            case chappe_mrf_endpoint:attach(Ep, Conn, Channel) of
                ok -> ok;
                {error, _} -> refuse(Conn)
            end;
        error ->
            refuse(Conn)
    end.

refuse(Conn) ->
    _ = chappe_esl:execute(Conn, <<"hangup">>, <<"UNALLOCATED_NUMBER">>),
    chappe_esl:close(Conn).
