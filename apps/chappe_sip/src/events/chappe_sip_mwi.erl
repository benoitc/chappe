%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Message waiting (RFC 3842): the simple-message-summary body and a
%% notifier for the message-summary package.
%%
%% A summary is a map:
%%   #{waiting => boolean(),               Messages-Waiting (default: any
%%                                         new message)
%%     account => binary(),                Message-Account
%%     messages => #{Class => {New, Old} | {New, Old, NewUrgent, OldUrgent}}}
%% Class is voice, fax, pager, multimedia, text or none (the message
%% context classes of RFC 3458). Counts are capped at 2^32-1 both ways.
%%
%% serve/1 registers the message-summary SUBSCRIBE handler: the first
%% NOTIFY carries what your summary fun says for the account (the
%% Request-URI's address-of-record), and update/2 sends a new summary to
%% every subscriber of an account, never more than once a second to one of
%% them (RFC 3842 3.11).
%%
%% Across nodes: the notifier of each node joins the chappe_sip_mwi group
%% of the chappe_sip pg scope, and update/2 reaches the subscribers of
%% every node, whichever node took the SUBSCRIBE. It is a lookup, not an
%% owner: no lease, and it works without chappe_cluster. Each update
%% carries a version (a hybrid logical clock stamp, chappe_sip_hlc, then
%% the node and a counter), and a notifier keeps the latest it saw, so
%% updates made at once on two nodes end the same on both, and an update
%% made after another one was seen wins, whatever the nodes' wall clocks
%% say.
-module(chappe_sip_mwi).

-export([render/1, parse/1, content_type/0]).
-export([serve/1, update/2, body/3, group/0]).
-export_type([summary/0]).

-define(N, chappe_sip_mwi_notifier).
-define(PKG, <<"message-summary">>).
-define(CT, <<"application/simple-message-summary">>).
-define(MAX, 4294967295).

-type class() :: voice | fax | pager | multimedia | text | none.
-type counts() ::
    {non_neg_integer(), non_neg_integer()}
    | {
        non_neg_integer(),
        non_neg_integer(),
        non_neg_integer(),
        non_neg_integer()
    }.
-type summary() :: #{
    waiting => boolean(),
    account => binary(),
    messages => #{class() => counts()}
}.

-spec content_type() -> binary().
content_type() -> ?CT.

%% ---- the body ----

