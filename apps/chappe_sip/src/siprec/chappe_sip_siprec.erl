%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc SIPREC client: record a call to a recording server (RFC 7866).
%%
%% start/3 records an anchored B2BUA call. The recording is one process,
%% under chappe_sip_siprec_sup on the node that holds the call, owned by
%% the caller of start/3. It taps each party's media in rtpengine (one
%% subscription per party), and sends the recording server (SRS) an INVITE
%% that makes it a recording session (RS): the Contact carries +sip.src,
%% Require carries siprec (RFC 7866 6.1.1), and the body is a
%% multipart/mixed of an SDP offer, one sendonly m-line per recorded
%% stream with its a=label (RFC 7866 7.1.1), and the metadata
%% (chappe_sip_siprec_meta, RFC 7865) naming the call, its participants
%% and who sends which stream. Every metadata document is a full
%% snapshot.
%%
%% While it runs:
%%   pause/1 and resume/1   re-INVITE with the streams inactive, then
%%                          sendonly again (RFC 7866 7.1.1.1); while paused
%%                          the taps are removed, so no media leaves
%%   a party change         a replace_b/3 of the call, or update/1: the new
%%                          party's media is tapped on the same stream, and
%%                          a re-INVITE carries metadata where the old
%%                          party is disassociated and the new one
%%                          associated
%%   a snapshot request     an UPDATE from the SRS (RFC 7866 9.2) is
%%                          answered 200 and followed by a re-INVITE with a
%%                          full snapshot
%%   a re-INVITE of the SRS answered with the recorded streams as they are,
%%                          its answer handed to rtpengine
%%
%% It ends with a BYE to the SRS when the call ends (the call's rtpengine
%% session goes away), when the owner exits, or on stop/1; and when the
%% SRS refuses the INVITE, sends BYE, or does not answer an INVITE or
%% re-INVITE within answer_timeout. The owner gets every step as
%%   {chappe_sip_siprec, Rec, {Event, Info}}
%% with Event one of started, paused, resumed, updated, snapshot, stopped,
%% and Info a map that always carries call_ref (and srs, the recording
%% server's URI); stopped carries reason: stopped | call_ended | room_ended |
%% srs_bye | {rejected, Status} | {srs, timeout} | {error, _}. A recording
%% that crashes sends nothing: monitor Rec to see it go; its RS dialog
%% then sends the BYE, the call's media session removes its taps from
%% rtpengine (they are held for Rec), and the call goes on.
%%
%% {room, Room} records a chappe_mix room of this node (a native
%% conference, chappe_sip_media:conference/3) as one participant: a
%% sendonly leg of the room hears the whole mix and sends it to the SRS as
%% one stream. The room must be up ({error, no_room} in stopped
%% otherwise). Its leg does not keep the room up: when the last party
%% leaves, or the room's owner exits, the room ends and so does the
%% recording, with reason room_ended; stop/1, its owner exiting or the SRS
%% end it sooner. The room's participant
%% is sip:Room@chappe.invalid unless participants => #{room => _} names
%% it, and call_ref => binary() gives the recording the room's call_ref
%% (default a new one).
%%
%% Opts:
%%   owner          => pid() (default the caller): gets the events; its
%%                     exit ends the recording
%%   answer_timeout => ms the SRS may take to answer (default the
%%                     siprec_answer_timeout_ms config, 10000)
%%   from, headers, proxy, auth, flow => the RS INVITE's, as for
%%                     chappe_sip_uac:start/2
%%   codec, ptime   => the subscription's (chappe_sip_media:subscribe/2):
%%                     codec => #{mask => [all], transcode => ['PCMU']}
%%                     gives the SRS one plain codec
%%   participants   => #{a | b => #{aor := binary(), name => binary()}}:
%%                     who the party is in the metadata, instead of the
%%                     leg's From (a) or To (b)
%%   metadata       => #{names => boolean(), aors => boolean(),
%%                     call_ref => boolean()} (all true by default): what
%%                     the metadata may say. RFC 7865 10 lets the SRC keep
%%                     metadata back; names => false drops display names,
%%                     aors => false sends sip:anonymous@anonymous.invalid
%%   legacy_content_type => boolean() (default false): label the metadata
%%                     application/rs-metadata, RFC 7866's name, for a
%%                     recorder that predates RFC 9806
%%   allow_downgrade => boolean() (default false): record a secure call to a
%%                     recording server that is not as secure (below)
%%
%% RFC 7866 12: the RS must be at least as secure as the call. A call with
%% a leg over TLS (a sips: or transport=tls or wss Contact) is recorded
%% only to a sips: or transport=tls SrsUri (or proxy), else start/3 is
%% {error, {insecure_srs, tls}}; a call with an SRTP leg (RTP/SAVP,
%% RTP/SAVPF) has its taps offered to the SRS as RTP/SAVP, keyed by
%% rtpengine apart from the call's keys (12.2), so a recording server
%% without SRTP refuses them and the recording stops. allow_downgrade =>
%% true lifts both, for an SRS on a network the app trusts.
%% SrsUri is the SRS's URI, or `default' for the siprec_srs config.
%% start/3 returns once the process runs, before the SRS answers:
%% {error, badarg} for a bad argument, {error, not_anchored} for a call
%% with direct media, {error, too_many} past siprec_max_per_call, {error,
%% no_srs} for `default' with none configured. A recording joins its
%% call (chappe_sip:calls/1, as siprec) while it runs.
-module(chappe_sip_siprec).
-behaviour(gen_server).

-export([start/3, pause/1, resume/1, update/1, stop/1, info/1, local/1]).
-export([start_link/1]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).
-export([terminate/2]).

-export_type([rec/0]).

-include("chappe_sip.hrl").

-type rec() :: pid().

-define(CALL_TIMEOUT, 30000).

%% ---- API ----

-spec start(chappe_sip_b2b:b2b() | {room, binary()}, binary() | default, map()) ->
    {ok, rec()} | {error, term()}.
start(Source, Srs0, Opts) when is_map(Opts) ->
    case
        {
            chappe_sip_siprec_body:srs(Srs0),
            chappe_sip_siprec_body:valid_opts(Opts)
        }
    of
        {{ok, Srs}, true} -> start_source(Source, Srs, Opts);
        {{error, _} = E, _} -> E;
        {_, false} -> {error, badarg}
    end;
start(_Source, _Srs, _Opts) ->
    {error, badarg}.

%% the call is read in the caller's process, and the recording started on
%% the call's node
start_source({Pid, Ref} = B2b, Srs, Opts) when is_pid(Pid), is_reference(Ref) ->
    case chappe_sip_b2b:info(B2b) of
        #{
            media := anchor,
            session := S,
            call_ref := CallRef,
            parties := Parties
        } when
            is_binary(CallRef)
        ->
            Args = #{
                source => {b2b, B2b},
                session => S,
                call_ref => CallRef,
                parties => Parties,
                srs => Srs,
                opts => Opts,
                owner => maps:get(owner, Opts, self())
            },
            start_on(node(Pid), Args);
        #{media := _} ->
            {error, not_anchored};
        {error, _} = E ->
            E
    end;
start_source({room, Room}, Srs, Opts) when is_binary(Room) ->
    %% a room is recorded where its mixer runs: this node
    case chappe_sip_call:valid(Room) of
        true ->
            chappe_sip_siprec_sup:start_child(#{
                source => {room, Room},
                session => undefined,
                call_ref => maps:get(call_ref, Opts, chappe_sip_call:new_ref()),
                parties => #{
                    room => <<"<sip:", Room/binary, "@chappe.invalid>">>
                },
                srs => Srs,
                opts => Opts,
                owner => maps:get(owner, Opts, self())
            });
        false ->
            {error, badarg}
    end;
start_source(_Source, _Srs, _Opts) ->
    {error, badarg}.

start_on(Node, Args) when Node =:= node() ->
    chappe_sip_siprec_sup:start_child(Args);
start_on(Node, Args) ->
    try
        erpc:call(
            Node, chappe_sip_siprec_sup, start_child, [Args], ?CALL_TIMEOUT
        )
    catch
        _:Why -> {error, {node, Why}}
    end.

%% Put the recording on pause (RFC 7866 7.1.1.1): the streams go inactive
%% and no media is sent until resume/1. Returns once the SRS answered.
-spec pause(rec()) -> ok | {error, term()}.
pause(Rec) -> call(Rec, pause).

-spec resume(rec()) -> ok | {error, term()}.
resume(Rec) -> call(Rec, resume).

%% Read the call's parties again and send the SRS new metadata when they
%% changed (done by itself on a replace_b/3 of the call).
-spec update(rec()) -> ok | {error, term()}.
update(Rec) -> call(Rec, update).

%% End the recording: BYE to the SRS, then stopped to the owner.
-spec stop(rec()) -> ok.
stop(Rec) ->
    case call(Rec, stop) of
        ok -> ok;
        {error, noproc} -> ok;
        {error, _} -> ok
    end.

%% #{call_ref, srs, state := inviting | active | paused, labels, dialog}.
-spec info(rec()) -> map() | {error, term()}.
info(Rec) -> call(Rec, info).

%% The recordings of call CallRef on this node.
-spec local(binary() | undefined) -> [rec()].
local(undefined) ->
    [];
local(CallRef) ->
    [H || {siprec, H} <- chappe_sip_call:local(CallRef)].

call(Rec, Req) when is_pid(Rec) ->
    try
        gen_server:call(Rec, Req, ?CALL_TIMEOUT)
    catch
        exit:{noproc, _} -> {error, noproc};
        exit:{normal, _} -> {error, noproc};
        exit:{timeout, _} -> {error, timeout};
        exit:{{nodedown, _}, _} -> {error, noproc}
    end;
call(_Rec, _Req) ->
    {error, badarg}.

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%% ---- the process ----

init(#{call_ref := CallRef, owner := Owner} = Args) ->
    %% the bound on recordings per call: every recording of a call runs on
    %% the call's node, so this count is that of the cluster
    case length(local(CallRef)) >= chappe_sip_config:get(siprec_max_per_call) of
        true ->
            {stop, too_many};
        false ->
            case chappe_sip_siprec_body:security(Args) of
                {ok, Srtp} ->
                    ok = chappe_sip_call:join(CallRef, siprec, self()),
                    St = new_state(Args, erlang:monitor(process, Owner)),
                    {ok, St#{srtp => Srtp}, {continue, invite}};
                {error, Why} ->
                    {stop, Why}
            end
    end.

new_state(
    #{source := Source, srs := Srs, opts := Opts, owner := Owner} = Args, OMon
) ->
    S = maps:get(session, Args),
    #{
        source => Source,
        srs => Srs,
        opts => Opts,
        owner => Owner,
        owner_mon => OMon,
        call_ref => maps:get(call_ref, Args),
        session => S,
        media_mon => monitor_session(S),
        cs_id => chappe_sip_siprec_meta:new_id(),
        start => chappe_sip_siprec_meta:now(),
        participants => [],
        streams => [],
        parties0 => maps:get(parties, Args),
        state => inviting,
        paused => false,
        version => 1,
        next_label => 1,
        uac => undefined,
        timer => undefined,
        dialog => undefined,
        pending => undefined,
        dirty => false,
        recheck => false
    }.

monitor_session(S) ->
    case chappe_sip_media:pid(S) of
        undefined -> undefined;
        Pid -> erlang:monitor(process, Pid)
    end.

handle_continue(invite, #{parties0 := Parties} = St0) ->
    St1 = lists:foldl(
        fun(Leg, Acc) -> join_party(Leg, Parties, Acc) end,
        St0,
        lists:sort(maps:keys(Parties))
    ),
    case chappe_sip_siprec_tap:open(St1) of
        {ok, St2} -> send_invite(watch_room(St2));
        {error, Why} -> {stop, normal, stopped({error, Why}, St1)}
    end.

%% ---- parties and streams ----

%% A participant joins: its identity from the leg (or the app's), its own
%% stream (made on first join, reused when the party changes).
join_party(Leg, Parties, #{participants := Ps, opts := Opts} = St) ->
    Who = chappe_sip_siprec_body:identity(
        Leg, maps:get(Leg, Parties, undefined), Opts
    ),
    P = Who#{
        id => chappe_sip_siprec_meta:new_id(),
        party => Leg,
        addr => maps:get(Leg, Parties, undefined),
        since => chappe_sip_siprec_meta:now()
    },
    ensure_stream(Leg, St#{participants := Ps ++ [P]}).

ensure_stream(Leg, #{streams := Ss} = St) ->
    case [S || #{party := L} = S <- Ss, L =:= Leg] of
        [_ | _] ->
            St;
        [] ->
            St#{
                streams := Ss ++
                    [#{party => Leg, tap => undefined, media => []}]
            }
    end.

%% ---- the RS INVITE ----

send_invite(#{srs := Srs, opts := Opts, call_ref := CallRef} = St) ->
    {CT, Body} = chappe_sip_siprec_body:body(St),
    Uac = maps:merge(
        maps:with([from, proxy, auth, flow], Opts),
        #{
            body => Body,
            content_type => CT,
            headers => [
                {<<"Require">>, <<"siprec">>},
                {<<"Accept">>,
                    <<"application/sdp, application/rs-metadata+xml, multipart/mixed">>}
                | maps:get(headers, Opts, [])
            ],
            contact_params => <<";+sip.src">>,
            owner => self(),
            notify => self(),
            handled_events => [modify, update],
            call_ref => CallRef,
            related => CallRef
        }
    ),
    case chappe_sip_uac:start(Srs, Uac) of
        {ok, Ref} ->
            {noreply, St#{uac := Ref, timer := timer(St)}};
        {error, Why} ->
            fail(Why, St)
    end.

timer(#{opts := Opts}) ->
    Ms = maps:get(
        answer_timeout, Opts, chappe_sip_config:get(siprec_answer_timeout_ms)
    ),
    erlang:start_timer(Ms, self(), answer_timeout).

cancel_timer(undefined) ->
    ok;
cancel_timer(T) ->
    _ = erlang:cancel_timer(T),
    ok.

%% ---- calls ----

handle_call(info, _From, St) ->
    {reply, info_map(St), St};
handle_call(stop, _From, St) ->
    {stop, normal, ok,
        stopped(stopped, chappe_sip_siprec_tap:close(abandon(St)))};
handle_call(_Req, _From, #{state := inviting} = St) ->
    {reply, {error, not_started}, St};
handle_call(_Req, _From, #{pending := P} = St) when P =/= undefined ->
    {reply, {error, busy}, St};
handle_call(pause, _From, #{paused := true} = St) ->
    {reply, ok, St};
handle_call(pause, From, St) ->
    reoffer(From, paused, chappe_sip_siprec_tap:close(St#{paused := true}));
handle_call(resume, _From, #{paused := false} = St) ->
    {reply, ok, St};
handle_call(resume, From, St) ->
    case chappe_sip_siprec_tap:open(St#{paused := false}) of
        {ok, St1} -> reoffer(From, resumed, St1);
        {error, Why} -> {reply, {error, Why}, St}
    end;
handle_call(update, From, St) ->
    party_change(From, St).

handle_cast(_Msg, St) ->
    {noreply, St}.

info_map(
    #{call_ref := C, srs := Srs, state := State, paused := Paused, dialog := D} =
        St
) ->
    #{
        call_ref => C,
        srs => Srs,
        state =>
            case {State, Paused} of
                {active, true} -> paused;
                _ -> State
            end,
        labels => [L || #{label := L} <- chappe_sip_siprec_body:media(St)],
        dialog => D
    }.

%% ---- re-INVITEs ----

%% A re-INVITE with the current offer and metadata, in a helper so the
%% process keeps answering; From hears when the SRS answered.
reoffer(From, Event, #{dialog := D, version := V} = St0) ->
    St = St0#{version := V + 1},
    {CT, Body} = chappe_sip_siprec_body:body(St),
    Self = self(),
    {Pid, Mon} = spawn_monitor(fun() ->
        Self !
            {reoffered, self(),
                chappe_sip_dialog:modify(D, Body, #{content_type => CT})}
    end),
    {noreply, St#{
        pending := #{pid => Pid, mon => Mon, from => From, event => Event},
        timer := timer(St)
    }}.

reoffered(
    Result,
    #{pending := #{mon := Mon, from := From, event := Ev}, timer := T} = St0
) ->
    erlang:demonitor(Mon, [flush]),
    cancel_timer(T),
    St = St0#{pending := undefined, timer := undefined},
    case Result of
        {ok, Answer} ->
            case chappe_sip_siprec_tap:answer(Answer, St) of
                ok ->
                    reply(From, ok),
                    _ = Ev =/= none andalso event(Ev, #{}, St),
                    again(St);
                {error, Why} ->
                    reply(From, {error, Why}),
                    fail(Why, St)
            end;
        {error, Why} ->
            %% the SRS refused the change: the session goes on as it was
            reply(From, {error, Why}),
            again(St)
    end.

reply(undefined, _) -> ok;
reply(From, R) -> gen_server:reply(From, R).

%% a change that came while the INVITE or a re-INVITE was out is sent now
again(#{recheck := true} = St) ->
    party_change(undefined, St#{recheck := false});
again(#{dirty := true} = St) ->
    reoffer(undefined, none, St#{dirty := false});
again(St) ->
    {noreply, St}.

%% The parties of the call again: a leg whose party changed gets a new
%% participant (the old one disassociated) and a new tap on its stream.
party_change(From, #{source := {room, _}} = St) ->
    %% the room is one participant, whoever is in it
    reply(From, ok),
    {noreply, St};
party_change(From, #{source := {b2b, B2b}} = St) ->
    case chappe_sip_b2b:info(B2b) of
        #{parties := Parties} ->
            case changed(Parties, St) of
                [] ->
                    reply(From, ok),
                    {noreply, St};
                Legs ->
                    retap(
                        From,
                        lists:foldl(
                            fun(Leg, Acc) ->
                                replace_party(Leg, Parties, Acc)
                            end,
                            St,
                            Legs
                        )
                    )
            end;
        {error, Why} ->
            reply(From, {error, Why}),
            {noreply, St}
    end.

%% the new parties' media is tapped (unless paused) and the SRS told
retap(From, #{paused := true} = St) ->
    reoffer(From, updated, St);
retap(From, St) ->
    case chappe_sip_siprec_tap:open(St) of
        {ok, St1} ->
            reoffer(From, updated, St1);
        {error, Why} ->
            reply(From, {error, Why}),
            {stop, normal, stopped({error, Why}, St)}
    end.

%% the legs whose party is no longer the one recorded (a new B after
%% replace_b/3 has another To, its tag at least); a party the app named
%% stays as it is
changed(Parties, #{participants := Ps, opts := Opts}) ->
    Fixed = maps:get(participants, Opts, #{}),
    [
        Leg
     || #{party := Leg, addr := Addr} = P <- Ps,
        not maps:is_key(until, P),
        not maps:is_key(Leg, Fixed),
        maps:get(Leg, Parties, Addr) =/= Addr
    ].

replace_party(Leg, Parties, #{participants := Ps, streams := Ss} = St) ->
    Now = chappe_sip_siprec_meta:now(),
    Ps1 = [
        case P of
            #{party := Leg} when not is_map_key(until, P) -> P#{until => Now};
            _ -> P
        end
     || P <- Ps
    ],
    St1 = St#{
        participants := Ps1,
        streams := [
            case S of
                #{party := Leg} -> chappe_sip_siprec_tap:close_one(S, St);
                _ -> S
            end
         || S <- Ss
        ]
    },
    join_party(Leg, Parties, St1).

%% ---- messages ----

handle_info({chappe_sip_uac, Ref, {ok, D}}, #{uac := Ref, timer := T} = St) ->
    cancel_timer(T),
    St1 = St#{
        uac := undefined, timer := undefined, dialog := D, state := active
    },
    %% the SRS answered: each tap gets its streams of the answer
    case chappe_sip_siprec_tap:answer(chappe_sip_dialog:remote_sdp(D), St1) of
        ok ->
            event(started, #{dialog => D}, St1),
            again(St1);
        {error, Why} ->
            fail(Why, St1)
    end;
handle_info(
    {chappe_sip_uac, Ref, {error, Why}}, #{uac := Ref, timer := T} = St
) ->
    cancel_timer(T),
    stop_with(rejected(Why), St#{uac := undefined});
handle_info({chappe_sip_uac, _Ref, _Ev}, St) ->
    {noreply, St};
handle_info({timeout, T, answer_timeout}, #{timer := T} = St) ->
    stop_with({srs, timeout}, abandon(St));
handle_info({timeout, _T, answer_timeout}, St) ->
    {noreply, St};
handle_info({reoffered, Pid, Result}, #{pending := #{pid := Pid}} = St) ->
    reoffered(Result, St);
handle_info(
    {'DOWN', Mon, process, _, Why},
    #{pending := #{mon := Mon, from := From}} = St
) ->
    reply(From, {error, Why}),
    fail(Why, St#{pending := undefined});
%% a party change of the call (chappe_sip_b2b_media:event/2)
handle_info(
    {chappe_sip_b2b, _Ref, {replaced, _Leg}},
    #{state := active, pending := undefined} = St
) ->
    party_change(undefined, St);
handle_info({chappe_sip_b2b, _Ref, {replaced, _Leg}}, St) ->
    {noreply, St#{recheck := true}};
%% the SRS: a snapshot request (RFC 7866 9.2), a re-INVITE, its BYE
handle_info({chappe_sip_dialog, D, update, Req, Res}, #{dialog := D} = St) ->
    srs_update(Req, Res, St);
handle_info({chappe_sip_dialog, D, modify, Req, Res}, #{dialog := D} = St) ->
    srs_reinvite(Req, Res, St);
handle_info({chappe_sip_dialog, D, destroy, _}, #{dialog := D} = St) ->
    stop_with(srs_bye, St#{dialog := undefined});
handle_info({chappe_sip_dialog, _D, _Ev, _}, St) ->
    {noreply, St};
handle_info({chappe_sip_dialog, _D, _Ev, _Req, Res}, St) ->
    _ = chappe_sip_res:send(Res, 405),
    {noreply, St};
%% the call ended: its rtpengine session is gone
handle_info({'DOWN', Mon, process, _, _}, #{media_mon := Mon} = St) ->
    {stop, normal, stopped(ended(St), abandon(St#{media_mon := undefined}))};
handle_info({'DOWN', Mon, process, _, _}, #{owner_mon := Mon} = St) ->
    %% the owner is gone: nobody to tell; the BYE goes with the dialog
    {stop, normal, chappe_sip_siprec_tap:close(abandon(St))};
handle_info(Msg, St) ->
    logger:notice("chappe_sip_siprec: unexpected ~0P", [Msg, 20]),
    {noreply, St}.

%% what ended the recording when its media went: the call, or the room
ended(#{source := {room, _}}) -> room_ended;
ended(_St) -> call_ended.

%% a room recording ends with the room: its mixer is watched once the
%% recording's leg is in it
watch_room(#{source := {room, _}, media_mon := undefined} = St) ->
    St#{media_mon := chappe_sip_siprec_tap:watch(St)};
watch_room(St) ->
    St.

terminate(_Why, _St) ->
    ok.

%% an INVITE still out is cancelled; an established RS ends with the BYE
%% its dialog sends when this process exits (its owner)
abandon(#{uac := undefined} = St) ->
    St;
abandon(#{uac := Ref} = St) ->
    ok = chappe_sip_uac:abandon(Ref),
    St#{uac := undefined}.

rejected(#chappe_sip_error{status = Status}) when is_integer(Status) ->
    {rejected, Status};
rejected(timeout) ->
    {srs, timeout};
rejected(Why) ->
    {error, Why}.

%% RFC 7866 9.2: an UPDATE with a snapshot request is answered, then a
%% full snapshot goes in a re-INVITE (9.1: "MUST immediately")
srs_update(Req, Res, St) ->
    Body = chappe_sip_req:body(Req),
    case
        chappe_sip_siprec_meta:snapshot_request(
            chappe_sip_req:get(<<"content-type">>, Req), Body
        )
    of
        {ok, Reason} ->
            _ = chappe_sip_res:send(Res, 200),
            event(snapshot, #{reason => Reason}, St),
            case St of
                #{pending := undefined} -> reoffer(undefined, none, St);
                _ -> {noreply, St#{dirty := true}}
            end;
        no when Body =:= <<>> ->
            _ = chappe_sip_res:send(Res, 200),
            {noreply, St};
        no ->
            %% an offer from the SRS: the recorded streams stay as they are
            _ = chappe_sip_res:send(Res, 488),
            {noreply, St}
    end.

%% A re-INVITE of the SRS (RFC 7866 7.2: ready to record now, or a stream
%% it no longer takes): the recorded streams are answered as they are,
%% sendonly or, paused, inactive; its offer reaches rtpengine.
srs_reinvite(Req, Res, St) ->
    case chappe_sip_req:body(Req) of
        <<>> ->
            _ = chappe_sip_res:send(Res, 488),
            {noreply, St};
        Offer ->
            {_CT, Body} = chappe_sip_siprec_body:body(St),
            Sdp = chappe_sip_siprec_body:sdp_of(Body),
            _ = chappe_sip_res:send(Res, 200, #{
                body => chappe_sip_siprec_body:sdp_only(Sdp),
                headers => [{<<"Content-Type">>, <<"application/sdp">>}]
            }),
            _ = chappe_sip_siprec_tap:answer(Offer, St),
            {noreply, St}
    end.

%% ---- events ----

event(Ev, Extra, #{owner := Owner, call_ref := C, srs := Srs}) ->
    Owner !
        {?MODULE, self(),
            {Ev, maps:merge(#{call_ref => C, srs => Srs}, Extra)}},
    ok.

fail(Why, St) ->
    stop_with({error, Why}, St).

%% the end: the taps removed, the owner told
stop_with(Reason, St) ->
    {stop, normal, stopped(Reason, chappe_sip_siprec_tap:close(St))}.

stopped(Reason, St) ->
    event(stopped, #{reason => Reason}, St),
    St.
