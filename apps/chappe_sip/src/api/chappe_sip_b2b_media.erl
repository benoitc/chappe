%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The SDP path of a B2BUA call: the app's rewrite_sdp hook, then the
%% media anchor.
%%
%% Every offer and answer that crosses from one leg to the other goes
%% through offer/3 or answer/3 here. The hook sees the SDP as the leg sent
%% it; in anchor mode the result then goes through the call's rtpengine
%% session (chappe_sip_media), so the far leg sees rtpengine's address. In
%% direct mode the SDP passes as the hook left it. An offer whose streams
%% all stop receiving (RFC 3264 8.4) puts its leg on hold, and the notify
%% process, when there is one, gets {chappe_sip_b2b, Ref, {hold | unhold,
%% Leg}} on each change.
%%
%% rtpengine names the parties by tag: the caller is leg A's From tag, the
%% callee leg B's To tag, and an offer from B is a callee-initiated one.
%%
%% The branches of a fork may need different flags toward B (a browser
%% and a desk phone). fork_offer/3 then sends one rtpengine offer per
%% distinct set of flags, each under its own via-branch, and branch/2
%% points the state at a branch's flags before its answer goes through.
-module(chappe_sip_b2b_media).

-export([new/2, start/1, stop/1, mode/1, set_mode/2, session/1]).
-export([set_tag/3, offer/3, answer/3, final_answer/3, rejected/3, hook/1]).
-export([fork_offer/3, branch/2, unhold/2, b_flags/1, flags/2]).
-export([serve/1, call_opts/1, event/2]).

-export_type([state/0, mode/0, leg/0, profile/0]).

-type mode() :: direct | anchor.
-type leg() :: a | b.
-type state() :: #{
    mode := mode(),
    session := chappe_sip_media:session() | undefined,
    call_id := binary(),
    tags := #{leg() => binary() | undefined},
    webrtc := #{leg() => boolean()},
    hold := #{leg() => boolean()},
    rewrite := fun(
        (leg(), offer | answer, binary()) -> iodata() | {reject, 300..699}
    ),
    params := #{leg() => map()},
    notify := pid() | undefined,
    ref := reference(),
    call_ref := binary() | undefined,
    related := binary() | undefined,
    last := {leg(), binary() | undefined, binary(), binary()} | undefined,
    origin := leg() | undefined,
    via := binary() | undefined
}.
%% The media side of a fork branch: whether B is a WebRTC endpoint, the
%% anchor params of the call with the branch's over them, and the
%% via-branch of its rtpengine offer when the fork needed several.
-type profile() :: #{
    webrtc := boolean(),
    params := #{leg() => map()},
    via => binary() | undefined
}.

%% Init: #{mode, call_id, a_tag, b_webrtc, a_webrtc, ref, call_ref,
%% related} plus the app's Opts (rewrite_sdp, anchor_params, notify).
-spec new(map(), map()) -> state().
new(Init, Opts) ->
    #{
        mode => maps:get(mode, Init),
        session => undefined,
        call_id => maps:get(call_id, Init),
        tags => #{a => maps:get(a_tag, Init), b => undefined},
        webrtc => #{
            a => maps:get(a_webrtc, Init, false),
            b => maps:get(b_webrtc, Init, false)
        },
        hold => #{a => false, b => false},
        rewrite => hook(maps:get(rewrite_sdp, Opts, undefined)),
        params => maps:get(anchor_params, Opts, #{}),
        notify => maps:get(notify, Opts, undefined),
        ref => maps:get(ref, Init),
        call_ref => maps:get(call_ref, Init, undefined),
        related => maps:get(related, Init, undefined),
        last => undefined,
        origin => undefined,
        via => undefined
    }.

