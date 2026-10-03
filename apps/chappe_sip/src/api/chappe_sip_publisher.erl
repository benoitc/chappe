%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc An event publication agent (RFC 3903): one process per state you
%% publish (chappe_sip:publish_state/4).
%%
%% It sends the initial PUBLISH with the body, keeps the entity-tag of
%% each 2xx, refreshes before the granted Expires runs out (no body,
%% SIP-If-Match), modifies on update/2 (the body, SIP-If-Match) and
%% removes on unpublish/1 (Expires: 0, SIP-If-Match). A 412 drops the
%% entity-tag and the whole body goes out again in an initial PUBLISH; a
%% 423 is retried with its Min-Expires. One PUBLISH at a time: an update
%% made while one is out waits for its final response (RFC 3903 4).
%% The owner gets {chappe_sip_publication, Pub, Event}:
%%   {published, Expires}     a 2xx to an initial PUBLISH or a modify
%%   {failed, Status | term()}  the PUBLISH failed; the process stops
%%   unpublished              the state was removed; the process stops
-module(chappe_sip_publisher).
-behaviour(gen_statem).

-include("chappe_sip.hrl").

-export([start/4, update/2, unpublish/1]).
-export([start_link/1]).
-export([init/1, callback_mode/0, handle_event/4]).
-export_type([publication/0]).

-type publication() :: pid().

%% Opts: content_type (default application/pidf+xml for presence),
%% expires (3600), owner (default self()), from, to, proxy, route_set,
%% auth, flow, headers (as chappe_sip_uac).
-spec start(binary(), binary(), iodata(), map()) ->
    {ok, publication()} | {error, term()}.
start(Uri, Event, Body, Opts) ->
    chappe_sip_events_sup:start_publisher(#{
        uri => Uri,
        event => Event,
        body => iolist_to_binary(Body),
        opts => Opts,
        owner => maps:get(owner, Opts, self())
    }).

%% Publish this body instead (a modify).
-spec update(publication(), iodata()) -> ok.
update(Pub, Body) ->
    gen_statem:cast(Pub, {update, iolist_to_binary(Body)}).

%% Remove the published state.
-spec unpublish(publication()) -> ok.
unpublish(Pub) ->
    gen_statem:cast(Pub, unpublish).

start_link(Args) ->
    gen_statem:start_link(?MODULE, Args, []).

callback_mode() -> handle_event_function.

init(#{owner := Owner} = Args) ->
    Tag = chappe_sip_dialog:gen_tag(),
    D = #{
        uri => maps:get(uri, Args),
        event => maps:get(event, Args),
        body => maps:get(body, Args),
        opts => maps:get(opts, Args),
        owner => Owner,
        owner_mon => erlang:monitor(process, Owner),
        call_id => <<
            (binary:encode_hex(crypto:strong_rand_bytes(8), lowercase))/binary,
            "@chappe"
        >>,
        tag => Tag,
        cseq => 0,
        etag => undefined,
        expires => maps:get(expires, maps:get(opts, Args), 3600),
        uac => undefined,
        queue => []
    },
    case send(initial, D) of
        {ok, D1} -> {ok, busy, D1};
        {error, Why} -> {stop, Why}
    end.

%% ---- events ----

handle_event(cast, Op, busy, D) when
    Op =:= unpublish; element(1, Op) =:= update
