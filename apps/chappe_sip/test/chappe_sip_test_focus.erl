%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The smallest conference an app would write on chappe_sip_focus: one
%% gen_server per conference URI, participants joined by INVITE (an audio
%% answer, no real media), the first one in is the host and the conference
%% ends when the host leaves (RFC 4579 5.12). A participant's REFER makes
%% the focus call the target (RFC 4579 5.5); an INVITE to a factory URI
%% (user part `factory') creates the conference (RFC 4579 5.4). A leg that
%% left stays listed as disconnected, with how it left. Used by
%% chappe_sip_focus_SUITE and chappe_sip_gate2_SUITE.
-module(chappe_sip_test_focus).
-behaviour(gen_server).

-include_lib("chappe_sip/include/chappe_sip.hrl").
-include_lib("chappe_sip/include/chappe_sip_uac.hrl").

-export([start/1, start/2, stop/0, install/0]).
-export([set_description/1, kick/1, uri/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(ANSWER,
    <<"v=0\r\no=focus 1 1 IN IP4 127.0.0.1\r\ns=conf\r\nc=IN IP4 127.0.0.1\r\n"
    "t=0 0\r\nm=audio 40020 RTP/AVP 0\r\na=sendrecv\r\n">>
).
-define(AVAILABLE, [
    #{label => <<"main-audio">>, type => audio, status => sendrecv}
]).

-record(state, {
    uri :: binary(),
    contact :: binary(),
    focus :: chappe_sip_focus:focus(),
    description :: map(),
    %% leg key => #{uri, display, private, n, ep, dialog, refer}
    legs = #{} :: map(),
    host :: term(),
    seq = 0 :: non_neg_integer()
}).

%% Uri: the conference URI; one conference at a time, registered locally.
%% FocusOpts go to chappe_sip_focus:new/1.
start(Uri) ->
    start(Uri, #{}).

start(Uri, FocusOpts) ->
    gen_server:start({local, ?MODULE}, ?MODULE, {Uri, FocusOpts}, []).

stop() ->
    case whereis(?MODULE) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid)
    end.

uri() ->
    gen_server:call(?MODULE, uri).

%% merged into the conference description
set_description(D) ->
    gen_server:call(?MODULE, {description, D}).

%% the focus hangs up the participant whose user entity is Uri
kick(Uri) ->
    gen_server:call(?MODULE, {kick, Uri}).

%% the SIP entry points, routed to the running conference
install() ->
    ok = chappe_sip:invite(fun invite/2),
    ok = chappe_sip:options(fun options/2),
    ok = chappe_sip:subscribe(fun subscribe/2),
    ok.

invite(Req, Res) ->
    case conference(Req) of
        undefined ->
            chappe_sip_res:send(Res, 404);
        Conf ->
            Contact = gen_server:call(Conf, contact),
            Opts0 = #{
                owner => Conf,
                handled_events => [refer],
                headers => chappe_sip_focus:headers(Contact)
            },
            Opts =
                case chappe_sip_req:body(Req) of
                    <<>> -> Opts0;
                    _ -> Opts0#{local_sdp => ?ANSWER}
                end,
            case chappe_sip:create_uas(Req, Res, Opts) of
                {ok, D} -> gen_server:cast(Conf, {joined, D, summary(Req)});
                {error, _} -> ok
            end
    end.

%% the running conference, or a new one for an INVITE to the factory URI
conference(Req) ->
    case {whereis(?MODULE), factory(chappe_sip_req:uri(Req))} of
        {undefined, {true, Uri}} ->
            {ok, Pid} = start(Uri),
            Pid;
        {Pid, _} ->
            Pid
    end.

factory(<<"sip:factory@", Host/binary>>) ->
    Id = binary:encode_hex(crypto:strong_rand_bytes(4), lowercase),
    {true, <<"sip:conf-", Id/binary, "@", Host/binary>>};
factory(_) ->
    false.

options(_Req, Res) ->
    case whereis(?MODULE) of
        undefined ->
            chappe_sip_res:send(Res, 404);
        Conf ->
            Contact = gen_server:call(Conf, contact),
            chappe_sip_res:send(Res, 200, #{
                headers => chappe_sip_focus:headers(Contact)
            })
    end.

subscribe(Req, Res) ->
    case whereis(?MODULE) of
        undefined ->
            chappe_sip_res:send(Res, 404);
        Conf ->
            Contact = gen_server:call(Conf, contact),
            chappe_sip_focus:subscribe(Req, Res, Conf, #{contact => Contact})
    end.

summary(Req) ->
    Msg = chappe_sip_req:msg(Req),
    {Uri, Display} =
        case chappe_sip_msg:parsed(<<"from">>, Msg) of
            {ok, #{uri := U} = F} -> {U, maps:get(display, F, undefined)};
            _ -> {<<>>, undefined}
        end,
    Contact =
        case chappe_sip_msg:parsed(<<"contact">>, Msg) of
            {ok, [#{uri := C} | _]} -> C;
            _ -> Uri
        end,
    #{
        uri => Uri,
        display => Display,
        contact => Contact,
        sdp => chappe_sip_req:body(Req),
        private => chappe_sip_focus:privacy_requested(Req)
    }.

%% ---- gen_server ----

init({Uri, FocusOpts}) ->
    {ok, #state{
        uri = Uri,
        contact = chappe_sip_focus:contact(Uri),
        focus = chappe_sip_focus:new(FocusOpts#{entity => Uri}),
        description = #{
            conf_uris => [#{uri => Uri, purpose => <<"participation">>}],
            available_media => ?AVAILABLE
        }
    }}.

handle_call(contact, _From, S) ->
    {reply, S#state.contact, S};
handle_call(uri, _From, S) ->
    {reply, S#state.uri, S};
handle_call({description, D}, _From, S) ->
    {reply, ok, changed(S#state{description = maps:merge(S#state.description, D)})};
handle_call({kick, Uri}, _From, S) ->
    Ds = [
        D
     || #{uri := U, dialog := D, ep := #{status := St}} <- maps:values(
            S#state.legs
        ),
        U =:= Uri,
        D =/= undefined,
        St =/= disconnected
    ],
    [spawn(fun() -> hangup(D) end) || D <- Ds],
    {reply, length(Ds), S}.

handle_cast({joined, D, Summary}, S) ->
    #{contact := Contact, sdp := Sdp} = Summary,
    Ep = #{
        entity => Contact,
        status => chappe_sip_focus:leg_status(Sdp),
        joining_method => dialed_in,
        call_info => call_info(D, uas),
        media => chappe_sip_focus:media(Sdp, ?AVAILABLE)
    },
    Leg = maps:with([uri, display, private], Summary),
    {noreply, changed(add_leg(chappe_sip_dialog:id(D), Leg#{dialog => D, ep => Ep}, S))}.

add_leg(Key, Leg, S) ->
    N = S#state.seq + 1,
    Host =
        case S#state.host of
            undefined -> Key;
            H -> H
        end,
    S#state{
        legs = maps:put(Key, Leg#{n => N, key => Key}, S#state.legs),
        seq = N,
        host = Host
    }.

handle_info(Msg, S) ->
    case chappe_sip_focus:handle_info(Msg, S#state.focus) of
        {ok, F} -> {noreply, S#state{focus = F}};
        ignore -> leg_info(Msg, S)
    end.

%% a participant asks the focus to call someone (RFC 4579 5.5)
leg_info({chappe_sip_dialog, D, refer, Req, Res}, S) ->
    case chappe_sip_refer:accept(D, Req, Res, #{}) of
        {ok, Refer} ->
            #{target := Target} = chappe_sip_refer:target(Refer),
            {noreply, changed(dial(Target, Refer, S))};
        {error, _} ->
            {noreply, S}
    end;
%% a re-INVITE the dialog answered itself: hold or resume
leg_info({chappe_sip_dialog, D, {auto_answered, modify}, Req}, S) ->
    Sdp = chappe_sip_req:body(Req),
    {noreply,
        changed(
            update_ep(
                chappe_sip_dialog:id(D),
                fun(Ep) ->
                    Ep#{
                        status => chappe_sip_focus:leg_status(Sdp),
                        media => chappe_sip_focus:media(Sdp, ?AVAILABLE)
                    }
                end,
                S
            )
        )};
leg_info({chappe_sip_dialog, D, destroy, Why}, S) ->
    Id = chappe_sip_dialog:id(D),
    S1 = changed(left(Id, Why, S)),
    case S1#state.host of
        Id -> {stop, normal, S1};
        _ -> {noreply, S1}
    end;
leg_info({chappe_sip_uac, Ref, {provisional, Msg}}, S) ->
    case chappe_sip_msg:status(Msg) of
        St when St >= 180 ->
            {noreply,
                changed(update_ep({dial, Ref}, fun(Ep) -> Ep#{status => alerting} end, S))};
        _ ->
            {noreply, S}
    end;
leg_info({chappe_sip_uac, Ref, {ok, D}}, S) ->
    Key = {dial, Ref},
    Sdp = chappe_sip_dialog:remote_sdp(D),
    S1 = update_ep(
        Key,
        fun(Ep) ->
            Ep#{
                status => chappe_sip_focus:leg_status(Sdp),
                call_info => call_info(D, uac),
                media => chappe_sip_focus:media(Sdp, ?AVAILABLE)
            }
        end,
        S
    ),
    #{Key := Leg} = S1#state.legs,
    ok = chappe_sip_refer:final(maps:get(refer, Leg), 200),
    %% the leg is known by its dialog from now on
    Legs = maps:put(
        chappe_sip_dialog:id(D), Leg#{dialog => D}, maps:remove(Key, S1#state.legs)
    ),
    {noreply, changed(S1#state{legs = Legs})};
leg_info({chappe_sip_uac, Ref, {error, E}}, S) ->
    Key = {dial, Ref},
    case maps:find(Key, S#state.legs) of
        {ok, #{refer := Refer}} ->
            Status =
                case E of
                    #chappe_sip_error{status = St} -> St;
                    _ -> 500
                end,
            ok = chappe_sip_refer:final(Refer, Status),
            {noreply, changed(left(Key, E, S))};
        error ->
            {noreply, S}
    end;
leg_info(_Msg, S) ->
    {noreply, S}.

%% call Target as the focus, for the participant who REFERred it
dial(Target, Refer, S) ->
    {ok, Ref} = chappe_sip_uac:start(Target, #{
        contact => S#state.uri,
        contact_params => chappe_sip_focus:contact_params(),
        from => <<"<", (S#state.uri)/binary, ">">>,
        local_sdp => ?ANSWER,
        notify => self(),
        owner => self()
    }),
    Ep = #{
        entity => Target,
        status => dialing_out,
        joining_method => dialed_out,
        referred => chappe_sip_focus:referred(Refer)
    },
    Leg = #{
        uri => Target,
        display => undefined,
        private => false,
        ep => Ep,
        dialog => undefined,
        refer => Refer
    },
    add_leg({dial, Ref}, Leg, S).

%% the leg stays listed, disconnected, saying how it left
left(Key, Why, S) ->
    update_ep(
        Key,
        fun(Ep) ->
            maps:remove(media, Ep#{
                status => disconnected,
                disconnection_method => chappe_sip_focus:departure(Why)
            })
        end,
        S
    ).

update_ep(Key, F, S) ->
    case maps:find(Key, S#state.legs) of
        {ok, #{ep := Ep} = Leg} ->
            S#state{legs = maps:put(Key, Leg#{ep => F(Ep)}, S#state.legs)};
        error ->
            S
    end.

%% the dialog's identifiers as the participant's INVITE (uas) or ours
%% (uac) set them
call_info(D, Role) ->
    {L, R} = {chappe_sip_dialog:local_tag(D), chappe_sip_dialog:remote_tag(D)},
    {From, To} =
        case Role of
            uas -> {R, L};
            uac -> {L, R}
        end,
    #{call_id => chappe_sip_dialog:call_id(D), from_tag => From, to_tag => To}.

%% as an app would: end the subscriptions, then hang up the legs (which
%% keeps the process alive a round trip longer)
terminate(_Reason, S) ->
    ok = chappe_sip_focus:stop(S#state.focus),
    [
        hangup(D)
     || #{dialog := D, ep := #{status := St}} <- maps:values(S#state.legs),
        D =/= undefined,
        St =/= disconnected
    ],
    ok.

hangup(D) ->
    try
        chappe_sip_dialog:destroy(D)
    catch
        exit:_ -> ok
    end.

changed(S) ->
    S#state{focus = chappe_sip_focus:update(model(S), S#state.focus)}.

model(S) ->
    Legs = lists:sort(
        fun(#{n := A}, #{n := B}) -> A =< B end, maps:values(S#state.legs)
    ),
    Users = [user(Leg, S) || Leg <- Legs],
    In = [L || #{ep := #{status := St}} = L <- Legs, St =/= disconnected],
    #{
        entity => S#state.uri,
        version => 0,
        description => S#state.description,
        user_count => length(In),
        users => Users
    }.

user(#{uri := Uri, n := N, key := Key, ep := Ep} = Leg, S) ->
    Role =
        case Key of
            H when H =:= S#state.host -> <<"host">>;
            _ -> <<"participant">>
        end,
    U0 = #{entity => Uri, roles => [Role], endpoints => [Ep]},
    U =
        case Leg of
            #{display := Disp} when is_binary(Disp), Disp =/= <<>> ->
                U0#{display_text => Disp};
            _ ->
                U0
        end,
    case Leg of
        #{private := true} -> chappe_sip_confinfo:anonymize(U, N);
        _ -> U
    end.
