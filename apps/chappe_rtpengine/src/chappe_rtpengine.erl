%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Public API for controlling rtpengine nodes over the NG protocol.
%%
%% Add a node, then issue commands against it by name. Parameters are
%% maps with atom keys (call_id, from_tag, sdp, ...); see chappe_rtpengine_ng for
%% the wire mapping. SDP bodies are opaque binaries: this library does
%% not parse or interpret SDP, and SIP signalling stays outside it.
-module(chappe_rtpengine).

-export([
    add_node/2,
    remove_node/1,
    select_node/0,
    list_nodes/0,
    start_session/1,
    ping/1,
    offer/2,
    answer/2,
    publish/2,
    delete/2,
    query/2,
    cmd/3,
    stats/1
]).

-type node_name() :: atom().
-type result() :: chappe_rtpengine_ng:result() | {error, term()}.

-export_type([node_name/0, result/0]).

%% Start a client for an rtpengine node and register it in the pool.
%% Name is a locally registered atom; Opts needs host and port, and
%% accepts timeout (per attempt, milliseconds, default 1000), attempts
%% (total, default 3), health_interval (ms between health pings,
%% default 5000) and down_after (consecutive failures before the node
%% is marked down, default 2).
-spec add_node(node_name(), map()) -> ok | {error, term()}.
add_node(Name, Opts) ->
    chappe_rtpengine_pool:add_node(Name, Opts).

-spec remove_node(node_name()) -> ok | {error, term()}.
remove_node(Name) ->
    chappe_rtpengine_pool:remove_node(Name).

%% Healthy node with the least load (in-flight requests plus pinned
%% calls).
-spec select_node() -> {ok, node_name()} | {error, no_nodes}.
select_node() ->
    chappe_rtpengine_pool:select().

-spec list_nodes() -> [map()].
list_nodes() ->
    chappe_rtpengine_pool:list_nodes().

%% Start a supervised media session owned by the calling process.
%% Opts: call_id (required), node (optional, pool-selected when
%% absent). Drive it with chappe_rtpengine_session:offer/answer/query/stop.
-spec start_session(map()) -> {ok, pid()} | {error, term()}.
start_session(Opts) ->
    chappe_rtpengine_session:start(Opts).

-spec ping(node_name()) -> result().
ping(Node) ->
    safe_cmd(Node, ping, #{}).

%% Params: call_id, from_tag, sdp required; anything else (ice, flags,
%% transport_protocol, replace, direction, ...) passes through.
-spec offer(node_name(), chappe_rtpengine_ng:params()) -> result().
offer(Node, Params) ->
    offering(Node, offer, Params).

%% Same as offer plus the answering party's to_tag.
-spec answer(node_name(), chappe_rtpengine_ng:params()) -> result().
answer(Node, Params) ->
    ok = required([call_id, from_tag, to_tag, sdp], Params),
    safe_cmd(Node, answer, Params).

%% One-sided offer for a session with no second leg: rtpengine answers
%% it itself and the reply SDP is the answer to send back. Params:
%% call_id, from_tag, sdp required.
-spec publish(node_name(), chappe_rtpengine_ng:params()) -> result().
publish(Node, Params) ->
    offering(Node, publish, Params).

%% offer and publish take the same parameters; only the party count on
%% the far side differs.
offering(Node, Command, Params) ->
    ok = required([call_id, from_tag, sdp], Params),
    safe_cmd(Node, Command, Params).

-spec delete(node_name(), chappe_rtpengine_ng:params()) -> result().
delete(Node, Params) ->
    ok = required([call_id, from_tag], Params),
    safe_cmd(Node, delete, Params).

-spec query(node_name(), chappe_rtpengine_ng:params()) -> result().
query(Node, Params) ->
    ok = required([call_id], Params),
    safe_cmd(Node, query, Params).

%% Escape hatch for any NG command (statistics, list, recording, ...).
-spec cmd(node_name(), atom(), chappe_rtpengine_ng:params()) -> result().
cmd(Node, Command, Params) ->
    safe_cmd(Node, Command, Params).

-spec stats(node_name()) -> #{atom() => non_neg_integer()}.
stats(Node) ->
    chappe_rtpengine_client:stats(Node).

%% internal

required(Keys, Params) ->
    case [K || K <- Keys, not maps:is_key(K, Params)] of
        [] -> ok;
        Missing -> error({missing_params, Missing})
    end.

%% Wraps the client call with pool accounting for managed nodes: the
%% in-flight counter feeds load-based selection, and timeout/success
%% reports feed health tracking (any reply, including an rtpengine
%% error, proves the node alive).
safe_cmd(Node, Command, Params) ->
    Managed = chappe_rtpengine_pool:is_managed(Node),
    Managed andalso chappe_rtpengine_pool:track_start(Node),
    try chappe_rtpengine_client:cmd(Node, Command, Params) of
        {error, timeout} = Error ->
            Managed andalso chappe_rtpengine_pool:report(Node, timeout),
            Error;
        Result ->
            Managed andalso chappe_rtpengine_pool:report(Node, ok),
            Result
    catch
        exit:{noproc, _} -> {error, client_down};
        exit:{shutdown, _} -> {error, client_down};
        exit:{normal, _} -> {error, client_down};
        exit:{killed, _} -> {error, client_down}
    after
        Managed andalso chappe_rtpengine_pool:track_end(Node)
    end.
