%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The supervision tree, rest_for_one so that what depends on a process
%% restarts with it:
%%
%% - the keeper of chappe_audio's groups in the `chappe' pg scope, which
%%   it starts when nothing on the node runs it (chappe_audio_pg);
%% - the registry, which owns the table of streams waiting for their
%%   connection;
%% - the store (its config, its pg membership and its sweep) and the
%%   supervisor of its writers, one per recording being written;
%% - one simple_one_for_one supervisor per kind of short-lived process:
%%   writers, streams, handshakes and listeners, every child temporary (a
%%   stream or a writer that crashes is not restarted; its owner sees it
%%   go);
%% - the default listener, when the `listener' env is set.
-module(chappe_audio_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, top).

init(top) ->
    Children =
        [
            #{
                id => chappe_audio_pg,
                start => {chappe_audio_pg, start_link, []}
            },
            #{
                id => chappe_audio_registry,
                start => {chappe_audio_registry, start_link, []}
            },
            #{
                id => chappe_audio_store_srv,
                start => {chappe_audio_store_srv, start_link, []}
            },
            sup(chappe_audio_writer_sup, chappe_audio_writer),
            sup(chappe_audio_stream_sup, chappe_audio_stream),
            sup(chappe_audio_conn_sup, chappe_audio_conn),
            sup(chappe_audio_listener_sup, chappe_audio_listener)
        ] ++ default_listener(application:get_env(chappe_audio, listener)),
    {ok, {#{strategy => rest_for_one, intensity => 5, period => 10}, Children}};
init({child, Mod}) ->
    Child = #{id => Mod, start => {Mod, start_link, []}, restart => temporary},
    {ok, {#{strategy => simple_one_for_one}, [Child]}}.

sup(Name, Mod) ->
    #{
        id => Name,
        start =>
            {supervisor, start_link, [{local, Name}, ?MODULE, {child, Mod}]},
        type => supervisor
    }.

%% The listener open/1 uses, registered under chappe_audio_listener.
default_listener({ok, Opts}) when is_map(Opts) ->
    [
        #{
            id => chappe_audio_listener,
            start =>
                {chappe_audio_listener, start_link, [
                    Opts#{register => chappe_audio_listener}
                ]}
        }
    ];
default_listener(_) ->
    [].
