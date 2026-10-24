# Copyright (c) 2026: NexOR Optimization SRL
# HiGHS adapter for the minimal client test backend.
module SolverRuntime

import HiGHS
import JSON
import MathOptInterface as MOI

function refusal(status, err)
    return Dict(
        "solution" => Dict(),
        "termination_status" => status,
        "diagnostics" => Dict("warnings" => [Dict("message" => sprint(showerror, err))]),
    )
end

const _SOLUTION_ATTRIBUTES = Dict{String,MOI.AbstractModelAttribute}(
    "termination_status" => MOI.TerminationStatus(),
    "primal_status" => MOI.PrimalStatus(),
    "dual_status" => MOI.DualStatus(),
    "result_count" => MOI.ResultCount(),
    "objective_value" => MOI.ObjectiveValue(),
    "dual_objective_value" => MOI.DualObjectiveValue(),
    "raw_status" => MOI.RawStatusString(),
)

function solution_attributes(optimizer::MOI.ModelLike)
    attributes = Dict{String,Any}()
    for (name, attr) in _SOLUTION_ATTRIBUTES
        value = try
            MOI.get(optimizer, attr)
        catch # the solver is free not to provide this attribute
            continue
        end
        if value isa AbstractFloat && !isfinite(value)
            continue # JSON has no Inf/NaN
        end
        attributes[name] = value isa Enum ? string(value) : value
    end
    return attributes
end

const _NAMED_PARAMETERS = Dict{String,MOI.AbstractOptimizerAttribute}(
    "silent" => MOI.Silent(),
    "time_limit_seconds" => MOI.TimeLimitSec(),
    "threads" => MOI.NumberOfThreads(),
)

function parameter(name::String)
    return get(_NAMED_PARAMETERS, name, MOI.RawOptimizerAttribute(name))
end

"""
    solve_problem(problem, options)

Read MathOptFormat and return a client result or a structured input refusal.
"""
function solve_problem(problem, options)
    mof = MOI.FileFormats.MOF.Model()
    try
        read!(IOBuffer(JSON.json(problem)), mof)
    catch err
        return refusal("INVALID_PROBLEM", err)
    end
    optimizer = try
        parameters = Pair{MOI.AbstractOptimizerAttribute,Any}[
            parameter(String(name)) => value for (name, value) in options
        ]
        MOI.instantiate(
            MOI.OptimizerWithAttributes(HiGHS.Optimizer, parameters...);
            with_bridge_type = Float64,
            with_cache_type = Float64,
        )
    catch err
        return refusal("INVALID_OPTION", err)
    end
    index_map = try
        MOI.copy_to(optimizer, mof)
    catch err
        return refusal("INVALID_MODEL", err)
    end
    MOI.optimize!(optimizer)
    attributes = solution_attributes(optimizer)
    primal = if MOI.get(optimizer, MOI.PrimalStatus()) == MOI.NO_SOLUTION
        nothing
    else
        [
            MOI.get(optimizer, MOI.VariablePrimal(), index_map[vi]) for
            vi in MOI.get(mof, MOI.ListOfVariableIndices())
        ]
    end
    return Dict("solution" => Dict("attributes" => attributes, "primal" => primal))
end

end
