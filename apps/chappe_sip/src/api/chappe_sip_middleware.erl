%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Connect-style middleware runner.
%%
%% A middleware is fun(Req, Res, Next) where Next is a 0-arity fun that
%% runs the rest of the chain. The chain stops when a middleware does
%% not call Next or when a final response has been sent.
-module(chappe_sip_middleware).

-export([run/4, select/2]).

-type mw() :: fun(
    (chappe_sip_req:req(), chappe_sip_res:res(), fun(() -> any())) -> any()
).
-export_type([mw/0]).

%% Middlewares are stored as {Method | '*', Fun}; select the ones that
%% apply to this method, in registration order.
-spec select([{binary() | '*', mw()}], binary()) -> [mw()].
select(Middlewares, Method) ->
    [F || {M, F} <- Middlewares, M =:= '*' orelse M =:= Method].

-spec run(
    [mw()],
    fun((chappe_sip_req:req(), chappe_sip_res:res()) -> any()),
    chappe_sip_req:req(),
    chappe_sip_res:res()
) -> any().
run([], Handler, Req, Res) ->
    Handler(Req, Res);
run([MW | Rest], Handler, Req, Res) ->
    case chappe_sip_res:finished(Res) of
        true -> ok;
        false -> MW(Req, Res, fun() -> run(Rest, Handler, Req, Res) end)
    end.
