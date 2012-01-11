%%%-------------------------------------------------------------------
%%% File    : client.erl
%%% Author  : Jem
%%% Description : 
%%%
%%% Created :  11 Jan 2012
%%%-------------------------------------------------------------------
-module(client_process).

-behaviour(gen_server).

%% API
-export([start_link/1,
        start/0,
        start/1,
        send/2,
        socket_transfer/2,
        change_user/3,
        ghostkick/1,
        get_peername/1,
        get_connection_info/1
    ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("record.hrl").

-define(DECODE(Data), (State#client_state.protocol):decode(Data)).
-define(ENCODE(Data), (State#client_state.protocol):encode(Data)).
-define(SEND(Data), (State#client_state.user_module):send(State#client_state.user_pid, Data)).
-define(SOCKET, State#client_state.socket).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Protocol) ->
    gen_server:start_link(?MODULE, [Protocol], []).

start() ->
    gen_server:start(?MODULE, [], []).

start(Protocol) ->
    gen_server:start(?MODULE, [Protocol], []).

send(Pid, Data) ->
    gen_server:cast(Pid, {send, Data}).

socket_transfer(Pid, Socket) ->
    gen_server:call(Pid, {socket_transfer, Socket}).

change_user(Pid, Module, UserPid) ->
    gen_server:call(Pid, {change_user, Module, UserPid}).

ghostkick(Pid) ->
    gen_server:call(Pid, ghostkick).

get_peername(Pid) ->
    gen_server:call(Pid, peername).

get_connection_info(Pid) ->
    gen_server:call(Pid, connection_info).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([]) ->
    {ok, Pid} = virvel_auth:start_link(),
    State = #client_state{user_pid = Pid},
    {ok, State};

init([Protocol]) ->
    {ok, Pid} = virvel_auth:start_link(),
    State = #client_state{protocol = Protocol, user_pid = Pid},
    {ok, State}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------

handle_call({socket_transfer, Socket}, _From, State) ->
    case ssl:ssl_accept(Socket, 30000) of
        ok -> 
            ok = ssl:setopts(Socket, [{active, once}, binary, {packet, 2}]), 
            {ok, TRef} = timer:send_after(config:ping_timeout(), ping_timeout),
            NewState = State#client_state{ping_timer = TRef, socket = Socket},
            {reply, ok, NewState};
        Else ->
            {stop, Else, State}
    end;

handle_call({change_user, Mod, Pid}, _From, State) ->
    NewState = State#client_state{user_module = Mod, user_pid = Pid},
    {reply, ok, NewState};

handle_call(ghostkick, _From, State) ->
    {stop, ghostkick, ok, State};

handle_call(peername, _From, State) ->
    Reply = ssl:peername(?SOCKET),
    {reply, Reply, State};

handle_call(connection_info, _From, State) ->
    Reply = ssl:connection_info(?SOCKET),
    {reply, Reply, State};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({send, Data}, State) ->
    ssl:send(?SOCKET, ?ENCODE(Data)),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------

handle_info({ssl, Socket, Data}, State) ->
    try
        Result = ?DECODE(Data),
        %io:format("~s: ~p~n", [who(State), Result]),
        case Result of
            browser ->
                ssl:send(Socket, config:browser_string()),
                {stop, browser, State};
            ping ->
                {ok, cancel} = timer:cancel(State#client_state.ping_timer),
                {ok, NewTRef} = timer:send_after(config:ping_timeout(), ping_timeout),
                NewState = State#client_state{ping_timer = NewTRef},
                ssl:send(Socket, ?ENCODE(ping)),
                ssl:setopts(Socket, [{active, once}]),
                {noreply, NewState};
            Else ->
                ssl:setopts(Socket, [{active, once}]),
                ?SEND(Else),
                {noreply, State}
        end
    catch
        throw:{syntax_error, FaultyCode, Details} -> 
            io:format("Protocol syntax error: ~p, ~p~n", [FaultyCode, Details]),
            ssl:setopts(Socket, [{active,once}]),
            ssl:send(Socket, ?ENCODE(protocol_error)),
            protocol_error_check(State);
        throw:{function_error, FaultyCode, Details} ->
            io:format("Protocol function error: ~p, ~p~n", [FaultyCode, Details]),
            ssl:setopts(Socket, [{active,once}]),
            ssl:send(Socket, ?ENCODE(protocol_error)),
            protocol_error_check(State);
        Type:AnyException ->
            io:format("Unknown exception of type ~p raised: ~p, stacktrace: ~p~n", [Type, AnyException, erlang:get_stacktrace()]),
            ssl:setopts(Socket, [{active,once}]),
            ssl:send(Socket, ?ENCODE(protocol_error)),
            protocol_error_check(State)
    end;

handle_info({ssl_closed, _Socket}, State) -> 
    io:format("~s: Closed the connection.~n", [who(State)]),
    {stop, connection_lost, State};

handle_info({ssl_error, _Socket, Reason}, State) -> 
    io:format("~s: received socket error: ~p~n", [who(State), Reason]),
    {stop, ssl_error, State};

handle_info(Info, State) ->
    io:format("~s: received unknown data: ~p~n", [who(State)], Info),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
    % Reason will be send to the client in virvel1.0
    ssl:send(?SOCKET, ?ENCODE(user_quit)),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

logic_error(Anything, State) -> 
    io:format("~s: protocol logic error: ~p~n", [who(State), Anything]),
    ssl:send(?SOCKET, ?ENCODE(protocol_error)),
    protocol_error_check(State).

protocol_error_check(State) ->
    ProtocolError = State#client_state.protocolerrors,
    NewState = State#client_state{protocolerrors = (ProtocolError + 1)},
    case NewState#client_state.protocolerrors >= config:max_protocol_errors() of
        true ->
            {stop, too_many_protocol_errors, NewState};
        false ->
            {noreply, NewState}
    end.

who(State) ->
    try
        {ok, {{A, B, C, D}, Port}} = ssl:peername(?SOCKET),
        %%Username = case is_atom(State#client_state.username) of
        %%    true -> atom_to_list(State#client_state.username);
        %%    false -> State#client_state.username
        %%end,
        integer_to_list(A) 
        ++ "." ++ integer_to_list(B) 
        ++ "." ++ integer_to_list(C) 
        ++ "." ++ integer_to_list(D) 
        ++ ":" ++ integer_to_list(Port)
        %%++ " -> " ++ Username
    catch
        _:_ -> "(no info)"
    end.