-spec render(summary()) -> binary().
render(S) ->
    Msgs = maps:get(messages, S, #{}),
    Waiting = maps:get(waiting, S, any_new(Msgs)),
    iolist_to_binary([
        <<"Messages-Waiting: ">>,
        yes_no(Waiting),
        <<"\r\n">>,
        case maps:get(account, S, undefined) of
            %% RFC 3842 3.5: the account URI without angle brackets
            undefined -> <<>>;
            A -> [<<"Message-Account: ">>, strip_angle(A), <<"\r\n">>]
        end,
        [
            summary_line(C, maps:get(C, Msgs))
         || C <- classes(), is_map_key(C, Msgs)
        ]
    ]).

any_new(Msgs) ->
    lists:any(fun(C) -> element(1, C) > 0 end, maps:values(Msgs)).

yes_no(true) -> <<"yes">>;
yes_no(false) -> <<"no">>.

summary_line(Class, {New, Old}) ->
    [header(Class), <<": ">>, n(New), <<"/">>, n(Old), <<"\r\n">>];
summary_line(Class, {New, Old, NewU, OldU}) ->
    [
        header(Class),
        <<": ">>,
        n(New),
        <<"/">>,
        n(Old),
        <<" (">>,
        n(NewU),
        <<"/">>,
        n(OldU),
        <<")\r\n">>
    ].

%% RFC 3842 3.5: never more than 2^32-1
n(N) -> integer_to_binary(min(N, ?MAX)).

classes() -> [voice, fax, pager, multimedia, text, none].

header(voice) -> <<"Voice-Message">>;
header(fax) -> <<"Fax-Message">>;
header(pager) -> <<"Pager-Message">>;
header(multimedia) -> <<"Multimedia-Message">>;
header(text) -> <<"Text-Message">>;
header(none) -> <<"None">>.

strip_angle(<<"<", Rest/binary>>) -> hd(binary:split(Rest, <<">">>));
strip_angle(A) -> A.

%% The summary a simple-message-summary body states; lines it does not
%% know are skipped.
-spec parse(binary()) -> {ok, summary()} | {error, no_status}.
parse(Body) ->
    Lines = binary:split(Body, [<<"\r\n">>, <<"\n">>], [global, trim_all]),
    S = lists:foldl(fun line/2, #{messages => #{}}, Lines),
    case maps:is_key(waiting, S) of
        true -> {ok, S};
        false -> {error, no_status}
    end.

line(Line, S) ->
    case binary:split(Line, <<":">>) of
        [Name, Value] ->
            field(string:lowercase(string:trim(Name)), string:trim(Value), S);
        _ ->
            S
    end.

field(<<"messages-waiting">>, V, S) ->
    S#{waiting => string:lowercase(V) =:= <<"yes">>};
field(<<"message-account">>, V, S) ->
    S#{account => strip_angle(V)};
field(Name, V, #{messages := M} = S) ->
    case class(Name) of
        undefined ->
            S;
        Class ->
            case counts(V) of
                {ok, C} -> S#{messages := M#{Class => C}};
                error -> S
            end
    end.

class(<<"voice-message">>) -> voice;
class(<<"fax-message">>) -> fax;
class(<<"pager-message">>) -> pager;
class(<<"multimedia-message">>) -> multimedia;
class(<<"text-message">>) -> text;
class(<<"none">>) -> none;
class(_) -> undefined.

counts(V) ->
    case
        re:run(V, "^([0-9]+)/([0-9]+)(?:\\s*\\(([0-9]+)/([0-9]+)\\))?", [
            {capture, all_but_first, binary}
        ])
    of
        {match, [N, O]} -> {ok, {cap(N), cap(O)}};
        {match, [N, O, NU, OU]} -> {ok, {cap(N), cap(O), cap(NU), cap(OU)}};
        nomatch -> error
    end.

%% RFC 3842 3.5: a larger value is 2^32-1
cap(B) -> min(binary_to_integer(B), ?MAX).

%% ---- the notifier ----

%% Opts:
%%   summary := fun((Account) -> summary())   the current summary of an
%%       account (its address-of-record), for a new subscription
%%   authorize => fun((Subscriber, Account, Req) -> boolean())  (default:
%%       anyone authenticated)
%%   auth => #{realm, secret}   digest on SUBSCRIBE (RFC 3842 3.7)
%%   expires (3600), min_expires (60)
-spec serve(#{summary := fun(), _ => _}) -> ok.
serve(#{summary := Summary} = Opts) when is_function(Summary, 1) ->
    chappe_sip_engine:handle(
        <<"SUBSCRIBE">>,
        fun(Req, Res) ->
            subscribe(Req, Res, Opts)
        end,
        #{package => ?PKG}
    ).

%% Account's summary changed: its subscribers get it, on every node.
-spec update(binary(), summary()) -> ok.
update(Account, Summary) ->
    Key = chappe_sip_esc:resource(Account),
    %% this node's clock now, moved past the update the notifier last
    %% took for the account when that one is not before it (an update
    %% seen from a node whose wall clock runs ahead); then the node and a
    %% counter. The later update wins on every node, whichever arrives
    %% last
    Here = node(),
    Stamp = chappe_sip_hlc:now(),
    N = erlang:unique_integer([monotonic]),
    Next = fun(Last) ->
        {chappe_sip_hlc:later(Stamp, stamp(Last)), Here, N}
    end,
    {ok, Version} = chappe_sip_notifier:put_next(?N, Key, Summary, Next),
    _ = [
        chappe_sip_notifier:put_async(P, Key, Summary, Version)
     || P <- pg:get_members(chappe_sip_call:scope(), group()),
        node(P) =/= Here
    ],
    ok.

stamp({Stamp, _Node, _N}) -> Stamp;
stamp(_) -> undefined.

%% The pg group (chappe_sip scope) of the message-summary notifiers.
-spec group() -> atom().
group() -> chappe_sip_mwi.

%% chappe_sip_notifier callback
-spec body(binary(), atom(), term()) -> {binary(), binary()}.
body(Account, _WState, Summary) when is_map(Summary) ->
    %% RFC 3842 3.8: the account goes in every NOTIFY
    {?CT, render(Summary#{account => maps:get(account, Summary, Account)})};
body(Account, _WState, _None) ->
    {?CT, render(#{account => Account, waiting => false})}.

subscribe(Req, Res, Opts) ->
    case chappe_sip_esc:authenticate(maps:get(auth, Opts, undefined), Req) of
        {ok, User} ->
            Account = chappe_sip_esc:resource(chappe_sip_req:uri(Req)),
            Authorize = maps:get(authorize, Opts, fun(_, _, _) -> true end),
            case Authorize(User, Account, Req) of
                true -> accept(Req, Res, Account, Opts);
                false -> reply(Res, 403, [])
            end;
        {reject, Status, Hdrs} ->
            reply(Res, Status, Hdrs)
    end.

accept(Req, Res, Account, #{summary := Summary} = Opts) ->
    case accepts(chappe_sip_req:get_all(<<"accept">>, Req)) of
        false ->
            reply(Res, 406, [{<<"Accept">>, ?CT}]);
        true ->
            UasOpts = #{
                owner => whereis(?N),
                expires => maps:get(expires, Opts, 3600),
                min_expires => maps:get(min_expires, Opts, 60)
            },
            case chappe_sip_dialog:create_uas(Req, Res, UasOpts) of
                {ok, Dialog} ->
                    %% RFC 3842 3.8: the current summary at once
                    _ =
                        chappe_sip_notifier:get(?N, Account) =:= undefined andalso
                            chappe_sip_notifier:put(
                                ?N, Account, Summary(Account)
                            ),
                    Fetch =
                        chappe_sip_subscription:requested_expires(Req, 1) =:= 0,
                    chappe_sip_notifier:add(?N, Dialog, Account, active, Fetch);
                {error, _} ->
                    ok
            end
    end.

%% RFC 3842 3.5: no Accept means ours
accepts([]) ->
    true;
accepts(Values) ->
    Types = [
        string:lowercase(string:trim(hd(binary:split(T, <<";">>))))
     || V <- Values, T <- binary:split(V, <<",">>, [global])
    ],
    lists:any(
        fun(T) -> lists:member(T, [?CT, <<"*/*">>, <<"application/*">>]) end,
        Types
    ).

reply(Res, Status, Hdrs) ->
    _ = chappe_sip_res:send(Res, Status, #{headers => Hdrs}),
    ok.
