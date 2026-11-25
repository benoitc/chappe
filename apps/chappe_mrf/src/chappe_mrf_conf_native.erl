%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The native backend of chappe_mrf_conf (chappe_mrf_conf_backend): a
%% chappe_mix room behind rtpengine, reached by a loopback INVITE (see
%% chappe_mrf_conf). The room's rate (8000 or 16000, fixed) goes with every
%% join of the mixer, and rtpengine's flags for it
%% (chappe_sip_media:mixer_params/2) lie under the app's anchor and
%% endpoint params, so a caller on any codec is transcoded to the room's.
-module(chappe_mrf_conf_native).
-behaviour(chappe_mrf_conf_backend).

-include("chappe_mrf_conf.hrl").

-export([init/2, info/1, join/4, admit/3, handle_call/3, handle_cast/2]).
-export([handle_info/2]).
-export([set_flag/5, hangup/3, left/2, play/3, portable/0]).
-export([relate/4, record/3, stop_record/1, handover/1, dial/4, dial_out/4]).
-export([loop_invite/4, check_rate/1, same_rate/2]).

-record(native, {
    %% the mixer room's sample rate
    rate = 8000 :: 8000 | 16000,
    anchor_params = #{} :: map(),
    %% rtpengine flags between the mixer and an endpoint's node:
    %% #{offer => map(), answer => map()}
    endpoint_params = #{} :: map(),
    bridge = #{} :: map(),
    %% the room's SIPREC sessions (chappe_sip_siprec), owned by the room
    siprec = [] :: [pid()]
}).

%% ---- the backend ----

