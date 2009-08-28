
-module(fair_scheduler_job).
-behaviour(gen_server).

-export([start/0, init/1, next_task/3, handle_call/3, handle_cast/2, 
        handle_info/2, terminate/2, code_change/3]).

start(JobName, JobCoord) ->
        error_logger:info_report([{"JobProc starts for", JobName}]),
        gen_server:start(fair_scheduler_job, JobCoord, []).

init(JobCoord) ->
        link(JobCoord),
        {ok, {gb_trees:empty(), 
                gb_trees:insert(nopref, {0, []}, gb_trees:empty()), []}}.

% MAIN FUNCTION:
% Return a next task to be executed from this Job.
next_task(Job, Jobs, AvailableNodes) ->
        % First try to find a node-local or remote task to execute
        case gen_server:call(Job, {schedule_local, AvailableNodes}) of
                {run, Node, Task} ->
                        {ok, {Node, Task}};
                nolocal ->
                        % No locals, if empty nodes (i.e. nodes where no job
                        % has any tasks assigned) are available, we can assign
                        % a task to one of them.
                        Empty = all_empty_nodes(Jobs, AvailableNodes),
                        case gen_server:call(Job, {schedule_remote, Empty}) of
                                {run, Node, Task} ->
                                        {ok, {Node, Task}};
                                nonodes ->
                                        none
                        end
        end

% Return an often empty subset of AvailableNodes that don't have any tasks 
% assigned to them by any job.
all_empty_nodes(_, []) -> [];
all_empty_nodes([], AvailableNodes) -> AvailableNodes;
all_empty_nodes([Job|Jobs], AvailableNodes) -> 
        get_empty(Jobs, gen_server:call(Job,
                {get_empty_nodes, AvailableNodes})).

% Assign a new task to this job.
handle_cast({new_task, Task}, {Tasks, Running, Nodes}) ->
        NewTasks = assign_task(Task, Tasks, Nodes),
        {noreply, {NewTasks, Running, Nodes}};

% Cluster topology changed (see below).
handle_cast({update_nodes, NewNodes}, {Tasks, Running, Nodes}) ->
        NewTasks = reassign_tasks(Tasks, NewNodes),
        {noreply, {NewTasks, Running, NewNodes}};

% Add a new task to the list of running tasks (for the fairness fairy).
handle_cast({task_started, Node, Worker}, {Tasks, Running, Nodes}) ->
        erlang:monitor(Worker),
        NewRunning = gb_trees:insert(Worker, Node, Running),
        {noreply, {Tasks, NewRunning, Nodes}}.

% Job stats for the fairness fairy
handle_call(get_stats, _, {Tasks, Running, _} = S) ->
        NumTasks = lists:sum([N || {N, _} <- gb_trees:values(Tasks)]),
        {reply, {ok, {NumTasks, gb_trees:size(Running)}}, S};

% Return a subset of AvailableNodes that don't have any tasks assigned
% to them by this job.
handle_call({get_empty_nodes, AvailableNodes}, _, {Tasks, _, _} = S) ->
        case gb_trees:get(nopref, Tasks) of
                {0, _} ->
                        {reply, empty_nodes(Tasks, AvailableNodes), S};
                _ =>
                        {reply, [], S}
        end; 

% Primary scheduling policy (see below).
handle_call({schedule_local, AvailableNodes}, _, {Tasks, Running, Nodes}) ->
        {Reply, UpdatedTasks} = schedule_local(Tasks, AvailableNodes),
        {reply, Reply, {UpdatedTasks, Running, Nodes}};

% Secondary scheduling policy (see below).
handle_call({schedule_remote, FreeNodes}, _, {Tasks, Running, Nodes} = S) ->
        {Reply, UpdatedTasks} = schedule_remote(Tasks, FreeNodes),
        {reply, Reply, {UpdatedTasks, Running, Nodes}}.

% Task done. Remove it from the list of running tasks. (for the fairness fairy)
handle_info({'DOWN', _, _, Worker, _}, {Tasks, Running, Nodes}) ->
        {noreply, {Tasks, gb_trees:delete(Worker, Running), Nodes}}.

