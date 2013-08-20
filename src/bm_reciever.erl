-module(bm_reciever).
-compile([export_all]).
-include("../include/bm.hrl").

-record(state, {socket, transport, version, stream = 1, init_stage = 0, remote_streams, remote_addr}).
-record(init_stage, {verack_sent=0,verack_recv=0}).

loop(#state{socket = Socket, transport = Transport}=IState) ->
    case Transport:recv(Socket,4096, 5000) of
        {ok, <<16#e9, 16#be, 16#b4, 16#d9, Command:12/bytes, Length:32, Check:4/bytes, Packet/bytes>>} ->
            
            State = if 
                size(Packet) == Length ->
                    <<Check:32/bits, _/bits>> = crypto:hash(sha512, Packet),
                    analyse_packet(Command, Length, Packet, IState);
                size(Packet) < Length ->
                    {ok, Data} = Transport:recv(Socket, Length - size(Packet), 5000),
                    analyse_packet(Command, Length, <<Packet/bytes, Data/bytes>>, IState)
            end, 
            loop(State);
        _ ->
            loop(IState)
    end.

analyse_packet(<<"version", _>>, Length, <<Version:32/integer,
                                           1:64/integer, % 'services' field of protocol
                                           _Time:64/integer,
                                           _AddrRecv:26/bytes,
                                           AddrFrom:26/bytes,
                                           _Nonce:8/bytes,
                                           Data/bytes>>,
              State) 
        when Length > 83, Version > 1 ->
    {_UA, StremsL} = bm_types:decode_varstr(Data),
    {Streams, _} = bm_types:decode_intlist(StremsL),
    #state{transport=Transport, socket=Socket} = State,
    % Sending verack
    Transport:send(Socket, <<?MAGIC/bytes, "verack", 0:6/unit:8-integer, 0:32/integer, 16#cf83e135:32/big-integer>>),
    Stage = State#state.init_stage#init_stage{verack_sent=true},

    if Stage#init_stage.verack_recv == false ->
            send_version(State)
    end,
    State#state{version=Version, init_stage=Stage, remote_streams=Streams, remote_addr=bm_types:decode_network(AddrFrom)};
analyse_packet(<<"verack", _>>, 0, <<>>, State) ->
    State#state{init_stage=State#state.init_stage#init_stage{verack_recv=true}};
analyse_packet(<<"addr", _>>, Length, Data, #state{init_stage=#init_stage{verack_recv=true, verack_sent=true}} = State) ->
    {Len, AList} = bm_types:decode_varint(Data),
    Addrs = decode_addr_list(AList, Len),
    dets:insert(addr, Addrs),
    State;
analyse_packet(<<"getpubkey", _>>, Length, <<PNonce:64/big-integer,
                                             Time:64/big-integer,
                                             AVer:8/big-integer,
                                             Packet/bytes>>,
                 #state{init_stage=#init_stage{verack_recv=true, verack_sent=true}} = State) ->
    ompl;
analyse_packet(<<"pubkey", _>>, Length, <<PNonce:64/big-integer,
                                          Time:64/big-integer,
                                          AVer:8/big-integer,
                                          Packet/bytes>>,
                 #state{init_stage=#init_stage{verack_recv=true, verack_sent=true}} = State) ->
    impl;
analyse_packet(<<"inv",_>>, Length, Packet, 
                 #state{init_stage=#init_stage{verack_recv=true, verack_sent=true}} = State) ->
    impl;
analyse_packet(<<"getdata", _>>, Length, Packet,
                 #state{init_stage=#init_stage{verack_recv=true, verack_sent=true}} = State) ->
    impl;
analyse_packet(<<"msg", _>>, Length, Packet,
                 #state{init_stage=#init_stage{verack_recv=true, verack_sent=true}} = State) ->
    impl;
analyse_packet(<<"broadcast", _>>, Length, Packet,
                 #state{init_stage=#init_stage{verack_recv=true, verack_sent=true}} = State) ->
    impl;
analyse_packet(<<"ping", _>>, Length, Packet,
                 #state{transport=Transport, socket=Socket,init_stage=#init_stage{verack_recv=true, verack_sent=true}} = State) ->
    % Sending pong
    Transport:send(Socket, <<?MAGIC/bytes, "pong", 0:8/unit:8-integer, 0:32/integer, 16#cf83e135:32/big-integer>>);
analyse_packet(_, _, _,
                 #state{init_stage=#init_stage{verack_recv=true, verack_sent=true}} = State) ->
    State.
               
send_version(#state{transport=Transport, socket=Socket, stream=Stream, remote_addr=RAddr } = State) ->
    {MSec, Sec, _} = now(),
    Time = MSec * 1.0e6 + Sec,
    {ok, {Ip, Port}} = inet:sockname(Socket),
    <<_:12/bytes, AddrRecv/bytes>> = bm_types:encode_address(RAddr),
    <<_:12/bytes, AddrFrom/bytes>> = bm_types:encode_address(#network_address{time=Time, stream=Stream, ip=Ip, port=Port}),
    Nonce = crypto:rand_bytes(8),
    Message = <<2:32/integer,
                1:64/integer, % 'services' field of protocol
                Time:64/integer,
                AddrRecv:26/bytes,
                AddrFrom:26/bytes,
                Nonce:8/bytes,
                (bm_types:encode_varstr("/BitMessageErl:0.1/"))/bytes,
                (bm_types:encode_intlist([1, Stream]))/bytes>>,
    Transport:send(Socket, Message).

decode_addr_list(_, 0) ->
    [];
decode_addr_list(<<Addr:34/bytes, Rest/bytes>>, Length) ->
    [bm_types:decode_network(Addr) | decode_addr_list(Rest, Length - 1)].
    
