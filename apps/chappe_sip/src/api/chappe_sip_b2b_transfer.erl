%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc A transfer the B2BUA carries out itself (create_b2bua/4's
%% transfer => auto): one process per REFER a leg of a relayed call sends
%% (RFC 3515 as updated by RFC 7647), under chappe_sip_b2b_sup.
%%
%% The leg that sends the REFER is the transferor; the other leg is the
%% transferee and keeps its media. The process checks the REFER (one
%% Refer-To, a sip, sips or tel target, at most one Referred-By), asks the
%% call's policy, accepts it (200, never 202, and a NOTIFY "100 Trying")
%% and brings the target in on the transferor's side of the call
%% (chappe_sip_b2b:replace_leg/4): the transferee sees no re-INVITE. On a
%% 2xx the transferor gets the final NOTIFY, then a BYE; on a failure it
%% gets the final status and the call stays as it was. The transferor may
%% hang up once its REFER has its answer (RFC 5589 6): the transferee then
%% stays for the target, and the call ends if the transfer fails.
%%
%% Its owner is the call's relay: it monitors it and stops when the call
%% ends. The relay monitors it too and frees the call's transfer slot when
%% it ends, however it ends. The call's notify process gets
%%   {chappe_sip_b2b, Ref, {transfer, Leg, Info}}         accepted
%%   {chappe_sip_b2b, Ref, {transferred, Leg, Info}}      the target took over
%%   {chappe_sip_b2b, Ref, {transfer_failed, Leg, Info}}  Info has status
%% with Info #{kind, target, referrer, referred_by}.
-module(chappe_sip_b2b_transfer).

-include("chappe_sip.hrl").

-export([valid/1, mode/1, start/1, start_link/1, init/1]).
-export([accept/2, reject/2]).
%% for the relay loop (chappe_sip_b2b_relay)
-export([options/2, refer/4, monitor/1, down/2, detach/3, transferor/1]).
-export([handled/3]).

-export_type([mode/0, info/0]).

-type mode() :: off | auto | notify.
%% What the policy fun sees of a REFER. referrer is the From of the
%% REFER, the identity its dialog was formed with; referred_by is what the
%% REFER claims and is not checked (RFC 3892 6): never grant on it alone.
%% An attended transfer (a Replaces in the Refer-To) is local when the
%% dialog it names is a leg of another B2BUA call of the cluster.
-type info() :: #{
    kind := blind | attended,
    local => boolean(),
    replaces => chappe_sip_hdr:replaces(),
    leg := a | b,
    target := binary(),
    refer_to := chappe_sip_hdr:refer_to(),
    referrer := binary(),
    referred_by := binary() | undefined,
    principal := term(),
    replaces_principal => term(),
    call_ref := binary() | undefined,
    transfers := non_neg_integer()
}.

%% how many transfers one call may carry out (a transfer loop ends there)
-define(MAX_TRANSFERS, 5).
%% how long the transferor's final NOTIFY may take before its BYE
-define(NOTIFY_WAIT, 5000).

