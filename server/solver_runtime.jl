# Copyright (c) 2026: NexOR Optimization SRL
# Independent solver-side adapter for the MathOptFormat process protocol.
module SolverRuntime

import HiGHS
import JSON
import MathOptInterface as MOI

struct SolverInputError <: Exception
    status::String
    message::String
end

Base.showerror(io::IO, err::SolverInputError) = print(io, err.message)

function outcome(status::String)
    if status in ("OPTIMAL", "LOCALLY_SOLVED", "ALMOST_OPTIMAL", "ALMOST_LOCALLY_SOLVED")
        return "solved"
    elseif status in (
        "INFEASIBLE",
        "LOCALLY_INFEASIBLE",
        "DUAL_INFEASIBLE",
        "INFEASIBLE_OR_UNBOUNDED",
        "ALMOST_INFEASIBLE",
        "ALMOST_DUAL_INFEASIBLE",
    )
        return "no_solution"
    elseif status in (
        "TIME_LIMIT",
        "ITERATION_LIMIT",
        "MEMORY_LIMIT",
        "NODE_LIMIT",
        "OTHER_LIMIT",
        "SLOW_PROGRESS",
        "INTERRUPTED",
        "SOLUTION_LIMIT",
        "OBJECTIVE_LIMIT",
        "NORM_LIMIT",
    )
        return "limit"
    end
    return "error"
end

function failure_solution(err::SolverInputError)
    status = err.status == "INVALID_PROBLEM" ? "INVALID_MODEL" : err.status
    return Dict(
        "outcome" => "error",
        "termination_status" => err.status,
        "objective_value" => nothing,
        "body" => Dict(
            "attributes" => Dict(
                "termination_status" => status,
                "primal_status" => "NO_SOLUTION",
                "dual_status" => "NO_SOLUTION",
                "result_count" => 0,
                "raw_status" => err.message,
            ),
            "primal" => nothing,
        ),
        "extensions" => Dict(),
        "diagnostics" => Dict(
            "warnings" =>
                [Dict("code" => lowercase(err.status), "message" => err.message)],
        ),
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
    solve_problem(problem, solver::String, options; time_limit = Inf)

Read a MathOptFormat body and return a process-protocol v1 solution.
`time_limit` is the remaining budget granted by the runner, in seconds.
"""
function solve_problem(problem, solver::String, options; time_limit = Inf)
    started = time()
    mof = MOI.FileFormats.MOF.Model()
    try
        read!(IOBuffer(JSON.json(problem)), mof)
    catch err
        throw(SolverInputError("INVALID_PROBLEM", sprint(showerror, err)))
    end
    optimizer = try
        solver == "highs-mof" || error("Unsupported solver: $solver")
        parameters = Pair{MOI.AbstractOptimizerAttribute,Any}[
            parameter(String(name)) => value for (name, value) in options
        ]
        MOI.instantiate(
            MOI.OptimizerWithAttributes(HiGHS.Optimizer, parameters...);
            with_bridge_type = Float64,
            with_cache_type = Float64,
        )
    catch err
        throw(SolverInputError("INVALID_OPTION", sprint(showerror, err)))
    end
    index_map = try
        MOI.copy_to(optimizer, mof)
    catch err
        throw(SolverInputError("INVALID_MODEL", sprint(showerror, err)))
    end
    if isfinite(time_limit)
        time_limit = max(0.0, time_limit - (time() - started))
        requested = MOI.get(optimizer, MOI.TimeLimitSec())
        MOI.set(
            optimizer,
            MOI.TimeLimitSec(),
            max(0.0, requested === nothing ? time_limit : min(requested, time_limit)),
        )
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
    status = attributes["termination_status"]
    return Dict(
        "outcome" => outcome(status),
        "termination_status" => status,
        "objective_value" => get(attributes, "objective_value", nothing),
        "body" => Dict("attributes" => attributes, "primal" => primal),
        "extensions" => Dict(),
        "diagnostics" => Dict("warnings" => []),
    )
end

end
