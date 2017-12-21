struct Sched
    id::UInt64                                  # component id
    name::String                                # component name
    role::Symbol                                # :executor or :broker
    pinger::RemoteChannel                       # signalling channel between peers
    meta::SchedulerNodeMetadata                 # node level shared metadata store
    reserved::Vector{TaskIdType}                # tasks reserved for this component
    shared::SharedCircularDeque{TaskIdType}     # tasks put out by this component for sharing
    stolen::Set{TaskIdType}                     # tasks that this component has stolen from others
    expanded::Set{TaskIdType}                   # tasks that have been expanded (not new tasks)
    help_threshold::Int                         # threshold for putting out tasks for sharing
    nshared::Ref{Int}                           # cumulative number of tasks shared
    root_task::Ref{Union{Thunk,Void}}           # the root of dag being processed
    dependents::Dict{Thunk,Set{Thunk}}          # dependents of each node in the dag being processed
    reset_task::Ref{Union{Task,Void}}           # async task to reset the scheduler env after a run
    debug::Bool                                 # switch on debug logging

    function Sched(name::String, role::Symbol, pinger::RemoteChannel, metastore::String, help_threshold::Int; share_limit::Int=1024, debug::Bool=false)
        new(hash(name), name, role, pinger,
            SchedulerNodeMetadata(metastore), Vector{TaskIdType}(), SharedCircularDeque{TaskIdType}(name, share_limit; create=false),
            Set{TaskIdType}(), Set{TaskIdType}(),
            help_threshold, Ref(0), Ref{Union{Thunk,Void}}(nothing), Dict{Thunk,Set{Thunk}}(),
            Ref{Union{Task,Void}}(nothing), debug)
    end
end

struct SchedPeer
    id::UInt64                                  # peer componet id
    name::String                                # peer name
    shared::SharedCircularDeque{TaskIdType}     # tasks put out by peer for sharing

    function SchedPeer(name::String; share_limit::Int=1024)
        new(hash(name), name, SharedCircularDeque{TaskIdType}(name, share_limit; create=false))
    end
end

# enqueue can enqueue either to the reserved or shared section
# enqueuing to shared section is done under lock
function enqueue(stack::Sched, task::TaskIdType, isreserved::Bool)
    if isreserved
        enqueue(stack.reserved, task)
    else
        stack.nshared[] += 1
        enqueue(stack.shared, task)
    end
end
function enqueue(shared::SharedCircularDeque{TaskIdType}, task::TaskIdType)
    withlock(shared.lck) do
        (task in shared) || push!(shared, task)
    end
    task
end
function enqueue(reserved::Vector{TaskIdType}, task::TaskIdType)
    if task in reserved
        if task !== reserved[end]
            push!(reserved, splice!(reserved, findlast(reserved, task)))
        end
    else
        push!(reserved, task)
    end
    task
end

function dequeue(stack::Sched, task::TaskIdType)
    idx = findlast(stack.reserved, task)
    (idx > 0) && splice!(stack.reserved, idx)
    nothing
end

function should_share(stack::Sched)
    withlock(stack.shared.lck) do
        return (length(stack.shared) < stack.help_threshold)
    end
end

has_shared(stack::Union{Sched,SchedPeer}) = !isempty(stack.shared)

function has_shared(stack::Union{Sched,SchedPeer}, howmuch::Int)
    withlock(stack.shared.lck) do
        length(stack.shared) >= howmuch
    end
end

function async_reset(env::Sched)
    env.reset_task[] = @async reset(env)
    nothing
end

function reset(env::Sched)
    reset(env.meta; dropdb=false)
    empty!(env.reserved)
    empty!(env.shared)
    empty!(env.stolen)
    empty!(env.expanded)
    empty!(env.dependents)
    env.nshared[] = 0
    env.root_task[] = nothing
    nothing
end

function init(env::Sched, task::Thunk)
    if env.reset_task[] !== nothing
        wait(env.reset_task[])
        env.reset_task[] = nothing
    end
    env.root_task[] = task
    Dagger.dependents(task, env.dependents)
    nothing
end

get_executable(env::Sched, task::TaskIdType) = find_task(env.root_task[], task)