%% The calling process serves the call of M as its B2BUA, under the
%% b2b() handle of M's reference (chappe_sip_call).
-spec serve(state()) -> ok.
serve(#{call_ref := CallRef, ref := Ref}) ->
    chappe_sip_call:join(CallRef, b2b, {self(), Ref}).

%% The call_ref and related of M, as options of a new leg's UAC.
-spec call_opts(state()) -> map().
call_opts(M) ->
    maps:filter(
        fun(_K, V) -> V =/= undefined end, maps:with([call_ref, related], M)
    ).

%% The rewrite_sdp hook as a 3-arity fun: fun(Leg, offer | answer, Sdp),
%% the 2-arity fun(Leg, Sdp) of earlier releases, or none.
-spec hook(fun() | undefined) ->
    fun((leg(), offer | answer, binary()) -> term()).
hook(undefined) ->
    fun(_Leg, _Kind, Sdp) -> Sdp end;
hook(F) when is_function(F, 3) ->
    F;
hook(F) when is_function(F, 2) ->
    fun(Leg, _Kind, Sdp) -> F(Leg, Sdp) end.

%% Start the rtpengine session of an anchored call.
-spec start(state()) -> {ok, state()} | {error, term()}.
start(#{mode := anchor, session := undefined} = M) ->
    #{call_id := CallId, tags := #{a := ATag}} = M,
    Id = #{call_id => CallId, from_tag => ATag},
    case chappe_sip_media:session(Id, #{capability => anchor}) of
        {ok, S} ->
            %% the session is found by the call's ref while it lives
            _ =
                case chappe_sip_media:pid(S) of
                    Pid when is_pid(Pid) ->
                        chappe_sip_call:join(
                            maps:get(call_ref, M), media, S, Pid
                        );
                    undefined ->
                        ok
                end,
            {ok, M#{session := S, last := undefined, origin := undefined}};
        {error, _} = Err ->
            Err
    end;
start(M) ->
    {ok, M}.

%% Release the session: the call ended or went direct.
-spec stop(state()) -> state().
stop(#{session := undefined} = M) ->
    M;
stop(#{session := S} = M) ->
    try chappe_sip_media:stop(S) of
        _ -> ok
    catch
        exit:_ -> ok
    end,
    M#{session := undefined, last := undefined, origin := undefined}.

-spec mode(state()) -> mode().
mode(#{mode := Mode}) -> Mode.

-spec set_mode(mode(), state()) -> state().
set_mode(Mode, M) -> M#{mode := Mode}.

-spec session(state()) -> chappe_sip_media:session() | undefined.
session(#{session := S}) -> S.

%% Leg B's To tag, once B answers.
-spec set_tag(leg(), binary() | undefined, state()) -> state().
set_tag(_Leg, undefined, M) ->
    M;
set_tag(Leg, Tag, #{tags := Tags} = M) ->
    M#{tags := Tags#{Leg => Tag}}.

%% An offer from leg X on its way to the other leg.
-spec offer(leg(), binary(), state()) ->
    {ok, binary(), state()} | {reject, 300..699}.
offer(X, Sdp, M0) ->
    M = seen(X, Sdp, hold(X, Sdp, M0)),
    case run_hook(X, offer, Sdp, M) of
        {reject, _} = Rej -> Rej;
        Out -> anchor_offer(X, Out, M)
    end.

%% Leg Y's answer to the other leg's offer.
-spec answer(leg(), binary(), state()) ->
    {ok, binary(), state()} | {reject, 300..699}.
answer(Y, Sdp, M) ->
    answer(Y, Sdp, M, #{}).

answer(Y, Sdp, M0, Extra) ->
    M = seen(Y, Sdp, M0),
    case run_hook(Y, answer, Sdp, M) of
        {reject, _} = Rej -> Rej;
        Out -> anchor_answer(Y, Out, M, Extra)
    end.

%% The answer of the winning branch of a fork: anchored, rtpengine takes
%% it as the final one and deletes the other branches' to-tags (their
%% early media answers). The call's later answers carry no via-branch.
-spec final_answer(leg(), binary(), state()) ->
    {ok, binary(), state()} | {reject, 300..699}.
final_answer(Y, Sdp, M) ->
    case answer(Y, Sdp, M, #{final => true}) of
        {ok, Out, M1} -> {ok, Out, M1#{via := undefined}};
        Rej -> Rej
    end.

%% Point the state at a fork branch's profile: its answers go through
%% with its flags (and its via-branch), and once it wins the call keeps
%% them.
-spec branch(profile(), state()) -> state().
branch(P, #{webrtc := W} = M) ->
    M#{
        webrtc := W#{b := maps:get(webrtc, P)},
        params := maps:get(params, P),
        via := maps:get(via, P, undefined)
    }.

%% A's offer to the branches of a fork, one profile per branch. The hook
%% runs once; anchored, rtpengine gets one offer per distinct set of
%% flags toward B, under a via-branch of its own when there are several.
%% Returns, in the order of Profiles, each profile (with its via-branch)
%% and the SDP its branch gets. {reject, Code} when rtpengine took no offer,
%% {reject, Code, offered} when it took some of them before one failed.
-spec fork_offer(binary(), [profile(), ...], state()) ->
    {ok, [{profile(), binary()}], state()}
    | {reject, 300..699}
    | {reject, 300..699, offered}.
fork_offer(Sdp, [P0 | _] = Ps, M0) ->
    Keys = [toward(b, branch(P, M0)) || P <- Ps],
    case distinct(Keys) of
        [_, _ | _] = Distinct when map_get(mode, M0) =:= anchor, Sdp =/= <<>> ->
            M = seen(a, Sdp, hold(a, Sdp, M0)),
            case run_hook(a, offer, Sdp, M) of
                {reject, _} = Rej -> Rej;
                Out -> profile_offers(Out, Ps, Keys, Distinct, M)
            end;
        _ ->
            case offer(a, Sdp, branch(P0, M0)) of
                {ok, Out, M1} -> {ok, [{P, Out} || P <- Ps], M1};
                Rej -> Rej
            end
    end.

%% The flags rtpengine writes the SDP toward B with.
-spec b_flags(state()) -> map().
b_flags(M) -> toward(b, M).

%% The flags rtpengine writes the SDP toward Leg with.
-spec flags(leg(), state()) -> map().
flags(Leg, M) -> toward(Leg, M).

%% Leg now has another party behind it, which is not on hold.
-spec unhold(leg(), state()) -> state().
unhold(Leg, #{hold := H} = M) ->
    case maps:get(Leg, H) of
        true ->
            event({unhold, Leg}, M),
            M#{hold := H#{Leg => false}};
        false ->
            M
    end.

%% Leg Y refused the offer relayed to it: rtpengine already took that
%% offer, so give it back Y's last good SDP as the answer. Without it the
%% session stays half-open and the next offer fails (glare).
-spec rejected(leg(), binary(), state()) -> state().
rejected(_Y, _LastSdp, #{session := undefined} = M) ->
    M;
rejected(_Y, <<>>, M) ->
    M;
rejected(Y, LastSdp, #{session := S} = M) ->
    _ = chappe_sip_media:answer(S, LastSdp, answer_opts(Y, M)),
    M#{last := undefined}.

%% ---- internal ----

%% one rtpengine offer per distinct Key, the first one opening the
%% session's offer/answer exchange. Not on a call whose first offer was
%% B's (replace_b/3 after a late offer): rtpengine's caller is B there,
%% so A's offers are callee-initiated and have no via-branch form.
profile_offers(_Sdp, _Ps, _Keys, _Distinct, #{origin := b}) ->
    {reject, 488};
profile_offers(Sdp, Ps, Keys, Distinct, #{session := S} = M0) ->
    M = M0#{origin := a},
    Indexed = lists:zip(Distinct, lists:seq(1, length(Distinct))),
    Sent = lists:map(
        fun({Key, N}) ->
            Via = <<"chappe-", (integer_to_binary(N))/binary>>,
            Opts = (offer_opts(a, M))#{
                params => Key#{via_branch => Via}, branch => N > 1
            },
            {Key, Via, chappe_sip_media:offer(S, Sdp, Opts)}
        end,
        Indexed
    ),
    case
        {[Why || {_, _, {error, Why}} <- Sent], [ok || {_, _, {ok, _}} <- Sent]}
    of
        {[], _} ->
            ByKey = #{Key => {Via, Out} || {Key, Via, {ok, Out}} <- Sent},
            {ok,
                [
                    {P#{via => Via}, Out}
                 || {P, Key} <- lists:zip(Ps, Keys),
                    {Via, Out} <- [maps:get(Key, ByKey)]
                ],
                M#{last := undefined}};
        {[Why | _], []} ->
            logger:warning("chappe_sip_b2b: rtpengine offer failed: ~p", [Why]),
            {reject, 500};
        {[Why | _], _} ->
            logger:warning("chappe_sip_b2b: rtpengine offer failed: ~p", [Why]),
            {reject, 500, offered}
    end.

distinct(Keys) ->
    lists:reverse(
        lists:foldl(
            fun(K, Acc) ->
                case lists:member(K, Acc) of
                    true -> Acc;
                    false -> [K | Acc]
                end
            end,
            [],
            Keys
        )
    ).

run_hook(Leg, Kind, Sdp, #{rewrite := Rw}) ->
    case Rw(Leg, Kind, Sdp) of
        {reject, Code} when is_integer(Code), Code >= 300, Code =< 699 ->
            {reject, Code};
        Out ->
            iolist_to_binary(Out)
    end.

anchor_offer(_X, Sdp, #{mode := direct} = M) ->
    {ok, Sdp, M};
anchor_offer(_X, <<>>, M) ->
    {ok, <<>>, M};
anchor_offer(X, Sdp, #{session := S} = M0) ->
    %% the leg of the session's first offer is rtpengine's caller (B for a
    %% late offer)
    M =
        case M0 of
            #{origin := undefined} -> M0#{origin := X};
            _ -> M0
        end,
    case chappe_sip_media:offer(S, Sdp, offer_opts(X, M)) of
        {ok, Out} ->
            {ok, Out, M#{last := undefined}};
        {error, Why} ->
            logger:warning("chappe_sip_b2b: rtpengine offer failed: ~p", [Why]),
            {reject, 500}
    end.

%% Extra: rtpengine params on top (final => true prunes fork branches)
anchor_answer(_Y, Sdp, #{mode := direct} = M, _Extra) ->
    {ok, Sdp, M};
anchor_answer(_Y, <<>>, M, _Extra) ->
    {ok, <<>>, M};
anchor_answer(Y, Sdp, #{last := {Y, Via, Sdp, Out}, via := Via} = M, Extra) when
    map_size(Extra) =:= 0
->
    %% the same answer again (a 183's SDP repeated in the 2xx)
    {ok, Out, M};
anchor_answer(Y, Sdp, #{session := S} = M, Extra) ->
    #{params := P} = Opts = answer_opts(Y, M),
    case
        chappe_sip_media:answer(S, Sdp, Opts#{params := maps:merge(P, Extra)})
    of
        {ok, Out} ->
            {ok, Out, M#{last := {Y, maps:get(via, M), Sdp, Out}}};
        {error, Why} ->
            logger:warning("chappe_sip_b2b: rtpengine answer failed: ~p", [Why]),
            {reject, 500}
    end.

%% rtpengine's from-tag is the offering party's; an offer from the leg
%% that did not make the session's first offer is the callee's, which
%% swaps the stored tags
offer_opts(X, #{tags := Tags, origin := Origin} = M) ->
    Params = toward(other(X), M),
    #{
        from_tag => maps:get(X, Tags),
        params =>
            case X of
                Origin -> Params;
                _ -> Params#{initiator => callee}
            end
    }.

%% a fork branch's answer names the via-branch of its offer
answer_opts(Y, #{tags := Tags, via := Via} = M) ->
    Params = toward(other(Y), M),
    #{
        to_tag => maps:get(Y, Tags),
        params =>
            case Via of
                undefined -> Params;
                _ -> Params#{via_branch => Via}
            end
    }.

other(a) -> b;
other(b) -> a.

%% what rtpengine writes for the leg the SDP goes to: DTLS-SRTP with ICE
%% for a WebRTC leg, plain RTP without ICE otherwise; the app's
%% anchor_params for that leg go on top
toward(Leg, #{webrtc := W, params := P}) ->
    Base =
        case maps:get(Leg, W) of
            true ->
                #{
                    ice => force,
                    transport_protocol => <<"UDP/TLS/RTP/SAVPF">>,
                    rtcp_mux => [offer, require]
                };
            false ->
                #{
                    ice => remove,
                    transport_protocol => <<"RTP/AVP">>,
                    rtcp_mux => [demux]
                }
        end,
    maps:merge(Base, maps:get(Leg, P, #{})).

seen(_Leg, <<>>, M) ->
    M;
seen(Leg, Sdp, #{webrtc := W} = M) ->
    M#{webrtc := W#{Leg => chappe_sip_sdp:webrtc(Sdp)}}.

hold(_X, <<>>, M) ->
    M;
hold(X, Sdp, #{hold := H} = M) ->
    New = chappe_sip_sdp:on_hold(Sdp),
    case maps:get(X, H) of
        New ->
            M;
        _ ->
            event(
                case New of
                    true -> {hold, X};
                    false -> {unhold, X}
                end,
                M
            ),
            M#{hold := H#{X => New}}
    end.

%% Send Ev to the call's notify process, if any, as {chappe_sip_b2b, Ref,
%% Ev}.
-spec event(term(), state()) -> ok.
event(_Ev, #{notify := undefined}) ->
    ok;
event(Ev, #{notify := Pid, ref := Ref}) ->
    Pid ! {chappe_sip_b2b, Ref, Ev},
    ok.
