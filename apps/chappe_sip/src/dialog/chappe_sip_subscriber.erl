%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The subscriber side of SIP events (RFC 6665): one process per
%% subscription we hold.
%%
%% start/3 sends the SUBSCRIBE (through the UAC: digest, a proxy, a flow)
%% and the process keeps the subscription until it ends:
%%   - the dialog is formed from the 2xx or from the first NOTIFY, whichever
%%     comes first (a NOTIFY may beat the 2xx, 4.1.2.4); a NOTIFY from
%%     another To tag (a fork, 4.1.4) starts a subscription of its own;
%%   - it refreshes before expiry, the NOTIFY's expires being the
%%     authoritative duration (4.1.3), and unsubscribes with Expires: 0;
%%   - Timer N (64*T1) bounds the wait for a NOTIFY after each SUBSCRIBE;
%%   - a terminated NOTIFY ends it: deactivated and timeout re-subscribe at
%%     once, probation and giveup after their retry-after, rejected,
%%     noresource and invariant stop.
%% The owner gets {chappe_sip_subscription, Sub, Event}:
%%   {notify, Info}             each NOTIFY, once answered 200; Info has
%%                              state, expires, reason, retry_after,
%%                              content_type, body and the request (req)
%%   {forked, Sub2}             a NOTIFY from another fork: Sub2 is a
%%                              subscription of its own
%%   {retrying, Reason, Secs}   the subscription ended and a new SUBSCRIBE
%%                              (new Call-ID and From tag) goes out in Secs
%%   {terminated, Reason}       it is over and the process stops
%% NOTIFYs reach us out of any dialog of the engine: the NOTIFY router
%% (chappe_sip_notify_router) finds the subscription by Call-ID, our tag
%% and the peer's, and we check the Event.
-module(chappe_sip_subscriber).
-behaviour(gen_statem).

-include("chappe_sip.hrl").

-export([start/3, unsubscribe/1]).
-export([start_link/1]).
-export([init/1, callback_mode/0, handle_event/4, terminate/3]).
-export_type([subscription/0, reason/0]).

-define(TAB, chappe_sip_subscribers).
%% Timer N, 64*T1
-define(TIMER_N, 32000).
%% refresh failures that end the subscription (RFC 6665 4.1.2.2)
-define(ENDS_SUB(S),
    (S =:= 404 orelse S =:= 405 orelse S =:= 410 orelse S =:= 416 orelse
        (S >= 480 andalso S =< 485) orelse S =:= 489 orelse S =:= 501 orelse
        S =:= 604)
).

-type subscription() :: pid().
-type reason() ::
    deactivated
    | probation
    | rejected
    | timeout
    | giveup
    | noresource
    | invariant
    | binary()
    | undefined
    | unsubscribed
    | expired
    | timer_n
    | owner_down
    | {subscribe_failed, 300..699}
    | {refresh_failed, 300..699}
    | {error, term()}.

%% Start a subscription to Event (a package name, with an `;id=' when you
%% need one) at Uri for the calling process (or `owner'). Opts:
%%   expires          the duration asked for, s (default 3600)
%%   accept           [binary()] the body types you take (Accept)
%%   headers          extra headers on every SUBSCRIBE
%%   from, to, contact, proxy, route_set, auth, flow   as chappe_sip_uac
%%   owner            the pid told of the subscription (default self())
%%   timer_n          ms to wait for a NOTIFY after a SUBSCRIBE (32000)
%%   probation_retry  s before re-subscribing after probation with no
%%                    retry-after (default 60)
%%   forks            take a NOTIFY of another fork as a subscription of
%%                    its own (default true, false for presence: RFC 3856
%%                    6.9 keeps one dialog, the other fork gets 481)
%% A presence or message-summary subscription asks for its body type
%% (Accept) unless accept says otherwise, and its NOTIFY Info carries the
%% body parsed as doc (chappe_sip_pidf, chappe_sip_mwi).
-spec start(binary(), binary(), map()) ->
    {ok, subscription()} | {error, term()}.
start(Uri, Event, Opts) ->
    Owner = maps:get(owner, Opts, self()),
    chappe_sip_subscriber_sup:start_subscriber(#{
        uri => Uri, event => Event, opts => Opts, owner => Owner
    }).

