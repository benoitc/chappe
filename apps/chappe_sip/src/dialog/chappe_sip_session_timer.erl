%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Session timer negotiation (RFC 4028), pure functions.
%%
%% The dialog fsm holds the negotiated state (st()) and arms two timers
%% from it: a refresh at half the interval when this side is the refresher,
%% and an expiry at interval - min(32, interval/3) seconds (section 10) at
%% which it sends a BYE. The UAS answer, the UAC request headers and 2xx
%% processing, and in-dialog refreshes are decided here.
%%
%% Settings come from the call opts, else the stack config:
%%   session_expires   (opt) / session_expires   (config): undefined
%%   min_se            (opt) / session_min_se    (config): 90
%%   session_refresher (opt) / session_refresher (config): uac
%% session_expires unset means this side never asks for a timer; it still
%% answers one the peer asks for. min_se is the smallest interval accepted
%% (a shorter one with Supported: timer gets 422); RFC 4028 section 5 puts
%% it at 90 at least, a lower value is for tests only.
-module(chappe_sip_session_timer).

-export([config/1, uas/2, supported/1, uac_headers/2, uac_answer/3]).
-export([refresh_headers/1, incoming/3, response/3]).
-export([timeouts/1, retry_after_422/2]).

-export_type([st/0, cfg/0]).

%% interval: seconds; refresher: which side of the dialog refreshes;
%% min_se: the largest Min-SE learned on the dialog (422s and peer
%% requests), 0 if none; peer_update: the peer listed UPDATE in Allow.
-type st() :: #{
    interval := pos_integer(),
    refresher := local | remote,
    min_se := non_neg_integer(),
    peer_update := boolean()
}.

-type cfg() :: #{
    expires := pos_integer() | undefined,
    min_se := pos_integer(),
    refresher := uac | uas
}.

-spec config(map()) -> cfg().
config(Opts) ->
    #{
        expires => maps:get(
            session_expires, Opts, chappe_sip_config:get(session_expires)
        ),
        min_se => maps:get(min_se, Opts, chappe_sip_config:get(session_min_se)),
        refresher => maps:get(
            session_refresher,
            Opts,
            chappe_sip_config:get(session_refresher)
        )
    }.

%% ---- UAS: the answer to an initial INVITE (section 9) ----

%% {reject, MinSE}: answer 422 with Min-SE; {ok, Headers, St}: add Headers
%% to the 2xx and run St (undefined: no session timer).
-spec uas(chappe_sip_msg:msg(), cfg()) ->
    {reject, pos_integer()} | {ok, [{binary(), binary()}], st() | undefined}.
uas(Msg, Cfg) ->
    negotiate(Msg, Cfg, undefined).

%% The same rules for an in-dialog INVITE or UPDATE: the request refreshes
%% the session and the 2xx carries the new interval. With a running timer
%% and no Session-Expires in the request, the timer carries on at its
%% interval (keeping the roles when the peer supports timers, else with us
%% refreshing).
-spec incoming(chappe_sip_msg:msg(), cfg(), st() | undefined) ->
    {reject, pos_integer()} | {ok, [{binary(), binary()}], st() | undefined}.
incoming(Msg, Cfg, Cur) ->
    negotiate(Msg, Cfg, Cur).

