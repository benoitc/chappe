%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc HEPv3 capture (Homer) for the traffic the native stack does not see.
%%
%% The native transports (UDP, TCP, TLS) are captured by sofia itself: the
%% engine hands it a capture URL (native_url/1) and every message it sends
%% or receives, retransmissions and nta's own responses included, goes to
%% the collector. The WebSocket transport is Erlang, so it calls capture/4
%% at its one send point and its one receive point, and this process
%% encodes the HEPv3 packet and sends it over UDP.
%%
%% Capture never blocks SIP: capture/4 is a cast, it is a no-op while
%% capture is off, and a capture is dropped while this process already has
%% ?MAX_QUEUE messages waiting (a slow collector, or none at all, only
%% loses captures). The packets carry the chunks sofia sends, plus the
%% correlation chunk (type 17) with the Call-ID.
%%
%% correlate/3 ties a Call-ID to the call_ref of its call (chappe_sip_call)
%% for every transport: two log packets (HEP protocol type 100), one whose
%% correlation chunk is the Call-ID and one whose correlation chunk is the
%% call_ref, each with the JSON payload
%% {"call_ref": Ref, "call_id": CallId, "role": uas | uac}. A collector
%% such as heplify-server stores them by correlation id, so a search by
%% either one finds the other, and every leg of the call shares the ref.
-module(chappe_sip_hep).
-behaviour(gen_server).

