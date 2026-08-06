%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Runnable examples. Compile against the app and call from a shell:
%%
%%   1> c("examples/chappe_sip_demo").
%%   2> chappe_sip_demo:echo(5060).       % answer INVITEs with your SDP echoed
%%   3> chappe_sip_demo:b2bua(5060, <<"sip:bob@10.0.0.2">>).  % bridge to Bob
%%
%% These are teaching examples, not part of the application.
-module(chappe_sip_demo).

-behaviour(chappe_sip_handler).

-export([echo/1, b2bua/2, registrar/1]).
-export([init/1, handle_dialog/4, terminate/2]).

%% ---- an echo UAS: answer every INVITE, echo the caller's SDP ----

-spec echo(inet:port_number()) -> ok.
echo(Port) ->
    ok = chappe_sip:start(#{contact => contact(Port)}),
    ok = chappe_sip:invite(fun(Req, Res) -> chappe_sip_handler:start(?MODULE, Req, Res) end),
    ok.

%% chappe_sip_handler callbacks for the echo UAS
init(Req) ->
    %% answer with the caller's own offer (loopback media)
    {answer, #{local_sdp => chappe_sip_req:body(Req)}, #{}}.

handle_dialog(info, _Req, Res, State) ->
    %% acknowledge INFO explicitly instead of the auto-200
    _ = chappe_sip_res:send(Res, 200, #{reason => <<"OK">>}),
    {ok, State};
handle_dialog(_Event, _Req, _Res, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ---- a B2BUA: bridge every INVITE to a fixed destination ----

-spec b2bua(inet:port_number(), binary()) -> ok.
b2bua(Port, Dest) ->
    ok = chappe_sip:start(#{contact => contact(Port)}),
    ok = chappe_sip:invite(fun(Req, Res) ->
        case chappe_sip:create_b2bua(Req, Res, Dest, #{}) of
            {ok, Legs} ->
                chappe_sip_b2b:relay(Legs);
            {error, _} ->
                ok
        end
    end),
    ok.

%% ---- a registrar backed by the location store (no auth, demo only) ----

-spec registrar(inet:port_number()) -> ok.
registrar(Port) ->
    ok = chappe_sip:start(#{contact => contact(Port)}),
    %% chappe_sip:registrar/0 records contacts and answers 200 with the live
    %% bindings; chappe_sip:location/1 resolves an AOR to its contacts.
    ok = chappe_sip:register(chappe_sip:registrar()),
    ok.

contact(Port) ->
    <<"sip:0.0.0.0:", (integer_to_binary(Port))/binary>>.
