#  Copyright (c) 2026: NexOR Optimization SRL
#
#  Use of this source code is governed by an MIT-style license that can be found
#  in the LICENSE.md file or at https://opensource.org/licenses/MIT.

# Solve one problem directory produced by server.jl: read envelope.json,
# build a JuMP model from the embedded MathOptFormat problem, solve it with
# HiGHS and write solution.json (a Solution Envelope v1, see
# ~/nexor docs/worker-protocol.md §7) plus the final status.json.
#
# Run as `julia --project=. solver.jl <problem-dir>` by server.jl, or
# included by it (NEXOR_INLINE_SOLVER=1) to solve in-process.

import HiGHS
import JSON
import JuMP

include("common.jl")

function envelope_status(summary)
    MOI = JuMP.MOI
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

function solve_envelope(envelope, dir)
    path = joinpath(dir, "problem.mof.json")
    write(path, JSON.json(envelope["problem"]))
    model = JuMP.read_from_file(path)
    JuMP.set_optimizer(model, HiGHS.Optimizer)
    for (name, value) in envelope["solver"]["parameters"]
        if name == "silent"
            value && JuMP.set_silent(model)
        elseif name == "time_limit_seconds"
            JuMP.set_time_limit_sec(model, value)
        else
            JuMP.set_attribute(model, name, value)
        end
    end
    started = time()
    JuMP.optimize!(model)
    wall_seconds = time() - started
    summary = JuMP.solution_summary(model)
    log_path = joinpath(dir, "worker.log")
    return Dict(
        "api_version" => "1",
        "status" => envelope_status(summary),
        "objective" => summary.has_values ? json_value(summary.objective_value) : nothing,
        "solution" => Dict(
            "summary" => summary_json(summary),
            "primal" => summary.has_values ?
                        JuMP.value.(JuMP.all_variables(model)) : nothing,
        ),
        "log" => isfile(log_path) ? first(read(log_path, String), 100_000) : nothing,
        "metering" => Dict("wall_seconds" => wall_seconds, "cpu_seconds" => nothing),
    )
end

function solve(dir)
    id = basename(dir)
    write_status(dir, Dict("id" => id, "status" => "running", "error" => nothing))
    try
        envelope = JSON.parsefile(joinpath(dir, "envelope.json"))
        solution = solve_envelope(envelope, dir)
        write_json(joinpath(dir, "solution.json"), solution)
        write_status(dir, Dict("id" => id, "status" => "returned", "error" => nothing))
    catch error
        write_status(
            dir,
            Dict(
                "id" => id,
                "status" => "failed",
                "error" => Dict(
                    "code" => "worker_error",
                    "message" => sprint(showerror, error),
                ),
            ),
        )
        rethrow()
    end
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    solve(ARGS[1])
end
