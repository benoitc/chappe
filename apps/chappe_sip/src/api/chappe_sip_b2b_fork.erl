%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The B-leg branches of a B2BUA call while B rings.
%%
%% A serial attempt has one branch; a {parallel, Uris} target has one per
%% URI, each its own UAC, all relayed to A under one To-tag. This module
%% keeps what each branch sent (its first SDP and its 2xx), picks the
%% winner (the first 2xx: the other branches are CANCELled, and a 2xx of
%% theirs that still comes is ACKed and BYEd by their UAC), and when every
%% branch failed, the best final (RFC 3261 16.7 step 6, shared with
%% chappe_sip_proxy through chappe_sip_proxy_rules:best_response/1). A
%% target that could not be called counts as a 503 (16.9). A 6xx ends the
%% fork at once (16.7 step 5). It also resolves a target into its URIs
%% and ends a call whose B leg failed for good (fail/2, which honours
%% pass_failure).
-module(chappe_sip_b2b_fork).

-include("chappe_sip.hrl").

-export([start/3, branch/0, sdp/3, answer/3, won/3, cancel/2, failed/3]).
-export([targets/2, ringing/1, failover/1, fail/2]).

%% RFC 3326 Reason on the CANCEL of a fork's other branches
-define(ELSEWHERE, <<"SIP;cause=200;text=\"Call completed elsewhere\"">>).

%% Ring every URI with BOpts. {wait, W} while a branch rings, {failed,
%% Error, W} when none could be called.
-spec start([binary()], map(), map()) ->
    {wait, map()} | {failed, term(), map()}.
