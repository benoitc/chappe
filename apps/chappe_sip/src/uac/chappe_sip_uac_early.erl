%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The dialogs one UAC INVITE forms: early dialogs from tagged
%% provisionals (RFC 3261 12.1), the PRACK of a reliable one (RFC 3262),
%% and the dialog of the 2xx, an early one confirmed or a new one
%% (13.2.2.4), handed to a dialog fsm. Used by chappe_sip_uac_fsm.
-module(chappe_sip_uac_early).

-include("chappe_sip_uac_fsm.hrl").

-export([early_dialog/3, take_early/2, end_early/2]).
-export([reliable/3, send_prack/3, prack_done/2]).
-export([establish_dialog/3, drop_dialog/1]).

%% ---- early dialogs (RFC 3261 12.1, 13.2.2.4) ----

%% A 101..199 with a To tag forms an early dialog {CallId, OurTag, Tag}:
%% a dialog fsm in the early state, its route set and remote target from
%% this provisional (12.1.2). A later one of the same dialog only brings
%% the SDP it may lack. When the fsm cannot start (the max_dialogs cap),
%% the call goes on without an early handle.
early_dialog(Status, Msg, #data{method = <<"INVITE">>} = D) when Status > 100 ->
    case chappe_sip_msg:to_tag(Msg) of
        undefined ->
            D;
        Tag ->
            case
                {maps:find(Tag, D#data.early), lists:member(Tag, D#data.byed)}
            of
                {{ok, Dialog}, _} ->
                    Body = chappe_sip_msg:body(Msg),
                    _ =
                        Body =/= <<>> andalso
                            gen_statem:cast(
                                chappe_sip_dialog:pid(Dialog), {early_sdp, Body}
                            ),
                    D;
                {error, true} ->
                    D;
                {error, false} ->
                    start_early(Tag, Msg, D)
            end
    end;
early_dialog(_Status, _Msg, D) ->
    D.

start_early(Tag, Msg, D) ->
    Args = (dialog_args(Msg, undefined, D))#{
        early_uac => self(),
        cseq_ref => D#data.seq,
        remote_sdp => chappe_sip_msg:body(Msg),
        pending_ack => undefined,
        %% an early dialog gets the record only if its 2xx confirms it
        cdr => undefined
    },
    case create_dialog(Args) of
        {ok, Dialog} ->
            chappe_sip_uac_fsm:notify(D, {early_dialog, Dialog}),
            D#data{early = (D#data.early)#{Tag => Dialog}};
        {error, Reason} ->
            logger:info("chappe_sip_uac: no early dialog ~s: ~p", [Tag, Reason]),
            D
    end.

%% the early dialog the 2xx with To tag Tag confirms, the others ended
take_early(Tag, #data{early = Early} = D) ->
    Mine = maps:get(Tag, Early, undefined),
    D1 = end_early(200, D#data{early = maps:remove(Tag, Early)}),
    {Mine, D1}.

%% the INVITE got its final response: its early dialogs end
end_early(Status, #data{early = Early} = D) ->
    _ = [
        gen_statem:cast(
            chappe_sip_dialog:pid(Dialog), {early_end, {early_ended, Status}}
        )
     || Dialog <- maps:values(Early)
    ],
    D#data{early = #{}}.

%% ---- reliable provisionals (100rel): PRACK ----

%% RFC 3262 4: a 101..199 with Require: 100rel and an RSeq is reliable (a
%% 100 never is); one lacking either is an ordinary provisional, never
%% PRACKed. In each early dialog the first one sets the sequence; after it
%% only RSeq + 1 is new, a lower or equal RSeq is a retransmission and a
%% higher one is out of order: both are dropped without a PRACK.
reliable(Status, Msg, #data{rseq = Seen}) when Status > 100 ->
    Required = lists:member(
        <<"100rel">>,
        chappe_sip_hdr:option_tags(chappe_sip_msg:get_all(<<"require">>, Msg))
    ),
    case Required andalso rseq(Msg) of
        false ->
            unreliable;
        undefined ->
            unreliable;
        N ->
            Key = chappe_sip_msg:to_tag(Msg),
            case maps:get(Key, Seen, undefined) of
                undefined -> {new, N, Key};
                Last when N =:= Last + 1 -> {new, N, Key};
                _ -> drop
            end
    end;
reliable(_Status, _Msg, _D) ->
    unreliable.

rseq(Msg) ->
    case chappe_sip_msg:get(<<"rseq">>, Msg) of
        undefined ->
            undefined;
        V ->
            case chappe_sip_lib:to_int(V, undefined) of
                N when is_integer(N), N >= 1, N =< 16#FFFFFFFF -> N;
                _ -> undefined
            end
    end.

%% RAck = RSeq CSeq method. The PRACK is a request of the early dialog
%% the 1xx formed: to its Contact, through its route set (RFC 3262 4,
%% RFC 3261 12.1.2), like the 2xx ACK.
send_prack(
    RSeq,
    Msg,
    #data{cseq = InvCSeq, seq = Seq} = D
) ->
    PCSeq = atomics:add_get(Seq, 1, 1),
    RAck = <<
        (integer_to_binary(RSeq))/binary,
        " ",
        (integer_to_binary(InvCSeq))/binary,
        " INVITE"
    >>,
    {Body, D1} = chappe_sip_uac_sdp:prack_answer(Msg, D),
    CT =
        case Body of
            <<>> -> <<>>;
            _ -> <<"Content-Type: application/sdp\r\n">>
        end,
    Hdrs = <<"RAck: ", RAck/binary, "\r\n", CT/binary>>,
    Raw = chappe_sip_uac_req:dialog_request(
        <<"PRACK">>, PCSeq, Hdrs, Body, Msg, D1
    ),
    Route = chappe_sip_uac_req:ack_route(Msg, D1),
    case chappe_sip_engine:send_request(Route, Raw, self()) of
        {ok, PTxn} ->
            D1#data{prack_txns = [PTxn | D1#data.prack_txns]};
        _ ->
            D1
    end.

prack_done(PTxn, D) ->
    case lists:member(PTxn, D#data.prack_txns) of
        true ->
            chappe_sip_engine:finish_txn(PTxn),
            D#data{prack_txns = D#data.prack_txns -- [PTxn]};
        false ->
            D
    end.

%% ---- the dialog of the 2xx ----

%% The dialog of the 2xx: its early dialog confirmed (13.2.2.4: route set
%% and remote target taken again from the 2xx), else a new one (12.1.2).
%% An early dialog gone meanwhile (its request got 481) gives a new one.
establish_dialog(Early, Msg, #data{min_se_422 = MinSE} = D) ->
    %% RFC 4028 7.2: the session timer the 2xx sets up
    St = chappe_sip_session_timer:uac_answer(
        Msg, chappe_sip_uac_retry:requested_interval(D), MinSE
    ),
    Args = dialog_args(Msg, St, D),
    case confirm_early(Early, Args) of
        ok -> {ok, Early};
        error -> create_dialog(Args)
    end.

confirm_early(undefined, _Args) ->
    error;
confirm_early(Dialog, Args) ->
    try gen_statem:call(chappe_sip_dialog:pid(Dialog), {confirm, Args}, 5000) of
        ok -> ok;
        _ -> error
    catch
        exit:_ -> error
    end.

dialog_args(
    Msg,
    St,
    #data{
        call_id = CallId,
        local_tag = LocalTag,
        owner = Owner,
        opts = Opts,
        seq = Seq,
        flow = Flow
    } = D
) ->
    %% the dialog continues from after any PRACKs sent during setup; carry the
    %% WS flow so the dialog can send in-dialog requests back over it
    DialogArgs0 = #{
        call_id => CallId,
        % our From incl. our tag
        local_addr => chappe_sip_msg:get(<<"from">>, Msg),
        % our To incl. peer tag
        remote_addr => chappe_sip_msg:get(<<"to">>, Msg),
        remote_target => chappe_sip_uac_req:target_uri(Msg),
        local_tag => LocalTag,
        owner => Owner,
        opts => Opts,
        %% the last CSeq number used; in-dialog requests take the next one
        cseq => atomics:get(Seq, 1),
        flow => Flow,
        %% RFC 3261 12.1.2: route set = 2xx Record-Route reversed
        route_set => chappe_sip_uac_req:route_set(Msg),
        remote_sdp => chappe_sip_uac_sdp:remote_sdp(Msg, D),
        %% repeated on in-dialog target refresh requests
        local_contact => chappe_sip_uac_req:contact_value(D#data.contact, Opts),
        session_timer => St,
        %% the dialog drives the call record once answered
        cdr => D#data.cdr
    },
    %% our session is the answer a PRACK carried, else the opts' offer
    DialogArgs1 =
        case D#data.local_answer of
            <<>> -> DialogArgs0;
            A -> DialogArgs0#{local_sdp => A}
        end,
    %% no_ack (3PCC): the dialog sends the 2xx ACK when the app has it
    case Opts of
        #{no_ack := true} ->
            DialogArgs1#{
                pending_ack => #{
                    cseq => D#data.cseq, headers => D#data.auth_hdrs
                }
            };
        _ ->
            DialogArgs1
    end.

create_dialog(DialogArgs) ->
    case chappe_sip_engine:create_dialog(DialogArgs) of
        {ok, Pid, LegH} ->
            %% wait for the leg to be confirmed before handing the dialog
            %% to the app (else an immediate destroy hits setup state)
            try gen_statem:call(Pid, await_ready, 5000) of
                {ok, _} -> {ok, chappe_sip_dialog:make(Pid, LegH)};
                {error, Reason} -> {error, Reason}
            catch
                exit:Reason -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% a dialog whose 2xx we could not ACK is not handed to the app; its BYE
%% may wait for Timer F, so not here
drop_dialog(Dialog) ->
    spawn(fun() ->
        try
            chappe_sip_dialog:destroy(Dialog)
        catch
            exit:_ -> ok
        end
    end).
