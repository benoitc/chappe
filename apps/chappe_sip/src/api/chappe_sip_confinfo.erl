%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% RFC 4575 conference-info documents, as the focus sends them in NOTIFY
%% for the `conference` event package.
%%
%% full/1 renders the whole conference, always with the
%% <conference-description> and <users> RFC 4575 5.2 requires. partial/3 renders only what
%% changed between two snapshots (RFC 4575 section 4.4): an added user is
%% sent in full, a removed one as state="deleted", a changed one as
%% state="partial" carrying the elements that differ (display-text,
%% roles) and its added or changed endpoints in full, removed endpoints as
%% state="deleted". The caller owns the version counter; partial/3 only
%% checks that it grows.
%%
%% Documents are built as iolists, not through xmerl. Every text and
%% attribute value is escaped. Display names and URIs come from the
%% network, so a byte sequence that is not UTF-8, or a character XML 1.0
%% does not allow (C0 controls other than tab, LF and CR, U+FFFE, U+FFFF),
%% is replaced with U+FFFD rather than refused: a NOTIFY must still go
%% out when a caller's display name is garbage.
%%
%% anonymize/2 turns a user who asked for privacy (RFC 3323, RFC 4579 6)
%% into AnonymousN at anonymous.invalid (RFC 4575 5.6). N comes from the
%% caller, so it stays the same across documents while the user is in.
%%
%% Enumerations use atoms with underscores (on_hold, dialed_in) and are
%% written with the RFC's hyphens (on-hold, dialed-in). A value outside the
%% RFC's list (RFC 4575 5.7.3 to 5.7.6, or a media type SDP does not
%% register, 5.8.2) is left out rather than written.
%%
%% Keys are unique among siblings whatever the model says (RFC 4575 4.5):
%% users sharing an entity are one user with all their endpoints, an
%% endpoint whose entity a sibling already has gets `;ep=N' added (5.7),
%% and a later media with the same id, conf-uris entry with the same URI
%% (5.3.1) or available-media entry with the same label is dropped. When
%% the conference lists its available media, an endpoint media label that
%% names none of them is dropped (5.8.3).
-module(chappe_sip_confinfo).

-export([full/1, partial/3, anonymize/2]).

-export_type([
    conf/0,
    user/0,
    endpoint/0,
    media/0,
    media_type/0,
    endpoint_status/0
]).

-type conf() :: #{
    entity := binary(),
    version := non_neg_integer(),
    state => full | partial,
    description => #{
        subject => binary(),
        display_text => binary(),
        conf_uris => [
            #{uri := binary(), display_text => binary(), purpose => binary()}
        ],
        available_media => [
            #{
                label := binary(),
                type := media_type(),
                display_text => binary(),
                status => sendrecv | sendonly | recvonly | inactive
            }
        ]
    },
    host_info => #{uri => binary(), display_text => binary()},
    user_count => non_neg_integer(),
    users => [user()]
}.
-type user() :: #{
    entity := binary(),
    display_text => binary(),
    state => full | partial | deleted,
    roles => [binary()],
    endpoints => [endpoint()]
}.
-type endpoint() :: #{
    entity := binary(),
    display_text => binary(),
    status => endpoint_status(),
    %% who had the focus bring this endpoint in (RFC 4575 5.7.2)
    referred => #{by => binary(), reason => binary(), 'when' => binary()},
    joining_method => dialed_in | dialed_out | focus_owner,
    disconnection_method => departed | booted | failed | busy,
    call_info => #{
        call_id := binary(), from_tag := binary(), to_tag := binary()
    },
    media => [media()]
}.
-type endpoint_status() ::
    pending
    | dialing_out
    | dialing_in
    | alerting
    | on_hold
    | connected
    | muted_via_focus
    | disconnecting
    | disconnected.
-type media() :: #{
    id := binary(),
    display_text => binary(),
    type => media_type(),
    label => binary(),
    src_id => binary(),
    status => sendrecv | sendonly | recvonly | inactive
}.

%% the "media" tokens SDP registers (RFC 4566 8.2.1, RFC 4145, RFC 4975)
-type media_type() :: audio | video | text | application | message | image.

-define(NS, "urn:ietf:params:xml:ns:conference-info").
-define(MEDIA_TYPES, [audio, video, text, application, message, image]).
-define(STATUSES, [
    pending,
    dialing_out,
    dialing_in,
    alerting,
    on_hold,
    connected,
    muted_via_focus,
    disconnecting,
    disconnected
]).
-define(DIRECTIONS, [sendrecv, sendonly, recvonly, inactive]).
%% xs:unsignedInt
-define(MAX_VERSION, 16#FFFFFFFF).

%% The whole conference. Users whose state is `deleted` are left out.
-spec full(conf()) -> binary().
full(#{entity := Entity, version := Version} = Conf0) ->
    Conf = keyed(Conf0),
    Users = [
        U
     || U <- maps:get(users, Conf, []), maps:get(state, U, full) =/= deleted
    ],
    Body = [
        full_description(Conf),
        host_info(Conf),
        conference_state(Conf),
        el(<<"users">>, [], [user_full(U, []) || U <- Users])
    ],
    document(Entity, <<"full">>, Version, Body).

%% What changed from Old to New, as notification number Version. Version
%% must be greater than Old's version and fit an xs:unsignedInt.
-spec partial(conf(), conf(), integer()) ->
    {ok, binary()} | {error, not_monotonic | entity_mismatch}.
partial(
    #{entity := E, version := OldV} = Old0, #{entity := E} = New0, Version
) when
    is_integer(Version), Version > OldV, Version =< ?MAX_VERSION
->
    Old = keyed(Old0),
    New = keyed(New0),
    Body = [
        changed(description, Old, New, fun description/1),
        changed(host_info, Old, New, fun host_info/1),
        changed(user_count, Old, New, fun conference_state/1),
        users_delta(maps:get(users, Old, []), maps:get(users, New, []))
    ],
    {ok, document(E, <<"partial">>, Version, Body)};
partial(#{entity := E}, #{entity := E}, _Version) ->
    {error, not_monotonic};
partial(_, _, _) ->
    {error, entity_mismatch}.

%% User as the anonymous participant number N: its URI, display name and
%% endpoint URIs replaced, the dialog identifiers dropped. Roles, status
%% and media stay: they say what the participant does, not who it is.
-spec anonymize(user(), pos_integer()) -> user().
anonymize(User, N) when is_integer(N), N > 0 ->
    Id = integer_to_binary(N),
    Uri = anonymous_uri(Id, 1),
    Eps = maps:get(endpoints, User, []),
    Anon = [
        maps:remove(call_info, Ep#{entity => anonymous_uri(Id, I)})
     || {I, Ep} <- lists:enumerate(Eps)
    ],
    User1 = maps:without([display_text, endpoints], User),
    User2 = User1#{entity => Uri, display_text => <<"Anonymous", Id/binary>>},
    case Eps of
        [] -> User2;
        _ -> User2#{endpoints => [maps:remove(display_text, E) || E <- Anon]}
    end.

%% the user's URI, then one per further endpoint so entities stay unique
anonymous_uri(Id, 1) ->
    <<"sip:anonymous", Id/binary, "@anonymous.invalid">>;
anonymous_uri(Id, I) ->
    <<"sip:anonymous", Id/binary, "-", (integer_to_binary(I))/binary,
        "@anonymous.invalid">>.

%% internal: keys (RFC 4575 4.5)

keyed(Conf) ->
    Available = [
        L
     || #{label := L} <- maps:get(
            available_media, maps:get(description, Conf, #{}), []
        )
    ],
    Users = [
        endpoints_keyed(U, Available)
     || U <- merge_users(maps:get(users, Conf, []))
    ],
    description_keyed(Conf#{users => Users}).

description_keyed(#{description := D} = Conf) ->
    Conf#{
        description => unique(available_media, label, unique(conf_uris, uri, D))
    };
description_keyed(Conf) ->
    Conf.

%% the first element of each Key value in Map's Field list
unique(Field, Key, Map) ->
    case Map of
        #{Field := L} ->
            {Kept, _} = lists:foldl(
                fun(X, {Acc, Seen}) ->
                    K = maps:get(Key, X),
                    case is_map_key(K, Seen) of
                        true -> {Acc, Seen};
                        false -> {[X | Acc], Seen#{K => true}}
                    end
                end,
                {[], #{}},
                L
            ),
            Map#{Field => lists:reverse(Kept)};
        _ ->
            Map
    end.

%% users with one entity are one user: the first one's fields, everyone's
%% endpoints
merge_users(Users) ->
    {Order, By} = lists:foldl(
        fun(#{entity := E} = U, {Es, Acc}) ->
            case Acc of
                #{E := Prev} ->
                    Eps =
                        maps:get(endpoints, Prev, []) ++
                            maps:get(endpoints, U, []),
                    {Es, Acc#{E => Prev#{endpoints => Eps}}};
                _ ->
                    {[E | Es], Acc#{E => U}}
            end
        end,
        {[], #{}},
        Users
    ),
    [maps:get(E, By) || E <- lists:reverse(Order)].

endpoints_keyed(#{endpoints := Eps} = U, Available) ->
    Taken0 = maps:from_list([{E, true} || #{entity := E} <- Eps]),
    {Out, _, _} = lists:foldl(
        fun(#{entity := E} = Ep, {Acc, Seen, Taken}) ->
            E1 =
                case is_map_key(E, Seen) of
                    true -> fresh_entity(E, 2, Taken);
                    false -> E
                end,
            Ep1 = media_keyed(Ep#{entity => E1}, Available),
            {[Ep1 | Acc], Seen#{E1 => true}, Taken#{E1 => true}}
        end,
        {[], #{}, Taken0},
        Eps
    ),
    U#{endpoints => lists:reverse(Out)};
endpoints_keyed(U, _Available) ->
    U.

%% the entity with `;ep=N' before any URI headers, for the lowest N free
fresh_entity(E, N, Taken) ->
    Tag = <<";ep=", (integer_to_binary(N))/binary>>,
    E1 =
        case binary:split(E, <<"?">>) of
            [U, H] -> <<U/binary, Tag/binary, "?", H/binary>>;
            [U] -> <<U/binary, Tag/binary>>
        end,
    case is_map_key(E1, Taken) of
        true -> fresh_entity(E, N + 1, Taken);
        false -> E1
    end.

