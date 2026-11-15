%% Distribution for the suites that start a peer node.
%%
%% A CT node runs undistributed, and net_kernel:start/2 needs an epmd to
%% register with: a fresh CI runner has none, which fails the start with
%% nodistribution. ensure/0 starts epmd first, then the node.
-module(chappe_audio_test_dist).

-export([ensure/0]).

-spec ensure() -> ok.
ensure() ->
    case node() of
        nonode@nohost ->
            _ = os:cmd("epmd -daemon"),
            Name = list_to_atom("chappe_audio_ct_" ++ os:getpid()),
            {ok, _} = net_kernel:start(Name, #{name_domain => shortnames}),
            ok;
        _ ->
            ok
    end.