-export([start_link/0, configure/1, validate/1, native_url/1, capture/4]).
-export([correlate/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-ifdef(TEST).
-export([encode/1, decode/1]).
-endif.
-export_type([config/0, packet/0]).

%% HEP protocol type of a log entry (heplify-server's hep_proto_100)
-define(LOG_TYPE, 100).
%% captures waiting past this many are dropped
-define(MAX_QUEUE, 10000).
%% capture on/off, read on every WS message without a call
-define(ON, {?MODULE, on}).

-type config() :: #{
    host := inet:ip_address(),
    port := 1024..65535,
    version := 3,
    capture_id := 1..4294967295
}.
%% A HEPv3 packet as encode/1 takes it and decode/1 returns it.
-type packet() :: #{
    family => inet | inet6,
    proto := udp | tcp | non_neg_integer(),
    src := {inet:ip_address(), inet:port_number()},
    dst := {inet:ip_address(), inet:port_number()},
    time := {non_neg_integer(), 0..999999},
    capture_id := non_neg_integer(),
    payload := binary(),
    proto_type => non_neg_integer(),
    correlation_id => binary()
}.

-record(state, {
    sock :: gen_udp:socket() | undefined,
    cfg :: config() | undefined
}).
-type state() :: #state{}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Turn capture on with a validated config, or off with undefined.
-spec configure(config() | undefined) -> ok | {error, term()}.
configure(Cfg) ->
    gen_server:call(?MODULE, {configure, Cfg}).

%% Check a `hep' start option: #{host := Host, port := Port, version => 3,
%% capture_id => Id}. Host is an address or a name, resolved once here.
%% sofia takes a port of 1024 or more only.
-spec validate(term()) -> {ok, config()} | {error, {hep, term()}}.
validate(#{host := Host, port := Port} = Opts) when
    is_integer(Port), Port >= 1024, Port =< 65535
->
    Version = maps:get(version, Opts, 3),
    Id = maps:get(capture_id, Opts, 200),
    case {resolve(Host), Version, Id} of
        {{error, Why}, _, _} ->
            {error, {hep, {bad_host, Host, Why}}};
        {_, V, _} when V =/= 3 ->
            {error, {hep, {bad_version, V}}};
        {_, _, I} when not is_integer(I); I < 1; I > 16#FFFFFFFF ->
            {error, {hep, {bad_capture_id, I}}};
        {{ok, Ip}, 3, I} ->
            {ok, #{host => Ip, port => Port, version => 3, capture_id => I}}
    end;
validate(#{host := _, port := Port}) ->
    {error, {hep, {bad_port, Port}}};
validate(Other) ->
    {error, {hep, {bad_options, Other}}}.

%% The capture URL sofia's tport takes (TPTAG_CAPT).
-spec native_url(config()) -> binary().
native_url(#{host := Ip, port := Port, version := V, capture_id := Id}) ->
    Host =
        case tuple_size(Ip) of
            4 -> inet:ntoa(Ip);
            8 -> ["[", inet:ntoa(Ip), "]"]
        end,
    iolist_to_binary(
        io_lib:format("udp:~s:~b;hep=~b;capture_id=~b", [Host, Port, V, Id])
    ).

%% Capture one WebSocket message: in (received) or out (sent), over the ws
%% or wss listener, with Peer ({Ip, Port}). Keepalives (a bare CRLF or
%% CRLFCRLF) are not SIP messages and are skipped.
-spec capture(in | out, ws | wss, term(), binary()) -> ok.
capture(_Dir, _Proto, _Peer, <<"\r\n">>) ->
    ok;
capture(_Dir, _Proto, _Peer, <<"\r\n\r\n">>) ->
    ok;
capture(Dir, Proto, Peer, Raw) ->
    case persistent_term:get(?ON, false) andalso whereis(?MODULE) of
        Pid when is_pid(Pid) ->
            case erlang:process_info(Pid, message_queue_len) of
                {message_queue_len, N} when N < ?MAX_QUEUE ->
                    gen_server:cast(
                        Pid,
                        {capture, Dir, Proto, Peer, Raw, now_us()}
                    );
                _ ->
                    ok
            end;
        _ ->
            ok
    end.

%% Tie CallId to CallRef at the capture server: one call leg (uas, a call
%% we answer or bridge; uac, one we send). A no-op while capture is off;
%% dropped as capture/4 is past ?MAX_QUEUE.
-spec correlate(binary() | undefined, binary() | undefined, uas | uac) -> ok.
correlate(CallId, CallRef, Role) when is_binary(CallId), is_binary(CallRef) ->
    case persistent_term:get(?ON, false) andalso whereis(?MODULE) of
        Pid when is_pid(Pid) ->
            case erlang:process_info(Pid, message_queue_len) of
                {message_queue_len, N} when N < ?MAX_QUEUE ->
                    gen_server:cast(
                        Pid, {correlate, CallId, CallRef, Role, now_us()}
                    );
                _ ->
                    ok
            end;
        _ ->
            ok
    end;
correlate(_CallId, _CallRef, _Role) ->
    ok.

%% ---- HEPv3 (chunks of vendor 0) ----

-spec encode(packet()) -> binary().
encode(#{src := {SIp, SPort}, dst := {DIp, DPort}, time := {Sec, Usec}} = P) ->
    {Fam, SChunk, DChunk} =
        case tuple_size(SIp) of
            4 -> {2, chunk(3, ip(SIp)), chunk(4, ip(DIp))};
            8 -> {10, chunk(5, ip(SIp)), chunk(6, ip(DIp))}
        end,
    Corr =
        case maps:get(correlation_id, P, undefined) of
            undefined -> [];
            C -> chunk(17, C)
        end,
    Chunks = [
        chunk(1, <<Fam:8>>),
        chunk(2, <<(proto_num(maps:get(proto, P))):8>>),
        SChunk,
        DChunk,
        chunk(7, <<SPort:16>>),
        chunk(8, <<DPort:16>>),
        chunk(9, <<Sec:32>>),
        chunk(10, <<Usec:32>>),
        chunk(11, <<(maps:get(proto_type, P, 1)):8>>),
        chunk(12, <<(maps:get(capture_id, P)):32>>),
        chunk(15, maps:get(payload, P)),
        Corr
    ],
    Body = iolist_to_binary(Chunks),
    <<"HEP3", (byte_size(Body) + 6):16, Body/binary>>.

chunk(Type, Data) ->
    [<<0:16, Type:16, (byte_size(Data) + 6):16>>, Data].

ip({A, B, C, D}) ->
    <<A, B, C, D>>;
ip({A, B, C, D, E, F, G, H}) ->
    <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>.

proto_num(udp) -> 17;
proto_num(tcp) -> 6.

%% ---- gen_server ----

-spec init([]) -> {ok, state()}.
init([]) ->
    persistent_term:put(?ON, false),
    {ok, #state{}}.

handle_call({configure, undefined}, _From, S) ->
    {reply, ok, off(S)};
handle_call({configure, #{host := Ip} = Cfg}, _From, S) ->
    S1 = off(S),
    Fam =
        case tuple_size(Ip) of
            4 -> inet;
            8 -> inet6
        end,
    case gen_udp:open(0, [binary, Fam, {active, false}]) of
        {ok, Sock} ->
            persistent_term:put(?ON, true),
            {reply, ok, S1#state{sock = Sock, cfg = Cfg}};
        {error, Why} ->
            {reply, {error, {hep, Why}}, S1}
    end;
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({capture, Dir, Proto, Peer, Raw, Us}, #state{sock = Sock} = S) when
    Sock =/= undefined
->
    #{host := Ip, port := Port, capture_id := Id} = S#state.cfg,
    Local = chappe_sip_ws_listener:port(Proto),
    {Src, Dst} =
        case Dir of
            in -> {addr(Peer), local(Local, Peer)};
            out -> {local(Local, Peer), addr(Peer)}
        end,
    P0 = #{
        proto => tcp,
        src => Src,
        dst => Dst,
        time => {Us div 1000000, Us rem 1000000},
        capture_id => Id,
        payload => Raw
    },
    P =
        case call_id(Raw) of
            undefined -> P0;
            CallId -> P0#{correlation_id => CallId}
        end,
    _ = gen_udp:send(Sock, Ip, Port, encode(P)),
    {noreply, S};
handle_cast(
    {correlate, CallId, CallRef, Role, Us}, #state{sock = Sock} = S
) when
    Sock =/= undefined
->
    #{host := Ip, port := Port, capture_id := Id} = S#state.cfg,
    _ = [
        gen_udp:send(Sock, Ip, Port, encode(P))
     || P <- correlation_packets(CallId, CallRef, Role, Us, Id)
    ],
    {noreply, S};
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, S) ->
    _ = off(S),
    ok.

off(#state{sock = undefined} = S) ->
    persistent_term:get(?ON, false) andalso persistent_term:put(?ON, false),
    S;
off(#state{sock = Sock} = S) ->
    persistent_term:put(?ON, false),
    ok = gen_udp:close(Sock),
    S#state{sock = undefined, cfg = undefined}.

%% ---- helpers ----

%% The log packets of correlate/3: the same payload under each id.
-spec correlation_packets(
    binary(), binary(), uas | uac, integer(), non_neg_integer()
) -> [packet()].
correlation_packets(CallId, CallRef, Role, Us, CaptureId) ->
    Payload = iolist_to_binary(
        json:encode(#{
            <<"call_ref">> => CallRef,
            <<"call_id">> => CallId,
            <<"role">> => atom_to_binary(Role)
        })
    ),
    Base = #{
        proto => udp,
        src => {{0, 0, 0, 0}, 0},
        dst => {{0, 0, 0, 0}, 0},
        time => {Us div 1000000, Us rem 1000000},
        capture_id => CaptureId,
        payload => Payload,
        proto_type => ?LOG_TYPE
    },
    [Base#{correlation_id => C} || C <- [CallId, CallRef]].

resolve(Host) when is_tuple(Host) ->
    case inet:ntoa(Host) of
        {error, _} = E -> E;
        _ -> {ok, Host}
    end;
resolve(Host) when is_binary(Host) ->
    resolve(binary_to_list(Host));
resolve(Host) when is_list(Host) ->
    case inet:parse_address(Host) of
        {ok, Ip} ->
            {ok, Ip};
        {error, _} ->
            case inet:getaddr(Host, inet) of
                {ok, Ip} -> {ok, Ip};
                {error, _} -> inet:getaddr(Host, inet6)
            end
    end;
resolve(_) ->
    {error, einval}.

addr({Ip, Port}) when is_tuple(Ip), is_integer(Port) -> {Ip, Port};
addr(_) -> {{0, 0, 0, 0}, 0}.

%% Our end of the connection. The WS listener binds every address, so the
%% local address is the unspecified one of the peer's family, with the
%% listener's port.
local(Port, {PeerIp, _}) when is_integer(Port), tuple_size(PeerIp) =:= 8 ->
    {{0, 0, 0, 0, 0, 0, 0, 0}, Port};
local(Port, _Peer) ->
    {{0, 0, 0, 0}, Port}.

%% the Call-ID (or its compact form i) of a SIP message, for chunk 17
call_id(Raw) ->
    case
        re:run(
            Raw,
            "\\r\\n(?:call-id|i)[ \\t]*:[ \\t]*([^\\r\\n]*[^\\r\\n \\t])",
            [caseless, {capture, all_but_first, binary}]
        )
    of
        {match, [Id]} -> Id;
        nomatch -> undefined
    end.

now_us() ->
    os:system_time(microsecond).

-ifdef(TEST).
-spec decode(binary()) -> {ok, packet()} | {error, term()}.
decode(<<"HEP3", Len:16, Rest/binary>>) when byte_size(Rest) =:= Len - 6 ->
    try chunks(Rest, #{}) of
        #{sip := SIp, dip := DIp, sport := SP, dport := DP} = M ->
            Base = maps:without([sip, dip, sport, dport, sec, usec], M),
            {ok, Base#{
                src => {SIp, SP},
                dst => {DIp, DP},
                time => {maps:get(sec, M, 0), maps:get(usec, M, 0)}
            }};
        _ ->
            {error, missing_chunks}
    catch
        error:_ -> {error, bad_chunk}
    end;
decode(_) ->
    {error, not_hep3}.

chunks(<<>>, M) ->
    M;
chunks(<<_Vendor:16, Type:16, Len:16, Rest/binary>>, M) when Len >= 6 ->
    DLen = Len - 6,
    <<Data:DLen/binary, Next/binary>> = Rest,
    chunks(Next, field(Type, Data, M)).

field(1, <<2:8>>, M) ->
    M#{family => inet};
field(1, <<_:8>>, M) ->
    M#{family => inet6};
field(2, <<6:8>>, M) ->
    M#{proto => tcp};
field(2, <<17:8>>, M) ->
    M#{proto => udp};
field(2, <<N:8>>, M) ->
    M#{proto => N};
field(T, <<A, B, C, D>>, M) when T =:= 3; T =:= 4 ->
    ip_field(T, {A, B, C, D}, M);
field(T, <<_:16/binary>> = B, M) when T =:= 5; T =:= 6 ->
    <<A:16, Bb:16, C:16, D:16, E:16, F:16, G:16, H:16>> = B,
    ip_field(T - 2, {A, Bb, C, D, E, F, G, H}, M);
field(7, <<P:16>>, M) ->
    M#{sport => P};
field(8, <<P:16>>, M) ->
    M#{dport => P};
field(9, <<S:32>>, M) ->
    M#{sec => S};
field(10, <<U:32>>, M) ->
    M#{usec => U};
field(11, <<T:8>>, M) ->
    M#{proto_type => T};
field(12, <<I:32>>, M) ->
    M#{capture_id => I};
field(15, P, M) ->
    M#{payload => P};
field(17, C, M) ->
    M#{correlation_id => C};
field(_, _, M) ->
    M.

ip_field(3, Ip, M) -> M#{sip => Ip};
ip_field(4, Ip, M) -> M#{dip => Ip}.
-endif.
