%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The engine's dispatch policy for an out-of-dialog request, as pure
%% functions of the request and of what the engine holds: the routes, the
%% event packages and their events, the merge index and the proxied
%% transactions. chappe_sip_engine keeps the state and the sends; this
%% module decides.
%%
%% - stray_in_dialog/2: a request that names a dialog we do not have (481).
%% - route_for/4: the handler of a request and the key of its route
%%   options, a 489 for an event package nobody serves, or none.
%% - bad_event/3: a SUBSCRIBE for a package not served (489) or for refer
%%   out of dialog (403).
%% - unrouted/3: what to answer a request no handler takes, or noreply.
%% - merge_check/4, merge_key/1: RFC 3261 8.2.2.2 merged requests.
%% - allow_value/2, allow_events/2, event_package/1, top_branch/1.
%% - is_own_route/2: a request loose-routed back to us after we
%%   record-routed its dialog.
-module(chappe_sip_dispatch).

-include("chappe_sip.hrl").

-export([stray_in_dialog/2, route_for/4, bad_event/3, unrouted/3]).
-export([unhandled/3, event_header/1]).
-export([merge_check/4, merge_key/1, top_branch/1]).
-export([allow_value/2, allow_events/2, event_package/1, is_own_route/2]).

-export_type([packages/0, events/0, merge/0, route_key/0]).

%% the handler of each event package a SUBSCRIBE may name, lowercase
-type packages() :: #{binary() => fun()}.
%% the events the SUBSCRIBE handler serves: a list, any, or undefined when
%% it was not registered
-type events() :: [binary()] | any | undefined.
%% {From-tag, Call-ID, CSeq, method} => {top Via branch, TxnH, worker}
-type merge() :: #{tuple() => {binary(), non_neg_integer(), pid()}}.
-type route_key() :: binary() | {package, binary()}.

%% the methods chappe_sip recognises; any other is answered 501
-define(KNOWN_METHODS, [
    <<"INVITE">>,
    <<"ACK">>,
    <<"CANCEL">>,
    <<"BYE">>,
    <<"OPTIONS">>,
    <<"REGISTER">>,
    <<"INFO">>,
    <<"UPDATE">>,
    <<"PRACK">>,
    <<"REFER">>,
    <<"SUBSCRIBE">>,
    <<"NOTIFY">>,
    <<"MESSAGE">>,
    <<"PUBLISH">>
]).

%% A BYE, or a request tagged for a dialog, reaching the default leg names
%% no dialog of ours. A NOTIFY is left to its handler: the application runs
%% its own subscriptions, and their NOTIFYs carry our tag.
-spec stray_in_dialog(binary(), binary()) -> boolean().
stray_in_dialog(Method, _Raw) when
    Method =:= <<"ACK">>; Method =:= <<"CANCEL">>; Method =:= <<"NOTIFY">>
->
    false;
stray_in_dialog(<<"BYE">>, _Raw) ->
    true;
stray_in_dialog(_Method, Raw) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, Msg} -> chappe_sip_msg:to_tag(Msg) =/= undefined;
        {error, _} -> false
    end.

%% The handler of a request: its method's, the built-in NOTIFY router
%% (subscriptions of ours, REFERs we sent, then yours), or for a SUBSCRIBE
%% the one of its event package. Key names the route options.
-spec route_for(binary(), binary(), #{binary() => fun()}, {
    packages(), events()
}) ->
    {fun(), route_key()} | {bad_event, any | [binary()]} | none.
route_for(<<"NOTIFY">> = M, _Raw, Routes, _Events) ->
    {chappe_sip_notify_router:handler(maps:get(M, Routes, undefined)), M};
