%%  The contents of this file are subject to the Mozilla Public License
%%  Version 1.1 (the "License"); you may not use this file except in
%%  compliance with the License. You may obtain a copy of the License
%%  at http://www.mozilla.org/MPL/
%%
%%  Software distributed under the License is distributed on an "AS IS"
%%  basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%%  the License for the specific language governing rights and
%%  limitations under the License.
%%
%%  The Original Code is RabbitMQ.
%%
%%  The Initial Developer of the Original Code is VMware, Inc.
%%  Copyright (c) 2007-2011 VMware, Inc.  All rights reserved.
%%

-module(rabbit_top_worker).
-behaviour(gen_server).

-define(PROCESS_INFO, [memory, message_queue_len, reductions, status]).

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([procs/4, proc/1, ets_tables/4, ets_table/1]).

-define(SERVER, ?MODULE).
-define(MILLIS, 1000).
-define(EVERY, 5).
-define(SLEEP, ?EVERY * ?MILLIS).

-record(state, {procs, ets_tables}).

%%--------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


procs(Node, Key, Rev, Count) ->
    gen_server:call({?SERVER, Node}, {procs, Key, Rev, Count}, infinity).

proc(Pid) ->
    gen_server:call({?SERVER, node(Pid)}, {proc, Pid}, infinity).

ets_tables(Node, Key, Rev, Count) ->
    gen_server:call({?SERVER, Node}, {ets_tables, Key, Rev, Count}, infinity).

ets_table(Name) ->
    table_info(Name).

%%--------------------------------------------------------------------

init([]) ->
    ensure_timer(),
    {ok, #state{procs = procs(dict:new()),
                ets_tables = ets_tables([])}}.

handle_call({ets_tables, Key, Order, Count}, _From,
            State = #state{ets_tables = Tables}) ->
    {reply, toplist(Key, Order, Count, Tables), State};

handle_call({procs, Key, Order, Count}, _From, State = #state{procs = Procs}) ->
    {reply, toplist(Key, Order, Count, flatten(Procs)), State};

handle_call({proc, Pid}, _From, State = #state{procs = Procs}) ->
    {reply, dict:find(Pid, Procs), State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State = #state{procs = OldProcs, ets_tables = OldTables}) ->
    ensure_timer(),
    {noreply, State#state{procs = procs(OldProcs),
                          ets_tables = ets_tables(OldTables)}};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------

ensure_timer() ->
    erlang:send_after(?SLEEP, self(), update).

procs(OldProcs) ->
    lists:foldl(
      fun(Pid, Procs) ->
              case process_info(Pid, ?PROCESS_INFO) of
                  undefined ->
                      Procs;
                  Props ->
                      Delta = (reductions(Props) -
                                   case dict:find(Pid, OldProcs) of
                                       {ok, OldProps} -> reductions(OldProps);
                                       error          -> 0
                                   end) div ?EVERY,
                      NewProps = expand_gen_server2_info(
                                   Pid, [{reduction_delta, Delta} | Props]),
                      dict:store(Pid, NewProps, Procs)
              end
      end, dict:new(), processes()).

reductions(Props) ->
    {reductions, R} = lists:keyfind(reductions, 1, Props),
    R.

ets_tables(_OldTables) ->
    lists:filtermap(
        fun(Table) ->
            case table_info(Table) of
                undefined -> false;
                Info      -> {true, Info}
            end
        end,
        ets:all()).

table_info(Table) when not is_atom(Table) -> undefined;
table_info(TableName) when is_atom(TableName) ->
    Info = lists:map(fun
                        ({memory, MemWords}) -> {memory, bytes(MemWords)};
                        (Other) -> Other
                     end,
                     ets:info(TableName)),
    {owner, OwnerPid} = lists:keyfind(owner, 1, Info),
    case process_info(OwnerPid, registered_name) of
        []                           -> Info;
        {registered_name, OwnerName} -> [{owner_name, OwnerName} | Info]
    end.

flatten(Procs) ->
    dict:fold(fun(Name, Props, Rest) ->
                      [[{pid, Name} | Props] | Rest]
              end, [], Procs).

%%--------------------------------------------------------------------

toplist(Key, Order, Count, List) ->
    RevFun = case Order of
                 asc  -> fun (L) -> L end;
                 desc -> fun lists:reverse/1
             end,
    Keyed = [toplist(Key, I) || I <- List],
    Sorted = lists:sublist(RevFun(lists:keysort(1, Keyed)), Count),
    [Info || {_, Info} <- Sorted].

toplist(Key, Info) ->
    % Do not crash if unknown sort key. Keep unsorted instead.
    case lists:keyfind(Key, 1, Info) of
        {Key, Val} -> {Val, Info};
        false      -> {undefined, Info}
    end.

bytes(Words) ->  try
                     Words * erlang:system_info(wordsize)
                 catch
                     _:_ -> 0
                 end.

expand_gen_server2_info(Pid, Props) ->
    case rabbit_core_metrics:get_gen_server2_stats(Pid) of
        not_found ->
            Props;
        BufferLength ->
            [{buffer_len, BufferLength} | Props]
    end.