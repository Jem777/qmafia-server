-module(game).

-behaviour(gen_server). %% warns, if not all gen_server processes are used

-export([start/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-compile(export_all).

-record(state, {imagesize = {1,1}, image = <<"">>, userlist = []}).


start() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
stop() -> gen_server:call(?MODULE, stop).

join() -> gen_server:call(?MODULE, join).
part() -> gen_server:call(?MODULE, part).
send(Diff) -> gen_server:call(?MODULE, {send, Diff}).


init([]) -> {ok, #state{}}.


handle_call(join, {Pid, _From}, State) ->
    Reply = {State#state.imagesize, State#state.image},
    Userlist = State#state.userlist,
    NewState = case lists:member(Pid, Userlist) of
        true -> State;
        false ->
            NewUserlist = [Pid | Userlist], 
            State#state{userlist = NewUserlist}
    end,
    {reply, Reply, NewState};
handle_call(part, {Pid, _From}, State) ->
    NewUserlist = lists:delete(Pid, State#state.userlist),
    {reply, ok, State#state{userlist = NewUserlist}};
handle_call({send, Diff}, {Pid, _From}, State) ->
    Userlist = State#state.userlist,
    Reply = case lists:member(Pid, Userlist) of
        false -> {error, not_joined};
        true ->
            broadcast(Diff, Pid, Userlist),
            ok
        end,
    {reply, Reply, State};
handle_call(stop, _From, State) ->
    {stop, normal, stopped, State}.


handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, Extra) -> {ok, State}.


broadcast(Diff, Pid, Userlist) ->
    lists:foreach(
        fun(X) ->
                case X =:= Pid of
                    true -> ok;
                    false -> X ! {diff, Diff}
                end
        end,
        Userlist).
