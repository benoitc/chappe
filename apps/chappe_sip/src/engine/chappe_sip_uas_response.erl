%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The dialog-forming response a UAS sends, and the arguments of the
%% dialog fsm it starts, as pure functions of the request and the
%% create_uas options. chappe_sip_engine allocates the leg, starts the fsm
%% and sends what build/3 gives.
%%
%% - build/2: the status, reason, header block and body of the response,
%%   with our Contact, Supported and Allow added where the RFCs want them.
%% - contact/3: the Contact our 2xx carries (sip or sips, RFC 3261 12.1.1
%%   and RFC 5630).
%% - fsm_args/2: the dialog fsm's arguments for the request.
-module(chappe_sip_uas_response).

-include("chappe_sip.hrl").

-export([build/2, with_contact/3, with_supported/3, with_allow/3]).
-export([dialog_contact/2, has_hdr/2]).
-export([contact/3, local_contact/1, contact_uri/2]).
-export([fsm_args/2, local_addr/2, ack_wait/2, early/2, remote_cseq/1]).

-export_type([headers/0]).

-type headers() :: [{binary(), iodata()}].

%% The response to send: Opts' status (default 200), reason, headers and
%% local_sdp, Contact the one a 2xx carries.
-spec build(map(), binary()) -> {100..699, binary(), binary(), binary()}.
build(Opts, Contact) ->
    Status = maps:get(status, Opts, 200),
    Reason = maps:get(reason, Opts, <<"OK">>),
    Extra = with_allow(
        Status,
        Opts,
        with_supported(
            Status,
            Opts,
            with_contact(Status, maps:get(headers, Opts, []), Contact)
        )
    ),
    case maps:get(local_sdp, Opts, undefined) of
        undefined ->
            {Status, Reason, chappe_sip_hdr_io:join(Extra), <<>>};
        Sdp ->
            Hdrs = [{<<"Content-Type">>, <<"application/sdp">>} | Extra],
            {Status, Reason, chappe_sip_hdr_io:join(Hdrs),
                iolist_to_binary(Sdp)}
    end.

%% A dialog-forming 2xx MUST carry a Contact (RFC 3261 12.1.1) so the peer
%% can build the dialog and target in-dialog requests. Add our own unless
%% the app already supplied one.
-spec with_contact(100..699, headers(), binary()) -> headers().
with_contact(Status, Headers, Contact) when Status >= 200, Status < 300 ->
    case has_hdr(<<"contact">>, Headers) of
        true -> Headers;
        false -> Headers ++ [{<<"Contact">>, Contact}]
    end;
with_contact(_Status, Headers, _Contact) ->
    Headers.

