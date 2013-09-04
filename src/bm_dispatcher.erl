-module(bm_dispatcher).

-behaviour(gen_server).

-include("../include/bm.hrl").

%% API
-export([start_link/0]).
-export([message_arrived/3,
         message_sent/1,
         broadcast_arrived/3,
         broadcast_sent/1,

         register_peer/1,
         register_cryptor/1]).


%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {addr, reciever}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

message_arrived(Data, Hash, Address) ->
    gen_server:cast(?MODULE, {arrived, message, Hash, Address, Data}).

broadcast_arrived(Data, Hash, Address) ->
    gen_server:cast(?MODULE, {arrived, broadcast,Hash, Address, Data}).

broadcast_sent(Data) ->
    gen_server:cast(?MODULE, {sent, message, Data}).

message_sent(Data) ->
    gen_server:cast(?MODULE, {sent, broadcast, Data}).

register_peer(Data) ->
    gen_server:call(?MODULE, {register, peer, Data}).

register_cryptor(Data) ->
    gen_server:call(?MODULE, {register, crypto, Data}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    {ok, inventory} = dets:open_file(inventory, [{file, "data/inventory.dets"}, {keypos, 2}, {ram_file, true}]),
    {ok, pubkey} = dets:open_file(pubkey, [{file, "data/pubkey.dets"}, {keypos, 2}, {ram_file, true}]),
    {ok, #state{reciever=self()}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({arrived, Type, Hash, #address{ripe=RIPE}=Address,  Data},  #state{reciever=RecieverPid}=State) ->
    {MsgVer, R} = bm_types:decode_varint(Data),
    {AddrVer, R1} = bm_types:decode_varint(R),
    {Stream, R2} = bm_types:decode_varint(R1),
    <<BField:32/big-integer, PSK:64/bytes, PEK:64/bytes, R3/bytes>> = R2,
    R4 = case MsgVer of
        2 -> 
            R3;
        MV when MV >= 3 ->
            {NonceTrailsPerBytes, RV} = bm_types:decode_varint(R3),
            {ExtraBytes, RV1} = bm_types:decode_varint(RV),
            RV1
        end,
    case Type of
        message ->
            <<DRIPE:20/bytes, MsgEnc/big-integer, R5/bytes>> = R4,
            if 
                DRIPE == RIPE ->
                    RecOK = true;
                true ->
                    RecOK = false
            end;
        broadcast ->
            <<MsgEnc/big-integer, R5/bytes>> = R4,
            RecOK = true
    end,

    {Message, R6} = bm_types:decode_varbin(R5),
    {AckData, R7} = bm_types:decode_varbin(R6),
    {Sig, R8} = bm_types:decode_varbin(R7),
    SLen = size(Data) - size(R7),
    <<DataSig:SLen/bytes, _/bytes>> = Data,
    SigOK = crypto:veryfy(ecdsa, sha512, DataSig, Sig, [<<4, PSK>>, secp256k1]),
    if 
        RecOK, SigOK, AddrVer > 0, AddrVer < 4 ->
            {Subject, Text} = case MsgEnc of
                1 ->
                    {"", Message};
                2 ->
                    [<<"Subject: ">>, <<S/bytes>>, <<"Body: ">>, <<T/bytes>>] = re:split(Message, "[\n:]", [{return, binary}, trim]),
                    {S, T}
            end,
            dets:insert(inbox, #message{hash=Hash, 
                                        enc=MsgEnc, 
                                        from=bm_auth:encode_address(AddrVer, Stream, RIPE), 
                                        to=Address, 
                                        subject=Subject,
                                        text=Text}),
            RecieverPid ! {msg, Hash},
            {noreply, State};
        true ->
            {noreply, State}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    dets:close(pubkey),
    dets:close(inventory),
    dets:close(addr),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================