%% Unsubscribe (SUBSCRIBE Expires: 0 in the dialog). The owner gets
%% {terminated, unsubscribed} once the final NOTIFY came, or Timer N
%% passed.
-spec unsubscribe(subscription()) -> ok.
unsubscribe(Sub) ->
    gen_statem:cast(Sub, unsubscribe).

start_link(Args) ->
    gen_statem:start_link(?MODULE, Args, []).

callback_mode() -> handle_event_function.

%% ---- init ----

init(#{owner := Owner, opts := Opts} = Args) ->
    D0 = #{
        uri => maps:get(uri, Args),
        event => maps:get(event, Args),
        opts => Opts,
        owner => Owner,
        owner_mon => erlang:monitor(process, Owner),
        dialog => undefined,
        uac => undefined,
        unsubscribing => false
    },
    case maps:get(fork, Args, undefined) of
        undefined ->
            new_subscription(D0);
        #{notify := {Req, Res}} = Fork ->
            %% a fork: the dialog the NOTIFY forms is ours
            D1 = D0#{
                call_id => maps:get(call_id, Fork),
                local_tag => maps:get(local_tag, Fork),
                from => maps:get(from, Fork),
                cseq => maps:get(cseq, Fork)
            },
            {ok, active, D1, [{next_event, internal, {notify, Req, Res}}]}
    end.

%% a new initial SUBSCRIBE: a fresh Call-ID and From tag (RFC 6665 4.1.2.2)
new_subscription(D0) ->
    Tag = chappe_sip_dialog:gen_tag(),
    CallId = <<
        (binary:encode_hex(crypto:strong_rand_bytes(8), lowercase))/binary,
        "@chappe"
    >>,
    D = D0#{
        call_id => CallId,
        local_tag => Tag,
        from => <<(from_base(D0))/binary, ";tag=", Tag/binary>>,
        cseq => 1,
        dialog => undefined
    },
    register_key({CallId, Tag, any}),
    case send_subscribe(initial, expires(D), D) of
        {ok, D1} ->
            {ok, notify_wait, D1, [timer_n(D1)]};
        {error, Reason} ->
            {stop, {subscribe_failed, Reason}}
    end.

%% ---- events ----

handle_event({call, From}, {notify, Req, Res}, _State, D) ->
    case same_event(Req, D) of
        true ->
            on_notify(From, Req, Res, D);
        false ->
            {keep_state_and_data, [{reply, From, pass}]}
    end;
handle_event(internal, {notify, Req, Res}, _State, D) ->
    on_notify(undefined, Req, Res, D);
handle_event(
    info, {chappe_sip_uac, Ref, Event}, State, #{uac := {Ref, Kind}} = D
) ->
    uac_event(Event, Kind, State, D);
handle_event(info, {chappe_sip_uac, _Ref, _Event}, _State, _D) ->
    keep_state_and_data;
