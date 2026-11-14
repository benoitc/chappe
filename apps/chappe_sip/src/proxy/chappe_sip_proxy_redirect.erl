%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The proxy's per-branch options and its recursion on 3xx (RFC 3261
%% 16.7 step 4), as pure functions chappe_sip_proxy calls.
%%
%% follow_redirects bounds what a single request can fan out to: every
%% 3xx of one transaction adds at most max_targets targets together, a
%% target comes from at most max_depth 3xx, each URI joins the target set
%% once (16.5), and the app's allow policy sees each one first.
-module(chappe_sip_proxy_redirect).

-export([check_opts/1, follow/1, recurse/3]).
-export_type([follow/0, state/0]).

%% defaults, and the hard caps whatever the app asks for
-define(MAX_TARGETS, 5).
-define(MAX_DEPTH, 2).
-define(CAP_TARGETS, 32).
-define(CAP_DEPTH, 8).

-type follow() :: #{
    max_targets := non_neg_integer(),
    max_depth := pos_integer(),
    allow := fun((binary()) -> boolean())
}.
%% what the transaction knows when a 3xx arrives
-type state() :: #{
    follow := follow(),
    tried := [binary()],
    added := non_neg_integer(),
    closed := boolean(),
    sips := boolean(),
    depth := non_neg_integer()
}.

%% provisional_timeout, final_timeout and follow_redirects, checked before
%% anything is sent
-spec check_opts(map()) -> ok | {error, {badarg, atom()}}.
check_opts(Opts) ->
    Bad = [
        K
     || {K, Ok} <- [
            {provisional_timeout, fun is_ms/1},
            {final_timeout, fun is_ms/1},
            {follow_redirects, fun is_follow/1}
        ],
        V <- [maps:get(K, Opts, undefined)],
        V =/= undefined,
        not Ok(V)
    ],
    case Bad of
        [] -> ok;
        [K | _] -> {error, {badarg, K}}
    end.

is_ms(T) -> is_integer(T) andalso T > 0.

is_follow(B) when is_boolean(B) ->
    true;
is_follow(#{} = F) ->
    lists:all(fun follow_opt/1, maps:to_list(F));
is_follow(_) ->
    false.

follow_opt({max_targets, N}) ->
    is_integer(N) andalso N >= 0 andalso N =< ?CAP_TARGETS;
follow_opt({max_depth, N}) ->
    is_integer(N) andalso N > 0 andalso N =< ?CAP_DEPTH;
follow_opt({allow, Fun}) ->
    is_function(Fun, 1);
follow_opt(_) ->
    false.

%% follow_redirects as a transaction uses it (undefined: off)
-spec follow(map()) -> follow() | undefined.
follow(Opts) ->
    case maps:get(follow_redirects, Opts, false) of
        false ->
            undefined;
        true ->
            follow(Opts#{follow_redirects => #{}});
        #{} = F ->
            #{
                max_targets => maps:get(max_targets, F, ?MAX_TARGETS),
                max_depth => maps:get(max_depth, F, ?MAX_DEPTH),
                allow => maps:get(allow, F, fun(_) -> true end)
            }
    end.

%% The targets a 3xx adds, in q order, and what stays of it as a
%% candidate final: the response unchanged when none is taken, nothing
%% when all its Contacts are, else the response with the Contacts left
%% (16.7 step 4: the Contacts recursed on leave it). A SIPS request never
%% recurses to a SIP URI. The allow fun runs in the caller (the request
%% worker); a crash or an answer other than true refuses the URI.
-spec recurse(state(), binary(), chappe_sip_msg:msg()) ->
    {[binary()], [binary()]}.
recurse(St, Raw, M) ->
    #{
        follow := #{max_targets := Max, max_depth := MaxDepth, allow := Allow},
        tried := Tried,
        added := Added,
        closed := Closed,
        sips := Sips,
        depth := Depth
    } = St,
    {Taken, _} = lists:foldl(
        fun({Uri, V}, {Acc, N}) ->
            case
                not Closed andalso N < Max andalso Depth < MaxDepth andalso
                    not lists:member(Uri, Tried) andalso
                    (not Sips orelse chappe_sip_uri:is_sips(Uri)) andalso
                    allowed(Allow, Uri)
            of
                true -> {[{Uri, V} | Acc], N + 1};
                false -> {Acc, N}
            end
        end,
        {[], Added},
        chappe_sip_route:redirect_targets(M)
    ),
    Left = [
        V
     || H <- chappe_sip_msg:get_all(<<"contact">>, M),
        V <- chappe_sip_hdr:split_list(H),
        not lists:keymember(V, 2, Taken)
    ],
    Final =
        case {Taken, Left} of
            {[], _} -> [Raw];
            {_, []} -> [];
            {_, _} -> [with_contacts(M, Left)]
        end,
    {[U || {U, _} <- lists:reverse(Taken)], Final}.

allowed(Allow, Uri) ->
    try Allow(Uri) of
        true -> true;
        _ -> false
    catch
        _:_ -> false
    end.

with_contacts(M, Contacts) ->
    M1 = chappe_sip_msg:prepend(
        <<"Contact">>,
        iolist_to_binary(lists:join(<<", ">>, Contacts)),
        chappe_sip_msg:remove(<<"contact">>, M)
    ),
    iolist_to_binary(chappe_sip_msg:encode(M1)).
