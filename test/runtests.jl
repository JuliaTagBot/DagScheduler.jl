addprocs(5)

include("daggen.jl")
using DagScheduler
using Base.Test

isdir(".mempool") && rm(".mempool"; recursive=true)

runenv = RunEnv()

@testset "deep dag" begin
    info("Testing deep dag...")
    dag1 = gen_straight_dag(ones(Int, 6^4))
    result = rundag(runenv, dag1)
    info("result = ", result)
    @test result == 1

    info("Testing cross connected dag...")
    dag3 = gen_cross_dag()
    result = rundag(runenv, dag3)
    info("result = ", result)
    @test result == 84
end

@testset "sorting" begin
    info("Testing sorting...")

    for L in (10^6, 10^7)
        dag2 = gen_sort_dag(L, 40, 4, 1)
        result = rundag(runenv, dag2)
        info("result = ", typeof(result), ", length: ", length(result), ", sorted: ", issorted(result))
        @test isa(result, Array{Float64,1})
        @test issorted(result)
        @test length(result) == L
        @everywhere MemPool.cleanup()

        # for cross dag
        dag4 = gen_sort_dag(L, 40, 4, 40)
        result = rundag(runenv, dag4)
        info("result = ", typeof(result), ", length: ", length(result))
        fullresult = collect(Dagger.treereduce(delayed(vcat), result))
        @test isa(fullresult, Array{Float64,1})
        @test issorted(fullresult)
        @test length(fullresult) == L
        @everywhere MemPool.cleanup()
    end
end

@testset "meta" begin
    info("Testing meta annotation...")
    x = [delayed(rand)(10) for i=1:10]
    y = delayed((c...) -> [c...]; meta=true)(x...)
    result = rundag(runenv, y)
    @test isa(result, Vector{<:Dagger.Chunk})
    @test length(result) == 10
    @everywhere MemPool.cleanup()
end

cleanup(runenv)
isdir(".mempool") && rm(".mempool"; recursive=true)

runenv = RunEnv([2,4,6], false)

@testset "selectedworkers" begin
    x = [delayed(rand)(10) for i=1:10]
    y = delayed((c...) -> [c...]; meta=true)(x...)
    result = rundag(runenv, y)
    @test isa(result, Vector{<:Dagger.Chunk})
    @test length(result) == 10
    @everywhere MemPool.cleanup()
    @test endswith(runenv.executors[1], "executor2")
    @test endswith(runenv.executors[2], "executor4")
    @test endswith(runenv.executors[3], "executor6")
end

cleanup(runenv)
isdir(".mempool") && rm(".mempool"; recursive=true)
