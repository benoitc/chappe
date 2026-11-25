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
%% endpoint's watch. The room answers its other requests meanwhile.
%%
%% The re-INVITE goes out only once the room agreed: the helper asks it
%% with a call, {ep_join, Id, reinvite_now, D}, which the room answers ok
%% only while the join is under way, and from then on the join's end
%% hangs the endpoint up. A join the room ended first (its deadline, the
%% endpoint's hangup) sends no re-INVITE. The helper then reports to the
%% room as {ep_join, Id, Step}:
%%
%%   {moved, D}      the node took it: its channel sends to rtpengine now
%%   {refused, D}    the node refused it (a final non-2xx), or it never
%%                   went out: the endpoint's media stays where it was
%%   {done, Result}  {ok, done} once the endpoint is in, or {error, Why}
%%
%% The room applies them: a member on {ok, done}; on an error, the
%% helper's death before it reported, or the join's deadline, it gives
%% back what the join took (the mixer leg, the rtpengine session), and
%% hangs the endpoint up when its media moved, or may have (the re-INVITE
%% out and neither answered nor refused: the helper died, the deadline
%% came, the dialog's own timeout): its channel would send to a session
%% that is gone. A step that fails before the re-INVITE leaves the
%% endpoint as it was, as does a node that refuses the re-INVITE. A room
%% that ends meanwhile stops the helper and takes its media sessions with
%% it, and the endpoint keeps its channel, as a member endpoint does at
%% the room's end.
-module(chappe_mrf_conf_native_ep).

-include_lib("chappe_sip/include/chappe_sip.hrl").

-export([start/3, agree/3, step/2, late/2, late_leave/1, stop_helpers/1]).
-export_type([cfg/0]).

%% Cfg: the room's name, its mixer room, endpoint_params and rate.
-type cfg() :: #{
    name := binary(), room := binary(), params := map(), rate := 8000 | 16000
}.

%% In the room: the endpoint Ep joins with the join's Opts (name, mute,
%% deaf). Its member id, its media sessions, owned by the room, and the
%% helper that sets them up, monitored. What the join holds: session (the
%% mixer's), rtpe (rtpengine's), helper and mon.
-spec start(pid(), map(), cfg()) ->
    {ok, binary(), #{
        session := chappe_sip_media:session(),
        rtpe := chappe_sip_media:session(),
        helper := pid(),
        mon := reference()
    }}
    | {error, term()}.
start(Ep, Opts, #{name := Name, room := MixRoom, rate := Rate} = Cfg) ->
    Id = chappe_mrf_lib:new_id(),
    CallId = <<"mrf-", Name/binary, "-", Id/binary>>,
    Room = self(),
    Steps = #{
        room => MixRoom,
        params => maps:get(params, Cfg),
        deaf => maps:get(deaf, Opts, false),
        join => chappe_mrf_lib:with_name(Opts, #{
            rate => Rate,
            owner => Room,
            persist => true,
            talk_events => true,
            talk_tag => Id,
            mute => maps:get(mute, Opts, false)
        })
    },
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
        {Pid, Mon} = spawn_monitor(fun() ->
            Room ! {ep_join, Id, {done, media(Room, Ep, Id, {MS, RS}, Steps)}}
        end),
        {ok, Id, #{session => MS, rtpe => RS, helper => Pid, mon => Mon}}
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
            maybe
                ok ?= ask_reinvite(Room, Id, D),
                moved(chappe_sip_dialog:modify(D, Offer), D, Report)
            end
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

%% The room agrees to the re-INVITE while the join is under way (agree/3).
%% The room kills the helper at the join's end, so the call waits as long
%% as the room takes; a room gone fails it.
ask_reinvite(Room, Id, D) ->
    chappe_mrf_conf:call(
        Room, {backend, {ep_join, Id, reinvite_now, D}}, infinity
    ).

%% The node's answer: it took the room's media, or refused it for sure
%% (refused/1). Any other end (the dialog's own timeout, a transaction
%% that failed, the dialog gone) may leave the re-INVITE at the node.
moved({ok, _} = Answer, D, Report) ->
    Report({moved, D}),
    Answer;
moved({error, Why} = Error, D, Report) ->
    _ = refused(Why) andalso Report({refused, D}),
    Error.

%% a final non-2xx, or a re-INVITE that never went out
refused(#chappe_sip_error{}) -> true;
refused(early) -> true;
refused(request_pending) -> true;
refused(_Why) -> false.

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

%% ---- in the room: what the native backend applies to its joins ----

%% The helper of join Id asks to send its re-INVITE of the endpoint's
%% dialog D: yes while the join is under way (in Pending, the room's
%% joins), and the join then notes it (reinvite); its end from then on
%% hangs the endpoint up.
-spec agree(binary(), chappe_sip_dialog:dialog(), #{term() => map()}) ->
    {ok, #{term() => map()}} | {error, join_ended}.
agree(Id, D, Pending) ->
    case Pending of
        #{Id := #{rtpe := _} = J} -> {ok, Pending#{Id := J#{reinvite => D}}};
        #{} -> {error, join_ended}
    end.

%% A report of the helper for its join J: the join goes on (the node took
%% the room's media: a failure hangs the endpoint up; the node refused
%% it: the endpoint's media stays where it was), the endpoint is in, or
%% the join failed. A re-INVITE neither answered nor refused (the
%% dialog's own timeout) stays noted: it may still move the media, and
%% the endpoint is hung up as for one the node took.
-spec step(term(), map()) ->
    {pending, map()} | {joined, map()} | {failed, map(), {error, term()}}.
step({moved, D}, J) -> {pending, (maps:remove(reinvite, J))#{moved => D}};
step({refused, _D}, J) -> {pending, maps:remove(reinvite, J)};
step({done, {ok, _}}, J) -> {joined, J};
step({done, {error, _} = Error}, J) -> {failed, J, Error}.

%% A report of a join that ended meanwhile: the room had let its
%% re-INVITE out, so the endpoint's dialog goes (the join's end sent its
%% BYE already; one more is nothing). Room is the room's state, as is.
-spec late(term(), Room) -> Room.
late({moved, D}, Room) ->
    ok = chappe_mrf_lib:destroy_later(D),
    Room;
late({refused, D}, Room) ->
    ok = chappe_mrf_lib:destroy_later(D),
    Room;
late({done, _Result}, Room) ->
    Room.

%% In the job that gives a failed join back: the join's helper is gone
%% (the room killed it, so this is soon), then its mixer session leaves
%% the mixer once more, as a mixer join it sent just before may have
%% reached the mixer after the room's leave.
-spec late_leave({pid(), chappe_sip_media:session()}) -> ok.
late_leave({Helper, MS}) ->
    Mon = monitor(process, Helper),
    receive
        {'DOWN', Mon, process, Helper, _} -> ok
    after 5000 ->
        demonitor(Mon, [flush])
    end,
    _ = chappe_sip_media:leave(MS),
    ok.

%% At the room's end: the helpers of its joins under way (Pending) stop.
-spec stop_helpers(#{term() => map()}) -> ok.
stop_helpers(Pending) ->
    _ = [exit(H, kill) || _ := #{helper := H} <- Pending],
    ok.
