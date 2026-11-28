%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The native backend of chappe_mrf_conf (chappe_mrf_conf_backend): a
%% chappe_mix room behind rtpengine, reached by a loopback INVITE (see
%% chappe_mrf_conf). The room's rate (8000 or 16000, fixed) goes with every
%% join of the mixer, and rtpengine's flags for it
%% (chappe_sip_media:mixer_params/2) lie under the app's anchor and
%% endpoint params, so a caller on any codec is transcoded to the room's.
%%
%% A join with a pin (chappe_mrf_conf_pin) has the caller enter it on a
%% FreeSWITCH endpoint first, in a helper the room watches, then moves
%% the call into the mixer as a call's join does: a caller joined from
%% its INVITE is answered to an endpoint of its own for it, a call joined
%% by the app enters it on the endpoint the join names.
-module(chappe_mrf_conf_native).
-behaviour(chappe_mrf_conf_backend).

-include("chappe_mrf_conf.hrl").

-export([init/2, info/1, join/4, admit/3, handle_call/3, handle_cast/2]).
-export([handle_info/2, terminate/1]).
-export([set_flag/5, hangup/3, left/2, play/3, portable/0]).
-export([relate/4, record/3, stop_record/1, handover/1, dial/4]).
-export([loop_invite/4, check_rate/1, check_join_timeout/1, same_rate/2]).

%% how much longer than its deadline a call's join whose loopback the
%% mixer answered has to report (its leg B may be swapped already):
%% within MRF_JOIN_MARGIN, so its joiner still waits
-define(SWAP_GRACE, 3000).

