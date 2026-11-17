%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The notifier side of one RFC 6665 subscription, as the dialog fsm
%% (chappe_sip_dialog_fsm) of the SUBSCRIBE dialog keeps it: a map of its
%% event, expiry, bounds and state, and pure functions over it. The fsm
%% sends; this module says when the subscription expires, what a refresh
%% grants, and what its NOTIFYs carry, the final one of its teardown
%% included.
-module(chappe_sip_subscription).

-export([new/2, timer/1, requested_expires/2, same_event/2]).
-export([unsubscribed/1, refreshed/2]).
-export([final_notify/3, state_value/3, keep_body/2, event_header/1]).

-export_type([sub/0]).

%% event, expires_at and granted_at (monotonic ms), max and min (s), grace
%% (ms), state, contact, term_reason, keep_body and last_body
-type sub() :: #{atom() => term()}.

%% The subscription of a SUBSCRIBE dialog from its create_uas option, or
%% undefined for any other dialog. Contact is the one our 2xx carried.
-spec new(map() | undefined, binary() | undefined) -> sub() | undefined.
new(undefined, _Contact) ->
    undefined;
new(#{expires := Expires} = Opts, Contact) ->
    Grace = maps:get(unsubscribe_grace, Opts, 5000),
    #{
        event => maps:get(event, Opts, undefined),
        %% Expires: 0 on the initial SUBSCRIBE is a fetch: the owner has the
        %% unsubscribe grace to send its one terminated NOTIFY
        expires_at => now_ms() + expiry_ms(Expires, Grace),
        granted_at => now_ms() + Expires * 1000,
        max => maps:get(max, Opts, Expires),
        min => maps:get(min, Opts, 0),
        grace => Grace,
        state => active,
        contact => Contact,
        term_reason => terminated,
        keep_body => maps:get(keep_body, Opts, false),
        last_body => undefined
    }.

%% the gen_statem timer of its expiry
-spec timer(sub() | undefined) -> [tuple()].
timer(undefined) ->
    [];
timer(#{expires_at := At}) ->
    [{{timeout, sub_expiry}, max(0, At - now_ms()), expire}].

expiry_ms(0, Grace) -> Grace;
expiry_ms(Seconds, _Grace) -> Seconds * 1000.

now_ms() -> erlang:monotonic_time(millisecond).

%% seconds left on the subscription, rounded up
remaining(#{granted_at := At}) ->
    max(0, (At - now_ms() + 999) div 1000).

%% The Expires a SUBSCRIBE asks for, or Default when it has none (or an
%% unreadable one).
-spec requested_expires(chappe_sip_req:req(), non_neg_integer()) ->
    non_neg_integer().
requested_expires(Req, Default) ->
    case chappe_sip_req:get(<<"expires">>, Req) of
        undefined ->
            Default;
        V ->
            chappe_sip_lib:delta_seconds(V, Default)
    end.

%% an in-dialog SUBSCRIBE names this subscription when its Event does
%% (RFC 6665 8.2.1: type and id)
-spec same_event(binary() | undefined, binary() | undefined) -> boolean().
same_event(_Asked, undefined) ->
    true;
same_event(Asked, Event) ->
    case {chappe_sip_hdr:event(Asked), chappe_sip_hdr:event(Event)} of
        {{ok, E}, {ok, E}} -> true;
        _ -> false
    end.

%% Expires 0: the owner has the grace to send the final NOTIFY
-spec unsubscribed(sub()) -> sub().
unsubscribed(Sub) ->
    Now = now_ms(),
    Sub#{expires_at := Now + maps:get(grace, Sub), granted_at := Now}.

%% a refresh granted Granted seconds
-spec refreshed(sub(), non_neg_integer()) -> sub().
refreshed(Sub, Granted) ->
    At = now_ms() + Granted * 1000,
    Sub#{expires_at := At, granted_at := At}.

%% The teardown's terminated NOTIFY (RFC 6665 4.2.2): the subscription
%% with its term reason, and the NOTIFY's headers and body (the last body
%% sent, when it is kept).
-spec final_notify(sub(), binary(), atom()) ->
    {sub(), [{binary(), iodata()}], binary()}.
final_notify(#{event := Event} = Sub, Reason, TermReason) ->
    State = <<"terminated;reason=", Reason/binary>>,
    {CT, Body} =
        case Sub of
            #{last_body := {C, B}} -> {C, B};
            _ -> {undefined, <<>>}
        end,
    Headers =
        event_header(Event) ++
            [{<<"Subscription-State">>, State}] ++ ct_header(CT, Body),
    {Sub#{term_reason := TermReason}, Headers, Body}.

ct_header(undefined, _Body) -> [];
ct_header(CT, _Body) -> [{<<"Content-Type">>, CT}].

%% The Subscription-State of a NOTIFY from notify/2's state, and whether
%% it ends the subscription. Sub is undefined outside a subscription (the
%% implicit REFER one of an INVITE dialog): only an explicit expires is
%% sent then.
-spec state_value(term(), map(), sub() | undefined) ->
    {ok, binary(), boolean()} | error.
state_value(State, Spec, Sub) when State =:= active; State =:= pending ->
    Value = <<
        (atom_to_binary(State))/binary, (expires_param(Spec, Sub))/binary
    >>,
    {ok, Value, false};
state_value({terminated, Reason}, _Spec, _Sub) ->
    {ok, <<"terminated;reason=", (to_bin(Reason))/binary>>, true};
state_value(_, _Spec, _Sub) ->
    error.

expires_param(_Spec, #{} = Sub) ->
    <<";expires=", (integer_to_binary(remaining(Sub)))/binary>>;
expires_param(#{expires := N}, _Sub) when is_integer(N), N >= 0 ->
    <<";expires=", (integer_to_binary(N))/binary>>;
expires_param(_Spec, _Sub) ->
    <<>>.

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(L) when is_list(L) -> iolist_to_binary(L).

%% the NOTIFY's body kept for the final one, when the owner asked
-spec keep_body(map(), sub() | undefined) -> sub() | undefined.
keep_body(#{content_type := CT, body := Body}, #{keep_body := true} = Sub) ->
    Sub#{last_body := {CT, iolist_to_binary(Body)}};
keep_body(_Spec, Sub) ->
    Sub.

-spec event_header(binary() | undefined) -> [{binary(), binary()}].
event_header(undefined) -> [];
event_header(Event) -> [{<<"Event">>, Event}].
