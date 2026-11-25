%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Where a NOTIFY outside any dialog of the stack goes.
%%
%% The engine runs handler/1 for every such NOTIFY: a subscription of ours
%% (chappe_sip_subscriber) by Call-ID, our tag and the peer's, then a
%% REFER we sent (chappe_sip_refer_notify:handle_notify/2), then your
%% chappe_sip:notify/1 handler; with none of them, 481 (RFC 6665 4.1.3).
-module(chappe_sip_notify_router).

-export([handler/1]).

-define(TAB, chappe_sip_subscribers).

-spec handler(fun() | undefined) ->
    fun((chappe_sip_req:req(), chappe_sip_res:res()) -> term()).
handler(App) ->
    fun(Req, Res) ->
        case route(Req, Res) of
            handled ->
                ok;
            pass ->
                case chappe_sip_refer_notify:handle_notify(Req, Res) of
                    handled ->
                        ok;
                    pass when is_function(App, 2) ->
                        App(Req, Res);
                    pass ->
                        chappe_sip_res:send(Res, 481, #{
                            reason => <<"Subscription Does Not Exist">>
                        })
                end
        end
    end.

%% Answer a NOTIFY belonging to a subscription of ours; pass otherwise.
%% The subscriptions register in chappe_sip_subscribers (see
%% chappe_sip_subscriber_sup) once their dialog forms, and by our tag alone
%% until then.
-spec route(chappe_sip_req:req(), chappe_sip_res:res()) -> handled | pass.
route(Req, Res) ->
    Msg = chappe_sip_req:msg(Req),
    CallId = chappe_sip_msg:call_id(Msg),
    Local = chappe_sip_msg:to_tag(Msg),
    Remote = chappe_sip_msg:from_tag(Msg),
    case find([{CallId, Local, Remote}, {CallId, Local, any}]) of
        {ok, Pid} ->
            try
                gen_statem:call(Pid, {notify, Req, Res}, 10000)
            catch
                exit:_ -> pass
            end;
        error ->
            pass
    end.

find([]) ->
    error;
find([Key | Rest]) ->
    try ets:lookup(?TAB, Key) of
        [{Key, Pid}] ->
            case is_process_alive(Pid) of
                true ->
                    {ok, Pid};
                false ->
                    _ = ets:delete(?TAB, Key),
                    find(Rest)
            end;
        [] ->
            find(Rest)
    catch
        error:badarg -> error
    end.
