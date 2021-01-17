import Optim
import Printf: @printf
import Random: shuffle!, randperm


include("constants.jl")

include("errors.jl")

if weighted
    const avgy = sum(y .* weights)/sum(weights)
    const baselineMSE = MSE(y, convert(Array{Float32, 1}, ones(len) .* avgy), weights)
else
    const avgy = sum(y)/len
    const baselineMSE = MSE(y, convert(Array{Float32, 1}, ones(len) .* avgy))
end

include("utils.jl")

include("Node.jl")

include("eval.jl")

include("randomMutations.jl")

include("simplification.jl")

include("PopMember.jl")


include("halloffame.jl")


include("complexityChecks.jl")

include("simulatedAnnealing.jl")

include("Population.jl")


# Pass through the population several times, replacing the oldest
# with the fittest of a small subsample
function regEvolCycle(pop::Population, T::Float32, curmaxsize::Integer,
                      frequencyComplexity::Array{Float32, 1})::Population
    # Batch over each subsample. Can give 15% improvement in speed; probably moreso for large pops.
    # but is ultimately a different algorithm than regularized evolution, and might not be
    # as good.
    if fast_cycle
        shuffle!(pop.members)
        n_evol_cycles = round(Integer, pop.n/ns)
        babies = Array{PopMember}(undef, n_evol_cycles)

        # Iterate each ns-member sub-sample
        @inbounds Threads.@threads for i=1:n_evol_cycles
            best_score = Inf32
            best_idx = 1+(i-1)*ns
            # Calculate best member of the subsample:
            for sub_i=1+(i-1)*ns:i*ns
                if pop.members[sub_i].score < best_score
                    best_score = pop.members[sub_i].score
                    best_idx = sub_i
                end
            end
            allstar = pop.members[best_idx]
            babies[i] = iterate(allstar, T, curmaxsize, frequencyComplexity)
        end

        # Replace the n_evol_cycles-oldest members of each population
        @inbounds for i=1:n_evol_cycles
            oldest = argmin([pop.members[member].birth for member=1:pop.n])
            pop.members[oldest] = babies[i]
        end
    else
        for i=1:round(Integer, pop.n/ns)
            allstar = bestOfSample(pop)
            baby = iterate(allstar, T, curmaxsize, frequencyComplexity)
            #printTree(baby.tree)
            oldest = argmin([pop.members[member].birth for member=1:pop.n])
            pop.members[oldest] = baby
        end
    end

    return pop
end

# Cycle through regularized evolution many times,
# printing the fittest equation every 10% through
function run(
        pop::Population,
        ncycles::Integer,
        curmaxsize::Integer,
        frequencyComplexity::Array{Float32, 1};
        verbosity::Integer=0
       )::Population

    allT = LinRange(1.0f0, 0.0f0, ncycles)
    for iT in 1:size(allT)[1]
        if annealing
            pop = regEvolCycle(pop, allT[iT], curmaxsize, frequencyComplexity)
        else
            pop = regEvolCycle(pop, 1.0f0, curmaxsize, frequencyComplexity)
        end

        if verbosity > 0 && (iT % verbosity == 0)
            bestPops = bestSubPop(pop)
            bestCurScoreIdx = argmin([bestPops.members[member].score for member=1:bestPops.n])
            bestCurScore = bestPops.members[bestCurScoreIdx].score
            debug(verbosity, bestCurScore, " is the score for ", stringTree(bestPops.members[bestCurScoreIdx].tree))
        end
    end

    return pop
end


# Proxy function for optimization
function optFunc(x::Array{Float32, 1}, tree::Node)::Float32
    setConstants(tree, x)
    return scoreFunc(tree)
end

# Use Nelder-Mead to optimize the constants in an equation
function optimizeConstants(member::PopMember)::PopMember
    nconst = countConstants(member.tree)
    if nconst == 0
        return member
    end
    x0 = getConstants(member.tree)
    f(x::Array{Float32,1})::Float32 = optFunc(x, member.tree)
    if size(x0)[1] == 1
        algorithm = Optim.Newton
    else
        algorithm = Optim.NelderMead
    end

    try
        result = Optim.optimize(f, x0, algorithm(), Optim.Options(iterations=100))
        # Try other initial conditions:
        for i=1:nrestarts
            tmpresult = Optim.optimize(f, x0 .* (1f0 .+ 5f-1*randn(Float32, size(x0)[1])), algorithm(), Optim.Options(iterations=100))
            if tmpresult.minimum < result.minimum
                result = tmpresult
            end
        end

        if Optim.converged(result)
            setConstants(member.tree, result.minimizer)
            member.score = convert(Float32, result.minimum)
            member.birth = getTime()
        else
            setConstants(member.tree, x0)
        end
    catch error
        # Fine if optimization encountered domain error, just return x0
        if isa(error, AssertionError)
            setConstants(member.tree, x0)
        else
            throw(error)
        end
    end
    return member
