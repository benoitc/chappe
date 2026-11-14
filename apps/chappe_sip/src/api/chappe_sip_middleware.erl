%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Connect-style middleware runner.
%%
%% A middleware is fun(Req, Res, Next) where Next is a 0-arity fun that
%% runs the rest of the chain with Req. To hand on a changed request (one
%% with locals, chappe_sip_req:set_local/3), return {next, Req1} instead
%% of calling Next: the rest of the chain runs with Req1. Call Next or
%% return {next, _}, not both. The chain stops when a middleware does
%% neither, or when a final response has been sent.
-module(chappe_sip_middleware).

-export([run/4, select/2]).

-type mw() :: fun(
    (chappe_sip_req:req(), chappe_sip_res:res(), fun(() -> any())) ->
        {next, chappe_sip_req:req()} | any()
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
        true ->
            ok;
        false ->
            case MW(Req, Res, fun() -> run(Rest, Handler, Req, Res) end) of
                {next, Req1} -> next(Req1, Rest, Handler, Res);
                Other -> Other
            end
    end.

%% {next, Req1}: the rest of the chain with the middleware's request; a
%% value that is no request is the middleware's bug, caught here
next(Req1, Rest, Handler, Res) ->
    case chappe_sip_req:is_req(Req1) of
        true -> run(Rest, Handler, Req1, Res);
        false -> error({bad_middleware_result, {next, Req1}})
    end.