route_for(<<"SUBSCRIBE">> = M, Raw, Routes, {Pkgs, Events}) ->
    Pkg = event_package(Raw),
    case {Pkgs, Routes} of
        {#{Pkg := Fun}, _} when Pkg =/= <<"refer">> ->
            {Fun, {package, Pkg}};
        {_, #{M := Handler}} ->
            {Handler, M};
        _ when map_size(Pkgs) > 0 ->
            {bad_event, allow_events(Pkgs, Events)};
        _ ->
            none
    end;
route_for(Method, _Raw, Routes, _Events) ->
    case Routes of
        #{Method := Handler} -> {Handler, Method};
        _ -> none
    end.

%% A SUBSCRIBE for a package the notifier does not serve, or with no Event
%% (the PINT default, never served), is answered 489 with the packages it
%% does serve (RFC 6665 4.2.1.1, 7.2.1, 8.3.2). An out-of-dialog SUBSCRIBE
%% for refer is refused 403.
-spec bad_event(binary(), binary(), {packages(), events()}) ->
    false | refer | {true, [binary()]}.
bad_event(<<"SUBSCRIBE">>, Raw, {Pkgs, Events}) ->
    case {event_package(Raw), allow_events(Pkgs, Events)} of
        {<<"refer">>, _} ->
            %% a refer subscription exists only inside its REFER's dialog:
            %% out of dialog it matches none (RFC 3515 2.4.4)
            refer;
        {_, any} ->
            false;
        {Pkg, Allowed} ->
            case lists:member(Pkg, Allowed) of
                true -> false;
                false -> {true, Allowed}
            end
    end;
bad_event(_Method, _Raw, _Events) ->
    false.

%% The answer to a request no handler takes: none to an ACK; 481 to a
%% CANCEL, since nta answers those that match one of our transactions and
%% this one matches none (RFC 3261 9.2); else unhandled/3.
-spec unrouted(binary(), #{binary() => fun()}, {packages(), events()}) ->
    {100..699, binary(), [{binary(), iodata()}]} | noreply.
unrouted(<<"ACK">>, _Routes, _Events) ->
    noreply;
unrouted(<<"CANCEL">>, _Routes, _Events) ->
    {481, <<"Call/Transaction Does Not Exist">>, []};
unrouted(Method, Routes, Events) ->
    unhandled(Method, Routes, Events).

%% No handler for the method. OPTIONS is answered 200 with what we take,
%% as every UA must (RFC 3261 11); a method we know gets 405 and one we do
%% not 501 (21.4.5, 21.5.2), both with Allow.
-spec unhandled(binary(), #{binary() => fun()}, {packages(), events()}) ->
    {100..699, binary(), [{binary(), iodata()}]}.
unhandled(<<"OPTIONS">>, Routes, {Pkgs, Events}) ->
    AllowEvents =
        case allow_events(Pkgs, Events) of
            any -> [];
            [] -> [];
            Served -> [event_header(Served)]
        end,
    {200, <<"OK">>,
        [
            {<<"Allow">>, allow_value(Routes, Pkgs)},
            {<<"Accept">>, <<"application/sdp">>},
            {<<"Supported">>, ?SUPPORTED}
        ] ++ AllowEvents};
unhandled(Method, Routes, {Pkgs, _Events}) ->
    Allow = [{<<"Allow">>, allow_value(Routes, Pkgs)}],
    case lists:member(Method, ?KNOWN_METHODS) of
        true -> {405, <<"Method Not Allowed">>, Allow};
        false -> {501, <<"Not Implemented">>, Allow}
    end.

%% the Allow-Events header listing the packages served
-spec event_header([binary()]) -> {binary(), binary()}.
event_header(Events) ->
    {<<"Allow-Events">>, iolist_to_binary(lists:join(<<", ">>, Events))}.

%% The event packages we serve: those registered with a handler of their
%% own and those the SUBSCRIBE handler serves (chappe_sip:subscribe/2), or
%% `any' when that handler was registered without a list (or none serves
%% any).
-spec allow_events(packages(), events()) -> any | [binary()].
allow_events(Packages, Events) ->
    Pkgs = lists:sort(maps:keys(Packages)),
    case {Events, Pkgs} of
        {any, _} -> any;
        {undefined, []} -> any;
        {undefined, _} -> Pkgs;
        {_, _} -> lists:usort(Events ++ Pkgs)
    end.

%% the package of a request's Event header, lowercase
-spec event_package(binary()) -> binary() | undefined.
event_package(Raw) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, Msg} -> package_of(chappe_sip_msg:get(<<"event">>, Msg));
        _ -> undefined
    end.

package_of(undefined) ->
    undefined;
package_of(Ev) ->
    [Pkg | _] = binary:split(Ev, <<";">>),
    string:lowercase(string:trim(Pkg)).

%% RFC 3261 8.2.2.2: a request with no To-tag whose From-tag, Call-ID and
%% CSeq match a transaction in progress but whose branch differs reached us
%% twice (a fork upstream): merged, 482. When that transaction is proxied
%% the request is a spiral through us (16.3) and goes on. The engine
%% checks native transactions only: the stack keys the WS ones by flow.
-spec merge_check(binary(), binary(), merge(), #{non_neg_integer() => pid()}) ->
    none | merged | {tuple(), binary()}.
merge_check(Method, _Raw, _Idx, _Px) when
    Method =:= <<"ACK">>; Method =:= <<"CANCEL">>
->
    none;
merge_check(_Method, Raw, Idx, Px) ->
    case merge_key(Raw) of
        none -> none;
        {Key, Branch} -> merged(Key, Branch, Idx, Px)
    end.

merged(Key, Branch, Idx, Px) ->
    case Idx of
        #{Key := {B, T, _}} when B =/= Branch ->
            case maps:is_key(T, Px) of
                true -> {Key, Branch};
                false -> merged
            end;
        _ ->
            {Key, Branch}
    end.

%% the merge key of a request with no To-tag, and its top Via branch
-spec merge_key(binary()) -> none | {tuple(), binary()}.
merge_key(Raw) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, Msg} -> merge_key_of(Msg);
        {error, _} -> none
    end.

merge_key_of(Msg) ->
    case
        {
            chappe_sip_msg:to_tag(Msg),
            chappe_sip_msg:from_tag(Msg),
            chappe_sip_msg:cseq(Msg),
            top_branch(Msg)
        }
    of
        {undefined, FT, {ok, #{seq := N, method := M}}, Branch} when
            is_binary(FT), is_binary(Branch)
        ->
            {{FT, chappe_sip_msg:call_id(Msg), N, M}, Branch};
        _ ->
            none
    end.

%% the branch of a message's top Via
-spec top_branch(chappe_sip_msg:msg()) -> binary() | undefined.
top_branch(Msg) ->
    case chappe_sip_msg:get(<<"via">>, Msg) of
        undefined ->
            undefined;
        V ->
            [Top | _] = chappe_sip_hdr:split_list(V) ++ [V],
            case chappe_sip_hdr:via(Top) of
                {ok, #{params := #{<<"branch">> := B}}} when is_binary(B) -> B;
                _ -> undefined
            end
    end.

%% the methods we take out of dialog: those with a handler, plus the ones
%% the stack answers itself (ACK, CANCEL, BYE in a dialog, OPTIONS)
-spec allow_value(#{binary() => fun()}, packages()) -> binary().
allow_value(Routes, Pkgs) ->
    Packages = [<<"SUBSCRIBE">> || map_size(Pkgs) > 0],
    Methods = lists:usort(
        maps:keys(Routes) ++ Packages ++
            [<<"ACK">>, <<"BYE">>, <<"CANCEL">>, <<"OPTIONS">>, <<"NOTIFY">>]
    ),
    iolist_to_binary(lists:join(<<", ">>, Methods)).

%% True when the top Route header targets this proxy (a request the far end
%% loose-routed back to us after we record-routed the dialog). Gated on a
%% cheap byte scan so requests without a Route header skip the parse.
-spec is_own_route(binary(), binary() | undefined) -> boolean().
is_own_route(Raw, Contact) ->
    case binary:match(Raw, <<"espx=">>) of
        nomatch ->
            false;
        _ ->
            case chappe_sip_msg:parse(Raw) of
                {ok, Msg} -> top_is_self(Msg, Contact);
                {error, _} -> false
            end
    end.

top_is_self(Msg, Contact) ->
    CallId = chappe_sip_msg:call_id(Msg),
    case chappe_sip_route:routes(Msg) of
        [Top | _] ->
            chappe_sip_route:is_self(Top, Contact, CallId) orelse
                %% behind a strict router our Record-Route is the
                %% Request-URI (RFC 3261 16.4)
                chappe_sip_route:uri_is_self(chappe_sip_msg:uri(Msg), CallId);
        [] ->
            false
    end.
