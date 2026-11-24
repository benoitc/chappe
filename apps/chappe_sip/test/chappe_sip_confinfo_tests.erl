%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% RFC 4575 conference-info documents: every rendered document is checked
%% against the RFC's XML schema (chappe_sip_test_confinfo), then scanned
%% back to check it says what the model says.
-module(chappe_sip_confinfo_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("xmerl/include/xmerl.hrl").

-define(CONF, <<"sip:conf-9f2@conf.example.com">>).

%% fixtures

caller() ->
    #{
        entity => <<"sip:+15555550123@carrier.example.net">>,
        display_text => <<"Caller">>,
        roles => [<<"participant">>],
        endpoints => [
            #{
                entity => <<"sip:+15555550123@192.0.2.44">>,
                status => connected,
                joining_method => dialed_in,
                call_info => #{
                    call_id => <<"a84b4c76e66710@192.0.2.44">>,
                    from_tag => <<"1928301774">>,
                    to_tag => <<"a6c85cf">>
                },
                media => [
                    #{
                        id => <<"1">>,
                        type => audio,
                        label => <<"audio-1">>,
                        src_id => <<"3735928559">>,
                        status => sendrecv
                    }
                ]
            }
        ]
    }.

organizer() ->
    #{
        entity => <<"sip:agent12@sales.example.com">>,
        display_text => <<"Sales Agent 12">>,
        roles => [<<"host">>, <<"participant">>],
        endpoints => [
            #{
                entity => <<"sip:agent12@192.0.2.10">>,
                status => connected,
                joining_method => focus_owner,
                media => [#{id => <<"2">>, type => audio, status => sendrecv}]
            }
        ]
    }.

guest() ->
    #{
        entity => <<"sip:support@partner.example.org">>,
        display_text => <<"Partner Support">>,
        roles => [<<"participant">>],
        endpoints => [
            #{
                entity => <<"sip:support@198.51.100.7">>,
                status => connected,
                joining_method => dialed_out,
                media => [#{id => <<"3">>, type => audio, status => sendrecv}]
            }
        ]
    }.

conf(Version, Users) ->
    #{
        entity => ?CONF,
        version => Version,
        state => full,
        description => #{
            subject => <<"Weekly sync 3b2a">>,
            display_text => <<"Team call">>
        },
        host_info => #{uri => <<"sip:conf.example.com">>},
        user_count => length(Users),
        users => Users
    }.

%% scanning helpers

%% well formed, valid against the schema, and returned in simple form
check(Doc) ->
    ?assert(is_binary(Doc)),
    simple(chappe_sip_test_confinfo:validate(Doc)).