end


function fullRun(niterations::Integer;
                npop::Integer=300,
                ncyclesperiteration::Integer=3000,
                fractionReplaced::Float32=0.1f0,
                verbosity::Integer=0,
                topn::Integer=10
               )

    testConfiguration()

    # 1. Start a population on every process
    allPops = Future[]
    # Set up a channel to send finished populations back to head node
    channels = [RemoteChannel(1) for j=1:npopulations]
    bestSubPops = [Population(1) for j=1:npopulations]
    hallOfFame = HallOfFame()
    frequencyComplexity = ones(Float32, actualMaxsize)
    curmaxsize = 3
    if warmupMaxsize == 0
        curmaxsize = maxsize
    end

    for i=1:npopulations
        future = @spawnat :any Population(npop, 3)
        push!(allPops, future)
    end

    # # 2. Start the cycle on every process:
    @sync for i=1:npopulations
        @async allPops[i] = @spawnat :any run(fetch(allPops[i]), ncyclesperiteration, curmaxsize, copy(frequencyComplexity)/sum(frequencyComplexity), verbosity=verbosity)
    end
    println("Started!")
    cycles_complete = npopulations * niterations
    if warmupMaxsize != 0
        curmaxsize += 1
        if curmaxsize > maxsize
            curmaxsize = maxsize
        end
    end

    last_print_time = time()
    num_equations = 0.0
    print_every_n_seconds = 5
    equation_speed = Float32[]

    for i=1:npopulations
        # Start listening for each population to finish:
        @async put!(channels[i], fetch(allPops[i]))
    end

    while cycles_complete > 0
        @inbounds for i=1:npopulations
            # Non-blocking check if a population is ready:
            if isready(channels[i])
                # Take the fetch operation from the channel since its ready
                cur_pop = take!(channels[i])
                bestSubPops[i] = bestSubPop(cur_pop, topn=topn)

                #Try normal copy...
                bestPops = Population([member for pop in bestSubPops for member in pop.members])

                for member in cur_pop.members
                    size = countNodes(member.tree)
                    frequencyComplexity[size] += 1
                    if member.score < hallOfFame.members[size].score
                        hallOfFame.members[size] = deepcopy(member)
                        hallOfFame.exists[size] = true
                    end
                end

                # Dominating pareto curve - must be better than all simpler equations
                dominating = PopMember[]
                open(hofFile, "w") do io
                    println(io,"Complexity|MSE|Equation")
                    for size=1:actualMaxsize
                        if hallOfFame.exists[size]
                            member = hallOfFame.members[size]
                            if weighted
                                curMSE = MSE(evalTreeArray(member.tree), y, weights)
                            else
                                curMSE = MSE(evalTreeArray(member.tree), y)
                            end
                            numberSmallerAndBetter = 0
                            for i=1:(size-1)
                                if weighted
                                    hofMSE = MSE(evalTreeArray(hallOfFame.members[i].tree), y, weights)
                                else
                                    hofMSE = MSE(evalTreeArray(hallOfFame.members[i].tree), y)
                                end
                                if (hallOfFame.exists[size] && curMSE > hofMSE)
                                    numberSmallerAndBetter += 1
                                end
                            end
                            betterThanAllSmaller = (numberSmallerAndBetter == 0)
                            if betterThanAllSmaller
                                println(io, "$size|$(curMSE)|$(stringTree(member.tree))")
                                push!(dominating, member)
                            end
                        end
                    end
                end
                cp(hofFile, hofFile*".bkup", force=true)

                # Try normal copy otherwise.
                if migration
                    for k in rand(1:npop, round(Integer, npop*fractionReplaced))
                        to_copy = rand(1:size(bestPops.members)[1])
                        cur_pop.members[k] = PopMember(
                            copyNode(bestPops.members[to_copy].tree),
                            bestPops.members[to_copy].score)
                    end
                end

                if hofMigration && size(dominating)[1] > 0
                    for k in rand(1:npop, round(Integer, npop*fractionReplacedHof))
                        # Copy in case one gets used twice
                        to_copy = rand(1:size(dominating)[1])
                        cur_pop.members[k] = PopMember(
                           copyNode(dominating[to_copy].tree)
                        )
                    end
                end

                @async begin
                    allPops[i] = @spawnat :any let
                        tmp_pop = run(cur_pop, ncyclesperiteration, curmaxsize, copy(frequencyComplexity)/sum(frequencyComplexity), verbosity=verbosity)
                        @inbounds @simd for j=1:tmp_pop.n
                            if rand() < 0.1
                                tmp_pop.members[j].tree = simplifyTree(tmp_pop.members[j].tree)
                                tmp_pop.members[j].tree = combineOperators(tmp_pop.members[j].tree)
                                if shouldOptimizeConstants
                                    tmp_pop.members[j] = optimizeConstants(tmp_pop.members[j])
                                end
                            end
                        end
                        tmp_pop = finalizeScores(tmp_pop)
                        tmp_pop
                    end
                    put!(channels[i], fetch(allPops[i]))
                end

                cycles_complete -= 1
                cycles_elapsed = npopulations * niterations - cycles_complete
                if warmupMaxsize != 0 && cycles_elapsed % warmupMaxsize == 0
                    curmaxsize += 1
                    if curmaxsize > maxsize
                        curmaxsize = maxsize
                    end
                end
                num_equations += ncyclesperiteration * npop / 10.0
            end
        end
        sleep(1e-3)
        elapsed = time() - last_print_time
        #Update if time has passed, and some new equations generated.
        if elapsed > print_every_n_seconds && num_equations > 0.0
            # Dominating pareto curve - must be better than all simpler equations
            current_speed = num_equations/elapsed
            average_over_m_measurements = 10 #for print_every...=5, this gives 50 second running average
            push!(equation_speed, current_speed)
            if length(equation_speed) > average_over_m_measurements
                deleteat!(equation_speed, 1)
            end
            average_speed = sum(equation_speed)/length(equation_speed)
            curMSE = baselineMSE
            lastMSE = curMSE
            lastComplexity = 0
            if verbosity > 0
                @printf("\n")
                @printf("Cycles per second: %.3e\n", round(average_speed, sigdigits=3))
                cycles_elapsed = npopulations * niterations - cycles_complete
                @printf("Progress: %d / %d total iterations (%.3f%%)\n", cycles_elapsed, npopulations * niterations, 100.0*cycles_elapsed/(npopulations*niterations))
                @printf("Hall of Fame:\n")
                @printf("-----------------------------------------\n")
                @printf("%-10s  %-8s   %-8s  %-8s\n", "Complexity", "MSE", "Score", "Equation")
                @printf("%-10d  %-8.3e  %-8.3e  %-.f\n", 0, curMSE, 0f0, avgy)
            end

            for size=1:actualMaxsize
                if hallOfFame.exists[size]
                    member = hallOfFame.members[size]
                    if weighted
                        curMSE = MSE(evalTreeArray(member.tree), y, weights)
                    else
                        curMSE = MSE(evalTreeArray(member.tree), y)
                    end
                    numberSmallerAndBetter = 0
                    for i=1:(size-1)
                        if weighted
                            hofMSE = MSE(evalTreeArray(hallOfFame.members[i].tree), y, weights)
                        else
                            hofMSE = MSE(evalTreeArray(hallOfFame.members[i].tree), y)
                        end
                        if (hallOfFame.exists[size] && curMSE > hofMSE)
                            numberSmallerAndBetter += 1
                        end
                    end
                    betterThanAllSmaller = (numberSmallerAndBetter == 0)
                    if betterThanAllSmaller
                        delta_c = size - lastComplexity
                        delta_l_mse = log(curMSE/lastMSE)
                        score = convert(Float32, -delta_l_mse/delta_c)
                        if verbosity > 0
                            @printf("%-10d  %-8.3e  %-8.3e  %-s\n" , size, curMSE, score, stringTree(member.tree))
                        end
                        lastMSE = curMSE
                        lastComplexity = size
                    end
                end
            end
            debug(verbosity, "")
            last_print_time = time()
            num_equations = 0.0
        end
    end
end