media_keyed(#{media := _} = Ep, Available) ->
    #{media := Ms} = Ep1 = unique(media, id, Ep),
    Ep1#{media => [label_keyed(M, Available) || M <- Ms]};
media_keyed(Ep, _Available) ->
    Ep.

label_keyed(#{label := L} = M, Available) when Available =/= [] ->
    case lists:member(L, Available) of
        true -> M;
        false -> maps:remove(label, M)
    end;
label_keyed(M, _Available) ->
    M.

%% internal: document

document(Entity, State, Version, Body) ->
    iolist_to_binary([
        <<"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n">>,
        el(
            <<"conference-info">>,
            [
                {<<"xmlns">>, <<?NS>>},
                {<<"entity">>, Entity},
                {<<"state">>, State},
                {<<"version">>, integer_to_binary(Version)}
            ],
            Body
        ),
        <<"\n">>
    ]).

changed(Key, Old, New, Render) ->
    case maps:get(Key, Old, undefined) =:= maps:get(Key, New, undefined) of
        true -> [];
        false -> Render(New)
    end.

%% a full document always has one, even empty (RFC 4575 5.2)
full_description(#{description := _} = Conf) ->
    description(Conf);
full_description(_) ->
    <<"<conference-description/>">>.

description(#{description := D}) ->
    el(<<"conference-description">>, [], [
        opt_text(<<"display-text">>, display_text, D),
        opt_text(<<"subject">>, subject, D),
        conf_uris(maps:get(conf_uris, D, [])),
        available_media(maps:get(available_media, D, []))
    ]);
description(_) ->
    [].

conf_uris([]) ->
    [];
conf_uris(Uris) ->
    el(<<"conf-uris">>, [], [
        el(<<"entry">>, [], [
            text(<<"uri">>, U),
            opt_text(<<"display-text">>, display_text, E),
            opt_text(<<"purpose">>, purpose, E)
        ])
     || #{uri := U} = E <- Uris
    ]).

%% <type> is mandatory in an entry: one whose type SDP does not register
%% is left out
available_media(Entries) ->
    case [E || #{type := T} = E <- Entries, lists:member(T, ?MEDIA_TYPES)] of
        [] ->
            [];
        Es ->
            el(<<"available-media">>, [], [
                el(<<"entry">>, [{<<"label">>, L}], [
                    opt_text(<<"display-text">>, display_text, E),
                    text(<<"type">>, enum(T)),
                    opt_enum(<<"status">>, status, E, ?DIRECTIONS)
                ])
             || #{label := L, type := T} = E <- Es
            ])
    end.

host_info(#{host_info := H}) ->
    Uris =
        case H of
            #{uri := U} ->
                el(<<"uris">>, [], [el(<<"entry">>, [], [text(<<"uri">>, U)])]);
            _ ->
                []
        end,
    el(<<"host-info">>, [], [
        opt_text(<<"display-text">>, display_text, H), Uris
    ]);
host_info(_) ->
    [].

conference_state(#{user_count := N}) ->
    el(<<"conference-state">>, [], [
        text(<<"user-count">>, integer_to_binary(N))
    ]);
conference_state(_) ->
    [].

%% internal: users

user_full(#{entity := E} = U, Attrs) ->
    el(<<"user">>, [{<<"entity">>, E} | Attrs], [
        opt_text(<<"display-text">>, display_text, U),
        roles(U),
        [endpoint(Ep, []) || Ep <- maps:get(endpoints, U, [])]
    ]).

roles(#{roles := Roles}) when Roles =/= [] ->
    el(<<"roles">>, [], [text(<<"entry">>, R) || R <- Roles]);
roles(_) ->
    [].

users_delta(Old, New) ->
    OldBy = by_entity(Old),
    NewBy = by_entity(New),
    Changed = lists:filtermap(
        fun(#{entity := E} = U) ->
            case maps:find(E, OldBy) of
                error -> {true, user_full(U, [{<<"state">>, <<"full">>}])};
                {ok, U} -> false;
                {ok, Prev} -> {true, user_partial(Prev, U)}
            end
        end,
        New
    ),
    case Changed ++ deleted(<<"user">>, Old, NewBy) of
        [] -> [];
        Us -> el(<<"users">>, [{<<"state">>, <<"partial">>}], Us)
    end.

user_partial(Prev, #{entity := E} = U) ->
    Display =
        case
            maps:get(display_text, Prev, undefined) =:=
                maps:get(display_text, U, undefined)
        of
            true -> [];
            false -> opt_text(<<"display-text">>, display_text, U)
        end,
    Roles =
        case maps:get(roles, Prev, []) =:= maps:get(roles, U, []) of
            true -> [];
            false -> roles(U)
        end,
    el(<<"user">>, [{<<"entity">>, E}, {<<"state">>, <<"partial">>}], [
        Display,
        Roles,
        endpoints_delta(
            maps:get(endpoints, Prev, []), maps:get(endpoints, U, [])
        )
    ]).

endpoints_delta(Old, New) ->
    OldBy = by_entity(Old),
    NewBy = by_entity(New),
    Changed = [
        endpoint(Ep, [{<<"state">>, <<"full">>}])
     || #{entity := E} = Ep <- New, maps:get(E, OldBy, undefined) =/= Ep
    ],
    Changed ++ deleted(<<"endpoint">>, Old, NewBy).

%% an empty element with state="deleted" for each entity of Old gone
%% from New
deleted(Tag, Old, NewBy) ->
    [
        el(Tag, [{<<"entity">>, E}, {<<"state">>, <<"deleted">>}], [])
     || #{entity := E} <- Old, not is_map_key(E, NewBy)
    ].

by_entity(L) ->
    maps:from_list([{E, X} || #{entity := E} = X <- L]).

%% internal: endpoints and media

endpoint(#{entity := E} = Ep, Attrs) ->
    el(<<"endpoint">>, [{<<"entity">>, E} | Attrs], [
        opt_text(<<"display-text">>, display_text, Ep),
        referred(Ep),
        opt_enum(<<"status">>, status, Ep, ?STATUSES),
        opt_enum(
            <<"joining-method">>,
            joining_method,
            Ep,
            [dialed_in, dialed_out, focus_owner]
        ),
        opt_enum(
            <<"disconnection-method">>,
            disconnection_method,
            Ep,
            [departed, booted, failed, busy]
        ),
        [media(M) || M <- maps:get(media, Ep, [])],
        call_info(Ep)
    ]).

referred(#{referred := R}) ->
    el(<<"referred">>, [], [
        opt_text(<<"when">>, 'when', R),
        opt_text(<<"reason">>, reason, R),
        opt_text(<<"by">>, by, R)
    ]);
referred(_) ->
    [].

call_info(#{call_info := #{call_id := C, from_tag := F, to_tag := T}}) ->
    el(<<"call-info">>, [], [
        el(<<"sip">>, [], [
            text(<<"call-id">>, C),
            text(<<"from-tag">>, F),
            text(<<"to-tag">>, T)
        ])
    ]);
call_info(_) ->
    [].

media(#{id := Id} = M) ->
    el(<<"media">>, [{<<"id">>, Id}], [
        opt_text(<<"display-text">>, display_text, M),
        opt_enum(<<"type">>, type, M, ?MEDIA_TYPES),
        opt_text(<<"label">>, label, M),
        opt_text(<<"src-id">>, src_id, M),
        opt_enum(<<"status">>, status, M, ?DIRECTIONS)
    ]).

%% only a value from the RFC's list is written
opt_enum(Name, Key, Map, Allowed) ->
    case Map of
        #{Key := A} when is_atom(A) ->
            case lists:member(A, Allowed) of
                true -> text(Name, enum(A));
                false -> []
            end;
        _ ->
            []
    end.

%% on_hold -> on-hold; the atoms are the model's, never a peer's
enum(A) ->
    binary:replace(atom_to_binary(A), <<"_">>, <<"-">>, [global]).

%% internal: XML

opt_text(Name, Key, Map) ->
    case Map of
        #{Key := V} -> text(Name, V);
        _ -> []
    end.

text(Name, Value) ->
    el(Name, [], [escape(Value)]).

el(Name, Attrs, Content) ->
    As = [[<<" ">>, K, <<"=\"">>, escape(V), <<"\"">>] || {K, V} <- Attrs],
    case iolist_size(Content) of
        0 -> [<<"<">>, Name, As, <<"/>">>];
        _ -> [<<"<">>, Name, As, <<">">>, Content, <<"</">>, Name, <<">">>]
    end.

escape(Bin) ->
    [escape_char(C) || C <- chars(Bin, [])].

escape_char($<) -> <<"&lt;">>;
escape_char($>) -> <<"&gt;">>;
escape_char($&) -> <<"&amp;">>;
escape_char($") -> <<"&quot;">>;
escape_char($') -> <<"&apos;">>;
%% in attributes a raw tab or newline would be normalised to a space
escape_char($\t) -> <<"&#9;">>;
escape_char($\n) -> <<"&#10;">>;
escape_char($\r) -> <<"&#13;">>;
escape_char(C) -> <<C/utf8>>.

%% code points of Bin; invalid UTF-8 and XML-forbidden characters become
%% U+FFFD
chars(<<C/utf8, Rest/binary>>, Acc) ->
    chars(Rest, [xml_char(C) | Acc]);
chars(<<_, Rest/binary>>, Acc) ->
    chars(Rest, [16#FFFD | Acc]);
chars(<<>>, Acc) ->
    lists:reverse(Acc).

xml_char(C) when C =:= 16#9; C =:= 16#A; C =:= 16#D -> C;
xml_char(C) when C < 16#20 -> 16#FFFD;
xml_char(C) when C =:= 16#FFFE; C =:= 16#FFFF -> 16#FFFD;
xml_char(C) -> C.
