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
%% gets the final status and the call stays as it was.
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
%% for the relay loop (chappe_sip_b2b_relay)
-export([options/2, refer/4, monitor/1, down/2]).

-export_type([mode/0, info/0]).

-type mode() :: off | auto.
%% What the policy fun sees of a REFER. referrer is the From of the
%% REFER, the identity its dialog was formed with; referred_by is what the
%% REFER claims and is not checked (RFC 3892 6): never grant on it alone.
-type info() :: #{
    kind := blind,
    leg := a | b,
    target := binary(),
    refer_to := chappe_sip_hdr:refer_to(),
    referrer := binary(),
    referred_by := binary() | undefined,
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
    lists:member(maps:get(transfer, Opts, off), [off, auto]) andalso
        valid_topts(maps:get(transfer_opts, Opts, #{})).

valid_topts(T) when is_map(T) ->
    maps:fold(fun(K, V, Acc) -> Acc andalso valid_topt(K, V) end, true, T);
valid_topts(_T) ->
    false.

valid_topt(policy, F) -> is_function(F, 1);
valid_topt(domains, Ds) -> is_list(Ds) andalso lists:all(fun is_binary/1, Ds);
valid_topt(max_transfers, N) -> is_integer(N) andalso N >= 0;
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
refer(_X, _Req, Res, #{transferring := {_, _}} = S) ->
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
        transfers => N
    },
    case start(Args) of
        {ok, Pid} ->
            S#{
                transferring := {Pid, erlang:monitor(process, Pid)},
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
monitor(#{transferring := {_, Mon}}) -> Mon;
monitor(_S) -> undefined.

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
        {ok, #{replaces := R}} when R =/= undefined ->
            {reject, 501, <<"Not Implemented">>};
        {ok, #{target := Target} = RT} ->
            {ok, #{
                kind => blind,
                leg => maps:get(leg, S),
                target => Target,
                refer_to => RT,
                referrer => referrer(Req),
                referred_by => chappe_sip_req:get(<<"referred-by">>, Req),
                call_ref => maps:get(call_ref, S, undefined),
                transfers => N
            }}
    end.

%% the identity the REFER's dialog was formed with: its From, which the
%% dialog layer matched by tag
referrer(Req) ->
    chappe_sip_b2b_hdr:caller(chappe_sip_req:get(<<"from">>, Req)).

%% ---- the call's policy ----

decide(Info, #{opts := TOpts, res := Res} = S) ->
    case policy(Info, TOpts) of
        true ->
            accept(Info, S);
        {reject, Code} ->
            _ = chappe_sip_res:send(Res, Code, #{}),
            ok;
        false ->
            _ = chappe_sip_res:send(Res, 403, #{reason => <<"Forbidden">>}),
            ok
    end.

%% The app's policy, else the default: a target on one of the call's
%% domains (transfer_opts domains, default this node's host). A tel: URI
%% or another host is off-net: refused, so a REFER cannot place a call the
%% referrer could not make itself (toll fraud).
policy(Info, #{policy := F}) ->
    case F(Info) of
        true -> true;
        {reject, Code} when is_integer(Code), Code >= 300, Code =< 699 -> {reject, Code};
        _ -> false
    end;
policy(#{target := Target}, TOpts) ->
    on_net(Target, maps:get(domains, TOpts, own_hosts())).

on_net(Target, Domains) ->
    case chappe_sip_uri:parse(Target) of
        {ok, #{scheme := S, host := Host}} when S =:= sip; S =:= sips ->
            lists:member(
                chappe_sip_lib:lower(Host), [chappe_sip_lib:lower(D) || D <- Domains]
            );
        _ ->
            false
    end.

own_hosts() ->
    case chappe_sip_engine:contact() of
        undefined ->
            [];
        C ->
            case chappe_sip_uri:parse(C) of
                {ok, #{host := H}} -> [H];
                _ -> []
            end
    end.

%% ---- carrying it out ----

accept(Info, #{dialog := D, req := Req, res := Res} = S) ->
    Opts = #{owner => self(), authorize => fun(_, _) -> true end},
    case chappe_sip_refer:accept(D, Req, Res, Opts) of
        {ok, Refer} ->
            event({transfer, maps:get(leg, Info), public(Info)}, S),
            blind(Info, Refer, S);
        {error, _} ->
            ok
    end.

blind(#{leg := Leg, target := Target} = Info, Refer, #{b2b := B2b} = S) ->
    Opts = #{keep_old => true},
    case chappe_sip_b2b:replace_leg(B2b, Leg, Target, Opts) of
        ok ->
            done(Info, Refer, S);
        {error, Why} ->
            failed(Info, Refer, status(Why), S)
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
    maps:with([kind, target, referrer, referred_by], Info).

event(Ev, #{notify := Pid, ref := Ref}) when is_pid(Pid) ->
    Pid ! {chappe_sip_b2b, Ref, Ev},
    ok;
event(_Ev, _S) ->
    ok.