handle_event({timeout, timer_n}, _, State, #{unsubscribing := true} = D) when
    State =/= retry_wait
->
    finish(unsubscribed, D);
handle_event({timeout, timer_n}, _, _State, D) ->
    %% no NOTIFY after our SUBSCRIBE (RFC 6665 4.1.2.2, 4.1.2.4)
    finish(timer_n, D);
handle_event({timeout, refresh}, _, active, D) ->
    case send_subscribe(refresh, expires(D), D) of
        {ok, D1} -> {keep_state, D1, [timer_n(D1)]};
        {error, Why} -> finish({error, Why}, D)
    end;
handle_event({timeout, expire}, _, _State, D) ->
    finish(expired, D);
handle_event({timeout, retry}, _, retry_wait, D) ->
    new_subscription_in(D);
handle_event({timeout, _}, _, _State, _D) ->
    keep_state_and_data;
handle_event(cast, unsubscribe, _State, D) ->
    do_unsubscribe(D);
handle_event(
    info, {'DOWN', MRef, process, _, _}, _State, #{owner_mon := MRef} = D
) ->
    %% nobody listens any more: end the subscription at the notifier too
    _ = do_unsubscribe(D),
    {stop, normal, D};
handle_event(_Type, _Msg, _State, _D) ->
    keep_state_and_data.

terminate(_Reason, _State, D) ->
    unregister_all(D),
    ok.

%% ---- NOTIFY ----

on_notify(From, Req, Res, D) ->
    Msg = chappe_sip_req:msg(Req),
    Remote = chappe_sip_msg:from_tag(Msg),
    case D of
        #{dialog := #{remote_tag := Tag}} when Tag =/= Remote ->
            case forks(D) of
                true ->
                    %% another fork answered: a subscription of its own
                    %% (4.1.4)
                    fork(From, Req, Res, D);
                false ->
                    %% one dialog per SUBSCRIBE for this package (RFC 3856
                    %% 6.9): the other fork's NOTIFY matches nothing
                    _ = chappe_sip_res:send(Res, 481, #{
                        reason => <<"Subscription Does Not Exist">>
                    }),
                    reply(From, handled),
                    keep_state_and_data
            end;
        _ ->
            notified(From, Req, Res, form_from_notify(Msg, D))
    end.

notified(From, Req, Res, D) ->
    case chappe_sip_hdr:subscription_state(sub_state_hdr(Req)) of
        {ok, SS} ->
            _ = chappe_sip_res:send(Res, 200, #{reason => <<"OK">>}),
            reply(From, handled),
            tell(D, {notify, notify_info(SS, Req)}),
            after_notify(SS, D);
        {error, _} ->
            %% RFC 6665 8.2.3: every NOTIFY carries Subscription-State
            _ = chappe_sip_res:send(Res, 400, #{
                reason => <<"Missing Subscription-State">>
            }),
            reply(From, handled),
            keep_state_and_data
    end.

after_notify(#{state := terminated}, #{unsubscribing := true} = D) ->
    finish(unsubscribed, D);
after_notify(
    #{state := terminated, reason := R}, #{opts := #{expires := 0}} = D
) ->
    %% a fetch (Expires: 0) ends with its one NOTIFY (RFC 6665 4.4.3)
    finish(reason(R), D);
after_notify(#{state := terminated, reason := R, retry_after := RA}, D) ->
    %% an expires on terminated means nothing (4.1.3)
    ended(reason(R), RA, D);
after_notify(#{expires := E}, D) when is_integer(E) ->
    %% the NOTIFY's expires is the authoritative duration (4.1.3)
    D1 = D#{expires_at => now_ms() + E * 1000},
    {next_state, active, D1, [cancel_n() | expiry_timers(D1)]};
after_notify(_SS, D) ->
    {next_state, active, D, [cancel_n()]}.

cancel_n() -> {{timeout, timer_n}, cancel}.

%% A terminated subscription: re-subscribe when the reason says so (4.1.3).
ended(Reason, _RetryAfter, D) when
    Reason =:= deactivated; Reason =:= timeout
->
    retry(Reason, 0, D);
ended(Reason, RetryAfter, D) when Reason =:= probation ->
    Default = maps:get(probation_retry, maps:get(opts, D), 60),
    retry(Reason, default(RetryAfter, Default), D);
ended(Reason, RetryAfter, D) when Reason =:= giveup ->
    retry(Reason, default(RetryAfter, 0), D);
ended(Reason, _RetryAfter, D) when
    Reason =:= rejected; Reason =:= noresource; Reason =:= invariant
->
    finish(Reason, D);
ended(Reason, RetryAfter, D) when is_integer(RetryAfter) ->
    %% no reason or an unknown one: not before retry-after
    retry(Reason, RetryAfter, D);
ended(Reason, undefined, D) ->
    finish(Reason, D).

default(undefined, Default) -> Default;
default(V, _Default) -> V.

retry(Reason, Secs, D) ->
    unregister_all(D),
    tell(D, {retrying, Reason, Secs}),
    {next_state, retry_wait, D#{dialog := undefined, uac := undefined}, [
        cancel_n(),
        {{timeout, refresh}, cancel},
        {{timeout, expire}, cancel},
        {{timeout, retry}, Secs * 1000, go}
    ]}.

new_subscription_in(D) ->
    case new_subscription(D) of
        {ok, State, D1, Actions} -> {next_state, State, D1, Actions};
        {stop, Why} -> finish({error, Why}, D)
    end.

%% a NOTIFY from a tag of another fork starts that subscription's process
fork(From, Req, Res, D) ->
    Args = #{
        uri => maps:get(uri, D),
        event => maps:get(event, D),
        opts => maps:get(opts, D),
        owner => maps:get(owner, D),
        fork => #{
            notify => {Req, Res},
            call_id => maps:get(call_id, D),
            local_tag => maps:get(local_tag, D),
            from => maps:get(from, D),
            cseq => maps:get(cseq, D)
        }
    },
    case chappe_sip_subscriber_sup:start_subscriber(Args) of
        {ok, Pid} ->
            tell(D, {forked, Pid}),
            reply(From, handled);
        {error, _} ->
            reply(From, pass)
    end,
    keep_state_and_data.

