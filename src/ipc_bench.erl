%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2016, Tony Rogvall
%%% @doc
%%%
%%% @end
%%% Created : 19 Feb 2016 by Tony Rogvall <tony@rogvall.se>

-module(ipc_bench).

-export([start/0]).
-export([run/1, run/2]).
-export([call/4]).

start() ->
    application:start(ipc_bench).

call(Node, M, F, A) when is_atom(Node), is_atom(M), is_atom(F), is_list(A) ->
    case ipc_bench_srv:find_node(Node) of
	{ok,Session} ->
	    Ref = make_ref(),
	    Session ! {call,Node,[self()|Ref],M,F,A},
	    receive
		{ok,Ref,Result} -> Result;
		{error,Ref,Error} -> error(Error)
	    end;
	{error, Reason} ->
	    error(Reason)
    end.

run(Node) ->
    run(Node, 10000).

run(Node,N) ->
    T0 = erlang:system_time(micro_seconds),
    loop(Node, N),
    T1 = erlang:system_time(micro_seconds),    
    (N/(T1-T0))*1000000.

loop(_Node, 0) ->
    ok;
loop(Node, I) ->
    42 = call(Node, erlang, abs, [-42]),
    loop(Node, I-1).

