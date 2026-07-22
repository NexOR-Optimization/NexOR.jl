#  Copyright (c) 2026: NexOR Optimization SRL
#
#  Use of this source code is governed by an MIT-style license that can be found
#  in the LICENSE.md file or at https://opensource.org/licenses/MIT.

# Solve one problem directory produced by server.jl: read envelope.json,
# build an MOI model from the embedded MathOptFormat problem, solve it with
# the requested solver and write solution.json (a Solution Envelope v1, see
# ~/nexor docs/worker-protocol.md §7) plus the final status.json.
#
# Run as `julia --project=. solver.jl <problem-dir>` by server.jl, or
# included by it (NEXOR_INLINE_SOLVER=1) to solve in-process.

import JSON
import MathOptInterface as MOI
import NexOR

import JuMP
function _solution_summary(model::MOI.ModelLike)
    return JuMP.solution_summary(JuMP.direct_model(optimizer))
end

function envelope_status(summary)
    status = summary.termination_status
    if status == MOI.OPTIMAL
        return "optimal"
    elseif status == MOI.LOCALLY_SOLVED || status == MOI.ALMOST_OPTIMAL
        return "feasible"
    elseif status == MOI.INFEASIBLE || status == MOI.LOCALLY_INFEASIBLE
        return "infeasible"
    elseif status == MOI.DUAL_INFEASIBLE || status == MOI.INFEASIBLE_OR_UNBOUNDED
        return "unbounded"
    elseif status == MOI.TIME_LIMIT
        return "timeout"
    end
    return "error"
end

# JSON has no Inf/NaN/missing and no enums, hence the lowering rules.
json_value(x) = x
json_value(x::Enum) = string(x)
json_value(::Missing) = nothing
json_value(x::AbstractFloat) = isfinite(x) ? x : nothing
json_value(x::AbstractDict) = Dict(k => json_value(v) for (k, v) in x)
json_value(x::AbstractVector) = [json_value(v) for v in x]

# The wire format of the solution is the `JuMP._SolutionSummary` struct,
# written field by field, plus the vector of all variable values in the
# order of the variables of the MathOptFormat file.
function summary_json(summary)
    return Dict(
        string(name) => json_value(getfield(summary, name)) for
        name in fieldnames(typeof(summary))
    )
end

function solve_envelope(envelope, solver, dir)
    path = joinpath(dir, "problem.mof.json")
    write(path, JSON.json(envelope["problem"]))
    mof = MOI.FileFormats.MOF.Model()
    MOI.read_from_file(mof, path)
    optimizer =
        MOI.instantiate(solver; with_bridge_type = Float64, with_cache_type = Float64)
    index_map = MOI.copy_to(optimizer, mof)
    started = time()
    MOI.optimize!(optimizer)
    summary = _solution_summary(optimizer)
    wall_seconds = time() - started
    primal =
        summary.has_values ?
        [
            MOI.get(optimizer, MOI.VariablePrimal(), index_map[vi]) for
            vi in MOI.get(mof, MOI.ListOfVariableIndices())
        ] : nothing
    log_path = joinpath(dir, "worker.log")
    return Dict(
        "api_version" => "1",
        "status" => envelope_status(summary),
        "objective" => summary.has_values ? json_value(summary.objective_value) : nothing,
        "solution" => Dict("summary" => summary_json(summary), "primal" => primal),
        "log" => isfile(log_path) ? first(read(log_path, String), 100_000) : nothing,
        "metering" => Dict("wall_seconds" => wall_seconds, "cpu_seconds" => nothing),
    )
end

function solve(dir)
    id = basename(dir)
    write_status(dir, Dict("id" => id, "status" => "running", "error" => nothing))
    try
        envelope = JSON.parsefile(joinpath(dir, "envelope.json"))
        # Resolving the solver loads its package, whose methods land in a
        # newer world than this running function: enter the solve through
        # invokelatest so it sees them.
        solver = MOI.OptimizerWithAttributes(
            JSON.parse(envelope["solver"], NexOR.OptimizerWithAttributes),
        )
        solution = Base.invokelatest(solve_envelope, envelope, solver, dir)
        write_json(joinpath(dir, "solution.json"), solution)
        write_status(dir, Dict("id" => id, "status" => "returned", "error" => nothing))
    catch error
        write_status(
            dir,
            Dict(
                "id" => id,
                "status" => "failed",
                "error" =>
                    Dict("code" => "worker_error", "message" => sprint(showerror, error)),
            ),
        )
        rethrow()
    end
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    solve(ARGS[1])
end
