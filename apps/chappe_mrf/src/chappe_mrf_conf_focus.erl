%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc A room as an RFC 4575 conference focus (start/2's focus => true): its
%% entity (the conference URI), the SUBSCRIBEs to its conference package
%% and the conference-info they get, one user per member, through
%% chappe_sip_focus.
-module(chappe_mrf_conf_focus).

-include("chappe_mrf_conf.hrl").

-export([setup/2, subscribe/3, publish/1, handle_info/2]).

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

%% the conference-info of a focus: one user per member
-spec publish(#state{}) -> #state{}.
publish(#state{focus = undefined} = S) ->
    S;
publish(#state{focus = F, entity = E, members = M} = S) ->
    Users = [user(E, Id, Mb) || {Id, Mb} <- lists:sort(maps:to_list(M))],
    Conf = #{
        entity => E,
        version => 0,
        user_count => length(Users),
        users => Users
    },
    S#state{focus = chappe_sip_focus:update(Conf, F)}.

user(E, Id, Mb) ->
    Entity = <<E/binary, ";member=", Id/binary>>,
    #{
        entity => Entity,
        display_text => maps:get(name, Mb),
        roles => [<<"moderator">> || maps:get(moderator, Mb)],
        endpoints => [
            #{
                entity => Entity,
                status =>
                    case maps:get(mute, Mb) of
                        true -> muted_via_focus;
                        false -> connected
                    end,
                joining_method => dialed_in
            }
        ]
    }.

%% The focus's own messages (its subscribers' dialogs, its flushes).
-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(_Info, #state{focus = undefined} = S) ->
    {noreply, S};
handle_info(Info, #state{focus = F} = S) ->
    case chappe_sip_focus:handle_info(Info, F) of
        {ok, F1} -> {noreply, S#state{focus = F1}};
        ignore -> {noreply, S}
    end.
