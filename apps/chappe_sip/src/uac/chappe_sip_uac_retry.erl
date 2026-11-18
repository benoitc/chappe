%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The retries of one UAC request, each a new transaction of the same
%% call: with credentials after a 401/407 (the challenge handling itself is
%% chappe_sip_uac_auth), to the targets of a 3xx or through the proxy of a
%% 305, without the extensions a 420 names, and with a larger session
%% interval after a 422. Each returns {ok, D} with the new transaction, or
%% says why it gave up. Used by chappe_sip_uac_fsm.
-module(chappe_sip_uac_retry).

-include("chappe_sip_uac_fsm.hrl").

-export([with_auth/3, redirect/3, next_target/1, without_extensions/2]).
-export([session_interval/2, requested_interval/1]).

%% challenged requests one INVITE may send: a realm per round, plus
%% stale nonces
-define(MAX_AUTH_ROUNDS, 4).

%% ---- 401 / 407 ----

%% RFC 3261 22.2, 22.3: answer every Digest challenge of the 401/407, one
%% per realm (the strongest algorithm, RFC 8760), and keep answering the
%% ones of earlier rounds: a 407 then a 401 ends with both credentials on
%% the request. A new challenge for a realm we already answered means our
%% credentials were refused, unless it says stale=true (only the nonce
%% expired: retry with the new one, RFC 7616 3.3).
with_auth(Status, Msg, #data{cseq = CSeq} = D) ->
    Auth = maps:get(auth, D#data.opts, undefined),
    {AuthHdrName, Usable} = chappe_sip_uac_auth:usable(Status, Msg, Auth),
    case chappe_sip_uac_auth:merge(AuthHdrName, Usable, D#data.challenges) of
        {ok, Cs} when D#data.auth_rounds < ?MAX_AUTH_ROUNDS ->
            chappe_sip_engine:finish_txn(D#data.txn),
            chappe_sip_uac_req:send_request(D#data{
                challenges = Cs,
                auth_rounds = D#data.auth_rounds + 1,
                cseq = CSeq + 1
            });
        {ok, _} ->
            {error, too_many_challenges};
        Err ->
            Err
    end.

%% ---- 3xx ----

%% RFC 3261 21.3.6: a 305 keeps the Request-URI and sends the request
%% again through the proxy its Contact names; the credentials of the old
%% next hop are forgotten
redirect(305, Msg, #data{redirects = R, cseq = CSeq} = D) ->
    chappe_sip_engine:finish_txn(D#data.txn),
    case redirect_targets(Msg, D#data{tried = []}) of
        [Proxy | _] ->
            chappe_sip_uac_req:send_request(D#data{
                proxy = Proxy,
                cseq = CSeq + 1,
                redirects = R + 1,
                rseq = #{},
                first_sdp = <<>>,
                challenges = [],
                nonce_count = #{},
                auth_hdrs = []
            });
        [] ->
            {error, no_target}
    end;
%% RFC 3261 8.1.3.4: the Contacts of a 3xx are new targets, tried best q
%% first; each failure moves to the next one
redirect(_Status, Msg, #data{redirects = R} = D) ->
    New = redirect_targets(Msg, D),
    Targets = New ++ (D#data.targets -- New),
    chappe_sip_engine:finish_txn(D#data.txn),
    next_target(D#data{targets = Targets, redirects = R + 1}).

next_target(#data{targets = []}) ->
    {error, no_target};
next_target(#data{targets = [T | Rest], cseq = CSeq} = D) ->
    D1 = redirect_to(T, D#data{
        cseq = CSeq + 1,
        targets = Rest,
        tried = [T | D#data.tried],
        rseq = #{},
        first_sdp = <<>>
    }),
    case chappe_sip_uac_req:send_request(D1) of
        {ok, D2} -> {ok, D2};
        {error, _} -> next_target(D1)
    end.

%% A redirect target T becomes the Request-URI and the To (RFC 3261
%% 8.1.3.4), or, with keep_uri_on_redirect (drachtio's keepUriOnRedirect),
%% only the next hop: the Request-URI and To stay, as for a 305. The
%% credentials stay with the authority they were given to.
redirect_to(T, #data{opts = #{keep_uri_on_redirect := true}} = D) ->
    Hop =
        case D#data.proxy of
            undefined -> D#data.uri;
            P -> P
        end,
    strip_auth_across_authority(Hop, T, D#data{proxy = T});
redirect_to(T, #data{uri = OldUri} = D) ->
    strip_auth_across_authority(OldUri, T, D#data{
        uri = T, to = <<"<", T/binary, ">">>
    }).

redirect_targets(Msg, #data{tried = Tried}) ->
    chappe_sip_uac_auth:redirect_targets(Msg, Tried).

%% Forget the challenges (and so the credentials) of the old target when a
%% redirect leaves its scheme, host or port, or when either URI does not
%% parse: they were issued for that authority only.
strip_auth_across_authority(OldUri, NewUri, D) ->
    case chappe_sip_uri:same_authority(OldUri, NewUri) of
        true -> D;
        false -> D#data{challenges = [], nonce_count = #{}, auth_hdrs = []}
    end.

%% ---- 420 ----

%% RFC 3261 8.1.3.5: retry once without the extensions the UAS does not
%% support, as a new transaction of the same call; error when we required
%% none of them (nothing to retry)
without_extensions(Msg, D) ->
    Unsupported = chappe_sip_hdr:option_tags(
        chappe_sip_msg:get_all(<<"unsupported">>, Msg)
    ),
    case without_tags(Unsupported, D#data.opts) of
        {ok, Opts2} ->
            chappe_sip_engine:finish_txn(D#data.txn),
            chappe_sip_uac_req:send_request(D#data{
                opts = Opts2,
                cseq = D#data.cseq + 1,
                ext_retried = true
            });
        error ->
            error
    end.

%% The request options with the option tags a 420 named taken out of what
%% we require; error when we required none of them.
without_tags([], _Opts) ->
    error;
without_tags(Tags, Opts) ->
    Rel100 =
        case
            {
                maps:get(rel100, Opts, undefined),
                lists:member(<<"100rel">>, Tags)
            }
        of
            {require, true} -> {changed, supported};
            {Other, _} -> Other
        end,
    Headers = maps:get(headers, Opts, []),
    Headers2 = lists:filtermap(fun(H) -> drop_required(H, Tags) end, Headers),
    case {Rel100, Headers2} of
        {{changed, R}, _} -> {ok, Opts#{rel100 => R, headers => Headers2}};
        {_, Headers} -> error;
        {_, _} -> {ok, Opts#{headers => Headers2}}
    end.

drop_required({N, V}, Tags) ->
    case string:lowercase(N) of
        <<"require">> ->
            case chappe_sip_hdr:option_tags([iolist_to_binary(V)]) -- Tags of
                [] ->
                    false;
                Left ->
                    {true, {N, iolist_to_binary(lists:join(<<", ">>, Left))}}
            end;
        _ ->
            true
    end.

%% ---- 422 (RFC 4028) ----

%% 7.3: retry after a 422 with Session-Expires and Min-SE raised to its
%% Min-SE, same Call-ID/From/To and the next CSeq; not when the 422 asks
%% for no more than we sent, and at most three times. The Min-SE check is
%% the one a refresh makes (chappe_sip_session_timer:retry_after_422/2).
session_interval(Msg, #data{cseq = CSeq} = D) ->
    case configured_interval(D) of
        Mine when is_integer(Mine), D#data.retries_422 < 3 ->
            Sent = #{
                interval => Mine,
                min_se => D#data.min_se_422,
                refresher => local,
                peer_update => false
            },
            case chappe_sip_session_timer:retry_after_422(Msg, Sent) of
                {retry, #{min_se := MinSE}} ->
                    chappe_sip_engine:finish_txn(D#data.txn),
                    resend_422(D#data{
                        cseq = CSeq + 1,
                        min_se_422 = MinSE,
                        retries_422 = D#data.retries_422 + 1
                    });
                give_up ->
                    give_up
            end;
        _ ->
            give_up
    end.

resend_422(D) ->
    case chappe_sip_uac_req:send_request(D) of
        {ok, D2} -> {ok, D2};
        {error, _} -> give_up
    end.

%% the Session-Expires our INVITE carries, undefined when it asks for none
requested_interval(#data{min_se_422 = M} = D) ->
    case configured_interval(D) of
        undefined -> undefined;
        Mine -> max(Mine, M)
    end.

configured_interval(#data{opts = Opts}) ->
    maps:get(expires, chappe_sip_session_timer:config(Opts)).