start(Uris, BOpts, W0) ->
    {Branches, Finals} = lists:foldl(
        fun(Uri, {Bs, Fs}) ->
            case chappe_sip_uac:start(Uri, BOpts) of
                {ok, BRef} -> {Bs#{BRef => branch()}, Fs};
                {error, Why} -> {Bs, [Why | Fs]}
            end
        end,
        {#{}, []},
        Uris
    ),
    W = W0#{
        bref => undefined,
        branches => Branches,
        rest => [],
        finals => lists:reverse(Finals)
    },
    case map_size(Branches) of
        0 -> {failed, best(W), W};
        _ -> {wait, W}
    end.

%% what each branch keeps: the first SDP it sent and its 2xx
-spec branch() -> map().
branch() -> #{b_sdp => <<>>, answer => undefined}.

%% The first SDP of the call (any branch) and of the branch.
-spec sdp(term(), chappe_sip_msg:msg(), map()) -> map().
sdp(BRef, BMsg, #{branches := Bs} = W0) ->
    Sdp = chappe_sip_msg:body(BMsg),
    W =
        case W0 of
            #{b_sdp := <<>>} -> W0#{b_sdp := Sdp};
            _ -> W0
        end,
    case maps:get(BRef, Bs) of
        #{b_sdp := <<>>} = B -> W#{branches := Bs#{BRef := B#{b_sdp := Sdp}}};
        _ -> W
    end.

%% The 2xx of a branch (report_answer), for the headers A's 2xx copies.
-spec answer(term(), chappe_sip_msg:msg(), map()) -> map().
answer(BRef, BMsg, #{branches := Bs} = W) ->
    W#{branches := Bs#{BRef := (maps:get(BRef, Bs))#{answer := BMsg}}}.

%% BRef answered first: it is the call's B leg, the others are given up.
-spec won(term(), chappe_sip_dialog:dialog(), map()) -> map().
won(BRef, BDialog, #{branches := Bs} = W) ->
    #{answer := Answer, b_sdp := Sdp} = maps:get(BRef, Bs),
    abandon(maps:keys(maps:remove(BRef, Bs)), [{<<"Reason">>, ?ELSEWHERE}]),
    W#{
        bref := BRef,
        branches := maps:with([BRef], Bs),
        ready := BDialog,
        answer := Answer,
        b_sdp :=
            case Sdp of
                <<>> -> maps:get(b_sdp, W);
                _ -> Sdp
            end
    }.

%% CANCEL every branch still ringing (A's CANCEL, Timer C), with Hdrs.
-spec cancel(map(), [{binary(), iodata()}]) -> ok.
cancel(#{branches := Bs}, Hdrs) ->
    abandon(maps:keys(Bs), Hdrs).

%% Branch BRef failed with Error: {wait, W} while others ring, else
%% {failed, Best, W}.
-spec failed(term(), term(), map()) ->
    {wait, map()} | {failed, term(), map()}.
failed(BRef, Error, #{branches := Bs0, finals := Fs} = W0) ->
    Bs = maps:remove(BRef, Bs0),
    W = W0#{branches := Bs, finals := Fs ++ [Error]},
    case {status(Error), map_size(Bs)} of
        {St, _} when St >= 600 ->
            abandon(maps:keys(Bs), []),
            {failed, best(W), W#{branches := #{}}};
        {_, 0} ->
            {failed, best(W), W};
        _ ->
            {wait, W}
    end.

%% Where B goes: {serial, Uris} tried in turn, or {parallel, Uris}.
-spec targets(chappe_sip_b2b:target(), map()) ->
    {serial | parallel, [binary()]}.
targets({peer_group, Group}, Opts) ->
    {serial,
        chappe_sip_peers:candidates(
            Group, maps:get(peer_policy, Opts, priority)
        )};
targets({parallel, Uris}, _Opts) when is_list(Uris) ->
    {parallel, Uris};
targets(Uri, _Opts) when is_binary(Uri) ->
    {serial, [Uri]};
targets(Uris, _Opts) when is_list(Uris) ->
    {serial, Uris}.

%% The state of a new ringing attempt.
-spec ringing(map()) -> map().
ringing(#{timer_c := TimerC} = W) ->
    W#{
        deadline => erlang:monotonic_time(millisecond) + TimerC,
        answer => undefined,
        %% the first SDP B answered with (a 183's or the 2xx's)
        b_sdp => <<>>,
        ready => undefined,
        bearly => undefined
    }.

%% A list or a peer group moves on after 408, 503 or a failure below
%% SIP (RFC 3263 4.3).
-spec failover(term()) -> boolean().
failover(#chappe_sip_error{status = St}) -> St =:= 408 orelse St =:= 503;
failover(_Other) -> true.

%% The B leg failed for good: A gets the failure (unless pass_failure is
%% false) and the call's media is released.
-spec fail(term(), map()) -> {error, term()}.
fail(Error, #{res := Res, opts := Opts, media := M}) ->
    _ = chappe_sip_b2b_media:stop(M),
    handle_b_failure(Res, Error, Opts).

%% pass_failure => false: A is not answered, the app may try elsewhere
handle_b_failure(Res, Error, Opts) ->
    _ =
        maps:get(pass_failure, Opts, true) andalso
            send_failure(Res, Error),
    case Error of
        #chappe_sip_error{status = Status, reason = Reason} ->
            {error, #chappe_sip_error{status = Status, reason = Reason}};
        Other ->
            {error, Other}
    end.

send_failure(Res, #chappe_sip_error{status = Status, reason = Reason}) ->
    chappe_sip_res:send(Res, Status, #{reason => Reason});
send_failure(Res, _Other) ->
    %% the B leg failed below the SIP layer (a bad target, engine down, ...)
    chappe_sip_res:send(Res, 500, #{reason => <<"Server Internal Error">>}).

%% ---- internal ----

%% give up on these branches; what they already sent us is dropped
abandon(BRefs, Hdrs) ->
    lists:foreach(
        fun(BRef) ->
            ok = chappe_sip_uac:abandon(BRef, #{headers => Hdrs}),
            flush(BRef)
        end,
        BRefs
    ).

flush(BRef) ->
    receive
        {chappe_sip_uac, BRef, {ok, D}} ->
            _ = spawn(fun() -> chappe_sip_b2b:destroy_quietly(D, []) end),
            flush(BRef);
        {chappe_sip_uac, BRef, _} ->
            flush(BRef)
    after 0 ->
        ok
    end.

%% the best of the finals; failures below SIP alone stay as they are
best(#{finals := Finals}) ->
    case [E || #chappe_sip_error{} = E <- Finals] of
        [] ->
            hd(Finals);
        _ ->
            {Status, _} = chappe_sip_proxy_rules:best_response(
                [{status(E), undefined} || E <- Finals]
            ),
            error_of(Status, Finals)
    end.

status(#chappe_sip_error{status = St}) -> St;
status(_Other) -> 503.

error_of(Status, Finals) ->
    case [E || #chappe_sip_error{status = St} = E <- Finals, St =:= Status] of
        [E | _] ->
            E;
        [] ->
            %% best_response turned a 503 into a 500
            #chappe_sip_error{
                status = Status, reason = <<"Server Internal Error">>
            }
    end.