-record(native, {
    %% the mixer room's sample rate
    rate = 8000 :: 8000 | 16000,
    anchor_params = #{} :: map(),
    %% rtpengine flags between the mixer and an endpoint's node:
    %% #{offer => map(), answer => map()}
    endpoint_params = #{} :: map(),
    bridge = #{} :: map(),
    %% the room's SIPREC sessions (chappe_sip_siprec), owned by the room
    siprec = [] :: [pid()],
    %% how long a call's join may take before it fails
    join_timeout = ?MRF_JOIN_MAX :: pos_integer()
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
        bridge = maps:get(bridge, Opts, #{}),
        %% checked by start/2 (check_join_timeout/1)
        join_timeout = maps:get(join_timeout, Opts, ?MRF_JOIN_MAX)
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

%% A room's join_timeout, checked in the caller of chappe_mrf_conf:start/2
%% on every backend: milliseconds, from 1 to 95000 (MRF_JOIN_MAX).
-spec check_join_timeout(map()) -> ok | {error, term()}.
check_join_timeout(#{join_timeout := Ms}) when
    is_integer(Ms), Ms > 0, Ms =< ?MRF_JOIN_MAX
->
    ok;
check_join_timeout(#{join_timeout := _}) ->
    {error, {bad_option, join_timeout}};
check_join_timeout(_Opts) ->
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

%% In the caller: chappe_mrf_conf_native_join.
join(Conf, Info, Target, Opts) ->
    chappe_mrf_conf_native_join:join(Conf, Info, Target, Opts).

admit({ep, Ep, Opts}, From, S) ->
    join_endpoint(Ep, Opts, From, S);
admit({b2b, B2b, Opts}, From, S) ->
    join_b2b(B2b, Opts, From, S);
admit({pin, B2b, Ep, Opts}, From, S) ->
    join_pin(B2b, Ep, Opts, From, S);
admit({call, Opts}, From, S) ->
    prepare_call(Opts, From, S);
admit(_Req, _From, S) ->
    {reply, {error, unknown_join}, S}.

handle_call({loop_offer, Token, Offer}, _From, S) ->
    offer(Token, Offer, S);
handle_call({call_done, Token, Result}, From, #state{pending = P} = S) ->
    case P of
        #{Token := J} -> {noreply, call_done(Token, J, Result, From, S)};
        _ -> {reply, {error, join_failed}, S}
    end;
handle_call({ep_join, Id, reinvite_now, D}, _From, #state{pending = P} = S) ->
    %% the helper of an endpoint's join asks to send its re-INVITE
    case chappe_mrf_conf_native_ep:agree(Id, D, P) of
        {ok, P1} -> {reply, ok, S#state{pending = P1}};
        {error, _} = Err -> {reply, Err, S}
    end;
handle_call({pin_ok, Token}, _From, #state{pending = P} = S) ->
    %% the helper of a PIN join has the PIN and asks to move the call
    case P of
        #{Token := #{helper := _} = J} ->
            {reply, ok, S#state{pending = P#{Token := pin_moving(Token, J)}}};
        _ ->
            {reply, {error, join_ended}, S}
    end;
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

%% the loopback dialog of loop_invite/4, or its failure
handle_cast({loop_dialog, Token, D}, #state{pending = P} = S) ->
    case P of
        #{Token := J} ->
            {noreply, complete(Token, J#{dialog => D}, S)};
        _ ->
            %% its join ended first: the loopback goes too
            ok = chappe_mrf_lib:destroy_later(D),
            {noreply, S}
    end;
handle_cast({loop_failed, Token}, #state{pending = P} = S) ->
    case P of
        #{Token := #{from := _} = J} ->
            {noreply, result(Token, J, {error, join_failed}, S)};
        #{Token := J} ->
            %% a caller's join: its worker hears it with call_done
            {noreply, S#state{pending = P#{Token := loop_gone(Token, J)}}};
        _ ->
            {noreply, S}
    end;
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({join_result, Token, Result}, #state{pending = P} = S) ->
    case P of
        #{Token := J} -> {noreply, result(Token, unwatch(J), Result, S)};
        _ -> {noreply, S}
    end;
handle_info({ep_join, Id, Step}, #state{pending = P} = S) ->
    %% the helper of an endpoint's join reports (chappe_mrf_conf_native_ep)
    case P of
        #{Id := #{rtpe := _} = J} -> {noreply, ep_step(Id, Step, J, S)};
        _ -> {noreply, chappe_mrf_conf_native_ep:late(Step, S)}
    end;
handle_info({native_join_timeout, Token}, #state{pending = P} = S) ->
    case P of
        #{Token := J} -> {noreply, deadline(Token, J, S)};
        _ -> {noreply, S}
    end;
handle_info({'DOWN', Mon, process, _, _}, #state{pending = P} = S) ->
    %% the worker of a join died before it reported
    case [T || T := #{mon := M} <- P, M =:= Mon] of
        [Token | _] ->
            {noreply,
                result(Token, maps:get(Token, P), {error, join_failed}, S)};
        [] ->
            ignore
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

gone_ep(Ep, #state{pending = P} = S) ->
    case chappe_mrf_conf_backend:member_by(ep, Ep, S) of
        {ok, Id} ->
            chappe_mrf_conf_backend:gone(Id, hangup, S);
        error ->
            %% one that hangs up before its join's helper reported (the
            %% room watches it from the join's last step): the join fails
            case [Id || Id := #{ep := E, rtpe := _} <- P, E =:= Ep] of
                [Id | _] -> result(Id, maps:get(Id, P), {error, hangup}, S);
                [] -> S
            end
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
    chappe_mrf_lib:destroy_later(D);
hangup(_Id, _Mb, _S) ->
    ok.

%% a member gone to another room keeps its call: only its mixer session
%% goes; an endpoint's rtpengine session, the room's, is deleted by a job
%% (the delete waits on rtpengine, up to its client's tries)
left(#{session := MS}, transferred) ->
    _ = chappe_sip_media:leave(MS),
    ok;
left(#{session := MS, rtpe := RS}, _Why) ->
    _ = chappe_sip_media:leave(MS),
    chappe_mrf_lib:later(fun() -> chappe_sip_media:stop(RS) end);
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

%% A REFER brings Target in: an endpoint bridges to it, and joins the
%% mixer once it answered (chappe_mrf_conf_refer_dial).
dial(Target, Key, Cfg, S) ->
    chappe_mrf_conf_refer_dial:native(Target, Key, Cfg, S).

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

%% A call's join: a helper runs replace_b/3, watched by the room, so a
%% helper that dies before it reports fails the join. swap: the join
%% replaces the leg B of a call that runs (deadline/3).
join_b2b(B2b, Opts, From, S) ->
    #native{anchor_params = AP} = chappe_mrf_conf_backend:bstate(S),
    Token = chappe_mrf_lib:new_id(),
    ok = chappe_mrf_registry:put({loop, Token}, self()),
    Uri = chappe_mrf:loop_target(Token),
    Self = self(),
    {_, Mon} = spawn_monitor(fun() ->
        Result = chappe_sip_b2b:replace_b(B2b, Uri, #{anchor_params => AP}),
        Self ! {join_result, Token, Result}
    end),
    J = #{from => From, b2b => B2b, opts => Opts, mon => Mon, swap => true},
    {noreply, pending(Token, J, S)}.

%% A call's join behind a PIN: a helper the room watches has the caller
%% enter it on the endpoint Ep the call is on (chappe_mrf_conf_pin:check/2),
%% asks the room to go on ({pin_ok, Token}), then moves the call as
%% join_b2b/4 does, so the room answers its other requests meanwhile. The
%% room stops the helper when the join ends during the PIN (its deadline,
%% the room's end); from pin_ok on the helper is in replace_b/3, which
%% the room lets end, and the loopback token is registered. A wrong PIN is
%% {error, bad_pin}: the call stays on Ep. The join's deadline covers the
%% PIN and the move.
join_pin(B2b, Ep, Opts, From, S) ->
    #native{anchor_params = AP} = chappe_mrf_conf_backend:bstate(S),
    Token = chappe_mrf_lib:new_id(),
    Uri = chappe_mrf:loop_target(Token),
    Room = self(),
    {Pid, Mon} = spawn_monitor(fun() ->
        Result =
            maybe
                ok ?= chappe_mrf_conf_pin:check(Ep, Opts),
                ok ?=
                    chappe_mrf_conf:call(
                        Room, {backend, {pin_ok, Token}}, infinity
                    ),
                chappe_sip_b2b:replace_b(B2b, Uri, #{anchor_params => AP})
            end,
        Room ! {join_result, Token, Result}
    end),
    J = #{
        from => From,
        b2b => B2b,
        opts => Opts,
        mon => Mon,
        helper => Pid,
        swap => true
    },
    {noreply, pending(Token, J, S)}.

%% the PIN is in: the loopback may reach the room now, and the helper,
%% in replace_b/3 from here, is no more stopped at the join's end
pin_moving(Token, J) ->
    ok = chappe_mrf_registry:put({loop, Token}, self()),
    maps:remove(helper, J).

%% A join under way, until join_timeout at most: then it fails, and
%% what it took goes back (deadline/3, result/4).
pending(Token, J, #state{pending = P} = S) ->
    #native{join_timeout = Ms} = chappe_mrf_conf_backend:bstate(S),
    T = erlang:send_after(Ms, self(), {native_join_timeout, Token}),
    S#state{pending = P#{Token => J#{timer => T}}}.

%% A join's deadline. A call's join (swap) whose loopback INVITE the
%% mixer answered may have swapped the call's leg B already: failing it
%% would end the call, as the loopback's BYE ends it. It gets SWAP_GRACE
%% more to report instead: a swap that went through makes a member, one
%% that failed left the call its old leg B. Any other join, or one still
%% not done then, fails with {error, timeout}.
deadline(Token, #{swap := true, session := _} = J, S) when
    not is_map_key(overdue, J)
->
    ok = with_key(timer, J, fun erlang:cancel_timer/1),
    T = erlang:send_after(?SWAP_GRACE, self(), {native_join_timeout, Token}),
    S#state{
        pending = (S#state.pending)#{Token := J#{timer := T, overdue => true}}
    };
deadline(Token, J, S) ->
    result(Token, J, {error, timeout}, S).

%% the worker reported: its exit is no failure any more, and a helper
%% that reported is done
unwatch(#{mon := Mon} = J) ->
    _ = demonitor(Mon, [flush]),
    maps:without([mon, helper], J);
unwatch(J) ->
    J.

%% the loopback a joining call is sent to, and the flags toward the mixer;
%% the INVITE's request worker that asks is watched until it reports
prepare_call(Opts, {Worker, _}, S) ->
    #native{anchor_params = AP} = chappe_mrf_conf_backend:bstate(S),
    Token = chappe_mrf_lib:new_id(),
    ok = chappe_mrf_registry:put({loop, Token}, self()),
    J = #{opts => Opts, mon => monitor(process, Worker)},
    Uri = iolist_to_binary(chappe_mrf:loop_target(Token)),
    {reply, {ok, Token, Uri, AP, S#state.entity}, pending(Token, J, S)}.

%% the B2BUA call of an incoming call's join (chappe_mrf_conf_native_join)
%% is up (or failed); a loopback that failed first fails it
call_done(Token, #{loop := failed} = J, _Result, From, S) ->
    result(Token, unwatch(J#{from => From}), {error, join_failed}, S);
call_done(Token, J, {ok, B2b}, From, S) ->
    J1 = unwatch(J#{from => From, b2b => B2b}),
    complete(Token, J1#{result => ok}, S);
call_done(Token, J, Error, From, S) ->
    result(Token, unwatch(J#{from => From}), Error, S).

%% a caller's loopback INVITE failed: no member can come of it, and the
%% mixer leg and the token go now; its worker hears it with call_done
loop_gone(Token, J) ->
    ok = chappe_mrf_registry:delete({loop, Token}),
    ok = with_key(session, J, fun chappe_sip_media:leave/1),
    (maps:remove(session, J))#{loop => failed}.

%% the mixer answers the loopback INVITE's offer (rtpengine's)
offer(Token, Offer, #state{pending = P} = S) ->
    case P of
        #{Token := #{opts := Opts} = J} when
            not is_map_key(session, J), not is_map_key(loop, J)
        ->
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
            chappe_sip_media:conference(
                MS, Room, chappe_mrf_lib:with_name(Opts, JoinOpts)
            ),
        _ = maps:get(deaf, Opts, false) andalso chappe_sip_media:deaf(MS),
        {ok, MS, Answer}
    end.

%% A join's outcome. A failure (its own, its worker's death, its
%% deadline) gives back all it took and answers the joiner when one waits
%% (a caller's worker waits only from call_done on); a room that lost its
%% name ends once nothing is left in it.
result(Token, J, ok, S) ->
    complete(Token, J#{result => ok}, S);
result(Token, J, Error, S) ->
    ok = forget(Token, J),
    ok = give_back(J),
    _ =
        case J of
            #{from := From} -> gen_server:reply(From, Error);
            #{} -> ok
        end,
    S1 = S#state{pending = maps:remove(Token, S#state.pending)},
    ok = chappe_mrf_conf_backend:close_if_empty(S1),
    S1.

%% a join that ends, either way: its token, deadline and watch go, and a
%% helper still at work (its deadline came first) is stopped
forget(Token, J) ->
    ok = drop_token(Token, J),
    ok = with_key(timer, J, fun erlang:cancel_timer/1),
    ok = with_key(mon, J, fun(Mon) -> demonitor(Mon, [flush]) end),
    with_key(helper, J, fun(Pid) -> exit(Pid, kill) end).

%% an endpoint's join has no loopback
drop_token(_Id, #{ep := _}) -> ok;
drop_token(Token, _J) -> chappe_mrf_registry:delete({loop, Token}).

%% What a failed join took goes back: its mixer leg now, and in a job
%% (chappe_mrf_lib:later/1) what waits on a peer, so the room goes on:
%% the delete of an endpoint's rtpengine session, then the BYE of the
%% loopback dialog, or of an endpoint whose media moved or may have (its
%% re-INVITE out when its helper died or its deadline came). That BYE
%% waits for the re-INVITE to end. The job first waits for the end of
%% the join's helper (stopped by forget/2) and leaves the mixer session
%% again: a mixer join the helper sent just before it was stopped may
%% reach the mixer after the room's leave.
give_back(J) ->
    ok = with_key(session, J, fun chappe_sip_media:leave/1),
    Late = [{H, MS} || #{helper := H, session := MS} <- [J]],
    Rtpe = [RS || #{rtpe := RS} <- [J]],
    Dialogs = [D || K <- [dialog, moved, reinvite], #{K := D} <- [J]],
    case Late ++ Rtpe ++ Dialogs of
        [] ->
            ok;
        _ ->
            chappe_mrf_lib:later(fun() ->
                lists:foreach(fun chappe_mrf_conf_native_ep:late_leave/1, Late),
                lists:foreach(fun chappe_sip_media:stop/1, Rtpe),
                lists:foreach(fun chappe_mrf_lib:destroy_dialog/1, Dialogs)
            end)
    end.

with_key(Key, Map, Fun) ->
    case Map of
        #{Key := V} ->
            _ = Fun(V),
            ok;
        #{} ->
            ok
    end.

%% both the replace_b result and the loopback dialog are in: a member
complete(Token, #{result := ok, dialog := D, session := MS} = J, S) ->
    #{from := From, b2b := B2b, opts := Opts} = J,
    ok = forget(Token, J),
    Base = #{b2b => B2b, dialog => D, session => MS},
    Mb = chappe_mrf_conf_backend:member(Opts, Token, Base),
    gen_server:reply(From, {ok, Token}),
    S1 = S#state{pending = maps:remove(Token, S#state.pending)},
    chappe_mrf_conf_backend:joined(Token, Mb, S1);
complete(Token, J, S) ->
    S#state{pending = (S#state.pending)#{Token => J}}.

%% An endpoint of create_endpoint/1 joins: the room makes its media
%% sessions, and a helper it watches sets them up
%% (chappe_mrf_conf_native_ep), so the room answers its other requests
%% meanwhile. The joiner waits in pending, and is answered on the
%% helper's result, at the join's deadline at the latest; a failure
%% leaves nothing behind (result/4). An endpoint joins once: a member,
%% or one whose join is under way, is refused.
join_endpoint(Ep, Opts, From, #state{pending = P} = S) ->
    Joining = [Id || Id := #{ep := E} <- P, E =:= Ep],
    case {chappe_mrf_conf_backend:member_by(ep, Ep, S), Joining} of
        {{ok, _}, _} -> {reply, {error, already_member}, S};
        {error, [_ | _]} -> {reply, {error, already_joining}, S};
        {error, []} -> start_endpoint(Ep, Opts, From, S)
    end.

start_endpoint(Ep, Opts, From, #state{name = Name, room = Room} = S) ->
    #native{endpoint_params = EP, rate = Rate} =
        chappe_mrf_conf_backend:bstate(S),
    Cfg = #{name => Name, room => Room, params => EP, rate => Rate},
    case chappe_mrf_conf_native_ep:start(Ep, Opts, Cfg) of
        {ok, Id, Job} ->
            J = Job#{from => From, ep => Ep, opts => Opts},
            {noreply, pending(Id, J, S)};
        {error, _} = Err ->
            {reply, Err, S}
    end.

%% What the helper of an endpoint's join reports, applied in the room
%% (chappe_mrf_conf_native_ep:step/2): the join goes on, the endpoint is
%% in, or the join failed.
ep_step(Id, Step, J, #state{pending = P} = S) ->
    case chappe_mrf_conf_native_ep:step(Step, J) of
        {pending, J1} -> S#state{pending = P#{Id := J1}};
        {joined, J1} -> ep_joined(Id, unwatch(J1), S);
        {failed, J1, Error} -> result(Id, unwatch(J1), Error, S)
    end.

%% The room's end: the helpers of the endpoints' joins under way stop
%% with it (their media sessions are the room's and end with it).
terminate(#state{pending = P}) ->
    chappe_mrf_conf_native_ep:stop_helpers(P).

%% the endpoint is in: a member, with the media sessions the room owns
ep_joined(Id, J, S) ->
    #{from := From, ep := Ep, opts := Opts, session := MS, rtpe := RS} = J,
    ok = forget(Id, J),
    Mb = chappe_mrf_conf_backend:member(Opts, Id, #{
        ep => Ep, session => MS, rtpe => RS
    }),
    gen_server:reply(From, {ok, Id}),
    S1 = S#state{pending = maps:remove(Id, S#state.pending)},
    chappe_mrf_conf_backend:joined(Id, Mb, S1).

%% an endpoint member: its node plays the file (a path on the node)
play_leg(#{ep := Ep, rtpe := _}, File) ->
    chappe_mrf_lib:later(fun() -> chappe_mrf:play(Ep, File) end);
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
