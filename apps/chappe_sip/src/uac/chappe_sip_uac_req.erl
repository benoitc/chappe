%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The requests of one UAC transaction: the request itself (built
%% from the fsm's #data{} and sent with fresh credentials), the 2xx ACK and
%% the BYE of a dialog we do not keep, both built from the response, and
%% our Contact and From. Used by chappe_sip_uac_fsm and its helpers.
-module(chappe_sip_uac_req).

-include("chappe_sip.hrl").
-include("chappe_sip_uac_fsm.hrl").

-export([send_request/1, maybe_ack/3, send_ack/3, send_bye/2, send_bye/3]).
-export([dialog_request/6, ack_route/2, route_set/1, target_uri/1]).
-export([default_contact/1, contact_value/2, build_from/2, extract_tag/1]).
-export([gen_call_id/0, preloaded_route/1]).

%% ---- the request ----

%% Send the request D describes, with fresh credentials for every challenge
%% we answer; {ok, D} carries the new client transaction.
send_request(#data{seq = Seq, cseq = CSeq} = D0) ->
    %% a new INVITE (a retry) sets the counter the next PRACK takes from
    atomics:put(Seq, 1, CSeq),
    %% a redirect or a 305 may move to a SIPS target or proxy
    D = with_credentials(D0#data{contact = default_contact(D0)}),
    Raw = build_request(D),
    case chappe_sip_engine:send_request(route(D), Raw, self(), send_opts(D)) of
        {ok, TxnH} -> {ok, D#data{txn = TxnH}};
        {error, _} = Err -> Err
    end.

%% the Authorization / Proxy-Authorization headers of the next request:
%% one per challenge, each nonce counting its requests (RFC 7616 3.4)
with_credentials(#data{challenges = Cs, opts = Opts} = D) ->
    Auth = maps:get(auth, Opts, undefined),
    {Hdrs, NC} = chappe_sip_uac_auth:headers(
        Cs, Auth, D#data.method, D#data.uri, D#data.nonce_count
    ),
    D#data{auth_hdrs = Hdrs, nonce_count = NC}.

%% With several listen addresses: the one we send from (the local option,
%% else the first of the target's family); the engine keeps it for our
%% later requests and for the dialog we form.
send_opts(D) ->
    case local(D) of
        undefined -> #{};
        L -> #{local => L}
    end.

local(#data{opts = Opts, uri = Uri, proxy = Proxy}) ->
    chappe_sip_binds:pick_local(
        maps:get(local, Opts, undefined), target(Proxy, Uri)
    ).

%% the proxy we send through, else the Request-URI
target(Proxy, _Uri) when is_binary(Proxy) -> Proxy;
target(_Proxy, Uri) -> Uri.

%% originate over the WS flow when targeting a registered browser, else the
%% proxy URL, else the first preloaded route (or undefined, letting sofia
%% route by the Request-URI); a sip: hop is reached as sips: when the
%% Request-URI is SIPS (RFC 3261 8.1.2)
route(#data{flow = Flow}) when Flow =/= undefined ->
    chappe_sip_flow:flow_route(Flow);
route(#data{uri = Uri} = D) ->
    chappe_sip_route:secure_hop(Uri, next_hop(D)).

%% RFC 3261 8.1.2: the stack's outbound_route option, as the route set of
%% a request that names no proxy, flow or route set of its own
preloaded_route(#{proxy := _}) -> [];
preloaded_route(#{flow := _}) -> [];
preloaded_route(_Opts) -> chappe_sip_binds:outbound_route().

next_hop(#data{proxy = Proxy}) when Proxy =/= undefined ->
    Proxy;
next_hop(#data{route_set = [First | _]}) ->
    case chappe_sip_hdr:name_addr(First) of
        {ok, #{uri := U}} -> U;
        _ -> undefined
    end;
next_hop(#data{}) ->
    undefined.

build_request(#data{
    method = Method,
    uri = Uri,
    from = From,
    to = To,
    call_id = CallId,
    cseq = CSeq,
    contact = Contact,
    opts = Opts,
    min_se_422 = MinSE,
    auth_hdrs = AuthHeaders,
    route_set = RouteSet0
}) ->
    Seq = integer_to_binary(CSeq),
    %% RFC 3261 8.1.1.1: a preloaded route set shapes the Request-URI and
    %% Route as in a dialog (12.2.1.1), the target as remote target
    {RURI, RouteSet} = chappe_sip_route:request_target(Uri, RouteSet0),
    Routes = <<<<"Route: ", R/binary, "\r\n">> || R <- RouteSet>>,
    %% RFC 4028 7.1: an INVITE asks for a Session-Expires when configured
    StHeaders =
        case Method of
            <<"INVITE">> -> chappe_sip_session_timer:uac_headers(Opts, MinSE);
            _ -> []
        end,
    {CT, Body} = request_body(Opts),
    HdrBin = chappe_sip_hdr_io:join(
        extra_headers(Method, Opts) ++ StHeaders ++ AuthHeaders ++ CT
    ),
    <<Method/binary, " ", RURI/binary, " SIP/2.0\r\n", Routes/binary, "From: ",
        From/binary, "\r\n", "To: ", To/binary, "\r\n", "Call-ID: ",
        CallId/binary, "\r\n", "CSeq: ", Seq/binary, " ", Method/binary, "\r\n",
        "Contact: ", (contact_value(Contact, Opts))/binary, "\r\n",
        "Max-Forwards: 70\r\n", HdrBin/binary, "Content-Length: ",
        (integer_to_binary(byte_size(Body)))/binary, "\r\n\r\n", Body/binary>>.

%% the app's headers, then the option tags and methods we advertise
extra_headers(Method, Opts) ->
    ExtraHeaders0 = maps:get(headers, Opts, []),
    %% advertise 100rel so the UAS may send reliable provisionals, and the
    %% option tags we support on an INVITE (RFC 3891 6.2)
    Supported = supported(Method, maps:get(rel100, Opts, undefined)),
    %% RFC 3262 4: Require: 100rel on an INVITE only
    case {Method, maps:get(rel100, Opts, undefined)} of
        {<<"INVITE">>, require} ->
            [{<<"Require">>, <<"100rel">>} | ExtraHeaders0];
        _ ->
            ExtraHeaders0
    end ++ supported_header(Supported, ExtraHeaders0) ++
        allow_header(Method, ExtraHeaders0) ++
        call_ref_header(Method, Opts, ExtraHeaders0).

supported(<<"INVITE">>, supported) -> <<"100rel, ", ?SUPPORTED/binary>>;
supported(<<"INVITE">>, _) -> ?SUPPORTED;
supported(_Method, supported) -> <<"100rel, timer">>;
%% RFC 4028 7.1: timer on every request, not only the INVITE
supported(_Method, _) -> <<"timer">>.

%% RFC 3261 13.2.1: an INVITE SHOULD carry Allow, listing the methods we
%% take in the dialog; an app-supplied one wins
allow_header(<<"INVITE">>, Headers) ->
    case has_header(<<"allow">>, Headers) of
        true -> [];
        false -> [{<<"Allow">>, ?ALLOW}]
    end;
allow_header(_Method, _Headers) ->
    [].

%% an app-supplied Supported wins
supported_header(Value, Headers) ->
    case has_header(<<"supported">>, Headers) of
        true -> [];
        false -> [{<<"Supported">>, Value}]
    end.

%% the X-Chappe-Call header of an INVITE, unless the caller put one in
%% its headers or asked for none (call_ref_header => false)
call_ref_header(<<"INVITE">>, #{call_ref := Ref} = Opts, Hdrs) when
    is_binary(Ref)
->
    Name = chappe_sip_call:header(),
    Has = has_header(string:lowercase(Name), Hdrs),
    case Has orelse not maps:get(call_ref_header, Opts, true) of
        true -> [];
        false -> [{Name, Ref}]
    end;
call_ref_header(_Method, _Opts, _Hdrs) ->
    [].

%% a header of that lowercase name in the list
has_header(LName, Headers) ->
    lists:any(fun({N, _}) -> string:lowercase(N) =:= LName end, Headers).

%% The request body: local_sdp is the common case and types itself
%% application/sdp; body carries anything else (a SIPREC
%% multipart/mixed of SDP plus rs-metadata, an ISUP body, ...) with
%% content_type naming it. body wins when both are given.
request_body(Opts) ->
    case maps:get(body, Opts, undefined) of
        undefined ->
            case maps:get(local_sdp, Opts, undefined) of
                undefined ->
                    {[], <<>>};
                Sdp ->
                    {content_type(<<"application/sdp">>), iolist_to_binary(Sdp)}
            end;
        Body ->
            CT = maps:get(content_type, Opts, <<"application/sdp">>),
            {content_type(CT), iolist_to_binary(Body)}
    end.

content_type(CT) ->
    [{<<"Content-Type">>, CT}].

%% ---- requests of the dialog a response forms: ACK, BYE, PRACK ----

%% ACK to a 2xx (unless no_ack for 3PCC). Built from the response so the
%% To carries the peer tag.
maybe_ack(_Msg, _Body, #data{opts = #{no_ack := true}}) ->
    ok;
maybe_ack(Msg, Body, D) ->
    send_ack(Msg, Body, D).

%% The ACK to a 2xx is a request of the dialog the 2xx forms (RFC 3261
%% 13.2.2.4): to its Contact, through its route set (12.1.2), with the
%% INVITE's CSeq number.
send_ack(Msg, Body, #data{cseq = CSeq} = D) ->
    CT =
        case Body of
            <<>> -> <<>>;
            _ -> <<"Content-Type: application/sdp\r\n">>
        end,
    %% the ACK carries the INVITE's credentials (13.2.2.4, 22.1)
    Hdrs = <<(chappe_sip_hdr_io:join(D#data.auth_hdrs))/binary, CT/binary>>,
    Raw = dialog_request(<<"ACK">>, CSeq, Hdrs, Body, Msg, D),
    case chappe_sip_engine:send_stateless(ack_route(Msg, D), Raw, self()) of
        {ok, _} -> ok;
        Err -> Err
    end.

%% Tear down a forked extra dialog, or one whose offer we refused.
send_bye(Msg, D) ->
    send_bye(Msg, [], D).

send_bye(Msg, Hdrs, #data{cseq = CSeq} = D) ->
    Raw = dialog_request(
        <<"BYE">>, CSeq + 1, chappe_sip_hdr_io:join(Hdrs), <<>>, Msg, D
    ),
    chappe_sip_engine:send_stateless(ack_route(Msg, D), Raw, self()).

%% RFC 3261 12.2.1.1: a strict router (no ;lr) takes the Request-URI
dialog_request(Method, Seq, Hdrs, Body, Msg, #data{call_id = CallId}) ->
    From = chappe_sip_msg:get(<<"from">>, Msg),
    To = chappe_sip_msg:get(<<"to">>, Msg),
    {RURI, RouteSet} = chappe_sip_route:request_target(
        target_uri(Msg), route_set(Msg)
    ),
    Routes = <<<<"Route: ", R/binary, "\r\n">> || R <- RouteSet>>,
    <<Method/binary, " ", RURI/binary, " SIP/2.0\r\n", Routes/binary, "From: ",
        From/binary, "\r\n", "To: ", To/binary, "\r\n", "Call-ID: ",
        CallId/binary, "\r\n", "CSeq: ", (integer_to_binary(Seq))/binary, " ",
        Method/binary, "\r\n", "Max-Forwards: 70\r\n", Hdrs/binary,
        "Content-Length: ", (integer_to_binary(byte_size(Body)))/binary,
        "\r\n\r\n", Body/binary>>.

%% RFC 3261 12.1.2: the route set is the 2xx Record-Route, reversed
route_set(Msg) ->
    lists:reverse(chappe_sip_msg:get_all(<<"record-route">>, Msg)).

%% ACK/BYE/PRACK destination: the WS flow for a browser target, else the
%% first route (a loose or a strict router), else by Request-URI
ack_route(_Msg, #data{flow = Flow}) when Flow =/= undefined ->
    chappe_sip_flow:flow_route(Flow);
ack_route(Msg, _D) ->
    case route_set(Msg) of
        [First | _] ->
            case chappe_sip_hdr:name_addr(First) of
                {ok, #{uri := Uri}} ->
                    chappe_sip_route:secure_hop(target_uri(Msg), Uri);
                _ ->
                    undefined
            end;
        [] ->
            undefined
    end.

target_uri(Msg) ->
    case chappe_sip_msg:get(<<"contact">>, Msg) of
        undefined ->
            to_uri(Msg);
        Contact ->
            case chappe_sip_hdr:name_addr(Contact) of
                {ok, #{uri := Uri}} -> Uri;
                _ -> to_uri(Msg)
            end
    end.

to_uri(Msg) ->
    case chappe_sip_msg:to(Msg) of
        {ok, #{uri := Uri}} -> Uri;
        _ -> <<"sip:unknown">>
    end.

%% ---- Contact and From ----

%% The app's contact, else ours: the TLS listener's sips URI when the
%% Request-URI, the outbound proxy or the first preloaded route is SIPS
%% (RFC 3261 8.1.1.8), so a dialog it forms is secure (12.2.1.1).
default_contact(#data{opts = #{contact := C}}) ->
    C;
default_contact(#data{uri = Uri, proxy = Proxy} = D) ->
    %% behind 1:1 NAT, a target on the local network gets the local address
    chappe_sip_binds:for_peer(bound_contact(D), target_host(Proxy, Uri)).

target_host(Proxy, Uri) ->
    Target = target(Proxy, Uri),
    case is_binary(Target) andalso chappe_sip_uri:parse(Target) of
        {ok, #{host := H}} -> H;
        _ -> undefined
    end.

bound_contact(#data{} = D) ->
    %% with several listen addresses, the one we send from
    case local(D) of
        undefined ->
            any_contact(D);
        L ->
            case secure(D) andalso chappe_sip_binds:tls_contact_at(L) of
                Tls when is_binary(Tls) ->
                    Tls;
                _ ->
                    case chappe_sip_binds:contact_at(L) of
                        undefined -> any_contact(D);
                        C -> C
                    end
            end
    end.

any_contact(#data{} = D) ->
    Plain =
        case chappe_sip_engine:contact() of
            undefined -> <<"sip:anonymous@localhost">>;
            C -> chappe_sip_hdr:name_addr_uri(C)
        end,
    case secure(D) andalso chappe_sip_engine:tls_contact() of
        Tls when is_binary(Tls) -> Tls;
        _ -> Plain
    end.

secure(#data{flow = Flow}) when Flow =/= undefined ->
    false;
secure(#data{uri = Uri, proxy = Proxy, route_set = Routes}) ->
    Top =
        case Routes of
            [First | _] -> chappe_sip_hdr:name_addr_uri(First);
            [] -> undefined
        end,
    lists:any(fun chappe_sip_uri:is_sips/1, [Uri, Proxy, Top]).

%% The Contact header value: our URI in angle brackets, then any
%% contact_params (`;isfocus' for a conference focus, RFC 4579).
contact_value(Contact, Opts) ->
    <<"<", Contact/binary, ">", (maps:get(contact_params, Opts, <<>>))/binary>>.

build_from(Opts, ContactUri) ->
    Tag = chappe_sip_dialog:gen_tag(),
    case maps:get(from, Opts, undefined) of
        undefined ->
            <<"<", ContactUri/binary, ">;tag=", Tag/binary>>;
        From ->
            case binary:match(From, <<";tag=">>) of
                nomatch -> <<From/binary, ";tag=", Tag/binary>>;
                _ -> From
            end
    end.

extract_tag(From) ->
    case binary:split(From, <<";tag=">>) of
        [_, Rest] ->
            case binary:split(Rest, <<";">>) of
                [Tag, _] -> Tag;
                [Tag] -> Tag
            end;
        _ ->
            chappe_sip_dialog:gen_tag()
    end.

gen_call_id() ->
    <<
        (binary:encode_hex(crypto:strong_rand_bytes(8), lowercase))/binary,
        "@chappe"
    >>.