simple(#xmlElement{name = N, attributes = As, content = C}) ->
    {
        local(N),
        [{local(A#xmlAttribute.name), to_bin(A#xmlAttribute.value)} || A <- As],
        [simple(X) || X <- C, not is_blank(X)]
    };
simple(#xmlText{value = V}) ->
    to_bin(V).

local(Name) ->
    L = atom_to_list(Name),
    case string:split(L, ":") of
        [_, Local] -> list_to_atom(Local);
        [Local] -> list_to_atom(Local)
    end.

to_bin(V) -> unicode:characters_to_binary(V).

is_blank(#xmlText{value = V}) -> string:trim(V) =:= "";
is_blank(_) -> false.

attr(K, {_, As, _}) -> proplists:get_value(K, As).
kids(Name, {_, _, C}) -> [E || {N, _, _} = E <- C, N =:= Name].
kid(Name, E) ->
    [K] = kids(Name, E),
    K.
text(Name, E) ->
    {_, _, [T]} = kid(Name, E),
    T.

user(Entity, Doc) ->
    [U] = [U || U <- kids(user, kid(users, Doc)), attr(entity, U) =:= Entity],
    U.

%% full documents

full_valid_and_matches_model_test() ->
    Doc = check(chappe_sip_confinfo:full(conf(1, [organizer(), caller()]))),
    ?assertEqual(?CONF, attr(entity, Doc)),
    ?assertEqual(<<"1">>, attr(version, Doc)),
    ?assertEqual(<<"full">>, attr(state, Doc)),
    Desc = kid('conference-description', Doc),
    ?assertEqual(<<"Team call">>, text('display-text', Desc)),
    ?assertEqual(<<"Weekly sync 3b2a">>, text(subject, Desc)),
    Host = kid('host-info', Doc),
    ?assertEqual(
        <<"sip:conf.example.com">>, text(uri, kid(entry, kid(uris, Host)))
    ),
    ?assertEqual(<<"2">>, text('user-count', kid('conference-state', Doc))),
    ?assertEqual(
        [
            <<"sip:agent12@sales.example.com">>,
            <<"sip:+15555550123@carrier.example.net">>
        ],
        [attr(entity, U) || U <- kids(user, kid(users, Doc))]
    ),
    Ct = user(<<"sip:agent12@sales.example.com">>, Doc),
    ?assertEqual(
        [<<"host">>, <<"participant">>],
        [T || {entry, _, [T]} <- kids(entry, kid(roles, Ct))]
    ),
    ?assertEqual(<<"focus-owner">>, text('joining-method', kid(endpoint, Ct))),
    C = user(<<"sip:+15555550123@carrier.example.net">>, Doc),
    Ep = kid(endpoint, C),
    ?assertEqual(<<"sip:+15555550123@192.0.2.44">>, attr(entity, Ep)),
    ?assertEqual(<<"connected">>, text(status, Ep)),
    ?assertEqual(<<"dialed-in">>, text('joining-method', Ep)),
    Sip = kid(sip, kid('call-info', Ep)),
    ?assertEqual(<<"a84b4c76e66710@192.0.2.44">>, text('call-id', Sip)),
    ?assertEqual(<<"1928301774">>, text('from-tag', Sip)),
    ?assertEqual(<<"a6c85cf">>, text('to-tag', Sip)),
    M = kid(media, Ep),
    ?assertEqual(<<"1">>, attr(id, M)),
    ?assertEqual(<<"audio">>, text(type, M)),
    ?assertEqual(<<"audio-1">>, text(label, M)),
    ?assertEqual(<<"3735928559">>, text('src-id', M)),
    ?assertEqual(<<"sendrecv">>, text(status, M)).

empty_conference_test() ->
    Doc = check(
        chappe_sip_confinfo:full(#{entity => ?CONF, version => 0, users => []})
    ),
    ?assertEqual(?CONF, attr(entity, Doc)).

%% a full document lists the users present; a deleted one is left out
full_omits_deleted_users_test() ->
    Gone = (guest())#{state => deleted},
    Doc = check(chappe_sip_confinfo:full(conf(3, [caller(), Gone]))),
    ?assertEqual(1, length(kids(user, kid(users, Doc)))).

every_enum_value_validates_test() ->
    Statuses = [
        pending,
        dialing_out,
        dialing_in,
        alerting,
        on_hold,
        connected,
        muted_via_focus,
        disconnecting,
        disconnected
    ],
    Wire = [
        <<"pending">>,
        <<"dialing-out">>,
        <<"dialing-in">>,
        <<"alerting">>,
        <<"on-hold">>,
        <<"connected">>,
        <<"muted-via-focus">>,
        <<"disconnecting">>,
        <<"disconnected">>
    ],
    Joins = [dialed_in, dialed_out, focus_owner],
    Discs = [departed, booted, failed, busy],
    Types = [audio, video, text, message],
    MStat = [sendrecv, sendonly, recvonly, inactive],
    Eps = [
        #{
            entity => integer_to_binary(I),
            status => lists:nth(I, Statuses),
            joining_method => lists:nth(1 + I rem 3, Joins),
            disconnection_method => lists:nth(1 + I rem 4, Discs),
            media => [
                #{
                    id => integer_to_binary(I),
                    type => lists:nth(1 + I rem 4, Types),
                    status => lists:nth(1 + I rem 4, MStat)
                }
            ]
        }
     || I <- lists:seq(1, 9)
    ],
    U = #{entity => <<"sip:u@example.com">>, endpoints => Eps},
    Doc = check(chappe_sip_confinfo:full(conf(1, [U]))),
    ?assertEqual(
        Wire,
        [
            text(status, E)
         || E <- kids(endpoint, user(<<"sip:u@example.com">>, Doc))
        ]
    ).

%% keys and enumerations (RFC 4575 4.5, 5.3, 5.7, 5.8)

one_user_per_entity_test() ->
    Ep = fun(E, Id) ->
        #{entity => E, media => [#{id => Id, type => audio}, #{id => Id}]}
    end,
    U1 = #{entity => <<"sip:a@x">>, endpoints => [Ep(<<"sip:a@h">>, <<"1">>)]},
    U2 = #{
        entity => <<"sip:a@x">>,
        endpoints => [
            Ep(<<"sip:a@h">>, <<"2">>), Ep(<<"sip:a@h;ep=2">>, <<"3">>)
        ]
    },
    Doc = check(chappe_sip_confinfo:full(conf(1, [U1, U2]))),
    ?assertMatch([_], kids(user, kid(users, Doc))),
    Eps = kids(endpoint, user(<<"sip:a@x">>, Doc)),
    ?assertEqual(
        [<<"sip:a@h">>, <<"sip:a@h;ep=3">>, <<"sip:a@h;ep=2">>],
        [attr(entity, E) || E <- Eps]
    ),
    [?assertMatch([_], kids(media, E)) || E <- Eps].

endpoint_entity_suffix_before_headers_test() ->
    E = <<"sip:a@h?subject=x">>,
    U = #{
        entity => <<"sip:a@x">>, endpoints => [#{entity => E}, #{entity => E}]
    },
    Doc = check(chappe_sip_confinfo:full(conf(1, [U]))),
    ?assertEqual(
        [E, <<"sip:a@h;ep=2?subject=x">>],
        [attr(entity, X) || X <- kids(endpoint, user(<<"sip:a@x">>, Doc))]
    ).

conf_uris_and_available_media_test() ->
    C = (conf(1, [caller()]))#{
        description => #{
            conf_uris => [
                #{uri => ?CONF, purpose => <<"participation">>},
                #{uri => <<"tel:+15555550100">>},
                #{uri => ?CONF}
            ],
            available_media => [
                #{label => <<"audio-1">>, type => audio, status => sendrecv},
                #{label => <<"audio-1">>, type => video},
                #{label => <<"x">>, type => smell}
            ]
        }
    },
    Doc = check(chappe_sip_confinfo:full(C)),
    Desc = kid('conference-description', Doc),
    ?assertEqual(
        [?CONF, <<"tel:+15555550100">>],
        [text(uri, E) || E <- kids(entry, kid('conf-uris', Desc))]
    ),
    ?assertEqual(
        [{<<"audio-1">>, <<"audio">>}],
        [
            {attr(label, E), text(type, E)}
         || E <- kids(entry, kid('available-media', Desc))
        ]
    ).

label_names_available_media_test() ->
    Media = [
        #{id => <<"1">>, type => audio, label => <<"main">>},
        #{id => <<"2">>, type => video, label => <<"gone">>}
    ],
    U = #{
        entity => <<"sip:a@x">>,
        endpoints => [#{entity => <<"e">>, media => Media}]
    },
    C = (conf(1, [U]))#{
        description => #{
            available_media => [#{label => <<"main">>, type => audio}]
        }
    },
    [E] = kids(
        endpoint, user(<<"sip:a@x">>, check(chappe_sip_confinfo:full(C)))
    ),
    ?assertEqual(
        [[<<"main">>], []],
        [[L || {label, _, [L]} <- Ks] || {media, _, Ks} <- kids(media, E)]
    ).

values_outside_the_rfc_left_out_test() ->
    Ep = #{
        entity => <<"e">>,
        status => sleeping,
        joining_method => teleported,
        disconnection_method => vanished,
        media => [#{id => <<"1">>, type => smell, status => loud}]
    },
    U = #{entity => <<"sip:a@x">>, endpoints => [Ep]},
    [E] = kids(
        endpoint,
        user(<<"sip:a@x">>, check(chappe_sip_confinfo:full(conf(1, [U]))))
    ),
    ?assertEqual([], [N || {N, _, _} <- element(3, E), N =/= media]),
    ?assertEqual([{media, [{id, <<"1">>}], []}], kids(media, E)).

referred_test() ->
    Ep = #{
        entity => <<"e">>,
        referred => #{
            by => <<"sip:host@x">>, reason => <<"Ad-hoc Invitation">>
        },
        status => dialing_out
    },
    U = #{entity => <<"sip:a@x">>, endpoints => [Ep]},
    [E] = kids(
        endpoint,
        user(<<"sip:a@x">>, check(chappe_sip_confinfo:full(conf(1, [U]))))
    ),
    R = kid(referred, E),
    ?assertEqual(<<"sip:host@x">>, text(by, R)),
    ?assertEqual(<<"Ad-hoc Invitation">>, text(reason, R)).

