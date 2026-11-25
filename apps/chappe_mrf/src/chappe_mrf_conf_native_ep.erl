%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The media of an endpoint joining a native room
%% (chappe_mrf_conf_native), in the room process: the mixer offers,
%% rtpengine carries the offer to the endpoint's node in a re-INVITE of
%% its dialog, and the node's answer comes back through rtpengine to the
%% mixer. The room owns both media sessions; the endpoint keeps its
%% channel.
%%
%% Each step runs on what the ones before made (ms, the mixer session;
%% rs, the rtpengine one). A step that fails or raises ends the join with
%% an error, and what exists so far goes: the rtpengine session is
%% stopped and the mixer leg left. The room goes on.
-module(chappe_mrf_conf_native_ep).

-export([media/3]).

%% Cfg: room (the mixer room), join (the mixer join options), params
%% (the room's endpoint_params) and deaf.
-spec media(
    pid(),
    {binary(), binary(), chappe_sip_dialog:dialog()},
    #{room := binary(), join := map(), params := map(), deaf := boolean()}
) ->
    {ok, #{ms := chappe_sip_media:session(), rs := chappe_sip_media:session()}}
    | {error, term()}.
media(Ep, {CallId, Id, D}, #{room := Room, join := JoinOpts} = Cfg) ->
    Plain = #{ice => remove, transport_protocol => <<"RTP/AVP">>},
    EP = maps:get(params, Cfg),
    Params = fun(Side) -> maps:merge(Plain, maps:get(Side, EP, #{})) end,
    Steps = [
        {ms, fun(_) ->
            chappe_sip_media:session(#{call_id => CallId}, #{
                capability => conference
            })
        end},
        {mix_offer, fun(#{ms := MS}) ->
            chappe_sip_media:conference(MS, Room, JoinOpts)
        end},
        {rs, fun(_) ->
            chappe_sip_media:session(
                #{call_id => CallId, from_tag => <<"mix-", Id/binary>>},
                #{capability => anchor}
            )
        end},
        {to_node, fun(#{rs := RS, mix_offer := Offer}) ->
            chappe_sip_media:offer(RS, Offer, #{params => Params(offer)})
        end},
        {node_answer, fun(#{to_node := Offer}) ->
            chappe_sip_dialog:modify(D, Offer)
        end},
        {to_mix, fun(#{rs := RS, node_answer := Answer}) ->
            chappe_sip_media:answer(RS, Answer, #{
                to_tag => chappe_sip_dialog:remote_tag(D),
                params => Params(answer)
            })
        end},
        {remote, fun(#{ms := MS, to_mix := Answer}) ->
            done(chappe_sip_media:set_remote(MS, Answer))
        end},
        {watch, fun(_) -> done(chappe_mrf_endpoint:watch(Ep, self())) end}
    ],
    case run(Steps, #{}) of
        {ok, #{ms := MS}} = Ok ->
            _ = maps:get(deaf, Cfg) andalso chappe_sip_media:deaf(MS),
            Ok;
        {error, _} = Err ->
            Err
    end.

done(ok) -> {ok, done};
done({error, _} = Err) -> Err.

run([], Got) ->
    {ok, Got};
run([{Key, Step} | Rest], Got) ->
    try Step(Got) of
        {ok, Value} ->
            run(Rest, Got#{Key => Value});
        {error, _} = Err ->
            give_back(Got, Err);
        Other ->
            give_back(Got, {error, Other})
    catch
        _:Why ->
            give_back(Got, {error, Why})
    end.

give_back(Got, Err) ->
    _ = [chappe_sip_media:stop(RS) || #{rs := RS} <- [Got]],
    _ = [chappe_sip_media:leave(MS) || #{ms := MS} <- [Got]],
    Err.
