%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The fs backend's join, in the caller of chappe_mrf_conf:join/3 (after
%% chappe_mrf_conf_fs:join/4 checked the room): an endpoint on the room's
%% node, made and bridged for a call, enters the PIN if the join asks one,
%% then joins the room ({join, {fs, Ep, Owned, Opts}}).
-module(chappe_mrf_conf_fs_join).

-export([join/4]).

%% Target: a call, an incoming call not answered yet, or an endpoint on
%% the room's node; Info: the room's info/1.
-spec join(pid(), map(), term(), map()) -> {ok, binary()} | {error, term()}.
join(Conf, Info, {call, Req, Res}, Opts) ->
    join_call(Conf, Info, Req, Res, Opts);
join(Conf, Info, B2b, Opts) when is_tuple(B2b) ->
    join_target(Conf, Info, B2b, Opts#{b2b => B2b});
join(Conf, Info, Ep, Opts) ->
    join_target(Conf, Info, Ep, Opts).

join_target(Conf, #{node := Node, bridge := Bridge} = Info, Target, Opts) ->
    case endpoint(Conf, Node, Bridge, Target) of
        {ok, Ep, Owned} -> enter(Conf, Info, Ep, Owned, Opts);
        {error, _} = Err -> Err
    end.

%% An incoming call not answered yet, in its request worker: chappe's
%% B2BUA answers the caller (chappe_mrf_conf_refer_member:member_opts/2) and
%% bridges it to an endpoint on the room's node, which then joins.
join_call(Conf, #{node := Node, bridge := Bridge} = Info, Req, Res, Opts0) ->
    Opts = maps:merge(
        #{uri => chappe_mrf_conf_refer_member:from_uri(Req)}, Opts0
    ),
    Member = chappe_mrf_conf_refer_member:member_opts(
        Conf, maps:get(entity, Info, undefined)
    ),
    CallOpts = maps:merge(maps:with([anchor_params], Bridge), Member#{
        node => Node, owner => Conf
    }),
    case chappe_mrf:connect_caller(Req, Res, CallOpts) of
        {ok, Ep, B2b} -> enter(Conf, Info, Ep, true, Opts#{b2b => B2b});
        {error, _} = Err -> Err
    end.

%% Ep, on the room's node, enters the PIN if the join asks one, then the
%% room, waiting past the room's join_timeout (its answer comes first);
%% an endpoint made for the join goes if it does not get in.
enter(Conf, Info, Ep, Owned, Opts) ->
    case check_pin(Ep, Opts) of
        ok ->
            case
                chappe_mrf_conf:call(
                    Conf,
                    {join, {fs, Ep, Owned, Opts}},
                    chappe_mrf_conf_fs:join_wait(Info)
                )
            of
                {ok, _} = Ok ->
                    Ok;
                {error, timeout} = Err ->
                    %% the conference destroys it on its own timer
                    Err;
                {error, _} = Err ->
                    %% refused (full, locked meanwhile): the endpoint
                    %% made for the join goes
                    _ = Owned andalso chappe_mrf:destroy(Ep),
                    Err
            end;
        {error, _} = Err ->
            _ = Owned andalso chappe_mrf:destroy(Ep),
            Err
    end.

endpoint(Conf, Node, Bridge, B2b) when is_tuple(B2b) ->
    case chappe_mrf:create_endpoint(#{node => Node, owner => Conf}) of
        {ok, Ep} ->
            case chappe_mrf:bridge(B2b, Ep, Bridge) of
                ok ->
                    {ok, Ep, true};
                {error, _} = Err ->
                    chappe_mrf:destroy(Ep),
                    Err
            end;
        {error, _} = Err ->
            Err
    end;
endpoint(_Conf, Node, _Bridge, Ep) when is_pid(Ep) ->
    case chappe_mrf:node(Ep) of
        {ok, Node} -> {ok, Ep, false};
        {ok, Other} -> {error, {wrong_node, Other}};
        Err -> Err
    end.

check_pin(Ep, #{pin := Pin} = Opts) ->
    Prompt = maps:get(pin_prompt, Opts, <<"silence_stream://250">>),
    check_pin(
        Ep, chappe_mrf_lib:to_bin(Pin), Prompt, maps:get(pin_tries, Opts, 3)
    );
check_pin(_Ep, _Opts) ->
    ok.

check_pin(_Ep, _Pin, _Prompt, 0) ->
    {error, bad_pin};
check_pin(Ep, Pin, Prompt, Tries) ->
    Len = byte_size(Pin),
    case
        chappe_mrf:play_collect(Ep, #{
            file => Prompt, min => Len, max => Len, timeout => 5000
        })
    of
        {ok, Pin} -> ok;
        {ok, _} -> check_pin(Ep, Pin, Prompt, Tries - 1);
        {error, _} = Err -> Err
    end.