%% The dialog is the one of the first NOTIFY or 2xx (RFC 6665 4.4.1): the
%% peer's tag and Contact, and as route set the NOTIFY's Record-Route as
%% received, or the 2xx's reversed.
form_from_notify(Msg, D) ->
    RR = chappe_sip_msg:get_all(<<"record-route">>, Msg),
    form(Msg, <<"from">>, chappe_sip_msg:from_tag(Msg), RR, D).

form_from_2xx(Msg, D) ->
    RR = lists:reverse(chappe_sip_msg:get_all(<<"record-route">>, Msg)),
    form(Msg, <<"to">>, chappe_sip_msg:to_tag(Msg), RR, D).

form(Msg, Peer, Tag, RouteSet, #{dialog := undefined} = D) ->
    register_key({maps:get(call_id, D), maps:get(local_tag, D), Tag}),
    D#{
        dialog := #{
            remote_tag => Tag,
            remote_addr => chappe_sip_msg:get(Peer, Msg),
            target => contact_uri(Msg, Peer),
            route_set => RouteSet
        }
    };
form(_Msg, _Peer, _Tag, _RouteSet, D) ->
    D.

notify_info(SS, Req) ->
    CT = chappe_sip_req:get(<<"content-type">>, Req),
    Body = chappe_sip_req:body(Req),
    Info = SS#{content_type => CT, body => Body, req => Req},
    case doc(base_type(CT), Body) of
        {ok, Doc} -> Info#{doc => Doc};
        _ -> Info
    end.

%% the bodies of the packages chappe knows, parsed: a PIDF (RFC 3863), a
%% message summary (RFC 3842)
doc(_CT, <<>>) ->
    none;
doc(<<"application/pidf+xml">>, Body) ->
    chappe_sip_pidf:parse(Body);
doc(<<"application/simple-message-summary">>, Body) ->
    chappe_sip_mwi:parse(Body);
doc(_CT, _Body) ->
    none.

base_type(undefined) -> undefined;
base_type(CT) -> string:lowercase(string:trim(hd(binary:split(CT, <<";">>)))).

%% ---- SUBSCRIBE transactions ----

uac_event({request_sent, _}, _Kind, _State, _D) ->
    keep_state_and_data;
uac_event({provisional, _}, _Kind, _State, _D) ->
    keep_state_and_data;
uac_event({response, Msg}, Kind, _State, D0) ->
    D = (seen_cseq(Msg, D0))#{uac := undefined},
    case Kind of
        unsubscribe ->
            {keep_state, D};
        _ ->
            D1 = form_from_2xx(Msg, D),
            granted(Msg, D1)
    end;
