-module(bm_db).

-behaviour(gen_server).
-include("../include/bm.hrl").

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).
-export([
    insert/2,
    first/1,
    next/2,
    lookup/2,
    foldr/3, 
    select/3,
    match/2,
    delete/2,
    clear/3,
    ackselect/1,
    wait_db/0
    ]).

-record(state, {addr}).

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

insert(Type, Data) ->
    gen_server:call(?MODULE, {insert, Type, Data}).

first(Type)->
    gen_server:call(?MODULE, {first, Type}).

next(Type, Prev)->
    gen_server:call(?MODULE, {next, Type, Prev}).

lookup(Type, Prev)->
    gen_server:call(?MODULE, {get, Type, Prev}).

foldr(Fun, Acc, Type)->
    gen_server:call(?MODULE, {foldr, Fun, Type, Acc}).

select(Type, MatchSpec, N)->
    gen_server:call(?MODULE, {select, Type, MatchSpec, N}).

match(Type, MatchSpec)->
    gen_server:call(?MODULE, {match, Type, MatchSpec}).

delete(Type, Rec)->
    gen_server:cast(?MODULE, {del, Type, Rec}).

clear(Addr, Inv, PubKey) ->
    gen_server:cast(?MODULE, {clear, Addr, Inv, PubKey}).

ackselect(Inv) ->
    gen_server:call(?MODULE, {ackselect, Inv}).

wait_db() ->
    Timeout = application:get_env(bitmessage, table_wait, 65536),
    OK = mnesia:wait_for_tables([privkey, addr, inventory, sent], Timeout),
    if 
        OK == ok ->
            ok;
        true ->
            wait_db()
    end.

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
    case mnesia:wait_for_tables([inventory, privkey, addr], 5000) of
        {timeout, [inventory, privkey, addr]}  ->
            mnesia:stop(),
            mnesia:create_schema([node()]),
            mnesia:start(),
            {atomic, ok} = mnesia:create_table(inventory, [{disc_copies, [node()]}, {attributes, record_info(fields, inventory)}, {type, set}]),
            {atomic, ok} = mnesia:create_table(pubkey, [{disc_copies, [node()]}, {attributes, record_info(fields, pubkey)}, {type, set}]),
            {atomic, ok} = mnesia:create_table(privkey, [{disc_copies, [node()]}, {attributes, record_info(fields, privkey)}, {type, set}]),
            {atomic, ok} = mnesia:create_table(addr, [{disc_copies, [node()]}, {attributes, record_info(fields, network_address)}, {type, set}, {record_name, network_address}]),
            {atomic, ok} = mnesia:create_table(incoming, [{disc_copies, [node()]}, {attributes, record_info(fields, message)}, {type, set}, {record_name, message}]),
            {atomic, ok} = mnesia:create_table(sent, [{disc_copies, [node()]}, {attributes, record_info(fields, message)}, {type, set}, {record_name, message}]),
            mnesia:info();
        {timeout, _} ->
            timer:sleep(5000);
         ok ->
            ok;
        {error, R} ->
            exit(R)
    end,
    {ok, #state{}}.

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
handle_call({first, Type}, _From, State) ->
    {atomic, Data} = mnesia:transaction(fun() ->
                    mnesia:first(Type)
            end),
    {reply, Data, State};
handle_call({next, Type, Prev}, _From, State) ->
    {atomic, Data} = mnesia:transaction(fun() ->
                    mnesia:next(Type, Prev)
            end),
    {reply, Data, State};
handle_call({get, Type, Key}, _From, State) ->
    {atomic, Data} = mnesia:transaction(fun() ->
                    mnesia:read(Type, Key)
            end),
    {reply, Data, State};
handle_call({foldr, Fun,  Type, Acc}, _From, State) ->
    {atomic, Data} = mnesia:transaction(fun() ->
                    mnesia:foldr(Fun, Acc, Type)
            end),
    {reply, Data, State};
handle_call({select, Type, MatchSpec, N}, _From, State) ->
     {atomic, Data} = mnesia:transaction(fun() ->
                case mnesia:select(Type, MatchSpec, N, read) of
                    {D, C} ->
                        iterate(C, [ D ]);
                    '$end_of_table' ->
                        []
                end
            end),
        {reply, Data, State};
handle_call({match, Type, MatchSpec}, _From, State) ->
     {atomic, Data} = mnesia:transaction(fun() ->
                    mnesia:match_object(Type, MatchSpec, read)
            end),
    {reply, Data, State};
handle_call({insert, Type, Data}, _From, State) ->
     R = mnesia:transaction(fun() ->
                insert_obj(Type, Data)
        end),
    {reply, R, State};
handle_call({ackselect, Inv}, _From, State) ->
    R = mnesia:transaction(fun() ->
                                   A = mnesia:select(sent, [{#message{status=ackwait, _='_'}, [], ['$_']}]),
                                   CTime = bm_types:timestamp(),
                                   lists:filter(fun(#message{payload = <<_:64/bits, Time:64/big-integer, _/bytes>>}) ->
                                                        CTime -Time > Inv
                                                end, A)

                           end),
    {reply, R, State};
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
handle_cast({clear, Addr, Inv, PubKey}, State) ->
    mnesia:transaction(fun() ->
                               Time= bm_types:timestamp(),
                               Addrs = mnesia:select(addr, [{#network_address{time='$1', _='_'}, [{'<', '$1', (Time - Addr)}], ['$_']}]),
                               lists:foreach(fun(A) ->
                                                     mnesia:delete_object(A)
                                             end, Addrs),
                               Invs = mnesia:select(inventory, [
                                                                {#inventory{time='$1', type='$2', _='_'}, [{'<', '$1', (Time - Inv)}, {'/=', '$2', <<"pubkey">>}], ['$_']},
                                                                {#inventory{time='$1', type='$2', _='_'}, [{'<', '$1', (Time - PubKey)}, {'==', '$2', <<"pubkey">>}], ['$_']}
                                                               ]),
                               lists:foreach(fun(A) ->
                                                     mnesia:delete_object(A)
                                             end, Invs),
                               PubKeys = mnesia:select(pubkey, [{#pubkey{time='$1', _='_'}, [{'<', '$1', (Time - PubKey)}], ['$_']}]),
                               lists:foreach(fun(A) ->
                                                     mnesia:delete_object(A)
                                             end, PubKeys)
                       end),
    {noreply, State};
handle_cast({insert, Type, Data}, State) ->
     R = mnesia:transaction(fun() ->
                insert_obj(Type, Data)
        end),
    {noreply, State};
handle_cast({del, Type, Data}, State) ->
     R = mnesia:transaction(fun() ->
                mnesia:delete({ Type, Data })
        end),
    {noreply, State};
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
insert_obj(_, []) ->
    ok;
insert_obj(Type, [I|R]) ->
    mnesia:write(Type, I, write),
    insert_obj(Type, R).
iterate(C, Acc) ->
    case mnesia:select(C) of
        {D, Cont} ->
            Acc ++ [D] ++ iterate(Cont, Acc);
        '$end_of_table' ->
            Acc
    end.
