%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc A presence agent (RFC 3856): the presence event package served
%% from the state the PUBLISHes left in chappe_sip_esc.
%%
%% serve/1 registers the PUBLISH handler (the ESC, for presence with
%% application/pidf+xml) and the SUBSCRIBE handler of the presence
%% package. A watcher is authenticated (auth), then your authorize fun
%% decides: allow (an active subscription), polite (200 and a document
%% saying closed: polite blocking), pending (200, a pending NOTIFY whose
%% document has a note, until decide/2) or deny (403). Every NOTIFY
%% carries the full state: the tuples of the presentity's live
%% publications, composed with chappe_sip_pidf:compose/2, the newest
%% tuple of each id winning. A change reaches every watcher, never more
%% than once per min_interval (5 s, RFC 3856 6.10).
-module(chappe_sip_presence).

-export([serve/1, decide/2, state/1, body/3]).

-define(N, chappe_sip_presence_notifier).
-define(PKG, <<"presence">>).

%% Opts:
%%   authorize := fun((Watcher, Presentity, Req) -> allow | polite |
%%                    pending | deny)
%%       Watcher is the authenticated user, else the From address-of-record;
%%       Presentity the Request-URI's (RFC 3856 6.6.2: required)
%%   auth => #{realm, secret}   digest on SUBSCRIBE (and PUBLISH unless
%%       esc has its own)
%%   expires (3600), min_expires (60)   the subscription bounds
%%   min_interval (5000)   ms between two NOTIFYs to one watcher
%%   esc => map() | false   the PUBLISH handler's options
%%       (chappe_sip_esc:handler/1), false to serve presence state you
%%       keep elsewhere
-spec serve(#{authorize := fun(), _ => _}) -> ok.
serve(#{authorize := Authorize} = Opts) when is_function(Authorize, 3) ->
    ok = chappe_sip_notifier:set_interval(
        ?N, maps:get(min_interval, Opts, 5000)
    ),
    case maps:get(esc, Opts, #{}) of
        false ->
            ok;
        Esc ->
            Pkgs = maps:get(packages, Esc, #{}),
            EscOpts = maps:merge(maps:with([auth], Opts), Esc),
            ok = chappe_sip_engine:handle(
                <<"PUBLISH">>,
                chappe_sip_esc:handler(EscOpts#{
                    packages => Pkgs#{?PKG => [chappe_sip_pidf:content_type()]}
                }),
                #{}
            )
    end,
    chappe_sip_engine:handle(
        <<"SUBSCRIBE">>,
        fun(Req, Res) ->
            subscribe(Req, Res, Authorize, Opts)
        end,
        #{package => ?PKG}
    );
serve(_Opts) ->
    erlang:error({presence, authorize_required}).

%% The pending watchers of Presentity are now allowed, politely blocked or
%% denied (a terminated NOTIFY, reason rejected).
-spec decide(binary(), allow | polite | deny) -> ok.
decide(Presentity, Decision) ->
    New = wstate(Decision),
    chappe_sip_notifier:set_state(
        ?N,
        chappe_sip_esc:resource(Presentity),
        fun
            (_Pid, pending) -> New;
            (_Pid, WS) -> WS
        end
    ).

%% The presence document watchers of Presentity get now.
-spec state(binary()) -> chappe_sip_pidf:doc().
state(Presentity) ->
    compose(chappe_sip_esc:resource(Presentity)).

%% chappe_sip_notifier callback: the document a watcher in WState gets
-spec body(binary(), atom(), term()) -> {binary(), binary()}.
body(Presentity, active, _Data) ->
    {
        chappe_sip_pidf:content_type(),
        chappe_sip_pidf:render(compose(Presentity))
    };
body(Presentity, polite, _Data) ->
    %% RFC 3856 6.6.2: nothing tells the watcher it was blocked
    Doc = #{
        entity => Presentity, tuples => [#{id => <<"p1">>, basic => closed}]
    },
    {chappe_sip_pidf:content_type(), chappe_sip_pidf:render(Doc)};
body(Presentity, _Pending, _Data) ->
    Doc = #{
        entity => Presentity,
        tuples => [],
        notes => [<<"Subscription pending authorization">>]
    },
    {chappe_sip_pidf:content_type(), chappe_sip_pidf:render(Doc)}.

%% ---- the SUBSCRIBE handler ----

subscribe(Req, Res, Authorize, Opts) ->
    case chappe_sip_esc:authenticate(maps:get(auth, Opts, undefined), Req) of
        {ok, User} ->
            accept_check(Req, Res, User, Authorize, Opts);
        {reject, Status, Hdrs} ->
            reply(Res, Status, Hdrs)
    end.

%% RFC 3856 6.5, 6.7: our NOTIFYs are application/pidf+xml, so an Accept
%% must take it
accept_check(Req, Res, User, Authorize, Opts) ->
    case accepts(chappe_sip_req:get_all(<<"accept">>, Req)) of
        true ->
            authorize(Req, Res, User, Authorize, Opts);
        false ->
            reply(Res, 406, [{<<"Accept">>, chappe_sip_pidf:content_type()}])
    end.

authorize(Req, Res, User, Authorize, Opts) ->
    Presentity = chappe_sip_esc:resource(chappe_sip_req:uri(Req)),
    Watcher =
        case User of
            undefined -> from_aor(Req);
            _ -> User
        end,
    case Authorize(Watcher, Presentity, Req) of
        deny ->
            reply(Res, 403, []);
        Decision ->
            accept(Req, Res, Presentity, wstate(Decision), Opts)
    end.

accept(Req, Res, Presentity, WState, Opts) ->
    UasOpts = #{
        owner => whereis(?N),
        expires => maps:get(expires, Opts, 3600),
        min_expires => maps:get(min_expires, Opts, 60)
    },
    case chappe_sip_dialog:create_uas(Req, Res, UasOpts) of
        {ok, Dialog} ->
            Fetch = chappe_sip_dialog_fsm:requested_expires(Req, 1) =:= 0,
            chappe_sip_notifier:add(?N, Dialog, Presentity, WState, Fetch);
        {error, _} ->
            ok
    end.

wstate(allow) -> active;
wstate(polite) -> polite;
wstate(pending) -> pending;
wstate(deny) -> rejected.

accepts([]) ->
    true;
accepts(Values) ->
    Types = [
        string:lowercase(string:trim(hd(binary:split(T, <<";">>))))
     || V <- Values, T <- binary:split(V, <<",">>, [global])
    ],
    lists:any(
        fun(T) ->
            lists:member(T, [
                chappe_sip_pidf:content_type(), <<"*/*">>, <<"application/*">>
            ])
        end,
        Types
    ).

compose(Presentity) ->
    Docs = [
        D
     || #{body := B} <- chappe_sip_esc:publications(Presentity, ?PKG),
        {ok, D} <- [chappe_sip_pidf:parse(B)]
    ],
    chappe_sip_pidf:compose(Presentity, Docs).

from_aor(Req) ->
    case chappe_sip_hdr:name_addr(chappe_sip_req:get(<<"from">>, Req)) of
        {ok, #{uri := U}} -> chappe_sip_esc:resource(U);
        _ -> undefined
    end.

reply(Res, Status, Hdrs) ->
    _ = chappe_sip_res:send(Res, Status, #{headers => Hdrs}),
    ok.
