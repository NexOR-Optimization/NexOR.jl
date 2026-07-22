#  Copyright (c) 2026: NexOR Optimization SRL
#
#  Use of this source code is governed by an MIT-style license that can be found
#  in the LICENSE.md file or at https://opensource.org/licenses/MIT.

# Solve one problem directory produced by server.jl: read envelope.json,
# build an MOI model from the embedded MathOptFormat problem, solve it with
# the requested solver and write solution.json (a Solution Envelope v1, see
# ~/nexor docs/worker-protocol.md §7) plus the final status.json. The
# solution is the wire format of NexOR/src/solution.jl: the MOI solution
# attributes by name plus the primal vector in MathOptFormat order.
#
# Included by server.jl, the single entry point: the solve runs in a spawned
# `julia server.jl <problem-dir>` process, or in a task of the serving
# process itself when NEXOR_INLINE_SOLVER=1 (used by the NexOR.jl tests to
# avoid Julia startup per solve).

import JSON
import MathOptInterface as MOI
import NexOR

function envelope_status(status::MOI.TerminationStatusCode)
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
    wall_seconds = time() - started
    attributes = NexOR.solution_attributes(optimizer)
    has_values = MOI.get(optimizer, MOI.PrimalStatus()) != MOI.NO_SOLUTION
    primal =
        has_values ?
        [
            MOI.get(optimizer, MOI.VariablePrimal(), index_map[vi]) for
            vi in MOI.get(mof, MOI.ListOfVariableIndices())
        ] : nothing
    log_path = joinpath(dir, "worker.log")
    return Dict(
        "api_version" => "1",
        "status" => envelope_status(MOI.get(optimizer, MOI.TerminationStatus())),
        "objective" => get(attributes, "objective_value", nothing),
        "solution" => Dict("attributes" => attributes, "primal" => primal),
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