negotiate(Msg, #{min_se := LocalMin} = Cfg, Cur) ->
    Supported = supports_timer(Msg),
    ReqMin = min_se(Msg),
    Update = allows_update(Msg),
    case parse_se(chappe_sip_msg:get(<<"session-expires">>, Msg)) of
        {V, _} when Supported, V < LocalMin ->
            {reject, LocalMin};
        {V, Param} ->
            Floor = max(LocalMin, ReqMin),
            Interval =
                case maps:get(expires, Cfg) of
                    undefined -> V;
                    Mine -> min(V, max(Mine, Floor))
                end,
            Refresher = uas_refresher(Supported, Param, Cfg, Cur),
            answer(Interval, Refresher, Supported, ReqMin, Update, Cur);
        undefined when Cur =/= undefined ->
            #{interval := I, refresher := Role} = Cur,
            Refresher =
                case Supported of
                    true -> role_param(Role, uas);
                    false -> uas
                end,
            answer(I, Refresher, Supported, ReqMin, Update, Cur);
        undefined ->
            case {Supported, maps:get(expires, Cfg)} of
                {true, Mine} when is_integer(Mine) ->
                    Interval = max(Mine, ReqMin),
                    Refresher = maps:get(refresher, Cfg),
                    answer(Interval, Refresher, true, ReqMin, Update, Cur);
                _ ->
                    {ok, [], undefined}
            end
    end.

%% Table 2: a UAC without timer support never refreshes; one with it keeps
%% its choice, else the UAS picks (the running roles, or the config).
uas_refresher(false, _Param, _Cfg, _Cur) ->
    uas;
uas_refresher(true, uac, _Cfg, _Cur) ->
    uac;
uas_refresher(true, uas, _Cfg, _Cur) ->
    uas;
uas_refresher(true, undefined, _Cfg, #{refresher := Role}) ->
    role_param(Role, uas);
uas_refresher(true, undefined, #{refresher := R}, undefined) ->
    R.

answer(Interval, Refresher, Supported, ReqMin, Update, Cur) ->
    %% refresher=uac needs Require: timer (MUST); refresher=uas SHOULD
    %% carry it when the UAC supports timers
    Headers =
        [{<<"Session-Expires">>, se_value(Interval, Refresher)}] ++
            [{<<"Require">>, <<"timer">>} || Supported],
    St = #{
        interval => Interval,
        refresher => from_param(Refresher, uas),
        min_se => max(ReqMin, prev_min(Cur)),
        peer_update => Update orelse prev_update(Cur)
    },
    {ok, Headers, St}.

prev_min(#{min_se := M}) -> M;
prev_min(_) -> 0.

prev_update(#{peer_update := U}) -> U;
prev_update(_) -> false.

%% ---- UAC: an initial INVITE and its 2xx (section 7) ----

%% 7.1: every request but ACK lists timer in Supported, whether or not it
%% asks for a timer; nothing to add when Headers already list it.
-spec supported([{binary(), iodata()}]) -> [{binary(), binary()}].
supported(Headers) ->
    Listed = [
        T
     || {N, V} <- Headers,
        lower(N) =:= <<"supported">> orelse lower(N) =:= <<"k">>,
        T0 <- binary:split(iolist_to_binary(V), <<",">>, [global]),
        T <- [lower(T0)]
    ],
    case lists:member(<<"timer">>, Listed) of
        true -> [];
        false -> [{<<"Supported">>, <<"timer">>}]
    end.

%% An initial INVITE: Session-Expires only when configured, raised to the
%% largest Min-SE from a 422 (7.4), which also goes out as Min-SE. The
%% refresher param only when the caller set session_refresher.
-spec uac_headers(map(), non_neg_integer()) -> [{binary(), binary()}].
uac_headers(Opts, MinSE422) ->
    Cfg = config(Opts),
    case maps:get(expires, Cfg) of
        undefined ->
            [];
        Mine ->
            Value =
                case maps:get(session_refresher, Opts, undefined) of
                    undefined -> integer_to_binary(max(Mine, MinSE422));
                    R -> se_value(max(Mine, MinSE422), R)
                end,
            [{<<"Session-Expires">>, Value}] ++
                min_se_header(MinSE422)
    end.

%% The session timer a 2xx to our INVITE sets up. Requested is the interval
%% we asked for (undefined if none): a 2xx without Session-Expires then
%% leaves us refreshing at our own value (7.2).
-spec uac_answer(
    chappe_sip_msg:msg(), pos_integer() | undefined, non_neg_integer()
) -> st() | undefined.
uac_answer(Msg, Requested, MinSE) ->
    Update = allows_update(Msg),
    case parse_se(chappe_sip_msg:get(<<"session-expires">>, Msg)) of
        {V, Param} ->
            #{
                interval => V,
                refresher => from_param(default_uac(Param), uac),
                min_se => MinSE,
                peer_update => Update
            };
        undefined when is_integer(Requested) ->
            #{
                interval => Requested,
                refresher => local,
                min_se => MinSE,
                peer_update => Update
            };
        undefined ->
            undefined
    end.

default_uac(undefined) -> uac;
default_uac(P) -> P.

%% ---- in-dialog refreshes we send (7.4, 10) ----

%% Headers of an in-dialog INVITE or UPDATE: Session-Expires at
%% max(Min-SE, interval) with the running roles, Min-SE once learned.
-spec refresh_headers(st() | undefined) -> [{binary(), binary()}].
refresh_headers(undefined) ->
    [];
refresh_headers(#{interval := I, refresher := Role, min_se := M}) ->
    [{<<"Session-Expires">>, se_value(max(I, M), role_param(Role, uac))}] ++
        min_se_header(M).

%% The state after a final response to our in-dialog INVITE or UPDATE:
%% only a 2xx changes it (section 10).
-spec response(chappe_sip_msg:msg(), 100..699, st() | undefined) ->
    st() | undefined.
response(Msg, Status, Cur) when Status >= 200, Status < 300 ->
    case Cur of
        undefined ->
            uac_answer(Msg, undefined, 0);
        #{interval := I, min_se := M, peer_update := U} ->
            case uac_answer(Msg, max(I, M), M) of
                #{} = St ->
                    St#{peer_update := U orelse maps:get(peer_update, St)};
                undefined ->
                    undefined
            end
    end;
response(_Msg, _Status, Cur) ->
    Cur.

%% After a 422 to a refresh: the Min-SE it names, when that is larger than
%% what we sent (a retry would otherwise repeat the same error).
-spec retry_after_422(chappe_sip_msg:msg(), st()) ->
    {retry, st()} | give_up.
retry_after_422(Msg, #{interval := I, min_se := M} = St) ->
    New = min_se(Msg),
    case New > max(I, M) of
        true -> {retry, St#{min_se := New}};
        false -> give_up
    end.

%% ---- timers (section 10) ----

%% generic timeouts for the fsm: refresh at half the interval when we
%% refresh, BYE at interval - min(32, interval/3) seconds either way
-spec timeouts(st() | undefined) -> [tuple()].
timeouts(undefined) ->
    cancel_timeouts();
timeouts(#{interval := I, refresher := Role}) ->
    Ms = I * 1000,
    Refresh =
        case Role of
            local -> {{timeout, st_refresh}, Ms div 2, refresh};
            remote -> {{timeout, st_refresh}, infinity, refresh}
        end,
    [Refresh, {{timeout, st_expire}, Ms - min(32000, Ms div 3), expire}].

-spec cancel_timeouts() -> [tuple()].
cancel_timeouts() ->
    [
        {{timeout, st_refresh}, infinity, refresh},
        {{timeout, st_expire}, infinity, expire}
    ].

%% ---- header parsing ----

%% "1800;refresher=uac" -> {1800, uac}; undefined when absent or malformed
-spec parse_se(binary() | undefined) ->
    {pos_integer(), uac | uas | undefined} | undefined.
parse_se(undefined) ->
    undefined;
parse_se(Value) ->
    [Delta | Params] = binary:split(Value, <<";">>, [global]),
    case chappe_sip_lib:to_int(Delta, undefined) of
        N when is_integer(N), N > 0 -> {N, refresher_param(Params)};
        _ -> undefined
    end.

refresher_param([]) ->
    undefined;
refresher_param([P | Rest]) ->
    case binary:split(P, <<"=">>) of
        [K, V] ->
            case {lower(K), lower(V)} of
                {<<"refresher">>, <<"uac">>} -> uac;
                {<<"refresher">>, <<"uas">>} -> uas;
                _ -> refresher_param(Rest)
            end;
        _ ->
            refresher_param(Rest)
    end.

-spec supports_timer(chappe_sip_msg:msg()) -> boolean().
supports_timer(Msg) ->
    lists:member(<<"timer">>, chappe_sip_msg:option_tags(<<"supported">>, Msg)).

-spec allows_update(chappe_sip_msg:msg()) -> boolean().
allows_update(Msg) ->
    lists:member(<<"update">>, chappe_sip_msg:option_tags(<<"allow">>, Msg)).

%% the Min-SE of a request or 422, 0 when absent
-spec min_se(chappe_sip_msg:msg()) -> non_neg_integer().
min_se(Msg) ->
    case chappe_sip_msg:get(<<"min-se">>, Msg) of
        undefined ->
            0;
        V ->
            [Delta | _] = binary:split(V, <<";">>),
            chappe_sip_lib:delta_seconds(Delta, 0)
    end.

min_se_header(0) -> [];
min_se_header(M) -> [{<<"Min-SE">>, integer_to_binary(M)}].

se_value(Interval, Refresher) ->
    <<
        (integer_to_binary(Interval))/binary,
        ";refresher=",
        (atom_to_binary(Refresher))/binary
    >>.

%% a role on the wire is named from the transaction's side: the sender of
%% the request is the uac, its receiver the uas
role_param(local, Us) -> Us;
role_param(remote, uac) -> uas;
role_param(remote, uas) -> uac.

from_param(Us, Us) -> local;
from_param(_, _) -> remote.

lower(B) -> chappe_sip_lib:lower(chappe_sip_lib:trim(B)).