%% Whether create_b2bua/4's transfer options can be used:
%%   transfer => off | auto
%%   transfer_opts => #{policy => fun((info()) -> boolean() | {reject,
%%       300..699}), domains => [binary()], max_transfers => pos_integer()}
-spec valid(map()) -> boolean().
valid(Opts) ->
    lists:member(maps:get(transfer, Opts, off), [off, auto, notify]) andalso
        valid_topts(maps:get(transfer_opts, Opts, #{})) andalso
        valid_principal(maps:get(principal, Opts, #{})).

%% create_b2bua/4's principal: #{a | b => term()}, who the app
%% authenticated on that leg
valid_principal(P) when is_map(P) ->
    lists:all(fun(K) -> K =:= a orelse K =:= b end, maps:keys(P));
valid_principal(_P) ->
    false.

valid_topts(T) when is_map(T) ->
    maps:fold(fun(K, V, Acc) -> Acc andalso valid_topt(K, V) end, true, T);
valid_topts(_T) ->
    false.

valid_topt(policy, F) -> is_function(F, 1);
valid_topt(domains, Ds) -> is_list(Ds) andalso lists:all(fun is_binary/1, Ds);
valid_topt(max_transfers, N) -> is_integer(N) andalso N >= 0;
valid_topt(timeout, T) -> is_integer(T) andalso T > 0;
valid_topt(_K, _V) -> false.

%% The transfer mode of a call's options.
-spec mode(map()) -> mode().
mode(Opts) -> maps:get(transfer, Opts, off).

%% ---- in the relay loop ----

%% The transfer mode and options of a relayed call: relay/2's win over
%% the ones create_b2bua/4 put in the legs.
-spec options(map(), map()) -> {mode(), map()}.
options(Opts, Legs) ->
    {Mode0, TOpts0} = maps:get(transfer, Legs, {off, #{}}),
    {maps:get(transfer, Opts, Mode0), maps:get(transfer_opts, Opts, TOpts0)}.

%% A REFER from leg X of the call whose relay state is S: the call carries
%% it out (transfer => auto), or it goes where the call's other claimed
%% requests go. Returns the relay state.
-spec refer(a | b, chappe_sip_req:req(), chappe_sip_res:res(), map()) -> map().
refer(X, Req, Res, #{transfer := off} = S) ->
    ok = chappe_sip_b2b_requests:request(X, refer, Req, Res, S),
    S;
refer(_X, _Req, Res, #{transferring := {_, _, _}} = S) ->
    %% one transfer at a time
    ok = chappe_sip_b2b_relay:retry_later(Res),
    S;
refer(_X, _Req, Res, #{media := #{mode := direct}} = S) ->
    %% the target replaces a leg behind rtpengine: a direct call cannot
    _ = chappe_sip_res:send(Res, 488, #{reason => <<"Not Acceptable Here">>}),
    S;
refer(X, Req, Res, #{media := M, transfers := N} = S) ->
    Args = #{
        b2b => {self(), maps:get(ref, M)},
        leg => X,
        dialog => maps:get(X, S),
        req => Req,
        res => Res,
        notify => maps:get(notify, M),
        ref => maps:get(ref, M),
        call_ref => maps:get(call_ref, M),
        opts => maps:get(transfer_opts, S),
        principal => maps:get(X, maps:get(principal, S), undefined),
        mode => maps:get(transfer, S),
        transfers => N
    },
    case start(Args) of
        {ok, Pid} ->
            S#{
                transferring := {Pid, erlang:monitor(process, Pid), X},
                transfers := N + 1
            };
        {error, Why} ->
            logger:warning("chappe_sip_b2b: transfer not started: ~p", [Why]),
            _ = chappe_sip_res:send(Res, 500, #{
                reason => <<"Server Internal Error">>
            }),
            S
    end.

%% The monitor of the transfer at work in relay state S, to match its
%% 'DOWN' and no other.
-spec monitor(map()) -> reference() | undefined.
monitor(#{transferring := {_, Mon, _}}) -> Mon;
monitor(_S) -> undefined.

%% The leg that sent the REFER of the transfer at work, if any.
-spec transferor(map()) -> a | b | undefined.
transferor(#{transferring := {_, _, Leg}}) -> Leg;
transferor(_S) -> undefined.

%% The transfer ended: the call takes a new one. A crash is logged, and
%% the call goes on.
-spec down(term(), map()) -> map().
down(normal, S) ->
    S#{transferring := undefined};
down(Why, S) ->
    logger:warning("chappe_sip_b2b: transfer died: ~p", [Why]),
    S#{transferring := undefined}.

%% ---- the transfer process ----

%% Start the transfer of a REFER (from the relay). Args:
%%   b2b, leg, dialog (the transferor's), req, res, notify, ref, call_ref,
%%   opts (transfer_opts), transfers (how many the call made already).
-spec start(map()) -> {ok, pid()} | {error, term()}.
start(Args) ->
    chappe_sip_b2b_sup:start_transfer(Args).

-spec start_link(map()) -> {ok, pid()}.
start_link(Args) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [Args])}.

-spec init(map()) -> ok.
init(#{b2b := {Relay, _}} = Args) ->
    Mon = erlang:monitor(process, Relay),
    S = Args#{mon => Mon},
    case classify(S) of
        {reject, Status, Reason} ->
            _ = chappe_sip_res:send(maps:get(res, S), Status, #{
                reason => Reason
            }),
            ok;
        {ok, Info} ->
            decide(Info, S)
    end.

%% ---- what the REFER asks for ----

classify(#{req := Req, opts := TOpts, transfers := N} = S) ->
    Max = maps:get(max_transfers, TOpts, ?MAX_TRANSFERS),
    case chappe_sip_refer:check(Req) of
        {reject, _, _} = Rej ->
            Rej;
        {ok, #{method := M}} when M =/= <<"INVITE">> ->
            %% a B2BUA call only carries transfers: a REFER for a BYE or
            %% another method is not one (RFC 3515 2.4.2: any 4xx-6xx)
            {reject, 403, <<"Forbidden">>};
        {ok, _} when N >= Max ->
            %% a transfer that transfers again, and again: a loop
            {reject, 403, <<"Too Many Transfers">>};
        {ok, #{target := Target, replaces := R} = RT} when R =/= undefined ->
            attended(R, base(Target, RT, S), S);
        {ok, #{target := Target} = RT} ->
            {ok, base(Target, RT, S)}
    end.

base(Target, RT, #{req := Req, transfers := N} = S) ->
    #{
        kind => blind,
        leg => maps:get(leg, S),
        target => Target,
        refer_to => RT,
        referrer => referrer(Req),
        referred_by => chappe_sip_req:get(<<"referred-by">>, Req),
        call_ref => maps:get(call_ref, S, undefined),
        principal => maps:get(principal, S, undefined),
        transfers => N
    }.

%% ---- attended transfer (RFC 5589 7.3) ----

%% The Replaces names the dialog the referrer has with the target. When
%% it is a confirmed leg of another B2BUA call of the cluster (found
%% through the dialog index of every node, then its call_ref), the two
%% remote parties are joined through rtpengine; otherwise the target gets
%% an INVITE with Replaces. Who may name that dialog is the policy's to
%% decide (RFC 3891 3 and 8: the referrer must be authenticated as the
%% party being replaced, or authorized to replace it): Info carries the
%% principal the app recorded for the referrer's leg (create_b2bua/4's
%% principal option) and replaces_principal, the one of the named leg.
%% The From of the REFER is never enough: nothing authenticated it.
%%
%% A REFER comes in a dialog, where a 481 would tell the referrer that
%% dialog is gone (RFC 3261 12.2.1.2): a named dialog that is ending gets
%% 603 (as an INVITE with that Replaces would, RFC 3891 3), an early one
%% 403 (only confirmed legs are joined).
attended(#{call_id := C, to_tag := T, from_tag := F} = R, Info, S) ->
    Info1 = Info#{kind := attended, replaces => R},
    case chappe_sip_dialog_index:find({C, T, F}) of
        not_found ->
            {ok, Info1#{local => false}};
        {ok, {Pid, Id, confirmed, _Role}} ->
            local(chappe_sip_dialog:make(Pid, Id), Info1, S);
        {ok, {_, _, early, _}} ->
            {reject, 403, <<"Forbidden">>};
        {ok, _} ->
            {reject, 603, <<"Declined">>}
    end.

local(D2, Info, #{b2b := Own}) ->
    try chappe_sip_dialog:call_ref(D2) of
        Ref when is_binary(Ref) ->
            #{b2b := Calls} = chappe_sip_call:lookup(Ref),
            holder([B || B <- Calls, B =/= Own], D2, Info);
        _ ->
            {reject, 403, <<"Forbidden">>}
    catch
        %% it ended meanwhile
        exit:_ -> {reject, 603, <<"Declined">>}
    end.

%% the B2BUA call that holds D2, and the principal of that leg
holder([], _D2, _Info) ->
    %% a dialog no B2BUA call relays: nothing to join
    {reject, 403, <<"Forbidden">>};
holder([B | Rest], D2, Info) ->
    case chappe_sip_b2b:call(B, {principal, D2}, 5000) of
        {ok, P} ->
            {ok, Info#{
                local => true,
                dialog2 => D2,
                b2b2 => B,
                replaces_principal => P
            }};
        _ ->
            holder(Rest, D2, Info)
    end.

%% join: the target's leg leaves its call (the referrer's leg there gets a
%% BYE) and takes the referrer's place in this one with a re-INVITE from
%% rtpengine; the transferee sees nothing. The call that holds the target
%% only lends its leg until this call took it: when the re-INVITE fails
%% (the target refuses it, this call is busy or gone), the leg goes back
%% and both calls stay as they were.
join(#{leg := Leg} = Info, Refer, #{b2b := B2b} = S) ->
    case lend(Info) of
        {ok, Lender, Target} ->
            case
                chappe_sip_b2b:replace_leg(B2b, Leg, {dialog, Target}, #{
                    keep_old => true
                })
            of
                ok ->
                    ok = settle(Lender, done),
                    done(Info, Refer, S);
                {error, Why} ->
                    ok = settle(Lender, back),
                    failed(Info, Refer, status(Why), S)
            end;
        error ->
            failed(Info, Refer, 481, S)
    end.

%% the call that holds the named dialog lends its other leg
lend(#{dialog2 := D2, b2b2 := B}) ->
    case chappe_sip_b2b:call(B, {detach, D2}) of
        {ok, Target} -> {ok, B, Target};
        _ -> error
    end.

%% tell the lender whether its leg was taken (done) or comes back (back)
settle({Pid, Ref}, How) ->
    Pid ! {chappe_sip_b2b, Ref, {lent, self(), How}},
    ok.

%% The relay of the call that holds D, a leg of its, lends the other leg
%% (Keep) to the caller (From), a transfer joining it to its own call,
%% and waits for the outcome (lent/5): taken, D gets a BYE, the call's
%% rtpengine session goes and the relay ends; given back, the call goes
%% on as it was. {loop, S} when D is not one of its legs or an offer is
%% pending; the caller then gets an error.
-spec detach({pid(), term()}, chappe_sip_dialog:dialog(), map()) ->
    {done, transferred} | {loop, map()}.
detach(From, D, #{a := A, b := B, pending := undefined} = S) ->
    P = chappe_sip_dialog:pid(D),
    case {chappe_sip_dialog:pid(A), chappe_sip_dialog:pid(B)} of
        {P, _} -> lend_out(From, A, B, S);
        {_, P} -> lend_out(From, B, A, S);
        _ -> not_mine(From, S)
    end;
detach(From, _D, S) ->
    not_mine(From, S).

lend_out({Caller, Tag}, D, Keep, #{refs := {RefA, RefB}} = S) ->
    try chappe_sip_dialog:set_owner(Keep, Caller) of
        ok ->
            erlang:demonitor(RefA, [flush]),
            erlang:demonitor(RefB, [flush]),
            Caller ! {Tag, {ok, Keep}},
            lent(Caller, erlang:monitor(process, Caller), D, Keep, S)
    catch
        exit:_ ->
            Caller ! {Tag, {error, gone}},
            {loop, S}
    end.

%% While its leg Keep is lent, the call answers nothing of D but its
%% ACKs (500 with Retry-After, as for an offer under way) and no call to
%% its relay (busy). A borrower that dies keeps the leg: whoever owns
%% Keep then carries it on (or ends it), and this call ends.
lent(Caller, CMon, D, Keep, #{ref := Ref, media := M} = S) ->
    receive
        {chappe_sip_b2b, Ref, {lent, Caller, done}} ->
            erlang:demonitor(CMon, [flush]),
            handed_over(D, M);
        {chappe_sip_b2b, Ref, {lent, Caller, back}} ->
            erlang:demonitor(CMon, [flush]),
            {loop, take_back(Keep, S)};
        {'DOWN', CMon, process, Caller, _} ->
            handed_over(D, M);
        {chappe_sip_b2b, Ref, {call, {Pid, Tag}, _Req}} ->
            Pid ! {Tag, {error, busy}},
            lent(Caller, CMon, D, Keep, S);
        {chappe_sip_dialog, D, ack, _, _} ->
            lent(Caller, CMon, D, Keep, S);
        {chappe_sip_dialog, D, _Event, _Req, Res} ->
            ok = chappe_sip_b2b_relay:retry_later(Res),
            lent(Caller, CMon, D, Keep, S)
    end.

handed_over(D, M) ->
    _ = chappe_sip_b2b_media:stop(M),
    _ = spawn(fun() -> chappe_sip_b2b:destroy_quietly(D, []) end),
    {done, transferred}.

%% Keep comes back: its events come here again, with the requests this
%% call claims, and both legs are watched again (a leg that ended
%% meanwhile ends the call at once)
take_back(Keep, #{a := A, b := B} = S) ->
    _ =
        try
            ok = chappe_sip_dialog:set_owner(Keep, self()),
            chappe_sip_dialog:set_handled(Keep, handled(S))
        catch
            exit:_ -> ok
        end,
    S#{refs := {chappe_sip_dialog:monitor(A), chappe_sip_dialog:monitor(B)}}.

handled(#{requests := Requests, relay_info := RelayInfo, transfer := Mode}) ->
    handled(Requests, RelayInfo, Mode).

%% The handled_events of each leg of a relayed call: its claimed
%% requests, and REFER when the call carries transfers.
-spec handled([atom()], boolean(), mode()) -> [atom()].
handled(Requests, RelayInfo, Mode) ->
    chappe_sip_b2b_requests:handled(
        Requests ++ [refer || Mode =/= off], RelayInfo
    ).

not_mine({Caller, Tag}, S) ->
    Caller ! {Tag, {error, not_found}},
    {loop, S}.

%% the identity the REFER's dialog was formed with: its From, which the
%% dialog layer matched by tag
referrer(Req) ->
    chappe_sip_b2b_hdr:caller(chappe_sip_req:get(<<"from">>, Req)).

%% ---- the call's policy ----

decide(Info, #{mode := notify} = S) ->
    ask(Info, S);
decide(Info, #{opts := TOpts, res := Res} = S) ->
    case policy(Info, TOpts) of
        true ->
            take(Info, S);
        {reject, Code} ->
            _ = chappe_sip_res:send(Res, Code, #{}),
            ok;
        false ->
            _ = chappe_sip_res:send(Res, 403, #{reason => <<"Forbidden">>}),
            ok
    end.

%% transfer => notify: the call's notify process decides, with accept/2
%% or reject/2, within the timeout (10 s, then 603)
ask(Info, #{notify := Pid, ref := Ref, res := Res, mon := Mon} = S) when
    is_pid(Pid)
->
    Public = maps:without([dialog2, b2b2], Info),
    Pid ! {chappe_sip_b2b, Ref, {refer, Public#{transfer => self()}}},
    receive
        {?MODULE, {accept, Opts}} ->
            take(retarget(Info, Opts), S);
        {?MODULE, {reject, Code}} ->
            _ = chappe_sip_res:send(Res, Code, #{}),
            ok;
        {'DOWN', Mon, process, _, _} ->
            %% the call is over (603, not 481: see attended/3)
            _ = chappe_sip_res:send(Res, 603, #{reason => <<"Declined">>}),
            ok
    after maps:get(timeout, maps:get(opts, S), 10000) ->
        _ = chappe_sip_res:send(Res, 603, #{reason => <<"Declined">>}),
        ok
    end;
ask(_Info, #{res := Res}) ->
    _ = chappe_sip_res:send(Res, 603, #{reason => <<"Declined">>}),
    ok.

%% the app's own target: a blind transfer there
retarget(Info, #{target := T}) when is_binary(T), T =/= <<>> ->
    (maps:without(
        [replaces, local, dialog2, b2b2, replaces_principal], Info
    ))#{
        target := T, kind := blind
    };
retarget(Info, _Opts) ->
    Info.

%% Carry out the REFER that {refer, Info} announced (transfer => notify).
%% Opts: target => Uri sends the transferee there instead (a blind
%% transfer then, whatever the REFER named). Runs on any node.
-spec accept(map(), map()) -> ok | {error, badarg}.
accept(#{transfer := Pid}, Opts) when is_pid(Pid), is_map(Opts) ->
    case maps:get(target, Opts, <<>>) of
        T when is_binary(T) ->
            Pid ! {?MODULE, {accept, Opts}},
            ok;
        _ ->
            {error, badarg}
    end;
accept(_Info, _Opts) ->
    {error, badarg}.

%% Refuse it: the REFER gets Code (403 by default practice), nothing is
%% called.
-spec reject(map(), 300..699) -> ok | {error, badarg}.
reject(#{transfer := Pid}, Code) when
    is_pid(Pid), is_integer(Code), Code >= 300, Code =< 699
->
    Pid ! {?MODULE, {reject, Code}},
    ok;
reject(_Info, _Code) ->
    {error, badarg}.

%% The app's policy, else the default: a target on one of the call's
%% domains (transfer_opts domains, default this node's own listen
%% addresses). A tel: URI or another host is off-net: refused, so a REFER
%% cannot place a call the referrer could not make itself (toll fraud).
%% The target must name a user (a URI with none names a server), carry
%% no maddr (which sofia would send the INVITE to instead of the host),
%% and be on a domain's port: a domain given as Host takes any port,
%% Host:Port and the node's own addresses only theirs.
policy(Info, #{policy := F}) ->
    case F(Info) of
        true ->
            true;
        {reject, Code} when is_integer(Code), Code >= 300, Code =< 699 ->
            {reject, Code};
        _ ->
            false
    end;
policy(#{kind := attended, local := true} = Info, _TOpts) ->
    %% two parties already in calls: nothing new is called,
    %% but the referrer must be the party it replaces, as the app knows
    %% it (RFC 3891 3)
    case Info of
        #{principal := P, replaces_principal := P} -> P =/= undefined;
        _ -> false
    end;
policy(#{target := Target}, TOpts) ->
    Domains =
        case maps:find(domains, TOpts) of
            {ok, Ds} -> [domain(<<"sip:", D/binary>>, any) || D <- Ds];
            error -> [domain(C, default) || C <- own_contacts()]
        end,
    on_net(Target, [D || {_, _} = D <- Domains]).

on_net(Target, Domains) ->
    case chappe_sip_uri:parse(Target) of
        {ok, #{scheme := S, host := Host, user := User, params := Ps} = U} when
            (S =:= sip orelse S =:= sips) andalso User =/= <<>>
        ->
            Port = port(S, maps:get(port, U, undefined)),
            not has_maddr(Ps) andalso
                lists:any(
                    fun({H, P}) ->
                        H =:= chappe_sip_lib:lower(Host) andalso
                            (P =:= any orelse P =:= Port)
                    end,
                    Domains
                );
        _ ->
            false
    end.

has_maddr(Params) ->
    lists:member(
        <<"maddr">>, [chappe_sip_lib:lower(K) || K <- maps:keys(Params)]
    ).

%% {Host, Port | any} of an app's domain (no port: any) or of a listen
%% address (no port: the scheme's default)
domain(Uri, NoPort) ->
    case chappe_sip_uri:parse(Uri) of
        {ok, #{scheme := S, host := H} = U} ->
            {chappe_sip_lib:lower(H),
                case {maps:find(port, U), NoPort} of
                    {{ok, P}, _} -> P;
                    {error, any} -> any;
                    {error, default} -> port(S, undefined)
                end};
        _ ->
            error
    end.

own_contacts() ->
    case {chappe_sip_binds:contacts(), chappe_sip_engine:contact()} of
        {[], undefined} -> [];
        {[], C} -> [C];
        {Cs, _} -> Cs
    end.

port(sips, undefined) -> 5061;
port(_S, undefined) -> 5060;
port(_S, P) -> P.

%% ---- carrying it out ----

take(Info, #{dialog := D, req := Req, res := Res} = S) ->
    Opts = #{owner => self(), authorize => fun(_, _) -> true end},
    case chappe_sip_refer:accept(D, Req, Res, Opts) of
        {ok, Refer} ->
            event({transfer, maps:get(leg, Info), public(Info)}, S),
            carry_out(Info, Refer, S);
        {error, _} ->
            ok
    end.

carry_out(#{kind := attended, local := true} = Info, Refer, S) ->
    join(Info, Refer, S);
carry_out(Info, Refer, S) ->
    blind(Info, Refer, S).

%% a blind transfer, or an attended one whose dialog is elsewhere: the
%% target gets an INVITE (with the Replaces, then)
blind(#{leg := Leg, target := Target} = Info, Refer, #{b2b := B2b} = S) ->
    %% the target's 1xx reach the referrer as NOTIFYs (RFC 3515 2.4.4),
    %% rate-limited by the subscription (3.10)
    Progress = fun(St) -> chappe_sip_refer:progress(Refer, St) end,
    Opts = (new_party(Info, S))#{on_progress => Progress},
    case chappe_sip_b2b:replace_leg(B2b, Leg, Target, Opts) of
        ok ->
            done(Info, Refer, S);
        {error, Why} ->
            failed(Info, Refer, status(Why), S)
    end.

%% The INVITE to the target: it comes from the transferee (RFC 5589 6),
%% under the identity the referrer saw on its leg (RFC 3892 2.2: the same
%% identity to the referrer and the target), privacy applied as it was
%% there. Referred-By goes on as the
%% REFER had it (RFC 3892 2.2). The new leg keeps the call's call_ref,
%% with related naming the call it came from.
new_party(#{referred_by := RB} = Info, S) ->
    Opts = #{
        keep_old => true,
        headers =>
            [{<<"Referred-By">>, RB} || RB =/= undefined] ++ replaces(Info)
    },
    Related =
        case maps:get(call_ref, Info) of
            undefined -> #{};
            Ref -> #{related => Ref}
        end,
    maps:merge(maps:merge(Opts, Related), transferee_from(S)).

%% RFC 3891 6.1 and RFC 5589 7.3: the Replaces from the Refer-To, with
%% Require: replaces so a UA that would ignore it fails the INVITE
replaces(#{replaces := R}) ->
    [
        {<<"Replaces">>, chappe_sip_hdr:replaces_value(R)},
        {<<"Require">>, <<"replaces">>}
    ];
replaces(_Info) ->
    [].

transferee_from(#{dialog := D}) ->
    try chappe_sip_dialog:local_addr(D) of
        A -> #{from => chappe_sip_b2b_hdr:caller(A)}
    catch
        exit:_ -> #{}
    end.

%% the target answered: the transferor hears it, then gets its BYE (RFC
%% 5589 6: the transferee ends the call with the transferor)
done(#{leg := Leg} = Info, Refer, #{dialog := D} = S) ->
    ok = chappe_sip_refer:final(Refer, 200),
    wait_notify(Refer),
    _ = chappe_sip_b2b:destroy_quietly(D, []),
    event({transferred, Leg, public(Info)}, S),
    ok.

failed(#{leg := Leg} = Info, Refer, Status, S) ->
    ok = chappe_sip_refer:final(Refer, Status),
    event({transfer_failed, Leg, (public(Info))#{status => Status}}, S),
    ok.

wait_notify(Refer) ->
    case chappe_sip_refer:subscription(Refer) of
        undefined ->
            ok;
        Pid ->
            MRef = erlang:monitor(process, Pid),
            receive
                {'DOWN', MRef, process, Pid, _} -> ok
            after ?NOTIFY_WAIT ->
                erlang:demonitor(MRef, [flush]),
                ok
            end
    end.

%% the status the referrer's final NOTIFY carries for a failure
status({error, E}) -> status(E);
status(#chappe_sip_error{status = St}) when is_integer(St), St >= 300 -> St;
status(timeout) -> 408;
status({rejected, Code}) when is_integer(Code) -> Code;
status(not_anchored) -> 488;
status(busy) -> 491;
status(_) -> 503.

public(Info) ->
    maps:with([kind, local, target, referrer, referred_by], Info).

event(Ev, #{notify := Pid, ref := Ref}) when is_pid(Pid) ->
    Pid ! {chappe_sip_b2b, Ref, Ev},
    ok;
event(_Ev, _S) ->
    ok.
