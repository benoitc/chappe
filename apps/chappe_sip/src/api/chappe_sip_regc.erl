%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc An outbound registration (RFC 3261 10.2): one process per binding
%% chappe keeps at a registrar, a trunk or an upstream PBX account.
%%
%% It sends REGISTER for the AOR with the contact, answers a digest
%% challenge (the auth option, as chappe_sip_uac), and refreshes before
%% the expiry the registrar granted. Every REGISTER of a registration
%% shares one Call-ID and counts up its CSeq (10.2.4). A 423 is retried
%% with the Min-Expires it names (10.2.8). A failure (another final
%% response, a timeout) is retried with an exponential backoff, after the
%% Retry-After of a 503 when it gives one. unregister/1 removes the
%% binding (Expires: 0) and stops the process.
%%
%% Subscribers (subscribe/1) get {chappe_sip_regc, Name, Event} on each
%% change:
%%   registered  a 2xx after a start, a failure or an expiry
%%   failed      a REGISTER failed while registering or registered
%%   expired     the granted expiry passed with no successful refresh
-module(chappe_sip_regc).
-behaviour(gen_statem).

-include("chappe_sip.hrl").

-export([start/2, unregister/1, status/1, subscribe/1, list/0, load_env/0]).
-export([start_link/2]).
-export([init/1, callback_mode/0, handle_event/4, terminate/3]).
-export_type([name/0, opts/0, status/0]).

-type name() :: term().
-type opts() :: #{
    aor := binary(),
    registrar => binary(),
    auth => map() | [map()],
    expires => pos_integer(),
    contact => binary(),
    proxy => binary(),
    route_set => [binary()],
    headers => [{binary(), iodata()}],
    retry_min_ms => pos_integer(),
    retry_max_ms => pos_integer()
}.
-type status() :: registering | registered | failed | expired.

-define(SCOPE, chappe_sip_regc).
-define(GROUP, subscribers).
-define(DEFAULT_EXPIRES, 3600).
-define(RETRY_MIN_MS, 1000).
-define(RETRY_MAX_MS, 300000).
-define(UNREGISTER_TIMEOUT_MS, 45000).
-define(UAC_LOST_MS, 40000).