init(_Name, Opts) ->
    Rate = maps:get(rate, Opts, 8000),
    AP = maps:get(anchor_params, Opts, #{}),
    EP = maps:get(endpoint_params, Opts, #{}),
    {ok, #native{
        rate = Rate,
        %% toward the mixer (leg b of a member's call) and toward an
        %% endpoint's node (the offer): the room's format, the app's keys
        %% on top
        anchor_params = under(
            b, chappe_sip_media:mixer_params(Rate, mixer), AP
        ),
        endpoint_params = under(
            offer, chappe_sip_media:mixer_params(Rate, endpoint), EP
        ),
        bridge = maps:get(bridge, Opts, #{})
    }}.

%% A room's rate, checked in the caller of chappe_mrf_conf:start/2: 8000 or
%% 16000 on native (the default backend); any other backend refuses one,
%% its rate being its own (an fs room's is its profile's).
-spec check_rate(map()) -> ok | {error, term()}.
check_rate(#{rate := R}) when R =/= 8000, R =/= 16000 ->
    {error, {bad_option, rate}};
check_rate(#{rate := _, backend := B}) when B =/= native ->
    {error, {unsupported, rate}};
check_rate(_Opts) ->
    ok.

%% The room that start/2 found or started, for Opts: asked a rate, it
%% must run at that rate, as a chappe_sip_media join asking another rate
%% than its room's is refused. A room of a backend with no rate (fs)
%% takes none. A start that failed is returned as it is.
-spec same_rate({ok, pid()} | {error, term()}, map()) ->
    {ok, pid()} | {error, term()}.
same_rate({ok, Conf}, #{rate := Want}) ->
    case chappe_mrf_conf:info(Conf) of
        #{rate := Want} -> {ok, Conf};
        #{rate := Rate} -> {error, {rate_mismatch, Rate}};
        #{} -> {error, {unsupported, rate}};
        {error, _} = Err -> Err
    end;
same_rate(Found, _Opts) ->
    Found.

%% Params under the app's map at Key, the app's keys winning; inside
%% codec too, key by key, so an app's codec flags (strip, offer, a
%% transcode of its own) do not drop the room's mask and transcode.
under(_Key, Params, App) when map_size(Params) =:= 0 ->
    App;
under(Key, Params, App) ->
    App#{Key => merge_params(Params, maps:get(Key, App, #{}))}.

merge_params(#{codec := Room} = Params, #{codec := Codec} = App) ->
    maps:merge(Params, App#{codec := maps:merge(Room, Codec)});
merge_params(Params, App) ->
    maps:merge(Params, App).

info(#native{bridge = Bridge, rate = Rate}) ->
    #{node => undefined, bridge => Bridge, rate => Rate}.

%% in the caller
join(Conf, _Info, {call, Req, Res}, Opts) ->
    join_call(Conf, Req, Res, Opts);
join(Conf, _Info, B2b, Opts) when is_tuple(B2b) ->
    chappe_mrf_conf:call(
        Conf, {join, {b2b, B2b, Opts}}, ?MRF_JOIN_TIMEOUT + 80000
    );
join(Conf, _Info, Ep, Opts) ->
    chappe_mrf_conf:call(
        Conf, {join, {ep, Ep, Opts}}, ?MRF_JOIN_TIMEOUT + 80000
    ).

admit({ep, Ep, Opts}, _From, S) ->
    join_endpoint(Ep, Opts, S);
admit({b2b, B2b, Opts}, From, S) ->
    join_b2b(B2b, Opts, From, S);
admit({call, Opts}, _From, S) ->
    prepare_call(Opts, S);
admit(_Req, _From, S) ->
    {reply, {error, unknown_join}, S}.

handle_call({loop_offer, Token, Offer}, _From, S) ->
    offer(Token, Offer, S);
handle_call({call_done, Token, Result}, From, #state{pending = P} = S) ->
    case P of
        #{Token := J} -> {noreply, call_done(Token, J, Result, From, S)};
        _ -> {reply, {error, join_failed}, S}
    end;
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

%% the loopback dialog of loop_invite/4, or its failure
handle_cast({loop_dialog, Token, D}, #state{pending = P} = S) ->
    case P of
        #{Token := J} -> {noreply, complete(Token, J#{dialog => D}, S)};
        _ -> {noreply, S}
    end;
handle_cast({loop_failed, Token}, S) ->
    {noreply, S#state{pending = maps:remove(Token, S#state.pending)}};
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({join_result, Token, Result}, #state{pending = P} = S) ->
    case P of
        #{Token := J} -> {noreply, result(Token, J, Result, S)};
        _ -> {noreply, S}
    end;
handle_info({chappe_sip_siprec, Rec, {stopped, _}}, S) ->
    %% a stopped recording is forgotten
    #native{siprec = R} = B = chappe_mrf_conf_backend:bstate(S),
    {noreply,
        chappe_mrf_conf_backend:bstate(
            B#native{siprec = lists:delete(Rec, R)}, S
        )};
handle_info({chappe_mrf_endpoint, Ep, hangup}, S) ->
    {noreply, gone_ep(Ep, S)};
handle_info({chappe_mrf_endpoint, Ep, {dtmf, Digit}}, S) ->
    case chappe_mrf_conf_backend:member_by(ep, Ep, S) of
        {ok, Id} ->
            {noreply, chappe_mrf_conf_backend:emit({dtmf, Id, Digit}, S)};
        error ->
            {noreply, S}
    end;
handle_info({chappe_mrf, Ep, {hangup, _} = E}, S) when is_pid(Ep) ->
    %% a dialed endpoint's (chappe_mrf_conf_refer), or a member's
    {noreply, gone_ep(Ep, chappe_mrf_conf_refer:native_event(Ep, E, S))};
handle_info({chappe_mrf, Ep, Event}, S) when is_pid(Ep) ->
    %% a dialed endpoint's channel and completion events
    {noreply, chappe_mrf_conf_refer:native_event(Ep, Event, S)};
handle_info(_Msg, _S) ->
    ignore.

gone_ep(Ep, S) ->
    case chappe_mrf_conf_backend:member_by(ep, Ep, S) of
        {ok, Id} -> chappe_mrf_conf_backend:gone(Id, hangup, S);
        error -> S
    end.

set_flag(_Id, #{session := MS}, deaf, true, S) ->
    flag_ok(chappe_sip_media:deaf(MS), S);
set_flag(_Id, #{session := MS}, deaf, false, S) ->
    flag_ok(chappe_sip_media:undeaf(MS), S);
set_flag(Id, #{session := MS}, mute, true, S) ->
    muted(Id, true, chappe_sip_media:mute(MS), S);
set_flag(Id, #{session := MS}, mute, false, S) ->
    muted(Id, false, chappe_sip_media:unmute(MS), S);
set_flag(_Id, _Mb, _Flag, _Value, _S) ->
    %% a member without a mixer session
    {error, unsupported}.

flag_ok(ok, S) -> {ok, S};
flag_ok({error, _} = Err, _S) -> Err.

%% the mixer does not say it: the room does
muted(Id, Mute, ok, S) ->
    {ok, chappe_mrf_conf_backend:emit({muted, Id, Mute}, S)};
muted(_Id, _Mute, {error, _} = Err, _S) ->
    Err.

hangup(_Id, #{rtpe := _}, _S) ->
    %% an endpoint of the app: out of the room, its channel stays
    ok;
hangup(_Id, #{dialog := D}, _S) ->
    _ = spawn(fun() -> chappe_mrf_lib:destroy_dialog(D) end),
    ok;
hangup(_Id, _Mb, _S) ->
    ok.

%% a member gone to another room keeps its call: only its mixer session
%% goes
left(#{session := MS}, transferred) ->
    _ = chappe_sip_media:leave(MS),
    ok;
left(#{session := MS, rtpe := RS}, _Why) ->
    _ = chappe_sip_media:leave(MS),
    _ = chappe_sip_media:stop(RS),
    ok;
left(#{session := MS}, _Why) ->
    _ = chappe_sip_media:leave(MS),
    ok;
left(_Mb, _Why) ->
    ok.

play(all, File, #state{members = M}) ->
    lists:foldl(
        fun(Mb, Acc) ->
            case play_leg(Mb, File) of
                ok -> Acc;
                Err -> Err
            end
        end,
        ok,
        maps:values(M)
    );
play({_Id, Mb}, File, _S) ->
    play_leg(Mb, File).

%% rehome: a member's call is re-anchored to the room on another node
portable() ->
    true.

relate(#{session := SL}, #{session := SS}, Rel, _S) ->
    chappe_sip_media:relate(SL, SS, Rel);
relate(_Listener, _Speaker, _Rel, _S) ->
    {error, not_member}.

%% The room's mix to a recording server through SIPREC.
record(Srs, Opts, #state{name = Name, room = Room} = S) ->
    #native{siprec = Recs} = B = chappe_mrf_conf_backend:bstate(S),
    Ref = maps:get(ref, Opts, Name),
    case
        chappe_sip_siprec:start({room, Room}, Srs, #{
            call_ref => Ref, owner => self()
        })
    of
        {ok, Rec} ->
            B1 = B#native{siprec = [Rec | Recs]},
            {ok, chappe_mrf_conf_backend:bstate(B1, S)};
        {error, _} = Err ->
            {Err, S}
    end.

stop_record(S) ->
    #native{siprec = Recs} = B = chappe_mrf_conf_backend:bstate(S),
    lists:foreach(fun chappe_sip_siprec:stop/1, Recs),
    {ok, chappe_mrf_conf_backend:bstate(B#native{siprec = []}, S)}.

%% A member's call moves to the other room's mixer (the caller sees no
%% re-INVITE); an endpoint of the app is its own dialog, not a call this
%% room can re-anchor.
handover(#{b2b := B2b}) ->
    {ok, {native, B2b}, false};
handover(#{rtpe := _}) ->
    {error, {unsupported, endpoint_member}};
handover(_Mb) ->
    {error, not_member}.

%% An endpoint joins the mixer, then bridges to the target. A REFER to
%% the room: in its request worker, which hears the outcome.
dial_out(Conf, Target, Refer, Cfg) ->
    chappe_mrf_conf_refer:dial_native(Conf, Target, Refer, Cfg).

%% A member's REFER: in a helper, since it waits for the endpoint.
dial(Target, Refer, Cfg, S) ->
    Conf = self(),
    _ = spawn(fun() ->
        chappe_mrf_conf_refer:dial_native(Conf, Target, Refer, Cfg)
    end),
    {ok, S}.

%% The loopback INVITE of a native join reached this node: the mixer
%% answers its offer, and the dialog is the conference's. Runs in the
%% INVITE's request worker (chappe_mrf's middleware).
-spec loop_invite(pid(), binary(), chappe_sip_req:req(), chappe_sip_res:res()) ->
    ok.
loop_invite(Conf, Token, Req, Res) ->
    Offer = chappe_sip_req:body(Req),
    case
        chappe_mrf_conf:call(Conf, {backend, {loop_offer, Token, Offer}}, 30000)
    of
        {ok, Answer} ->
            Msg =
                case
                    chappe_sip:create_uas(Req, Res, #{
                        local_sdp => Answer, owner => Conf
                    })
                of
                    {ok, D} -> {loop_dialog, Token, D};
                    {error, _} -> {loop_failed, Token}
                end,
            gen_server:cast(Conf, {backend, Msg});
        {error, _} ->
            _ = chappe_sip_res:send(Res, 488),
            ok
    end.

%% ---- joins ----

join_b2b(B2b, Opts, From, S) ->
    #native{anchor_params = AP} = chappe_mrf_conf_backend:bstate(S),
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
    Opts = maps:merge(#{uri => chappe_mrf_conf_refer:from_uri(Req)}, Opts0),
    case chappe_mrf_conf:call(Conf, {join, {call, Opts}}, 5000) of
        {ok, Token, Uri, AP, Entity} ->
            %% the room's REFERs come to the room (chappe_mrf_conf_refer);
            %% a focus room answers with the conference URI and isfocus
            %% as the member's Contact (RFC 4579 4.2)
            B2bOpts = (chappe_mrf_conf_refer:member_opts(Conf, Entity))#{
                media => anchor,
                anchor_params => AP
            },
            Result =
                case chappe_sip:create_b2bua(Req, Res, Uri, B2bOpts) of
                    {ok, Legs} -> relay(Legs, Conf);
                    {error, _} = Err -> Err
                end,
            chappe_mrf_conf:call(
                Conf,
                {backend, {call_done, Token, Result}},
                ?MRF_JOIN_TIMEOUT + 5000
            );
        Err ->
            Err
    end.

%% The call runs on its own; its member dialog (leg A) is kept with it so
%% a REFER the call hands the room can be answered in that dialog.
relay(Legs, Conf) ->
    case chappe_sip_b2b:relay_async(Legs, #{notify => Conf}) of
        {ok, B2b} = Ok ->
            ok = chappe_mrf_conf_refer:keep_dialog(B2b, Legs),
            Ok;
        Err ->
            Err
    end.

%% the loopback a joining call is sent to, and the flags toward the mixer
prepare_call(Opts, S) ->
    #native{anchor_params = AP} = chappe_mrf_conf_backend:bstate(S),
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
offer(Token, Offer, #state{pending = P} = S) ->
    case P of
        #{Token := #{opts := Opts} = J} when not is_map_key(session, J) ->
            case mixer_answer(Token, Offer, Opts, S) of
                {ok, MS, Answer} ->
                    {reply, {ok, Answer}, S#state{
                        pending = P#{Token := J#{session => MS}}
                    }};
                {error, _} = Err ->
                    {reply, Err, S}
            end;
        _ ->
            {reply, {error, unknown_join}, S}
    end.

mixer_answer(Token, Offer, Opts, #state{room = Room, name = Name} = S) ->
    CallId = <<"mrf-", Name/binary, "-", Token/binary>>,
    #native{rate = Rate} = chappe_mrf_conf_backend:bstate(S),
    maybe
        {ok, MS} ?=
            chappe_sip_media:session(#{call_id => CallId}, #{
                capability => conference
            }),
        JoinOpts = #{
            sdp => Offer,
            rate => Rate,
            owner => self(),
            persist => true,
            talk_events => true,
            talk_tag => Token,
            mute => maps:get(mute, Opts, false)
        },
        {ok, Answer} ?=
            chappe_sip_media:conference(MS, Room, with_name(Opts, JoinOpts)),
        _ = maps:get(deaf, Opts, false) andalso chappe_sip_media:deaf(MS),
        {ok, MS, Answer}
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
    Base = #{b2b => B2b, dialog => D, session => MS},
    Mb = chappe_mrf_conf_backend:member(Opts, Token, Base),
    gen_server:reply(From, {ok, Token}),
    S1 = S#state{pending = maps:remove(Token, S#state.pending)},
    chappe_mrf_conf_backend:joined(Token, Mb, S1);
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
                    Mb = chappe_mrf_conf_backend:member(Opts, Id, #{
                        ep => Ep, session => MS, rtpe => RS
                    }),
                    {reply, {ok, Id},
                        chappe_mrf_conf_backend:joined(Id, Mb, S)};
                {error, _} = Err ->
                    {reply, Err, S}
            end;
        #{} ->
            {reply, {error, no_dialog}, S};
        Err ->
            {reply, Err, S}
    end.

endpoint_media(CallId, Id, D, Room, Opts, S) ->
    #native{endpoint_params = EP, rate = Rate} =
        chappe_mrf_conf_backend:bstate(S),
    {ok, MS} = chappe_sip_media:session(#{call_id => CallId}, #{
        capability => conference
    }),
    JoinOpts = with_name(Opts, #{
        rate => Rate,
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
