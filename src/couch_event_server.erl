% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_event_server).
-behavior(gen_server).


-export([
    start_link/0
]).

-export([
    init/1,
    terminate/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    code_change/3
]).

-export([
    watchdog/0
]).


-include("couch_event_int.hrl").


-record(st, {
    by_pid,
    by_dbname,
    watchdog
}).


start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, nil, []).


init(_) ->
    {ok, ByPid} = khash:new(),
    {ok, ByDbName} = khash:new(),
    {ok, #st{
        by_pid = ByPid,
        by_dbname = ByDbName,
        watchdog = spawn_monitor(?MODULE, watchdog, [])
    }}.


terminate(_Reason, _St) ->
    ok.


handle_call({register, Pid, NewDbNames}, _From, St) ->
    case khash:get(St#st.by_pid, Pid) of
        undefined ->
            NewRef = erlang:monitor(process, Pid),
            register(St, NewRef, Pid, NewDbNames);
        {ReuseRef, OldDbNames} ->
            unregister(St, Pid, OldDbNames),
            register(St, ReuseRef, Pid, NewDbNames)
    end,
    {reply, ok, St};

handle_call({unregister, Pid}, _From, St) ->
    Reply = case khash:get(St#st.by_pid, Pid) of
        undefined ->
            not_registered;
        {Ref, OldDbNames} ->
            unregister(St, Pid, OldDbNames),
            erlang:demonitor(Ref, [flush]),
            ok
    end,
    {reply, Reply, St};

handle_call(Msg, From, St) ->
    couch_log:notice("~s ignoring call ~w from ~w", [?MODULE, Msg, From]),
    {reply, ignored, St}.


handle_cast({notify, DbName, Event}, St) ->
    notify_listeners(St#st.by_dbname, DbName, Event),
    {noreply, St};

handle_cast(Msg, St) ->
    couch_log:notice("~s ignoring cast ~w", [?MODULE, Msg]),
    {noreply, St}.


handle_info({'DOWN', Ref, _, _, Reason}, #st{watchdog={_,Ref}}=St) ->
    couch_log:notice("~s watchdog died: ~w", [?MODULE, Reason]),
    erlang:send_after(60000, self(), spawn_watchdog),
    {noreply, St#st{watchdog=undefined}};
handle_info({'DOWN', Ref, process, Pid, _Reason}, St) ->
    case khash:get(St#st.by_pid, Pid) of
        {Ref, OldDbNames} ->
            unregister(St, Pid, OldDbNames);
        undefined ->
            ok
    end,
    {noreply, St};


handle_info(spawn_watchdog, #st{watchdog=undefined}=St) ->
    NewWD = spawn_monitor(?MODULE, watchdog, []),
    {noreply, St#st{watchdog=NewWD}};
handle_info(Msg, St) ->
    couch_log:notice("~s ignoring info ~w", [?MODULE, Msg]),
    {noreply, St}.


code_change(_OldVsn, St, _Extra) ->
    {ok, St}.


watchdog() ->
    Handlers = gen_event:which_handlers(couch_db_update),
    case length(Handlers) > 0 of
        true ->
            exit(whereis(couch_db_update), force_upgrade);
        false ->
            ok
    end,
    timer:sleep(5000),
    ?MODULE:watchdog().


notify_listeners(ByDbName, DbName, Event) ->
    Msg = {'$couch_event', DbName, Event},
    notify_listeners(khash:get(ByDbName, all_dbs), Msg),
    notify_listeners(khash:get(ByDbName, DbName), Msg).


notify_listeners(undefined, _) ->
    ok;
notify_listeners(Listeners, Msg) ->
    khash:fold(Listeners, fun(Pid, _, _) -> Pid ! Msg, nil end, nil).


register(St, Ref, Pid, DbNames) ->
    khash:put(St#st.by_pid, Pid, {Ref, DbNames}),
    lists:foreach(fun(DbName) ->
        add_listener(St#st.by_dbname, DbName, Pid)
    end, DbNames).


add_listener(ByDbName, DbName, Pid) ->
    case khash:lookup(ByDbName, DbName) of
        {value, Listeners} ->
            khash:put(Listeners, Pid, nil);
        not_found ->
            {ok, NewListeners} = khash:new(),
            khash:put(NewListeners, Pid, nil),
            khash:put(ByDbName, DbName, NewListeners)
    end.


unregister(St, Pid, OldDbNames) ->
    ok = khash:del(St#st.by_pid, Pid),
    lists:foreach(fun(DbName) ->
        rem_listener(St#st.by_dbname, DbName, Pid)
    end, OldDbNames).


rem_listener(ByDbName, DbName, Pid) ->
    {value, Listeners} = khash:lookup(ByDbName, DbName),
    khash:del(Listeners, Pid),
    Size = khash:size(Listeners),
    if Size > 0 -> ok; true ->
        khash:del(ByDbName, DbName)
    end.