%% display names come from the network

escaping_test() ->
    Nasty = <<"<script>&\"x\" 'y'</script>">>,
    U = (caller())#{
        display_text => Nasty, entity => <<"sip:a&b@x.example?c=\"d\"">>
    },
    Doc = check(chappe_sip_confinfo:full(conf(1, [U]))),
    [Got] = kids(user, kid(users, Doc)),
    ?assertEqual(Nasty, text('display-text', Got)),
    ?assertEqual(<<"sip:a&b@x.example?c=\"d\"">>, attr(entity, Got)).

utf8_kept_test() ->
    Name = <<"Jos", 16#C3, 16#A9, " ", 16#E2, 16#98, 16#8E>>,
    Doc = check(
        chappe_sip_confinfo:full(conf(1, [(caller())#{display_text => Name}]))
    ),
    [Got] = kids(user, kid(users, Doc)),
    ?assertEqual(Name, text('display-text', Got)).

%% invalid UTF-8 and characters XML 1.0 forbids become U+FFFD
invalid_bytes_replaced_test() ->
    Bad = <<"Caf", 16#E9, " x", 1, 0, "y", 16#EF, 16#BF, 16#BE>>,
    Doc = check(
        chappe_sip_confinfo:full(conf(1, [(caller())#{display_text => Bad}]))
    ),
    [Got] = kids(user, kid(users, Doc)),
    R = <<16#EF, 16#BF, 16#BD>>,
    ?assertEqual(
        <<"Caf", R/binary, " x", R/binary, R/binary, "y", R/binary>>,
        text('display-text', Got)
    ).

tab_and_newline_kept_test() ->
    T = <<"a\tb\nc">>,
    Doc = check(
        chappe_sip_confinfo:full(conf(1, [(caller())#{display_text => T}]))
    ),
    [Got] = kids(user, kid(users, Doc)),
    ?assertEqual(T, text('display-text', Got)).

%% partial notifications (RFC 4575 section 4.4)

partial_participant_added_test() ->
    Old = conf(4, [organizer(), caller()]),
    New = conf(4, [organizer(), caller(), guest()]),
    {ok, Bin} = chappe_sip_confinfo:partial(Old, New, 5),
    Doc = check(Bin),
    ?assertEqual(<<"partial">>, attr(state, Doc)),
    ?assertEqual(<<"5">>, attr(version, Doc)),
    ?assertEqual(<<"3">>, text('user-count', kid('conference-state', Doc))),
    Users = kid(users, Doc),
    ?assertEqual(<<"partial">>, attr(state, Users)),
    [U] = kids(user, Users),
    ?assertEqual(<<"sip:support@partner.example.org">>, attr(entity, U)),
    ?assertEqual(<<"full">>, attr(state, U)),
    ?assertEqual(<<"Partner Support">>, text('display-text', U)),
    ?assertEqual(<<"dialed-out">>, text('joining-method', kid(endpoint, U))),
    ?assertEqual([], kids('conference-description', Doc)),
    ?assertEqual([], kids('host-info', Doc)).

partial_status_change_test() ->
    Caller = caller(),
    [Ep] = maps:get(endpoints, Caller),
    Held = Caller#{endpoints => [Ep#{status => on_hold}]},
    Old = conf(7, [organizer(), Caller]),
    New = conf(7, [organizer(), Held]),
    {ok, Bin} = chappe_sip_confinfo:partial(Old, New, 8),
    Doc = check(Bin),
    [U] = kids(user, kid(users, Doc)),
    ?assertEqual(<<"sip:+15555550123@carrier.example.net">>, attr(entity, U)),
    ?assertEqual(<<"partial">>, attr(state, U)),
    ?assertEqual([], kids(roles, U)),
    ?assertEqual([], kids('display-text', U)),
    E = kid(endpoint, U),
    ?assertEqual(<<"sip:+15555550123@192.0.2.44">>, attr(entity, E)),
    ?assertEqual(<<"on-hold">>, text(status, E)),
    ?assertEqual([], kids('conference-state', Doc)).

partial_participant_deleted_test() ->
    Old = conf(9, [organizer(), caller(), guest()]),
    New = conf(9, [organizer(), caller()]),
    {ok, Bin} = chappe_sip_confinfo:partial(Old, New, 10),
    Doc = check(Bin),
    [U] = kids(user, kid(users, Doc)),
    ?assertEqual(<<"sip:support@partner.example.org">>, attr(entity, U)),
    ?assertEqual(<<"deleted">>, attr(state, U)),
    ?assertEqual(
        {user, [{entity, attr(entity, U)}, {state, <<"deleted">>}], []}, U
    ),
    ?assertEqual(<<"2">>, text('user-count', kid('conference-state', Doc))).

%% the organizer hands the host role to the guest
partial_host_role_change_test() ->
    Old = conf(11, [organizer(), caller(), guest()]),
    Ct = (organizer())#{roles => [<<"participant">>]},
    Rs = (guest())#{roles => [<<"host">>, <<"participant">>]},
    New = conf(11, [Ct, caller(), Rs]),
    {ok, Bin} = chappe_sip_confinfo:partial(Old, New, 12),
    Doc = check(Bin),
    Us = kids(user, kid(users, Doc)),
    ?assertEqual(
        [
            <<"sip:agent12@sales.example.com">>,
            <<"sip:support@partner.example.org">>
        ],
        [attr(entity, U) || U <- Us]
    ),
    Roles = fun(U) -> [T || {entry, _, [T]} <- kids(entry, kid(roles, U))] end,
    [UCt, URs] = Us,
    ?assertEqual(<<"partial">>, attr(state, UCt)),
    ?assertEqual([<<"participant">>], Roles(UCt)),
    ?assertEqual([<<"host">>, <<"participant">>], Roles(URs)),
    ?assertEqual([], kids(endpoint, UCt)).

partial_endpoint_deleted_test() ->
    Two = (caller())#{
        endpoints => maps:get(endpoints, caller()) ++
            [#{entity => <<"sip:second@192.0.2.45">>, status => connected}]
    },
    {ok, Bin} = chappe_sip_confinfo:partial(
        conf(1, [Two]), conf(1, [caller()]), 2
    ),
    Doc = check(Bin),
    [U] = kids(user, kid(users, Doc)),
    [E] = kids(endpoint, U),
    ?assertEqual(<<"sip:second@192.0.2.45">>, attr(entity, E)),
    ?assertEqual(<<"deleted">>, attr(state, E)).

partial_description_change_test() ->
    Old = conf(1, [caller()]),
    New = Old#{description => #{subject => <<"Weekly sync moved">>}},
    {ok, Bin} = chappe_sip_confinfo:partial(Old, New, 2),
    Doc = check(Bin),
    ?assertEqual(
        <<"Weekly sync moved">>,
        text(subject, kid('conference-description', Doc))
    ),
    ?assertEqual([], kids(users, Doc)).

partial_nothing_changed_test() ->
    C = conf(1, [caller()]),
    {ok, Bin} = chappe_sip_confinfo:partial(C, C, 2),
    Doc = check(Bin),
    ?assertEqual(
        {'conference-info',
            [
                {xmlns, <<"urn:ietf:params:xml:ns:conference-info">>},
                {entity, ?CONF},
                {state, <<"partial">>},
                {version, <<"2">>}
            ],
            []},
        Doc
    ).

partial_version_must_grow_test_() ->
    C = conf(5, [caller()]),
    [
        ?_assertEqual(
            {error, not_monotonic}, chappe_sip_confinfo:partial(C, C, 5)
        ),
        ?_assertEqual(
            {error, not_monotonic}, chappe_sip_confinfo:partial(C, C, 4)
        ),
        ?_assertEqual(
            {error, not_monotonic}, chappe_sip_confinfo:partial(C, C, -1)
        ),
        ?_assertEqual(
            {error, not_monotonic},
            chappe_sip_confinfo:partial(C, C, 16#100000000)
        ),
        ?_assertMatch({ok, _}, chappe_sip_confinfo:partial(C, C, 6))
    ].

partial_other_conference_test() ->
    Old = conf(1, [caller()]),
    New = Old#{entity => <<"sip:other@conf.example.com">>},
    ?assertEqual(
        {error, entity_mismatch}, chappe_sip_confinfo:partial(Old, New, 2)
    ).

%% RFC 4575 5.2: a full document carries <conference-description> and
%% <users> even when the model has neither
full_has_description_and_users_test() ->
    Doc = check(
        chappe_sip_confinfo:full(#{entity => ?CONF, version => 1})
    ),
    ?assertMatch([_], kids('conference-description', Doc)),
    ?assertMatch([_], kids(users, Doc)).

%% RFC 4575 5.6: a participant asking for privacy is AnonymousN at
%% anonymous.invalid; nothing of its own identity is left, not even the
%% dialog identifiers
anonymize_test() ->
    U = chappe_sip_confinfo:anonymize(caller(), 7),
    Doc = check(chappe_sip_confinfo:full(conf(1, [organizer(), U]))),
    Anon = user(<<"sip:anonymous7@anonymous.invalid">>, Doc),
    ?assertEqual(<<"Anonymous7">>, text('display-text', Anon)),
    [Ep] = kids(endpoint, Anon),
    ?assertEqual(<<"sip:anonymous7@anonymous.invalid">>, attr(entity, Ep)),
    ?assertEqual([], kids('call-info', Ep)),
    ?assertEqual(<<"connected">>, text(status, Ep)),
    Bin = chappe_sip_confinfo:full(conf(1, [U])),
    [
        ?assertEqual(nomatch, binary:match(Bin, Leak), Leak)
     || Leak <- [
            <<"15555550123">>,
            <<"192.0.2.44">>,
            <<"carrier.example.net">>,
            <<"Caller">>,
            <<"a84b4c76e66710">>
        ]
    ].

%% two endpoints of one anonymous user stay distinct
anonymize_endpoints_unique_test() ->
    Two = (caller())#{
        endpoints => maps:get(endpoints, caller()) ++
            [#{entity => <<"sip:second@192.0.2.45">>, status => connected}]
    },
    Doc = check(
        chappe_sip_confinfo:full(
            conf(1, [chappe_sip_confinfo:anonymize(Two, 3)])
        )
    ),
    Eps = kids(endpoint, user(<<"sip:anonymous3@anonymous.invalid">>, Doc)),
    Entities = [attr(entity, E) || E <- Eps],
    ?assertEqual(2, length(lists:usort(Entities))),
    [
        ?assertMatch({_, _}, binary:match(E, <<"@anonymous.invalid">>))
     || E <- Entities
    ],
    ?assertEqual(
        nomatch, binary:match(iolist_to_binary(Entities), <<"second">>)
    ).
