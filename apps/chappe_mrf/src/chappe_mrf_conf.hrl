%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The state of a conference process (chappe_mrf_conf). A backend keeps
%% its own state in bstate; native and fs, in this app, read the record
%% too. A backend of another app uses the room API of
%% chappe_mrf_conf_backend instead.

%% an fs room's join_timeout by default; the most any room's may be (and
%% a native room's by default); how much longer than its room's
%% join_timeout a joiner waits on the room, so that the room's own answer
%% at its deadline comes first
-define(MRF_JOIN_TIMEOUT, 15000).
-define(MRF_JOIN_MAX, (?MRF_JOIN_TIMEOUT + 80000)).
-define(MRF_JOIN_MARGIN, 5000).

-record(state, {
    name :: binary(),
    %% the backend start/2 was given (native, fs, or a module) and the
    %% module that runs it (undefined while the room waits for its lease)
    backend :: atom(),
    mod :: module() | undefined,
    room :: binary(),
    %% the backend's own state
    bstate :: term(),
    owner_mon :: reference() | undefined,
    listeners = #{} :: #{pid() => reference()},
    members = #{} :: #{binary() => map()},
    pending = #{} :: #{term() => map()},
    locked = false :: boolean(),
    %% no join past this many members (pending joins count)
    max_members = infinity :: pos_integer() | infinity,
    focus :: chappe_sip_focus:focus() | undefined,
    entity :: binary() | undefined,
    %% REFER to the room (chappe_mrf_conf_refer): who decides (and who
    %% decides a call's Replaces of a member, chappe_mrf_conf_refer_member),
    %% how a target is dialed (dial fun, profile, timeout, endpoint
    %% options), the
    %% dial-outs under way by their channel ({ep, Ep}, {uuid, Uuid}) or
    %% helper ({helper, Pid}), the REFERs in flight and done
    %% (chappe_mrf_conf_refer_op), and what marks this room's dial-outs on
    %% their node (the chappe_dial channel variable) with the nodes whose
    %% events it takes for them
    refer_policy :: fun((map()) -> boolean() | {reject, 300..699}) | undefined,
    replaces_policy :: fun((map()) -> boolean()) | undefined,
    dial = #{} :: map(),
    dialing = #{} :: #{term() => map()},
    refer_ops = #{} :: chappe_mrf_conf_refer_op:ops(),
    dial_tag = <<>> :: binary(),
    dial_nodes = [] :: [term()],
    %% cluster => chappe_cluster: the room's lease on its name; lost once
    %% the region took it back (no new member from then on)
    lease :: map() | undefined,
    lost = false :: boolean(),
    %% cluster: started, waiting for the lease its starter claims (the
    %% init args, and the starter's monitor); undefined once it runs
    waiting ::
        #{
            args := map(),
            mon := reference(),
            deferred := [{term(), term(), integer()}]
        }
        | undefined,
    %% the options it started with, for the room that takes its members
    %% over (a handoff, a lost lease)
    opts = #{} :: map(),
    %% the optional callbacks the backend has (chappe_mrf_conf_backend)
    callbacks = #{} :: #{{atom(), arity()} => true},
    %% the members a call with Replaces took the place of, for a while:
    %% the hold of that call, and the timer that forgets it
    %% (chappe_mrf_conf_refer_member)
    replaced = #{} :: #{binary() => {reference(), reference()}}
}).
