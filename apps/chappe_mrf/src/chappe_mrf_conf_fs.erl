%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The fs backend of chappe_mrf_conf: a mod_conference room on one
%% FreeSWITCH node. join/5 runs in the caller (an endpoint on the node,
%% made and bridged for a call, and the PIN); the rest runs in the
%% conference process.
-module(chappe_mrf_conf_fs).

-include("chappe_mrf_conf.hrl").

-export([join/5, start_join/5, event/3, gone_ep/2, api/3, lock_cmd/1]).
-export([adopt/6, record/2, stop_record/1, dtmf/3, room_event/2]).

%% ---- fs join, in the caller ----

join(Conf, Node, Bridge, Target, Opts) ->
    case endpoint(Conf, Node, Bridge, Target) of
        {ok, Ep, Owned} ->
            case check_pin(Ep, Opts) of
                ok ->
                    case
                        chappe_mrf_conf:call(
                            Conf,
                            {join, {fs, Ep, Owned, Opts}},
                            ?MRF_JOIN_TIMEOUT + 5000
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
            end;
        {error, _} = Err ->
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

%% ---- fs ----

start_join(
    Ep, Owned, Opts, From, #state{name = Name, profile = Profile} = S
) ->
    case watch(Ep) of
        {ok, Call} ->
            Flags =
                [mute || maps:get(mute, Opts, false)] ++
                    [deaf || maps:get(deaf, Opts, false)] ++
                    [moderator || maps:get(moderator, Opts, false)] ++
                    maps:get(flags, Opts, []),
            case
                room_flags(Call, S) =:= ok andalso
                    chappe_esl_call:conference(Call, Name, #{
                        profile => Profile, flags => Flags
                    })
            of
                {ok, _AppUuid} ->
                    {noreply,
                        pending(Ep, #{owned => Owned, opts => Opts}, From, S)};
                false ->
                    {reply, {error, room_flags}, S};
                {error, _} = Err ->
                    {reply, Err, S}
            end;
        {error, _} = Err ->
            {reply, Err, S}
    end.

%% A member of the conference FromName on this node comes over (transfer/3):
%% mod_conference moves its channel, and its add-member here completes the
%% join. Ownership of an endpoint the other conference made follows then.
adopt(Ep, Owned, Opts, {FromName, FromId}, From, #state{name = Name} = S) ->
    case watch(Ep) of
        {ok, _Call} ->
            Cmd = [
                <<"conference ">>,
                FromName,
                <<" transfer ">>,
                Name,
                <<" ">>,
                FromId
            ],
            case chappe_mrf_lib:api_ok(chappe_mrf:api(Ep, Cmd)) of
                ok ->
                    J = #{owned => Owned, opts => Opts, adopt => true},
                    {noreply, pending(Ep, J, From, S)};
                {error, _} = Err ->
                    {reply, Err, S}
            end;
        {error, _} = Err ->
            {reply, Err, S}
    end.

%% The member's channel events reach this conference: its own CUSTOM
%% conference::maintenance, dtmf and hangup (as a watcher).
watch(Ep) ->
    case chappe_mrf:info(Ep) of
        #{conn := Conn} when is_pid(Conn) ->
            ok = chappe_mrf_endpoint:watch(Ep, self()),
            _ = chappe_esl:subscribe(Conn, [
                <<"CUSTOM">>, <<"conference::maintenance">>
            ]),
            chappe_mrf_endpoint:call(Ep);
        #{} ->
            {error, not_connected};
        Err ->
            Err
    end.

room_flags(_Call, #state{room_flags = []}) ->
    ok;
room_flags(Call, #state{room_flags = Flags}) ->
    chappe_esl_call:set(Call, <<"conference_flags">>, lists:join($|, Flags)).

pending(Ep, J, From, S) ->
    TRef = erlang:send_after(
        S#state.join_timeout, self(), {fs_join_timeout, Ep}
    ),
    S#state{
        pending = (S#state.pending)#{
            {ep, Ep} => J#{from => From, timer => TRef}
        }
    }.

%% Record the room: a file on the node.
record(Path, S) ->
    chappe_mrf_lib:api_ok(
        api(any, [<<"recording start">>, chappe_esl_exec:arg(Path)], S)
    ).

stop_record(S) ->
    chappe_mrf_lib:api_ok(api(any, [<<"recording stop all">>], S)).

%% A digit from a member's channel.
dtmf(Ep, Digit, #state{members = M} = S) ->
    case [Id || {Id, #{ep := E}} <- maps:to_list(M), E =:= Ep] of
        [Id | _] -> chappe_mrf_conf:emit({dtmf, Id, Digit}, S);
        [] -> S
    end.

%% A node event (chappe_esl:node_events/1): only what carries no member,
%% the members' own come over their channels.
room_event(Ev, #state{name = Name} = S) ->
    H = fun(K) -> chappe_esl_event:header(K, Ev) end,
    case {H(<<"Event-Subclass">>), H(<<"Conference-Name">>), H(<<"Action">>)} of
        {<<"conference::maintenance">>, Name, <<"play-file-done">>} ->
            chappe_mrf_conf:emit(
                {play_done, chappe_mrf_lib:to_bin(H(<<"File">>))}, S
            );
        _ ->
            S
    end.

event(Ep, Ev, #state{name = Name} = S) ->
    H = fun(K) -> chappe_esl_event:header(K, Ev) end,
    case {H(<<"Event-Subclass">>), H(<<"Conference-Name">>)} of
        {<<"conference::maintenance">>, Name} ->
            action(
                H(<<"Action">>),
                chappe_mrf_lib:to_bin(H(<<"Member-ID">>)),
                Ep,
                Ev,
                S
            );
        _ ->
            S
    end.

action(<<"add-member">>, Id, Ep, _Ev, #state{pending = P} = S) ->
    case maps:take({ep, Ep}, P) of
        {#{from := From, owned := Owned, opts := Opts, timer := TRef} = J, P1} ->
            _ = erlang:cancel_timer(TRef),
            _ =
                Owned andalso maps:get(adopt, J, false) andalso
                    chappe_mrf_endpoint:set_owner(Ep, self()),
            Mb = chappe_mrf_conf:member(Opts, Id, #{ep => Ep, owned => Owned}),
            gen_server:reply(From, {ok, Id}),
            S1 = S#state{pending = P1, members = (S#state.members)#{Id => Mb}},
            chappe_mrf_conf:emit(
                {joined, Id, chappe_mrf_conf:public(Id, Mb)}, S1
            );
        error ->
            S
    end;
action(<<"del-member">>, Id, _Ep, _Ev, S) ->
    chappe_mrf_conf:gone(Id, S);
action(<<"start-talking">>, Id, _Ep, _Ev, S) ->
    chappe_mrf_conf:talking(Id, true, S);
action(<<"stop-talking">>, Id, _Ep, _Ev, S) ->
    chappe_mrf_conf:talking(Id, false, S);
action(<<"mute-member">>, Id, _Ep, _Ev, S) ->
    muted(Id, true, S);
action(<<"unmute-member">>, Id, _Ep, _Ev, S) ->
    muted(Id, false, S);
action(<<"play-file-member-done">>, Id, _Ep, Ev, S) ->
    File = chappe_mrf_lib:to_bin(chappe_esl_event:header(<<"File">>, Ev)),
    chappe_mrf_conf:emit({play_done, Id, File}, S);
action(_Action, _Id, _Ep, _Ev, S) ->
    S.

muted(Id, Mute, #state{members = M} = S) ->
    case M of
        #{Id := Mb} ->
            S1 = S#state{members = M#{Id := Mb#{mute => Mute}}},
            chappe_mrf_conf:publish(
                chappe_mrf_conf:emit({muted, Id, Mute}, S1)
            );
        _ ->
            S
    end.

gone_ep(Ep, #state{members = M, pending = P} = S) ->
    S1 =
        case maps:take({ep, Ep}, P) of
            {#{from := From, timer := TRef}, P1} ->
                _ = erlang:cancel_timer(TRef),
                gen_server:reply(From, {error, hangup}),
                S#state{pending = P1};
            error ->
                S
        end,
    case [Id || {Id, #{ep := E}} <- maps:to_list(M), E =:= Ep] of
        [Id | _] -> chappe_mrf_conf:gone(Id, hangup, S1);
        [] -> S1
    end.

api(any, Args, #state{members = M, node = Node, name = Name}) ->
    case [Ep || #{ep := Ep} <- maps:values(M)] of
        [Ep | _] -> chappe_mrf:api(Ep, conf_cmd(Name, Args));
        [] -> chappe_esl:node_api(Node, conf_cmd(Name, Args))
    end;
api(#{ep := Ep}, Args, #state{name = Name}) ->
    chappe_mrf:api(Ep, conf_cmd(Name, Args)).

conf_cmd(Name, Args) ->
    [<<"conference ">>, Name, <<" ">> | lists:join(<<" ">>, Args)].

lock_cmd(true) -> <<"lock">>;
lock_cmd(false) -> <<"unlock">>.
