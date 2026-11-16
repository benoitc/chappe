%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The outbound socket handler: FreeSWITCH runs the dialplan `socket'
%% application for a call chappe_mrf sent it, and connects here. The
%% channel carries the X-Chappe-Call header of the INVITE as
%% variable_sip_h_X-Chappe-Call; the endpoint registered under that id
%% takes the connection over. A channel nobody waits for is hung up.
%% It also starts and stops the listener chappe_mrf runs this handler on
%% (chappe_mrf:listen/2, chappe_mrf:stop_listener/0).
-module(chappe_mrf_esl).
-behaviour(chappe_esl_handler).

-export([handle_channel/3, header/0, var/0, headers/2]).
-export([listen/2, listener_opts/1, stop_listener/0]).

-define(HEADER, <<"X-Chappe-Call">>).
-define(EP_HEADER, <<"X-Chappe-Endpoint">>).
%% the port and options of the running listener
-define(LISTENER, {chappe_mrf, listener}).

%% Listen for FreeSWITCH outbound sockets on Port with this handler. A
%% listener of ours already on Port with the same options is kept; with
%% other options it returns {error, {listener_running, RunningOpts}}, so
%% an allow list asked for is never dropped silently. Another listener on
%% Port returns {error, already_started}.
-spec listen(inet:port_number(), chappe_esl:listener_opts()) ->
    ok | {error, term()}.
listen(Port, ListenerOpts) ->
    case chappe_esl:start_listener(Port, ?MODULE, [], ListenerOpts) of
        {ok, _} ->
            persistent_term:put(?LISTENER, {Port, ListenerOpts}),
            ok;
        {error, already_started} ->
            running(Port, ListenerOpts);
        {error, _} = Err ->
            Err
    end.

running(Port, Opts) ->
    case persistent_term:get(?LISTENER, undefined) of
        {Port, Opts} -> ok;
        {Port, Running} -> {error, {listener_running, Running}};
        _ -> {error, already_started}
    end.

%% chappe_mrf's esl_ip and esl_allow as chappe_esl's ip and allow.
-spec listener_opts(map()) -> chappe_esl:listener_opts().
listener_opts(Opts) ->
    Keys = #{esl_ip => ip, esl_allow => allow},
    #{maps:get(K, Keys) => V || K := V <- maps:with(maps:keys(Keys), Opts)}.

-spec stop_listener() -> ok | {error, term()}.
stop_listener() ->
    case persistent_term:get(?LISTENER, undefined) of
        undefined ->
            ok;
        {Port, _Opts} ->
            _ = persistent_term:erase(?LISTENER),
            chappe_esl:stop_listener(Port)
    end.

%% The SIP header that carries the call's correlation id.
-spec header() -> binary().
header() -> ?HEADER.

%% The channel variable FreeSWITCH puts that header in.
-spec var() -> binary().
var() -> <<"variable_sip_h_", ?HEADER/binary>>.

%% The headers of an endpoint's INVITE: X-Chappe-Call is the call's ref
%% when the app gave one (one call, several endpoints), else the
%% endpoint's own id; X-Chappe-Endpoint then names the endpoint.
-spec headers(binary(), binary() | undefined) -> [{binary(), binary()}].
headers(Id, undefined) ->
    [{?HEADER, Id}];
headers(Id, CallRef) ->
    [{?HEADER, CallRef}, {?EP_HEADER, Id}].

-spec handle_channel(pid(), chappe_esl_event:event(), term()) -> ok.
handle_channel(Conn, Channel, _Args) ->
    H = fun(Name) ->
        chappe_esl_event:header(<<"variable_sip_h_", Name/binary>>, Channel)
    end,
    Found =
        case {H(?EP_HEADER), H(?HEADER)} of
            {undefined, undefined} -> error;
            {undefined, Id} -> chappe_mrf_registry:lookup({call, Id});
            {Id, _} -> chappe_mrf_registry:lookup({call, Id})
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