->
    %% RFC 3903 4: not before the final response to the one out
    {keep_state, D#{queue := maps:get(queue, D) ++ [Op]}};
handle_event(cast, {update, Body}, idle, D) ->
    go(modify, D#{body := Body});
handle_event(cast, unpublish, idle, D) ->
    go(remove, D);
handle_event({timeout, refresh}, _, idle, D) ->
    go(refresh, D);
handle_event({timeout, refresh}, _, busy, _D) ->
    {keep_state_and_data, [postpone]};
handle_event(info, {chappe_sip_uac, Ref, Event}, busy, #{uac := {Ref, Op}} = D) ->
    response(Event, Op, D);
handle_event(
    info, {'DOWN', MRef, process, _, _}, _State, #{owner_mon := MRef} = D
) ->
    %% nobody wants the state any more: remove it
    case maps:get(etag, D) of
        undefined -> {stop, normal};
        _ -> {keep_state, D#{queue := [unpublish]}, [{next_event, cast, flush}]}
    end;
handle_event(cast, flush, idle, D) ->
    next(D);
handle_event(_Type, _Msg, _State, _D) ->
    keep_state_and_data.

response({request_sent, _}, _Op, _D) ->
    keep_state_and_data;
response({provisional, _}, _Op, _D) ->
    keep_state_and_data;
response({response, Msg}, Op, D0) ->
    D = seen(Msg, D0#{uac := undefined}),
    case Op of
        remove ->
            tell(D, unpublished),
            {stop, normal, D};
        _ ->
            %% RFC 3903 4.3, 4.4: keep the new entity-tag
            ETag = chappe_sip_msg:get(<<"sip-etag">>, Msg),
            Exp = expires(Msg, maps:get(expires, D)),
            _ = Op =/= refresh andalso tell(D, {published, Exp}),
            next(D#{etag := ETag}, [refresh_timer(Exp)])
    end;
response({error, #chappe_sip_error{status = 412, response = Msg}}, Op, D0) when
    Op =/= initial
->
    %% RFC 3903 5: drop the entity-tag, publish the whole state again
    D = seen(Msg, D0#{uac := undefined, etag := undefined}),
    case Op of
        remove ->
            tell(D, unpublished),
            {stop, normal, D};
        _ ->
            go(initial, D)
    end;
response({error, #chappe_sip_error{status = 423, response = Msg}}, Op, D0) ->
    %% RFC 3903 5: again, with the Expires the 423 asks for
    D = seen(Msg, D0#{uac := undefined}),
    case chappe_sip_msg:get(<<"min-expires">>, Msg) of
        undefined ->
            failed(423, D);
        V ->
            go(Op, D#{expires := binary_to_integer(string:trim(V))})
    end;
response({error, #chappe_sip_error{status = S, response = Msg}}, _Op, D) ->
    failed(S, seen(Msg, D));
response({error, Why}, _Op, D) ->
    failed(Why, D).

failed(Why, D) ->
    tell(D, {failed, Why}),
    {stop, normal, D}.

go(Op, D) ->
    case send(Op, D) of
        {ok, D1} -> {next_state, busy, D1};
        {error, Why} -> failed(Why, D)
    end.

next(D) ->
    next(D, []).

next(#{queue := [Op | Rest]} = D, Actions) ->
    {next_state, idle, D#{queue := Rest}, [{next_event, cast, Op} | Actions]};
next(D, Actions) ->
    {next_state, idle, D, Actions}.

%% ---- the PUBLISH ----

send(Op, D) ->
    Opts = maps:get(opts, D),
    Seq = maps:get(cseq, D) + 1,
    {Expires, Body, IfMatch} =
        case Op of
            initial -> {maps:get(expires, D), maps:get(body, D), []};
            modify -> {maps:get(expires, D), maps:get(body, D), if_match(D)};
            refresh -> {maps:get(expires, D), <<>>, if_match(D)};
            remove -> {0, <<>>, if_match(D)}
        end,
    Uac = maps:merge(
        maps:with([to, contact, proxy, route_set, auth, flow], Opts),
        #{
            method => <<"PUBLISH">>,
            call_id => maps:get(call_id, D),
            cseq => Seq,
            from => from(D),
            headers =>
                [
                    {<<"Event">>, maps:get(event, D)},
                    {<<"Expires">>, integer_to_binary(Expires)}
                ] ++ IfMatch ++ maps:get(headers, Opts, []),
            notify => self(),
            owner => self()
        }
    ),
    Uac1 =
        case Body of
            <<>> -> Uac;
            _ -> Uac#{body => Body, content_type => content_type(D)}
        end,
    case chappe_sip_uac:start(maps:get(uri, D), Uac1) of
        {ok, Ref} -> {ok, D#{uac := {Ref, Op}, cseq := Seq}};
        {error, _} = Err -> Err
    end.

if_match(#{etag := ETag}) when is_binary(ETag) -> [{<<"SIP-If-Match">>, ETag}];
if_match(_D) -> [].

content_type(#{opts := #{content_type := CT}}) -> CT;
content_type(_D) -> chappe_sip_pidf:content_type().

from(#{opts := #{from := From}, tag := Tag}) ->
    <<(hd(binary:split(From, <<";tag=">>)))/binary, ";tag=", Tag/binary>>;
from(#{uri := Uri, tag := Tag}) ->
    <<"<", Uri/binary, ">;tag=", Tag/binary>>.

%% the CSeq the UAC ended on (a digest retry takes the next one)
seen(undefined, D) ->
    D;
seen(Msg, D) ->
    case chappe_sip_msg:cseq(Msg) of
        {ok, #{seq := N}} -> D#{cseq := max(N, maps:get(cseq, D))};
        _ -> D
    end.

expires(Msg, Default) ->
    case chappe_sip_msg:get(<<"expires">>, Msg) of
        undefined ->
            Default;
        V ->
            try binary_to_integer(string:trim(V)) of
                N when N >= 0 -> N;
                _ -> Default
            catch
                error:badarg -> Default
            end
    end.

%% refresh a little before the expiry: a third early, at most 32 s
refresh_timer(Exp) ->
    Ms = Exp * 1000,
    {{timeout, refresh}, Ms - min(Ms div 3, 32000), go}.

tell(#{owner := Owner}, Event) ->
    Owner ! {chappe_sip_publication, self(), Event},
    ok.