%% the 2xx forming an INVITE dialog lists our option tags (RFC 3891 6.2),
%% unless the app set its own Supported
-spec with_supported(100..699, map(), headers()) -> headers().
with_supported(Status, #{subscription := _}, Headers) when Status >= 200 ->
    Headers;
with_supported(Status, _Opts, Headers) when Status >= 200, Status < 300 ->
    case has_hdr(<<"supported">>, Headers) of
        true -> Headers;
        false -> Headers ++ [{<<"Supported">>, ?SUPPORTED}]
    end;
with_supported(_Status, _Opts, Headers) ->
    Headers.

%% RFC 3261 13.3.1.4: a 2xx to an INVITE SHOULD carry Allow
-spec with_allow(100..699, map(), headers()) -> headers().
with_allow(Status, #{subscription := _}, Headers) when Status >= 200 ->
    Headers;
with_allow(Status, _Opts, Headers) when Status >= 200, Status < 300 ->
    case has_hdr(<<"allow">>, Headers) of
        true -> Headers;
        false -> Headers ++ [{<<"Allow">>, ?ALLOW}]
    end;
with_allow(_Status, _Opts, Headers) ->
    Headers.

%% the Contact the app put in Opts' headers, else ours
-spec dialog_contact(map(), binary()) -> binary().
dialog_contact(Opts, Contact) ->
    Supplied = [
        iolist_to_binary(V)
     || {N, V} <- maps:get(headers, Opts, []),
        string:lowercase(N) =:= <<"contact">>
    ],
    case Supplied of
        [C | _] -> C;
        [] -> Contact
    end.

%% a header of that lowercase name in the list
-spec has_hdr(binary(), list()) -> boolean().
has_hdr(Lname, Headers) ->
    lists:any(
        fun
            ({N, _}) -> string:lowercase(N) =:= Lname;
            (_) -> false
        end,
        Headers
    ).

%% RFC 3261 12.1.1: the 2xx Contact is a SIPS URI when the request had one
%% in its Request-URI, its top Record-Route, or (with no Record-Route) its
%% Contact; RFC 5630 also gives a dialog formed over TLS our sips Contact.
%% TlsUri is the TLS listener's URI, Bound the engine's bound contact.
-spec contact(
    chappe_sip_req:req(), binary() | undefined, binary() | undefined
) -> binary().
contact(Req, TlsUri, Bound) ->
    Msg = chappe_sip_req:msg(Req),
    Meta = chappe_sip_req:meta(Req),
    Secure =
        maps:get(transport, Meta, undefined) =:= <<"tls">> orelse
            lists:any(fun chappe_sip_uri:is_sips/1, [
                chappe_sip_msg:uri(Msg) | sips_candidates(Msg)
            ]),
    Local = chappe_sip_binds:local(Meta),
    Contact =
        case
            {
                Secure,
                chappe_sip_binds:tls_contact_at(Local),
                chappe_sip_binds:contact_at(Local),
                TlsUri
            }
        of
            {true, Tls, _, _} when is_binary(Tls) -> <<"<", Tls/binary, ">">>;
            {true, _, _, Tls} when is_binary(Tls) -> <<"<", Tls/binary, ">">>;
            {false, _, C, _} when is_binary(C) -> <<"<", C/binary, ">">>;
            _ -> local_contact(Bound)
        end,
    %% behind 1:1 NAT, a peer on the local network gets the local address
    chappe_sip_binds:for_peer(Contact, chappe_sip_req:source_ip(Req)).

%% the top Record-Route, else the Contact, as bare URIs
sips_candidates(Msg) ->
    Hdr =
        case chappe_sip_msg:get(<<"record-route">>, Msg) of
            undefined -> chappe_sip_msg:get(<<"contact">>, Msg);
            RR -> RR
        end,
    case Hdr of
        undefined ->
            [];
        V ->
            case chappe_sip_hdr:split_list(V) of
                [Top | _] -> [chappe_sip_hdr:name_addr_uri(Top)];
                [] -> []
            end
    end.

%% The bound contact may arrive as a name-addr (<uri;params>); extract the
%% bare URI and drop params so the Contact is a single well-formed name-addr.
-spec local_contact(binary() | undefined) -> binary().
local_contact(C) when is_binary(C) ->
    Uri = chappe_sip_hdr:name_addr_uri(C),
    Base =
        case binary:split(Uri, <<";">>) of
            [B | _] -> B;
            _ -> Uri
        end,
    <<"<", Base/binary, ">">>;
local_contact(_) ->
    <<"<sip:anonymous.invalid>">>.

%% peer Contact URI (in-dialog request target), else the remote addr URI
-spec contact_uri(binary() | undefined, binary()) -> binary().
contact_uri(undefined, RemoteAddr) ->
    chappe_sip_hdr:name_addr_uri(RemoteAddr);
contact_uri(Contact, RemoteAddr) ->
    case chappe_sip_hdr:name_addr(Contact) of
        {ok, #{uri := Uri}} -> Uri;
        _ -> chappe_sip_hdr:name_addr_uri(RemoteAddr)
    end.

%% our side of the dialog: the request's To with our tag
-spec local_addr(chappe_sip_msg:msg(), binary()) -> binary().
local_addr(Msg, LocalTag) ->
    ToVal = chappe_sip_msg:get(<<"to">>, Msg),
    <<ToVal/binary, ";tag=", LocalTag/binary>>.

%% a 2xx to an INVITE waits for its ACK (RFC 3261 13.3.1.4). The native
%% stack keeps its server transaction until the ACK or Timer H and names
%% it in both; the WS transport names the dialog leg.
-spec ack_wait(chappe_sip_msg:msg(), map()) -> boolean().
ack_wait(Msg, Opts) ->
    chappe_sip_msg:method(Msg) =:= <<"INVITE">> andalso
        is_2xx(maps:get(status, Opts, 200)).

is_2xx(Status) -> is_integer(Status) andalso Status >= 200 andalso Status < 300.

%% a 1xx from create_uas forms an early dialog of the INVITE
-spec early(chappe_sip_msg:msg(), map()) -> boolean().
early(Msg, Opts) ->
    case {chappe_sip_msg:method(Msg), maps:get(status, Opts, 200)} of
        {<<"INVITE">>, St} when is_integer(St), St < 200 -> true;
        _ -> false
    end.

%% RFC 3261 12.1.1: the remote CSeq starts at the request's
-spec remote_cseq(chappe_sip_msg:msg()) -> non_neg_integer().
remote_cseq(Msg) ->
    case chappe_sip_msg:cseq(Msg) of
        {ok, #{seq := N}} -> N;
        _ -> 0
    end.

%% The dialog fsm's arguments for Req, Opts' create_uas options plus
%% leg, owner, local_tag and contact (the Contact our response carries).
-spec fsm_args(chappe_sip_req:req(), #{
    leg := non_neg_integer(),
    owner := pid(),
    local_tag := binary(),
    contact := binary(),
    opts := map()
}) -> map().
fsm_args(Req, #{
    leg := LegH,
    owner := Owner,
    local_tag := LocalTag,
    contact := Contact,
    opts := Opts
}) ->
    Msg = chappe_sip_req:msg(Req),
    FromVal = chappe_sip_msg:get(<<"from">>, Msg),
    Meta = chappe_sip_req:meta(Req),
    #{
        leg => LegH,
        txn => chappe_sip_req:txn(Req),
        role => uas,
        opts => Opts,
        owner => Owner,
        local_tag => LocalTag,
        remote_addr => FromVal,
        local_addr => local_addr(Msg, LocalTag),
        remote_target => contact_uri(
            chappe_sip_msg:get(<<"contact">>, Msg), FromVal
        ),
        %% RFC 3261 12.1.1: route set = request Record-Route, in order, so
        %% in-dialog requests traverse the proxies
        route_set => chappe_sip_msg:get_all(<<"record-route">>, Msg),
        remote_sdp => chappe_sip_req:body(Req),
        %% a WS-originated request carries its flow so the dialog can send
        %% in-dialog requests back over it
        flow => maps:get(flow, Opts, maps:get(flow, Meta, undefined)),
        %% the Contact the 2xx carries; a subscription repeats it on a
        %% refresh 2xx (SUBSCRIBE is a target refresh request)
        local_contact => dialog_contact(Opts, Contact),
        call_id => chappe_sip_msg:call_id(Msg),
        remote_cseq => remote_cseq(Msg),
        %% the requests a B2BUA sent in the early dialog count
        cseq => maps:get(cseq, Opts, 1),
        leg_ready => maps:is_key(leg, Opts),
        ack_wait => ack_wait(Msg, Opts),
        %% the call record this INVITE opened, now the dialog's
        cdr => maps:get(cdr, Meta, undefined)
    }.
