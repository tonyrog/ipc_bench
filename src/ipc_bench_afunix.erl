%%%-------------------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2016, Tony Rogvall
%%% @doc
%%%    server side of TCP ip module
%%% @end
%%% Created : 19 Feb 2016 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(ipc_bench_afunix).

-export([client/2, client/1]).
-export([server/2, server/1]).

client(Name) ->
    application:start(ipc_bench),
    client(Name, "/tmp/ipc_bench.10111").

server(Name) ->
    application:start(ipc_bench),
    server(Name, "/tmp/ipc_bench.10111").

client(Name, SockName) ->
    SELF = self(),
    {Pid,Mon} = spawn_monitor(fun() -> session_connect(SELF,Name,SockName) end),
    receive
	{'DOWN',Mon,process,Pid,Reason} ->
	    {error, Reason};
	{Pid, Result} ->
	    erlang:demonitor(Mon,[flush]),
	    Result
    end.

server(Name, SockName) ->
    spawn(fun() -> init(Name, SockName) end).

init(Name, SockName) ->
    Options = [{packet,4},{mode,binary},{nodelay,true},{reuseaddr,true}],
    {ok,L} = afunix:listen(SockName, Options),
    accept_loop(Name, L).

accept_loop(Name, L) ->
    SELF = self(),
    {Pid,Mon} = spawn_monitor(fun() -> session_accept(SELF,Name,L) end),
    receive
	{'DOWN',Mon,process,Pid,_Reason} ->
	    accept_loop(Name,L);
	{Pid, _Result} ->
	    accept_loop(Name,L)
    end.
	
session_accept(Parent,Name,L) ->
    case afunix:accept(L) of
	{ok, S} ->
	    Parent ! {self(), ok},
	    session_init(S, Name);
	Error ->
	    Parent ! {self(), Error}
    end.

session_connect(Parent,Name,SockName) ->
    Options = [{packet,4},{mode,binary},{nodelay,true}],
    case afunix:connect(SockName, Options) of
	{ok, S} ->
	    Parent ! {self(), ok},
	    session_init(S, Name);
	Error ->
	    Parent ! {self(), Error},
	    error
    end.

session_init(S, Name) ->
    afunix:send(S, term_to_binary({name,0,Name})),
    inet:setopts(S, [{active, true}]),
    session_loop(S, #{},Name,undefined,1,0).

session_loop(S,Ws,LName,RName,LID,RID) ->
    receive
	{tcp, S, Data} ->
	    inet:setopts(S, [{active, true}]),
	    try binary_to_term(Data) of
		{name, RID, Name} ->
		    ipc_bench_srv:register_node(Name, self()),
		    session_loop(S,Ws,LName,Name,LID,RID+1);
		{call,RID,M,F,A} ->
		    try apply(M, F, A) of
			Result ->
			    afunix:send(S, term_to_binary({ok,RID,Result}))
		    catch
			error:Reason ->
			    afunix:send(S, term_to_binary({error,RID,Reason}))
		    end,
		    session_loop(S,Ws,LName,RName,LID,RID+1);
		{Tag,ID,Result} when Tag =:= ok; Tag =:= error ->
		    case maps:find(ID, Ws) of
			{ok,{[Pid|Ref],Mon}} ->
			    Ws1 = maps:remove(RID, Ws),
			    erlang:demonitor(Mon, [flush]),
			    Pid ! {Tag,Ref,Result},
			    session_loop(S,Ws1,LName,RName,LID,RID);
			error ->
			    session_loop(S,Ws,LName,RName,LID,RID)
		    end;
		Other ->
		    io:format("data not supported ~p\n", [Other]),
		    session_loop(S,Ws,LName,RName,LID,RID)
	    catch
		error:Error ->
		    io:format("bad data on socket: ~p\n", [Error]),
		    session_loop(S,Ws,LName,RName,LID,RID)
	    end;
	{call,_Node,From=[Pid|_Ref],M,F,A} when is_pid(Pid) ->
	    afunix:send(S, term_to_binary({call,LID,M,F,A})),
	    Mon = erlang:monitor(process, Pid),
	    Ws1 = Ws#{ LID => {From,Mon}},  %% add to wait list
	    session_loop(S,Ws1,LName,RName,LID+1,RID);
	{tcp_closed, S} ->
	    ipc_bench_srv:unregister_node(RName),
	    ok;
	{tcp_error, S, Error} ->
	    ipc_bench_srv:unregister_node(RName),
	    io:format("got tcp error ~p\n", [Error]),
	    ok;
	Other ->
	    io:format("got other message ~p\n", [Other]),
	    session_loop(S,Ws,LName,RName,LID,RID)
    end.
