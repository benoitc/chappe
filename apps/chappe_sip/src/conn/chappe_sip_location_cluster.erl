%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The location store on a cluster: one value per AOR in the region's
%% KV (chappe_cluster), under `chappe_sip/aor/<AOR>'.
%%
%% - A read is the local replica: eventually consistent, which routing
%%   tolerates, and it answers while the region has no quorum.
%% - A write is a compare-and-swap on the version the read returned, so
%%   two nodes taking REGISTERs for one AOR at once never lose either:
%%   the loser reads again. It waits for the quorum at most
%%   registrar_cluster_timeout_ms.
%% - A value is the AOR's bindings as maps, so a node running a later
%%   release, with more fields, still reads them. Its size is bounded by
%%   chappe_cluster's max_value_bytes (`too_large'), and the AORs by its
%%   max_keys (`full').
-module(chappe_sip_location_cluster).
-behaviour(chappe_sip_location).

-include("chappe_sip_location.hrl").

-export([read/1, write/3, aors/0, clear/0]).
-export([prefix/0]).

-define(PREFIX, <<"chappe_sip/aor/">>).

%% The KV prefix of the bindings.
-spec prefix() -> binary().
prefix() ->
    ?PREFIX.

read(Aor) ->
    case chappe_cluster:get(key(Aor)) of
        {ok, Maps, Version} when is_list(Maps) ->
            {ok, [from_map(M) || M <- Maps, is_map(M)], Version};
        not_found ->
            {ok, [], 0};
        {error, _} ->
            {error, no_quorum}
    end.

write(_Aor, 0, []) ->
    ok;
write(Aor, Version, []) ->
    result(
        chappe_cluster:delete(key(Aor), #{
            version => Version, timeout => timeout()
        })
    );
write(Aor, Version, Bs) ->
    result(
        chappe_cluster:cas(
            key(Aor), Version, [to_map(B) || B <- Bs], #{timeout => timeout()}
        )
    ).

%% Every AOR, a page of keys at a time.
aors() ->
    aors(#{}, []).

aors(Opts, Acc) ->
    N = byte_size(?PREFIX),
    case chappe_cluster:keys(?PREFIX, Opts) of
        {ok, Keys, Next} ->
            Aors = [Aor || <<_:N/binary, Aor/binary>> <- Keys],
            more(Next, [Aors | Acc]);
        {error, _} ->
            lists:append(lists:reverse(Acc))
    end.

more(done, Acc) -> lists:append(lists:reverse(Acc));
more({more, Cursor}, Acc) -> aors(#{cursor => Cursor}, Acc).

clear() ->
    lists:foreach(fun(Aor) -> chappe_cluster:delete(key(Aor)) end, aors()).

result(ok) -> ok;
result({ok, _Version}) -> ok;
result({error, {version, _}}) -> {error, conflict};
result({error, max_keys}) -> {error, full};
result({error, too_large}) -> {error, too_large};
result({error, _}) -> {error, no_quorum}.

key(Aor) ->
    <<?PREFIX/binary, Aor/binary>>.

timeout() ->
    chappe_sip_config:get(registrar_cluster_timeout_ms).

to_map(B) ->
    maps:from_list(
        lists:zip(record_info(fields, binding), tl(tuple_to_list(B)))
    ).

%% a field the writer did not know takes its default
from_map(M) ->
    Default = tl(tuple_to_list(#binding{contact = <<>>, expiry = 0, cseq = 0})),
    list_to_tuple([
        binding
        | [
            maps:get(F, M, D)
         || {F, D} <- lists:zip(record_info(fields, binding), Default)
        ]
    ]).
