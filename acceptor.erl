-module(acceptor).

-export([start/1, loop/1, client/1]).

start(Port) ->
    {ok, ListeningSocket} = gen_tcp:listen(Port, 
        [binary, {packet, 0}, {active, true}, {reuseaddr, true}]),
    spawn(?MODULE, loop, [ListeningSocket]).
 
loop(ListenSocket) ->
    {ok, Socket} = gen_tcp:accept(ListenSocket),
    io:format("accepted socket~n"),
    spawn(?MODULE, loop, [ListenSocket]),
    ?MODULE:client(Socket).

client(Socket) ->
    gameserver:join(),
    io:format("joining~n"),
    client_loop(Socket).

client_loop(Socket) ->
    receive
        {diff, Data} ->
            gen_tcp:send(Socket, Data),
            client_loop(Socket);
        {tcp, Socket, Data} ->
            gameserver:send(Data),
            client_loop(Socket);
        {tcp_closed, Socket} ->
            io:format("Client left game~n"),
            gameserver:part()
    end.