keep(env::Sched, executable::Any, depth::Int=1, isreserved::Bool=true) = keep(env, taskid(executable), depth, isreserved, executable)
function keep(env::Sched, task::TaskIdType, depth::Int=1, isreserved::Bool=true, executable::Any=nothing)
    #tasklog(env, "in keep for task ", task, " depth ", depth)
    has_result(env.meta, task) && (return true)

    #tasklog(env, "enqueue task ", task, " depth ", depth)
    enqueue(env, task, isreserved)
    !isreserved && (env.role === :executor) && ping(env)
    depth -= 1
    if depth >=0
        (executable == nothing) && (executable = get_executable(env, task))
        if istask(executable) && !(task in env.expanded)
            # reserve at least one task
            reservedforself = false
            for input in inputs(executable)
                if istask(input)
                    #tasklog(env, "will keep dependency input for executable ", task)
                    isthisreserved = (isreserved && (length(env.dependents[input]) < 2)) ? (!reservedforself || !should_share(env)) : false
                    keep(env, input, depth, isthisreserved)
                    reservedforself = reservedforself || isthisreserved
                end
            end
            push!(env.expanded, task)
        end
    end
    false
end

function steal(env::Sched, from::SchedPeer)
    withlock(from.shared.lck) do
        while true
            has_shared(from) || (return NoTask)
            task = shift!(from.shared)
            if !was_stolen(env, task)
                push!(env.stolen, task)
                return task
            end
        end
    end
end

was_stolen(env::Sched, task::TaskIdType) = task in env.stolen

inputs_available(env::Sched, task::TaskIdType) = inputs_available(env, get_executable(env, task))
function inputs_available(env::Sched, executable::Thunk)
    for inp in inputs(executable)
        if istask(inp)
            has_result(env.meta, taskid(inp)) || (return false)
        end
    end
    true
end

function runnable(env::Sched, task::TaskIdType)
    has_result(env.meta, task) && return true
    t = get_executable(env, task)
    istask(t) ? inputs_available(env, t) : true
end

# select a task from the reserved queue and mark it as being executed
# returns NoTask if no runnable task is found
function reserve(env::Sched)
    data = env.reserved
    #tasklog(env, "reserving from ", join(map(x->string(x.id), data), ", "))
    L = length(data)

    # find an unexpanded task
    restask = NoTask
    for idx in L:-1:1
        task = data[idx]
        if !(task in env.expanded)
            restask = task
            break
        end
    end

    # else find a runnable task
    if restask === NoTask
        for idx in L:-1:1
            task = data[idx]
            if runnable(env, task)
                restask = task
                break
            end
        end
        (restask === NoTask) || tasklog(env, " found a runnable task ", restask)
    else
        tasklog(env, " found an unexpanded task ", restask)
    end

    # else get the top task
    (restask === NoTask) && (L > 0) && (restask = data[L])

    tasklog(env, (restask !== NoTask) ? "reserved $(restask)" : "reserved notask")
    restask
end

function release(env::Sched, task::TaskIdType, complete::Bool)
    if complete
        dequeue(env, task)
    #else
    #    # if task is suspended, dequeue and put it up for stealing
    end
end

_collect(env, x::Chunk, _c) = collect(x)
function _collect(env, x::Union{Thunk,Function}, c::Bool=true)
    res = get_result(env.meta, taskid(x))
    (isa(res, Chunk) && c) ? collect(res) : res
end
_collect(env, x, _c) = x
function exec(env::Sched, task::TaskIdType)
    has_result(env.meta, task) && (return true)

    # run the task
    t = get_executable(env, task)
    if istask(t)
        res = t.f(map(x->_collect(env,x,!t.meta), inputs(t))...)
    elseif isa(t, Function)
        res = t()
    else
        res = t
    end

    if istask(t) && !t.get_result
        # dagger automatically sets persist and cache flags on dags it generated based on size
        res = Dagger.tochunk(res, persist = t.persist, cache = t.persist ? true : t.cache)
    end

    # export (if other processes need it) or keep in memory (for use in-process) the result
    if was_stolen(env, task)
        if isa(res, Chunk) && isa(res.handle, DRef)
            res = chunktodisk(res)
        end
        export_result(env.meta, task, res, UInt64(length(env.dependents[t])))
    else
        set_result(env.meta, task, res)
    end

    # clean up task inputs, we don't need them anymore
    if istask(t)
        for (inp, ires) in zip(t.inputs, map(x->_collect(env,x,false), inputs(t)))
            (istask(inp) && isa(ires, Chunk) && !ires.persist) || continue
            refcount = (length(env.dependents[inp]) > 1) ? decr_resultrefcount(env.meta, taskid(inp)) : UInt64(0)
            (refcount == 0) && pooldelete(ires.handle)
        end
    end
    true
end
