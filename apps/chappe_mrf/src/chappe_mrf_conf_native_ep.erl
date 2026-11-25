%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The media of an endpoint joining a native room
%% (chappe_mrf_conf_native): the mixer offers, rtpengine carries the
%% offer to the endpoint's node in a re-INVITE of its dialog, and the
%% node's answer comes back through rtpengine to the mixer. The endpoint
%% keeps its channel.
%%
%% The room makes both media sessions (start/3), so it owns them: they
%% end with it. Every step that waits on a peer runs in a helper the room
%% monitors: the endpoint's info, the mixer's offer, rtpengine's offer
%% and answer, the re-INVITE (up to 75 s), the mixer's answer and the
%% endpoint's watch. The room answers its other requests meanwhile. The
%% helper reports to the room as {ep_join, Id, Step}:
%%
%%   {reinvite, D}   the re-INVITE of the endpoint's dialog D goes out
%%   {moved, D}      the node took it: its channel sends to rtpengine now
%%   {done, Result}  {ok, done} once the endpoint is in, or {error, Why}
%%
%% The room applies them: a member on {ok, done}; on an error, the
%% helper's death before it reported, or the join's deadline, it gives
%% back what the join took (the mixer leg, the rtpengine session), and
%% hangs the endpoint up when its media moved, or may have (the helper
%% died with the re-INVITE out): its channel would send to a session that
%% is gone. A step that fails before the re-INVITE leaves the endpoint as
%% it was, as does a node that refuses the re-INVITE. A room that ends
%% meanwhile takes its media sessions with it; the helper's next step
%% then fails and it ends, and the endpoint keeps its channel, as a
%% member endpoint does at the room's end.
-module(chappe_mrf_conf_native_ep).

-export([start/3]).
-export_type([cfg/0]).

%% Cfg: room (the mixer room), join (the mixer join options), params
%% (the room's endpoint_params) and deaf.
-type cfg() :: #{
    room := binary(), join := map(), params := map(), deaf := boolean()
}.

%% In the room: the endpoint Ep's media sessions, owned by the room, and
%% the helper that sets them up, monitored. What the join holds: session
%% (the mixer's), rtpe (rtpengine's), helper and mon.
-spec start(pid(), {binary(), binary()}, cfg()) ->
    {ok, #{
        session := chappe_sip_media:session(),
        rtpe := chappe_sip_media:session(),
        helper := pid(),
        mon := reference()
    }}
    | {error, term()}.
start(Ep, {CallId, Id}, Cfg) ->
    maybe
        {ok, MS} ?=
            chappe_sip_media:session(#{call_id => CallId}, #{
                capability => conference
            }),
        {ok, RS} ?=
            chappe_sip_media:session(
                #{call_id => CallId, from_tag => <<"mix-", Id/binary>>},
                #{capability => anchor}
            ),
        Room = self(),
        {Pid, Mon} = spawn_monitor(fun() ->
            Room ! {ep_join, Id, {done, media(Room, Ep, Id, {MS, RS}, Cfg)}}
        end),
        {ok, #{session => MS, rtpe => RS, helper => Pid, mon => Mon}}
    end.

%% In the helper: each step runs on what the ones before made.
media(Room, Ep, Id, {MS, RS}, #{room := MixRoom, join := JoinOpts} = Cfg) ->
    Plain = #{ice => remove, transport_protocol => <<"RTP/AVP">>},
    EP = maps:get(params, Cfg),
    Params = fun(Side) -> maps:merge(Plain, maps:get(Side, EP, #{})) end,
    Report = fun(Step) -> Room ! {ep_join, Id, Step} end,
    Steps = [
        {dialog, fun(_) -> dialog(chappe_mrf:info(Ep)) end},
        {mix_offer, fun(_) ->
            chappe_sip_media:conference(MS, MixRoom, JoinOpts)
        end},
        {to_node, fun(#{mix_offer := Offer}) ->
            chappe_sip_media:offer(RS, Offer, #{params => Params(offer)})
        end},
        {node_answer, fun(#{dialog := D, to_node := Offer}) ->
            Report({reinvite, D}),
            moved(chappe_sip_dialog:modify(D, Offer), D, Report)
        end},
        {to_mix, fun(#{dialog := D, node_answer := Answer}) ->
            chappe_sip_media:answer(RS, Answer, #{
                to_tag => chappe_sip_dialog:remote_tag(D),
                params => Params(answer)
            })
        end},
        {remote, fun(#{to_mix := Answer}) ->
            done(chappe_sip_media:set_remote(MS, Answer))
        end},
        {watch, fun(_) -> done(chappe_mrf_endpoint:watch(Ep, Room)) end}
    ],
    case run(Steps, #{}) of
        {ok, _} ->
            _ = maps:get(deaf, Cfg) andalso chappe_sip_media:deaf(MS),
            {ok, done};
        {error, _} = Err ->
            Err
    end.

%% an endpoint of create_endpoint/1 not bridged has a dialog of its own
dialog(#{dialog := D, bridged := false}) when D =/= undefined -> {ok, D};
dialog(#{}) -> {error, no_dialog};
dialog(Err) -> Err.

moved({ok, _} = Answer, D, Report) ->
    Report({moved, D}),
    Answer;
moved(Refused, _D, _Report) ->
    Refused.

done(ok) -> {ok, done};
done({error, _} = Err) -> Err.

%% a step that fails or raises ends the join with an error; the room
%% gives back what the steps made
run([], Got) ->
    {ok, Got};
run([{Key, Step} | Rest], Got) ->
    try Step(Got) of
        {ok, Value} -> run(Rest, Got#{Key => Value});
        {error, _} = Err -> Err;
        Other -> {error, Other}
    catch
        _:Why -> {error, Why}
    end.
