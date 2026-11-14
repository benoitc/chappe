%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The native backend of chappe_mrf_conf: a chappe_mix room behind
%% rtpengine, reached by a loopback INVITE (see chappe_mrf_conf).
-module(chappe_mrf_conf_native).

-include("chappe_mrf_conf.hrl").

-export([join/4, offer/3, result/4, complete/3, play_leg/2]).
-export([join_endpoint/3, join_call/4, prepare_call/2, call_done/5]).

%% ---- native ----

join(B2b, Opts, From, #state{anchor_params = AP} = S) ->
    Token = chappe_mrf_lib:new_id(),
    ok = chappe_mrf_registry:put({loop, Token}, self()),
    Uri = chappe_mrf:loop_target(Token),
    Self = self(),
    _ = spawn(fun() ->
        Result = chappe_sip_b2b:replace_b(B2b, Uri, #{anchor_params => AP}),
        Self ! {join_result, Token, Result}
    end),
    J = #{from => From, b2b => B2b, opts => Opts},
    {noreply, S#state{pending = (S#state.pending)#{Token => J}}}.

%% An incoming call not answered yet, in its request worker: A is
%% answered by a B2BUA call to the loopback (the mixer behind rtpengine),
%% which then runs in a process of its own.
join_call(Conf, Req, Res, Opts0) ->
    %% who the member is, for a REFER's method=BYE: the URI it calls from
    Opts = maps:merge(#{uri => from_uri(Req)}, Opts0),
    case chappe_mrf_conf:call(Conf, {join, {call, Opts}}, 5000) of
        {ok, Token, Uri, AP, Entity} ->
            %% the room's REFERs come to the room (chappe_mrf_conf_refer);
            %% a focus room answers with the conference URI and isfocus
            %% as the member's Contact (RFC 4579 4.2)
            B2bOpts = (focus_opts(Entity))#{
                media => anchor,
                anchor_params => AP,
                requests => [refer],
                notify => Conf
            },
            Result =
                case chappe_sip:create_b2bua(Req, Res, Uri, B2bOpts) of
                    {ok, Legs} -> relay(Legs, Conf);
                    {error, _} = Err -> Err
                end,
            chappe_mrf_conf:call(
                Conf,
                {join, {call_done, Token, Result}},
                ?MRF_JOIN_TIMEOUT + 5000
            );
        Err ->
            Err
    end.

focus_opts(undefined) ->
    #{};
focus_opts(Entity) ->
    #{a_headers => chappe_sip_focus:headers(chappe_sip_focus:contact(Entity))}.

%% The call runs on its own; its member dialog (leg A) is kept with it so
%% a REFER the call hands the room can be answered in that dialog.
relay(#{uas := Uas} = Legs, Conf) ->
    case chappe_sip_b2b:relay_async(Legs, #{notify => Conf}) of
        {ok, {Pid, Ref}} = Ok ->
            _ = chappe_mrf_registry:put({a_dialog, Ref, Uas}, Pid),
            Ok;
        Err ->
            Err
    end.

from_uri(Req) ->
    case chappe_sip_hdr:name_addr(chappe_sip_req:get(<<"from">>, Req)) of
        {ok, #{uri := U}} -> U;
        _ -> undefined
    end.

%% the loopback a joining call is sent to, and the flags toward the mixer
prepare_call(Opts, #state{anchor_params = AP} = S) ->
    Token = chappe_mrf_lib:new_id(),
    ok = chappe_mrf_registry:put({loop, Token}, self()),
    J = #{opts => Opts},
    Uri = iolist_to_binary(chappe_mrf:loop_target(Token)),
    {reply, {ok, Token, Uri, AP, S#state.entity}, S#state{
        pending = (S#state.pending)#{Token => J}
    }}.

%% the B2BUA call of join_call/4 is up (or failed)
call_done(Token, J, {ok, B2b}, From, S) ->
    complete(Token, J#{from => From, b2b => B2b, result => ok}, S);
call_done(Token, J, Error, From, S) ->
    result(Token, J#{from => From}, Error, S).

%% the mixer answers the loopback INVITE's offer (rtpengine's)
offer(Token, Offer, #state{pending = P, room = Room, name = Name} = S) ->
    case P of
        #{Token := #{opts := Opts} = J} when not is_map_key(session, J) ->
            CallId = <<"mrf-", Name/binary, "-", Token/binary>>,
            case
                chappe_sip_media:session(#{call_id => CallId}, #{
                    capability => conference
                })
            of
                {ok, MS} ->
                    JoinOpts = #{
                        sdp => Offer,
                        owner => self(),
                        persist => true,
                        talk_events => true,
                        talk_tag => Token,
                        mute => maps:get(mute, Opts, false)
                    },
                    case
                        chappe_sip_media:conference(
                            MS, Room, with_name(Opts, JoinOpts)
                        )
                    of
                        {ok, Answer} ->
                            _ =
                                maps:get(deaf, Opts, false) andalso
                                    chappe_sip_media:deaf(MS),
                            J1 = J#{session => MS},
                            {reply, {ok, Answer}, S#state{
                                pending = P#{Token := J1}
                            }};
                        {error, _} = Err ->
                            {reply, Err, S}
                    end;
                {error, _} = Err ->
                    {reply, Err, S}
            end;
        _ ->
            {reply, {error, unknown_join}, S}
    end.

with_name(#{name := N}, Opts) -> Opts#{name => chappe_mrf_lib:to_bin(N)};
with_name(_, Opts) -> Opts.

result(Token, J, ok, S) ->
    complete(Token, J#{result => ok}, S);
result(Token, J, Error, S) ->
    #{from := From} = J,
    gen_server:reply(From, Error),
    _ = chappe_mrf_registry:delete({loop, Token}),
    _ =
        maps:is_key(session, J) andalso
            chappe_sip_media:leave(maps:get(session, J)),
    _ =
        maps:is_key(dialog, J) andalso
            chappe_mrf_lib:destroy_dialog(maps:get(dialog, J)),
    S#state{pending = maps:remove(Token, S#state.pending)}.

%% both the replace_b result and the loopback dialog are in: a member
complete(Token, #{result := ok, dialog := D, session := MS} = J, S) ->
    #{from := From, b2b := B2b, opts := Opts} = J,
    _ = chappe_mrf_registry:delete({loop, Token}),
    Mb = chappe_mrf_conf:member(Opts, Token, #{
        b2b => B2b, dialog => D, session => MS
    }),
    gen_server:reply(From, {ok, Token}),
    S1 = S#state{
        pending = maps:remove(Token, S#state.pending),
        members = (S#state.members)#{Token => Mb}
    },
    chappe_mrf_conf:publish(
        chappe_mrf_conf:emit(
            {joined, Token, chappe_mrf_conf:public(Token, Mb)}, S1
        )
    );
complete(Token, J, S) ->
    S#state{pending = (S#state.pending)#{Token => J}}.

%% An endpoint of create_endpoint/1 joins: the mixer offers, rtpengine
%% carries the offer to the endpoint's node in a re-INVITE of its dialog,
%% and the node's answer comes back through rtpengine to the mixer. The
%% conference owns both media sessions; the endpoint keeps its channel.
join_endpoint(Ep, Opts, #state{name = Name, room = Room} = S) ->
    case chappe_mrf:info(Ep) of
        #{dialog := D, bridged := false} when D =/= undefined ->
            Id = chappe_mrf_lib:new_id(),
            CallId = <<"mrf-", Name/binary, "-", Id/binary>>,
            case endpoint_media(CallId, Id, D, Room, Opts, S) of
                {ok, MS, RS} ->
                    ok = chappe_mrf_endpoint:watch(Ep, self()),
                    Mb = chappe_mrf_conf:member(Opts, Id, #{
                        ep => Ep, session => MS, rtpe => RS
                    }),
                    S1 = S#state{members = (S#state.members)#{Id => Mb}},
                    {reply, {ok, Id},
                        chappe_mrf_conf:publish(
                            chappe_mrf_conf:emit(
                                {joined, Id, chappe_mrf_conf:public(Id, Mb)}, S1
                            )
                        )};
                {error, _} = Err ->
                    {reply, Err, S}
            end;
        #{} ->
            {reply, {error, no_dialog}, S};
        Err ->
            {reply, Err, S}
    end.

endpoint_media(CallId, Id, D, Room, Opts, #state{endpoint_params = EP}) ->
    {ok, MS} = chappe_sip_media:session(#{call_id => CallId}, #{
        capability => conference
    }),
    JoinOpts = with_name(Opts, #{
        owner => self(),
        persist => true,
        talk_events => true,
        talk_tag => Id,
        mute => maps:get(mute, Opts, false)
    }),
    Steps = fun() ->
        {ok, MixOffer} = chappe_sip_media:conference(MS, Room, JoinOpts),
        {ok, RS} = chappe_sip_media:session(
            #{call_id => CallId, from_tag => <<"mix-", Id/binary>>},
            #{capability => anchor}
        ),
        Plain = #{ice => remove, transport_protocol => <<"RTP/AVP">>},
        {ok, ToNode} = chappe_sip_media:offer(RS, MixOffer, #{
            params => maps:merge(Plain, maps:get(offer, EP, #{}))
        }),
        case chappe_sip_dialog:modify(D, ToNode) of
            {ok, NodeAnswer} ->
                {ok, ToMix} = chappe_sip_media:answer(RS, NodeAnswer, #{
                    to_tag => chappe_sip_dialog:remote_tag(D),
                    params => maps:merge(Plain, maps:get(answer, EP, #{}))
                }),
                ok = chappe_sip_media:set_remote(MS, ToMix),
                _ =
                    maps:get(deaf, Opts, false) andalso
                        chappe_sip_media:deaf(MS),
                {ok, MS, RS};
            {error, _} = Err ->
                _ = chappe_sip_media:stop(RS),
                Err
        end
    end,
    try Steps() of
        {ok, _, _} = Ok ->
            Ok;
        Err ->
            _ = chappe_sip_media:leave(MS),
            Err
    catch
        error:{badmatch, {error, _} = Err} ->
            _ = chappe_sip_media:leave(MS),
            Err;
        exit:Why ->
            _ = chappe_sip_media:leave(MS),
            {error, Why}
    end.

%% an endpoint member: its node plays the file (a path on the node)
play_leg(#{ep := Ep, rtpe := _}, File) ->
    _ = spawn(fun() -> chappe_mrf:play(Ep, File) end),
    ok;
%% rtpengine plays the file to the caller of the member's call
play_leg(#{b2b := B2b}, File) ->
    case chappe_sip_b2b:info(B2b) of
        #{session := RS} when RS =/= undefined ->
            chappe_sip_media:play(RS, #{file => File});
        #{} ->
            {error, not_anchored};
        Err ->
            Err
    end.