%% Start a registration under chappe_sip_regc_sup. Opts:
%%   aor := binary()        the address-of-record (From and To)
%%   registrar => binary()  the Request-URI (default: the AOR's domain)
%%   auth => #{user, pass, realm => binary()} or a list of them
%%   expires => pos_integer() (default 3600)
%%   contact => binary()    the Contact URI (default: our contact with
%%                          the AOR's user)
%%   proxy, route_set, headers   as chappe_sip_uac
%%   retry_min_ms (1000), retry_max_ms (300000)   the failure backoff
-spec start(name(), opts()) -> ok | {error, term()}.
start(Name, #{aor := Aor} = Opts) when is_binary(Aor) ->
    case chappe_sip_uri:parse(Aor) of
        {ok, _} -> chappe_sip_regc_sup:start_child(Name, Opts);
        {error, _} -> {error, bad_aor}
    end;
start(_Name, _Opts) ->
    {error, bad_aor}.

%% Remove the binding (REGISTER with Expires: 0) and stop.
-spec unregister(name()) -> ok | {error, not_found}.
unregister(Name) ->
    case chappe_sip_regc_sup:whereis(Name) of
        undefined ->
            chappe_sip_regc_sup:delete_child(Name);
        Pid ->
            _ =
                try
                    gen_statem:call(Pid, unregister, ?UNREGISTER_TIMEOUT_MS)
                catch
                    exit:_ -> ok
                end,
            chappe_sip_regc_sup:delete_child(Name)
    end.

%% Where a registration stands: its status, the expiry the registrar
%% granted (seconds), the seconds left on the binding, the last final
%% status received (or timeout) and the failures in a row.
-spec status(name()) -> {ok, map()} | {error, not_found}.
status(Name) ->
    case chappe_sip_regc_sup:whereis(Name) of
        undefined ->
            {error, not_found};
        Pid ->
            try
                {ok, gen_statem:call(Pid, status, 5000)}
            catch
                exit:_ -> {error, not_found}
            end
    end.

%% Pid gets {chappe_sip_regc, Name, registered | failed | expired} for
%% every registration until it exits.
-spec subscribe(pid()) -> ok.
subscribe(Pid) ->
    case lists:member(Pid, pg:get_local_members(?SCOPE, ?GROUP)) of
        true -> ok;
        false -> pg:join(?SCOPE, ?GROUP, Pid)
    end.

%% Every registration and its status.
-spec list() -> [{name(), status()}].
list() ->
    lists:filtermap(
        fun({Name, _Pid}) ->
            case status(Name) of
                {ok, #{status := S}} -> {true, {Name, S}};
                {error, _} -> false
            end
        end,
        chappe_sip_regc_sup:children()
    ).

%% Start the registrations of the `registrations' application setting, a
%% map of Name => Opts or a list of Opts each with a name. One already
%% running is left alone.
-spec load_env() -> ok.
load_env() ->
    Regs =
        case application:get_env(chappe_sip, registrations, #{}) of
            M when is_map(M) -> maps:to_list(M);
            L when is_list(L) -> [{maps:get(name, O), O} || O <- L]
        end,
    lists:foreach(
        fun({Name, Opts}) ->
            case start(Name, maps:remove(name, Opts)) of
                ok ->
                    ok;
                {error, already_started} ->
                    ok;
                {error, Why} ->
                    logger:warning(
                        "chappe_sip_regc: registration ~p not started: ~p",
                        [Name, Why]
                    )
            end
        end,
        Regs
    ).

start_link(Name, Opts) ->
    gen_statem:start_link(?MODULE, {Name, Opts}, []).

callback_mode() -> handle_event_function.

init({Name, #{aor := Aor} = Opts}) ->
    process_flag(trap_exit, true),
    D = #{
        name => Name,
        aor => Aor,
        opts => Opts,
        registrar => maps:get(registrar, Opts, registrar_of(Aor)),
        expires => maps:get(expires, Opts, ?DEFAULT_EXPIRES),
        call_id => <<
            (binary:encode_hex(crypto:strong_rand_bytes(8), lowercase))/binary,
            "@chappe"
        >>,
        tag => chappe_sip_dialog:gen_tag(),
        cseq => 0,
        uac => undefined,
        contact => undefined,
        status => registering,
        live => false,
        granted => undefined,
        expires_at => undefined,
        last => undefined,
        failures => 0,
        %% the digest challenges the last REGISTER answered: the next one
        %% carries credentials for them at once (RFC 7616 3.4: same nonce,
        %% next nc, new cnonce) instead of being challenged again
        auth_state => undefined
    },
    {ok, idle, D, [{next_event, internal, register}]}.

%% ---- events ----

handle_event(internal, register, idle, D) ->
    send(register, D);
handle_event({timeout, refresh}, _, idle, D) ->
    send(register, D);
handle_event({timeout, retry}, _, idle, D) ->
    send(register, D);
handle_event({timeout, T}, _, busy, _D) when T =:= refresh; T =:= retry ->
    {keep_state_and_data, [postpone]};
handle_event({timeout, expiry}, _, _State, D) ->
    %% the binding is gone at the registrar: nothing refreshed it in time
    {keep_state,
        set_status(expired, D#{live := false, expires_at := undefined})};
handle_event(info, {chappe_sip_uac, Ref, Event}, busy, #{uac := {Ref, Op}} = D) ->
    response(Event, Op, D);
handle_event(state_timeout, uac_lost, busy, #{uac := {_, Op}} = D) ->
    response({error, uac_lost}, Op, D);
handle_event({call, From}, status, _State, D) ->
    {keep_state_and_data, [{reply, From, status_map(D)}]};
handle_event({call, _From}, unregister, busy, _D) ->
    %% after the REGISTER that is out
    {keep_state_and_data, [postpone]};
handle_event({call, From}, unregister, idle, #{live := true} = D) ->
    case send(unregister, D) of
        {next_state, busy, D1, Actions} ->
            {next_state, busy, D1#{unregister_from => From}, Actions};
        _Failed ->
            {stop_and_reply, normal, [{reply, From, ok}], D#{live := false}}
    end;
handle_event({call, From}, unregister, idle, D) ->
    {stop_and_reply, normal, [{reply, From, ok}], D};
handle_event(_Type, _Msg, _State, _D) ->
    keep_state_and_data.

terminate(_Reason, _State, #{live := true} = D) ->
    %% stopped by its supervisor (the application going down): remove the
    %% binding on a best-effort REGISTER nobody waits for
    _ = uac(unregister, D),
    ok;
terminate(_Reason, _State, _D) ->
    ok.

%% ---- responses ----

response({request_sent, _}, _Op, _D) ->
    keep_state_and_data;
response({provisional, _}, _Op, _D) ->
    keep_state_and_data;
response({auth_state, State}, _Op, D) ->
    {keep_state, D#{auth_state := State}};
response(
    {error, #chappe_sip_error{status = S, response = Msg}},
    Op,
    #{auth_state := {_, _}} = D0
) when S =:= 401; S =:= 407 ->
    %% the nonce we reused is refused (expired without stale=true): start
    %% over with a fresh challenge
    send(Op, seen(Msg, D0#{uac := undefined, auth_state := undefined}));
response(Event, unregister, D0) ->
    D = seen(event_msg(Event), D0#{uac := undefined}),
    Status = event_status(Event),
    {stop_and_reply, normal, [{reply, maps:get(unregister_from, D), ok}], D#{
        live := false, last := Status
    }};
response({response, Msg}, register, D0) ->
    D = seen(Msg, D0#{uac := undefined}),
    Granted = granted(Msg, D),
    Ms = Granted * 1000,
    D1 = set_status(registered, D#{
        live := true,
        granted := Granted,
        expires_at := erlang:monotonic_time(millisecond) + Ms,
        last := chappe_sip_msg:status(Msg),
        failures := 0
    }),
    {next_state, idle, D1, [
        {{timeout, refresh}, Ms - min(Ms div 3, 32000), go},
        {{timeout, expiry}, Ms, go}
    ]};
response({error, #chappe_sip_error{status = 423, response = Msg}}, Op, D0) ->
    %% RFC 3261 10.2.8: again, with the expiry the registrar asks for
    D = seen(Msg, D0#{uac := undefined, last := 423}),
    case min_expires(Msg) of
        Min when is_integer(Min), Min > map_get(expires, D) ->
            send(Op, D#{expires := Min});
        _ ->
            failed(423, D)
    end;
response({error, #chappe_sip_error{status = S, response = Msg}}, _Op, D) ->
    failed(S, seen(Msg, D#{uac := undefined}), retry_after(Msg));
response({error, _Why}, _Op, D) ->
    failed(timeout, D#{uac := undefined}).

failed(Last, D) ->
    failed(Last, D, undefined).

failed(Last, #{failures := N} = D0, RetryAfter) ->
    D = D0#{last := Last, failures := N + 1},
    Backoff = backoff(N, maps:get(opts, D)),
    Delay =
        case RetryAfter of
            undefined -> Backoff;
            Secs -> max(Backoff, Secs * 1000)
        end,
    {next_state, idle, failed_status(D), [{{timeout, retry}, Delay, go}]}.

%% a failure reported once: an expired binding stays expired
failed_status(#{status := expired} = D) -> D;
failed_status(D) -> set_status(failed, D).

backoff(N, Opts) ->
    Min = maps:get(retry_min_ms, Opts, ?RETRY_MIN_MS),
    Max = maps:get(retry_max_ms, Opts, ?RETRY_MAX_MS),
    min(Max, Min bsl min(N, 20)).

set_status(Status, #{status := Status} = D) ->
    D;
set_status(Status, #{name := Name} = D) ->
    Event = {chappe_sip_regc, Name, Status},
    _ = [P ! Event || P <- pg:get_local_members(?SCOPE, ?GROUP)],
    D#{status := Status}.

%% ---- the REGISTER ----

send(Op, D) ->
    case uac(Op, D) of
        {ok, D1} ->
            %% the UAC reports its end (Timer F at worst); a UAC gone
            %% without a word must not leave the registration waiting
            {next_state, busy, D1, [{state_timeout, ?UAC_LOST_MS, uac_lost}]};
        {error, _} ->
            failed(timeout, D)
    end.

uac(Op, #{aor := Aor, opts := Opts} = D) ->
    Seq = maps:get(cseq, D) + 1,
    Contact = contact(D),
    Expires =
        case Op of
            register -> maps:get(expires, D);
            unregister -> 0
        end,
    Auth =
        case {maps:is_key(auth, Opts), maps:get(auth_state, D)} of
            {false, _} -> #{};
            {true, undefined} -> #{report_auth => true};
            {true, St} -> #{report_auth => true, auth_state => St}
        end,
    Uac = maps:merge(
        maps:merge(maps:with([auth, proxy, route_set], Opts), Auth),
        #{
            method => <<"REGISTER">>,
            call_id => maps:get(call_id, D),
            cseq => Seq,
            from => <<"<", Aor/binary, ">;tag=", (maps:get(tag, D))/binary>>,
            to => <<"<", Aor/binary, ">">>,
            headers =>
                [{<<"Expires">>, integer_to_binary(Expires)}] ++
                maps:get(headers, Opts, []),
            notify => self(),
            owner => self()
        }
    ),
    Uac1 =
        case Contact of
            undefined -> Uac;
            _ -> Uac#{contact => Contact}
        end,
    try chappe_sip_uac:start(maps:get(registrar, D), Uac1) of
        {ok, Ref} ->
            {ok, D#{uac := {Ref, Op}, cseq := Seq, contact := Contact}};
        {error, _} = Err ->
            Err
    catch
        exit:Why -> {error, Why}
    end.

%% the app's contact, else ours with the AOR's user, so the registrar
%% routes calls for the AOR to it
contact(#{contact := C}) when is_binary(C) ->
    C;
contact(#{opts := #{contact := C}}) ->
    C;
contact(#{aor := Aor}) ->
    case {engine_contact(), chappe_sip_uri:parse(Aor)} of
        {undefined, _} ->
            undefined;
        {Ours, {ok, #{user := User}}} when is_binary(User) ->
            case chappe_sip_uri:parse(Ours) of
                {ok, U} -> chappe_sip_uri:format(U#{user => User});
                {error, _} -> Ours
            end;
        {Ours, _} ->
            Ours
    end.

engine_contact() ->
    try chappe_sip_engine:contact() of
        undefined ->
            undefined;
        C ->
            case chappe_sip_hdr:name_addr(C) of
                {ok, #{uri := Uri}} -> Uri;
                _ -> C
            end
    catch
        exit:_ -> undefined
    end.

registrar_of(Aor) ->
    case chappe_sip_uri:parse(Aor) of
        {ok, #{scheme := Scheme, host := Host} = U} ->
            Port =
                case maps:get(port, U, undefined) of
                    undefined -> <<>>;
                    P -> <<":", (integer_to_binary(P))/binary>>
                end,
            <<(atom_to_binary(Scheme))/binary, ":", Host/binary, Port/binary>>;
        _ ->
            Aor
    end.

%% RFC 3261 10.2.4: the expiry is the expires param of our Contact in the
%% 2xx, else its Expires header, else what we asked for
granted(Msg, #{expires := Asked} = D) ->
    Ours = maps:get(contact, D),
    Mine = [
        E
     || V <- chappe_sip_msg:get_all(<<"contact">>, Msg),
        {ok, Entries} <- [chappe_sip_hdr:name_addr_list(V)],
        #{uri := U} = E <- Entries,
        Ours =/= undefined,
        chappe_sip_uri:equal(U, Ours)
    ],
    case Mine of
        [#{params := #{<<"expires">> := X}} | _] ->
            int(X, int(chappe_sip_msg:get(<<"expires">>, Msg), Asked));
        _ ->
            int(chappe_sip_msg:get(<<"expires">>, Msg), Asked)
    end.

min_expires(Msg) ->
    int(chappe_sip_msg:get(<<"min-expires">>, Msg), undefined).

retry_after(undefined) ->
    undefined;
retry_after(Msg) ->
    case chappe_sip_msg:get(<<"retry-after">>, Msg) of
        undefined ->
            undefined;
        V ->
            [Secs | _] = binary:split(V, [<<";">>, <<"(">>]),
            int(Secs, undefined)
    end.

int(undefined, Default) ->
    Default;
int(V, Default) when is_binary(V) ->
    case chappe_sip_lib:to_int(V, Default) of
        N when is_integer(N), N > 0 -> N;
        _ -> Default
    end;
int(_V, Default) ->
    Default.

event_msg({response, Msg}) -> Msg;
event_msg({error, #chappe_sip_error{response = Msg}}) -> Msg;
event_msg(_) -> undefined.

event_status({response, Msg}) -> chappe_sip_msg:status(Msg);
event_status({error, #chappe_sip_error{status = S}}) -> S;
event_status(_) -> timeout.

%% the CSeq the UAC ended on (a digest retry takes the next one)
seen(undefined, D) ->
    D;
seen(Msg, D) ->
    case chappe_sip_msg:cseq(Msg) of
        {ok, #{seq := N}} -> D#{cseq := max(N, maps:get(cseq, D))};
        _ -> D
    end.

status_map(D) ->
    Left =
        case maps:get(expires_at, D) of
            undefined ->
                0;
            At ->
                max(0, (At - erlang:monotonic_time(millisecond)) div 1000)
        end,
    #{
        status => maps:get(status, D),
        aor => maps:get(aor, D),
        registrar => maps:get(registrar, D),
        contact => maps:get(contact, D),
        granted => maps:get(granted, D),
        expires_in => Left,
        last_status => maps:get(last, D),
        failures => maps:get(failures, D)
    }.