uac_event(
    {error, #chappe_sip_error{status = S, response = Msg}}, Kind, _State, D0
) ->
    D = (seen_cseq(Msg, D0))#{uac := undefined},
    failed(Kind, S, D);
uac_event({error, Why}, Kind, _State, D) ->
    failed(Kind, Why, D#{uac := undefined}).

%% the 2xx's Expires is the duration granted (RFC 6665 3.1.1)
granted(Msg, D) ->
    Secs =
        case chappe_sip_msg:get(<<"expires">>, Msg) of
            undefined -> expires(D);
            V -> to_int(V, expires(D))
        end,
    D1 = D#{expires_at => now_ms() + Secs * 1000},
    {keep_state, D1, expiry_timers(D1)}.

failed(unsubscribe, _Why, D) ->
    finish(unsubscribed, D);
failed(initial, S, D) when is_integer(S) ->
    finish({subscribe_failed, S}, D);
failed(refresh, S, D) when is_integer(S), ?ENDS_SUB(S) ->
    finish({refresh_failed, S}, D);
failed(refresh, _S, D) ->
    %% the subscription stands until its last known expiry (4.1.2.2)
    {keep_state, D, [cancel_n()]};
failed(_Kind, Why, D) ->
    finish({error, Why}, D).

do_unsubscribe(#{dialog := undefined} = D) ->
    finish(unsubscribed, D);
do_unsubscribe(#{unsubscribing := true}) ->
    keep_state_and_data;
do_unsubscribe(D) ->
    case send_subscribe(unsubscribe, 0, D#{unsubscribing := true}) of
        {ok, D1} ->
            {keep_state, D1, [
                timer_n(D1),
                {{timeout, refresh}, cancel},
                {{timeout, expire}, cancel}
            ]};
        {error, _} ->
            finish(unsubscribed, D)
    end.

%% one SUBSCRIBE through the UAC: the initial one outside any dialog,
%% a refresh or the unsubscribe in it
send_subscribe(Kind, Expires, D) ->
    Opts = maps:get(opts, D),
    Seq =
        case Kind of
            initial -> 1;
            _ -> maps:get(cseq, D) + 1
        end,
    {Uri, Dialog} =
        case maps:get(dialog, D) of
            undefined ->
                {maps:get(uri, D), #{}};
            #{target := T, remote_addr := RA, route_set := RS} ->
                {T, #{to => RA, route_set => RS}}
        end,
    Base = maps:with([to, contact, proxy, route_set, auth, flow], Opts),
    UacOpts = maps:merge(Base, Dialog#{
        method => <<"SUBSCRIBE">>,
        call_id => maps:get(call_id, D),
        cseq => Seq,
        from => maps:get(from, D),
        headers => subscribe_headers(Expires, D),
        notify => self(),
        owner => self()
    }),
    case chappe_sip_uac:start(Uri, UacOpts) of
        {ok, Ref} ->
            {ok, D#{uac := {Ref, Kind}, cseq := Seq}};
        {error, _} = Err ->
            Err
    end.

subscribe_headers(Expires, D) ->
    Opts = maps:get(opts, D),
    Accept =
        case maps:get(accept, Opts, default_accept(D)) of
            [] ->
                [];
            Types ->
                [{<<"Accept">>, iolist_to_binary(lists:join(<<", ">>, Types))}]
        end,
    [
        {<<"Event">>, maps:get(event, D)},
        {<<"Expires">>, integer_to_binary(Expires)}
    ] ++ Accept ++ maps:get(headers, Opts, []).

%% the CSeq the UAC ended on (a digest retry takes the next one)
seen_cseq(undefined, D) ->
    D;
seen_cseq(Msg, D) ->
    case chappe_sip_msg:cseq(Msg) of
        {ok, #{seq := N}} -> D#{cseq := max(N, maps:get(cseq, D))};
        _ -> D
    end.

%% ---- timers ----

timer_n(D) ->
    {{timeout, timer_n}, maps:get(timer_n, maps:get(opts, D), ?TIMER_N), go}.

%% refresh a little before the expiry: a third early, at most 32 s
expiry_timers(#{expires_at := At}) ->
    Left = max(0, At - now_ms()),
    Margin = min(Left div 3, 32000),
    [
        {{timeout, refresh}, Left - Margin, go},
        {{timeout, expire}, Left, go}
    ].

expires(D) ->
    maps:get(expires, maps:get(opts, D), 3600).

%% ---- the end ----

finish(Reason, D) ->
    unregister_all(D),
    tell(D, {terminated, Reason}),
    {stop, normal, D}.

tell(#{owner := Owner}, Event) ->
    Owner ! {chappe_sip_subscription, self(), Event},
    ok.

reply(undefined, _Msg) -> ok;
reply(From, Msg) -> gen_statem:reply(From, Msg).

%% ---- registry ----

register_key(Key) ->
    true = ets:insert(?TAB, {Key, self()}),
    put({?MODULE, keys}, [Key | my_keys()]),
    ok.

unregister_all(_D) ->
    _ = [ets:delete_object(?TAB, {K, self()}) || K <- my_keys()],
    put({?MODULE, keys}, []),
    ok.

my_keys() ->
    case get({?MODULE, keys}) of
        undefined -> [];
        Ks -> Ks
    end.

%% ---- helpers ----

%% RFC 3856 6.5: a presence Accept names application/pidf+xml
default_accept(D) ->
    case package(D) of
        <<"presence">> -> [chappe_sip_pidf:content_type()];
        <<"message-summary">> -> [chappe_sip_mwi:content_type()];
        _ -> []
    end.

%% RFC 3856 6.9: presence makes one dialog per SUBSCRIBE; other packages
%% take every fork (option forks)
forks(#{opts := #{forks := F}}) -> F;
forks(D) -> package(D) =/= <<"presence">>.

package(D) ->
    case chappe_sip_hdr:event(maps:get(event, D)) of
        {ok, #{type := T}} -> T;
        _ -> undefined
    end.

%% RFC 6665 8.2.1: the NOTIFY names our package and our id
same_event(Req, D) ->
    case
        {
            chappe_sip_hdr:event(chappe_sip_req:get(<<"event">>, Req)),
            chappe_sip_hdr:event(maps:get(event, D))
        }
    of
        {{ok, #{type := T, id := I}}, {ok, #{type := T, id := I}}} ->
            true;
        _ ->
            false
    end.

sub_state_hdr(Req) ->
    chappe_sip_req:get(<<"subscription-state">>, Req).

reason(undefined) -> undefined;
reason(<<"deactivated">>) -> deactivated;
reason(<<"probation">>) -> probation;
reason(<<"rejected">>) -> rejected;
reason(<<"timeout">>) -> timeout;
reason(<<"giveup">>) -> giveup;
reason(<<"noresource">>) -> noresource;
reason(<<"invariant">>) -> invariant;
reason(Other) -> Other.

contact_uri(Msg, Fallback) ->
    Hdr =
        case chappe_sip_msg:get(<<"contact">>, Msg) of
            undefined -> chappe_sip_msg:get(Fallback, Msg);
            C -> C
        end,
    case chappe_sip_hdr:name_addr(Hdr) of
        {ok, #{uri := Uri}} -> Uri;
        _ -> Hdr
    end.

from_base(#{opts := #{from := From}}) ->
    hd(binary:split(From, <<";tag=">>));
from_base(_D) ->
    Uri =
        case chappe_sip_engine:contact() of
            undefined ->
                <<"sip:anonymous.invalid">>;
            C ->
                case chappe_sip_hdr:name_addr(C) of
                    {ok, #{uri := U}} -> U;
                    _ -> C
                end
        end,
    <<"<", (hd(binary:split(Uri, <<";">>)))/binary, ">">>.

to_int(V, Default) ->
    try binary_to_integer(string:trim(V)) of
        N when N >= 0 -> N;
        _ -> Default
    catch
        error:badarg -> Default
    end.

now_ms() -> erlang:monotonic_time(millisecond).
