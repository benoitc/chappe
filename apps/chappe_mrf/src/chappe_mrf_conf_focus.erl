%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc A room as an RFC 4575 conference focus (start/2's focus => true): its
%% entity (the conference URI), the SUBSCRIBEs to its conference package
%% and the conference-info they get, one user per participant, through
%% chappe_sip_focus.
-module(chappe_mrf_conf_focus).

-include("chappe_mrf_conf.hrl").

-export([setup/2, subscribe/3, publish/1, departed/4, handle_info/2]).

%% The room's focus, when its options ask for one: entity defaults to
%% sip:Name@<this node>.
-spec setup(map(), #state{}) -> #state{}.
setup(#{focus := true} = Opts, #state{name = Name} = S) ->
    Entity =
        case maps:find(entity, Opts) of
            {ok, E} -> E;
            error -> conf_uri(Name)
        end,
    F = chappe_sip_focus:new(#{entity => Entity, min_interval => 0}),
    S#state{entity = Entity, focus = F};
setup(_Opts, S) ->
    S.

conf_uri(Name) ->
    case chappe_sip_hdr:name_addr(chappe_sip_b2b:contact()) of
        {ok, #{uri := Uri}} ->
            {ok, U} = chappe_sip_uri:parse(Uri),
            chappe_sip_uri:format(U#{user => Name});
        _ ->
            <<"sip:", Name/binary, "@invalid">>
    end.

%% A SUBSCRIBE to the room's state, in the caller; 489 for a room that is
%% no focus.
-spec subscribe(pid(), chappe_sip_req:req(), chappe_sip_res:res()) ->
    {ok, chappe_sip_dialog:dialog()} | {error, term()}.
subscribe(Conf, Req, Res) ->
    case chappe_mrf_conf:info(Conf) of
        #{entity := Entity} when is_binary(Entity) ->
            chappe_sip_focus:subscribe(Req, Res, Conf, #{
                contact => chappe_sip_focus:contact(Entity)
            });
        _ ->
            _ = chappe_sip_res:send(Res, 489),
            {error, no_focus}
    end.

%% The conference-info of a focus (RFC 4575): one user per participant,
%% by the address-of-record it came from (its endpoints grouped under
%% it), each member an endpoint <conference URI>;member=Id. A member the
%% room knows no URI of is a user of its own, under that endpoint entity.
-spec publish(#state{}) -> #state{}.
publish(S) ->
    publish(#{}, S).

%% Member Id is leaving for Why: the roster shows its endpoint
%% disconnected, with how it left (RFC 4575 5.7.6: departed, or booted
%% when the room removed it), before the next publish/1 deletes it. A
%% member moving to another room just goes.
-spec departed(binary(), map(), atom(), #state{}) -> #state{}.
departed(_Id, _Mb, transferred, S) ->
    S;
departed(Id, _Mb, Why, S) ->
    publish(#{Id => disconnection(Why)}, S).

disconnection(kicked) -> booted;
disconnection(_Why) -> departed.

publish(_Gone, #state{focus = undefined} = S) ->
    S;
publish(Gone, #state{focus = F, entity = E, members = M} = S) ->
    Users = users(E, lists:sort(maps:to_list(M)), Gone),
    In = [U || #{endpoints := Eps} = U <- Users, lists:any(fun in/1, Eps)],
    Conf = #{
        entity => E,
        version => 0,
        user_count => length(In),
        users => Users
    },
    S#state{focus = chappe_sip_focus:update(Conf, F)}.

in(#{status := disconnected}) -> false;
in(_Ep) -> true.

%% users by member id, endpoints grouped
users(E, Members, Gone) ->
    {Order, ByUser} = lists:foldl(
        fun({Id, Mb}, Acc) -> add_endpoint(E, Id, Mb, Gone, Acc) end,
        {[], #{}},
        Members
    ),
    [finish(maps:get(Entity, ByUser)) || Entity <- lists:reverse(Order)].

add_endpoint(E, Id, Mb, Gone, {Order, ByUser}) ->
    Entity = user_entity(E, Id, Mb),
    Ep = endpoint(E, Id, Mb, Gone),
    case ByUser of
        #{Entity := #{endpoints := Eps} = U} ->
            {Order, ByUser#{Entity := U#{endpoints := [Ep | Eps]}}};
        #{} ->
            {[Entity | Order], ByUser#{Entity => user(Entity, Mb, Ep)}}
    end.

finish(#{endpoints := Eps} = U) ->
    U#{endpoints := lists:reverse(Eps)}.

user(Entity, Mb, Ep) ->
    U = #{
        entity => Entity,
        display_text => maps:get(name, Mb),
        roles => [<<"moderator">> || maps:get(moderator, Mb)],
        endpoints => [Ep]
    },
    case Mb of
        %% asked for privacy (RFC 4579 6): AnonymousN, N fixed per member
        #{private := true} -> chappe_sip_confinfo:anonymize(U, anon(Entity));
        #{} -> U
    end.

anon(Entity) -> erlang:phash2(Entity, 1000000) + 1.

%% the participant's address-of-record, else (no URI known, or one it
%% asked to keep private) the member's own entity
user_entity(E, Id, Mb) ->
    case Mb of
        #{private := true} -> member_entity(E, Id);
        #{uri := U} when is_binary(U) -> chappe_mrf_conf_refer_op:aor(U);
        #{} -> member_entity(E, Id)
    end.

member_entity(E, Id) ->
    <<E/binary, ";member=", Id/binary>>.

endpoint(E, Id, Mb, Gone) ->
    Ep0 = #{
        entity => member_entity(E, Id),
        status =>
            case maps:get(mute, Mb) of
                true -> muted_via_focus;
                false -> connected
            end,
        joining_method => maps:get(joining, Mb, dialed_in)
    },
    Ep =
        case Mb of
            #{referred := #{by := _} = R} -> Ep0#{referred => R};
            #{} -> Ep0
        end,
    case Gone of
        #{Id := How} ->
            Ep#{status => disconnected, disconnection_method => How};
        #{} ->
            Ep
    end.

%% The focus's own messages (its subscribers' dialogs, its flushes).
-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(_Info, #state{focus = undefined} = S) ->
    {noreply, S};
handle_info(Info, #state{focus = F} = S) ->
    case chappe_sip_focus:handle_info(Info, F) of
        {ok, F1} -> {noreply, S#state{focus = F1}};
        ignore -> {noreply, S}
    end.