% Primary task scheduling policy:
% Try to find 
% 1) a local task assigned to one of the AvailableNodes
% 2) any remote task
schedule_local(Tasks, AvailableNodes) ->
        % Does the job have any local tasks to be run on AvailableNodes?
        case datalocal_nodes(Tasks, AvailableNodes) of
                % No local tasks assigned to AvailableNodes
                [] -> 
                        % Does the job have any remote tasks?
                        case gb_trees:get(nopref, Tasks) of
                                % No remote tasks either. Maybe we can move
                                % a local task -> we might receive a
                                % schedule_remote() call if free nodes are
                                % available.
                                {0, _} -> {nolocal, Tasks};
                                % Remote tasks found, pick the first one.
                                _ -> pop_busiest_node(Tasks, [nopref])
                        end;
                % Local tasks found. Choose an AvailableNode that has the
                % longest queue of tasks waiting. Pick the first task from it.
                Nodes -> pop_busiest_node(Tasks, AvailableNodes)
        end.

% Secondary task scheduling policy:
% No local or remote tasks were found. A free node is available that has
% no tasks assigned to it by any job. Pick a task from the longest queue
% and assign it to the free node.
schedule_remote(Tasks, []) -> {nonodes, Tasks};
schedule_remote(Tasks, [FreeNode|_]) ->
        case pop_busiest_node(Tasks, datalocal_nodes(Tasks, 
                        gb_trees:keys(Tasks))) of
                % No tasks left. However, the last currently running task
                % might fail, so we must stay alive.
                {nonodes, UTasks} -> {nonodes, UTasks};
                % Move Task from its local node to FreeNode
                {{run, _, Task}, UTasks} -> {{run, FreeNode, Task}, UTasks}
        end.

% pop_busiest_node defines the policy for choosing the next task from a chosen
% set of Nodes. Pick the task from the longest list.
pop_busiest_node(Tasks, []) -> {nonodes, Tasks};
pop_busiest_node(Tasks, Nodes) ->
        {{N, [Task|R]}, MaxNode} =
                lists:max([{gb_trees:get(Node), Node} || Node <- Nodes]),
        {{run, MaxNode, Task}, gb_trees:update(MaxNode, {N - 1, R}, Tasks)}.

% return nodes that don't have any local tasks assigned to them
empty_nodes(Tasks, AvailableNodes) ->
        filter_nodes(Tasks, AvailableNodes, false);

% return nodes that have at least one local tasks assigned to them
datalocal_nodes(Tasks, AvailableNodes) ->
        filter_nodes(Tasks, AvailableNodes, true);

filter_nodes(Tasks, AvailableNodes, Local) ->
        lists:filter(fun(Node) ->
                case gb_trees:lookup(Node, Tasks) of
                        none -> false == Local;
                        {0, _} -> false == Local;
                        _ -> true == Local
                end
        end, AvailableNodes).

% Assign a new task to a node which hostname match with the hostname
% of the task's input file, if the node is not in the task's blacklist.
% The task may have several redundant inputs, so we need to find the
% first one that matchs.
assign_task(Task, Tasks, Nodes) ->
        findpref(Task#task.input, Task, Tasks, Nodes).

findpref([], Task, Tasks, Nodes) ->
        {N, L} = gb_trees:get(nopref, Tasks)
        gb_trees:update(nopref, {N + 1, [Task|L]}, Tasks);

findpref([{_, Node}|R], Task, Tasks, Nodes) ->
        case gb_trees:lookup(Node, Tasks) of
                none ->
                        ValidNode = lists:member(Node, Nodes),
                        if ValidNode ->
                                gb_trees:insert(Node, {1, [Task]}, Tasks)
                        true ->
                                findpref(R, Task, Tasks)
                        end;
                {value, {N, L}} ->
                        IsBlack = lists:member(Node, Task#task.taskblack),
                        if IsBlack ->
                                findpref(R, Task, Tasks);
                        true ->
                                gb_trees:update(Node, {N + 1, [Task|L]}, Tasks)
                        end
        end.

% Cluster topology changed: New nodes appeared or existing ones were deleted
% or black- / whitelisted. Re-assign tasks.
reassign_tasks(Tasks, NewNodes) ->
        {OTasks, NTasks} = lists:foldl(fun(Node, {OTasks, NTasks}) ->
                case gb_trees:lookup(Node, OTasks) of
                        {value, TList} ->
                                {gb_trees:delete(Node, OTasks),
                                 gb_trees:insert(Node, TList, NTasks)}
                        none ->
                                {OTasks, NTasks};
                end
        end, {Tasks, gb_trees:empty()}, NewNodes),

        lists:foldl(fun(Task, NTasks) ->
                assing_task(Task, NTasks)
        end, gb_trees:insert(nopref, {0, []}, NTasks),
                lists:flatten([L || {_, L} <- gb_trees:values(OTasks)])).

% unused

terminate(_Reason, _State) -> {}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.
