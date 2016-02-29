%%%-------------------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2016, Tony Rogvall
%%% @doc
%%%    server side of TCP ip module
%%% @end
%%% Created : 19 Feb 2016 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(ipc_bench_udp).

-export([client/3, client/1]).
-export([server/2, server/1]).

client(Name) ->
    application:start(ipc_bench),
    client(Name, {127,0,0,1}, 10111).

server(Name) ->
    application:start(ipc_bench),
    server(Name, 10111).


client(Name, IP, Port) ->
    SELF = self(),
    {Pid,Mon} = spawn_monitor(fun() -> session_connect(SELF,Name,IP,Port) end),
    receive
	{'DOWN',Mon,process,Pid,Reason} ->
	    {error, Reason};
	{Pid, Result} ->
	    erlang:demonitor(Mon,[flush]),
	    Result
    end.

server(NodeName, Port) ->
    SELF = self(),
    {Pid,Mon} = spawn_monitor(fun() -> session_accept(SELF,NodeName,Port) end),
    receive
	{'DOWN',Mon,process,Pid,Reason} ->
	    {error, Reason};
	{Pid, Result} ->
	    erlang:demonitor(Mon,[flush]),
	    Result
    end.

session_accept(Parent,NodeName,Port) ->
    case gen_udp:open(Port, [{ifaddr,{127,0,0,1}},{mode,binary}]) of
	{ok, S} ->
	    Parent ! {self(), ok},
	    session_loop(S,#{},NodeName,0,0);
	Error ->
	    Parent ! {self(), Error},
	    error
    end.

session_connect(Parent,NodeName,IP,Port) ->
    case gen_udp:open(0, [{ifaddr,{127,0,0,1}},{mode,binary}]) of
	{ok, S} ->
	    Parent ! {self(), ok},
	    gen_udp:send(S, IP, Port, encode({name,0,NodeName})),
	    inet:setopts(S, [{active, true}]),
	    session_loop(S,#{},NodeName,1,0);
	Error ->
	    Parent ! {self(), Error},
	    error
    end.

session_loop(S,Ws,NodeName,LID,RID) ->
    receive
	{udp,S,RIP,RPort,Data} ->
	    inet:setopts(S, [{active, true}]),
	    try decode(Data) of
		{name,RID1,Name} when RID1 >= RID ->
		    ipc_bench_srv:register_node(Name, self()),
		    Ws1 = Ws#{ Name => {RIP,RPort} },
		    gen_udp:send(S,RIP,RPort,encode({rname,LID,NodeName})),
		    io:format("ipc_bench_udp: add node ~s ip=~w:~w\n",
			      [Name, RIP, RPort]),
		    session_loop(S,Ws1,NodeName,LID+1,RID1+1);
		{rname,RID1,Name} when RID1 >= RID ->
		    ipc_bench_srv:register_node(Name, self()),
		    Ws1 = Ws#{ Name => {RIP,RPort} },
		    io:format("ipc_bench_udp: radd node ~s ip=~w:~w\n",
			      [Name, RIP, RPort]),
		    session_loop(S,Ws1,NodeName,LID,RID1+1);
		{call,RID1,M,F,A} when RID1 >= RID ->
		    try apply(M, F, A) of
			Result ->
			    gen_udp:send(S,RIP,RPort,
					 encode({ok,RID1,Result}))
		    catch
			error:Reason ->
			    gen_udp:send(S,RIP,RPort,
					 encode({error,RID1,Reason}))
		    end,
		    session_loop(S,Ws,NodeName,LID,RID1+1);
		{Tag,ID,Result} when Tag =:= ok; Tag =:= error ->
		    case maps:find(ID, Ws) of
			{ok,{[Pid|Ref],Mon}} ->
			    Ws1 = maps:remove(RID, Ws),
			    erlang:demonitor(Mon, [flush]),
			    Pid ! {Tag,Ref,Result},
			    session_loop(S,Ws1,NodeName,LID,RID);
			error ->
			    session_loop(S,Ws,NodeName,LID,RID)
		    end;
		Other ->
		    io:format("data not supported ~p\n", [Other]),
		    session_loop(S,Ws,NodeName,LID,RID)
	    catch
		error:Error ->
		    io:format("bad data on socket: ~p\n", [Error]),
		    session_loop(S,Ws,NodeName,LID,RID)
	    end;

	{call,Node,From=[Pid|Ref],M,F,A} when is_pid(Pid) ->
	    case maps:find(Node, Ws) of
		error ->
		    Pid ! {error,Ref,enoent},
		    session_loop(S,Ws,NodeName,LID,RID);
		{ok,{RIP,RPort}} ->
		    gen_udp:send(S,RIP,RPort,encode({call,LID,M,F,A})),
		    Mon = erlang:monitor(process, Pid),
		    Ws1 = Ws#{ LID => {From,Mon}},  %% add to wait list
		    session_loop(S,Ws1,NodeName,LID+1,RID)
	    end;
	Other ->
	    io:format("got other message ~p\n", [Other]),
	    session_loop(S,Ws,NodeName,LID,RID)
    end.

encode(Term) ->
    erlang:term_to_binary(Term).

decode(Bin) ->
    erlang:binary_to_term(Bin).
