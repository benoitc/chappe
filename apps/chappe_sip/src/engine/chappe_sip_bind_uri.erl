%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The transport rules of a bind URI (a contact or TLS contact of
%% chappe_sip:start/1), as chappe_sip_binds hands it to sofia.
-module(chappe_sip_bind_uri).

-export([native/1, tls/1]).

%% A contact with no transport parameter is unrestricted for sofia: a sip:
%% one binds udp, tcp, sctp and ws, a sips: one tls, wss and ws. sofia's
%% WebSocket transport is never opened (the Erlang one serves WebSocket),
%% so a contact naming ws, wss or * is refused, and one naming nothing gets
%% udp,tcp (tls for a sips: URI). A contact in angle brackets is taken
%% unwrapped; an empty, malformed or percent-encoded ws transport is
%% refused as well.
-spec native(binary()) -> {ok, binary()} | badarg.
native(C) ->
    case bare(C) of
        {ok, U} -> restrict(U, scheme_default(U));
        error -> badarg
    end.

%% a TLS contact binds tls unless it names its transports
-spec tls(binary()) -> {ok, binary()} | badarg.
tls(C) ->
    case bare(C) of
        {ok, U} -> restrict(U, <<"tls">>);
        error -> badarg
    end.

scheme_default(U) ->
    case chappe_sip_lib:lower(binary:part(U, 0, min(5, byte_size(U)))) of
        <<"sips:">> -> <<"tls">>;
        _ -> <<"udp,tcp">>
    end.

restrict(C, Default) ->
    case transports(C) of
        none ->
            {ok, <<C/binary, ";transport=", Default/binary>>};
        {ok, Ts} ->
            case lists:any(fun sofia_ws/1, Ts) of
                true -> badarg;
                false -> {ok, C}
            end;
        error ->
            badarg
    end.

sofia_ws(<<"ws">>) -> true;
sofia_ws(<<"wss">>) -> true;
sofia_ws(<<"*">>) -> true;
sofia_ws(_) -> false.

%% a bind URI as sofia takes it: a bare URI, or one in angle brackets with
%% nothing around them (a display name or a parameter after the `>' would
%% not reach sofia as written)
bare(C) ->
    case chappe_sip_lib:trim(C) of
        <<"<", _/binary>> = T when byte_size(T) > 2 ->
            Inner = binary:part(T, 1, byte_size(T) - 2),
            case binary:last(T) =:= $> andalso no_angle(Inner) of
                true -> {ok, Inner};
                false -> error
            end;
        T ->
            case no_angle(T) of
                true -> {ok, T};
                false -> error
            end
    end.

no_angle(B) ->
    binary:match(B, [<<"<">>, <<">">>]) =:= nomatch.

%% the transports a bind URI names, decoded and lowercased, as sofia reads
%% them: the comma list of its transport parameter, none when it has no
%% such parameter, error when the value is empty, has an empty member or a
%% broken %XX escape
transports(C) ->
    L = chappe_sip_lib:lower(C),
    case binary:match(L, <<";transport=">>) of
        nomatch ->
            none;
        {At, Len} ->
            Rest = binary:part(L, At + Len, byte_size(L) - At - Len),
            [V | _] = binary:split(Rest, [<<";">>, <<"?">>]),
            case chappe_sip_hdr:unescape(V) of
                {ok, D} ->
                    Ts = binary:split(chappe_sip_lib:lower(D), <<",">>, [
                        global
                    ]),
                    case lists:member(<<>>, Ts) of
                        true -> error;
                        false -> {ok, Ts}
                    end;
                {error, _} ->
                    error
            end
    end.
