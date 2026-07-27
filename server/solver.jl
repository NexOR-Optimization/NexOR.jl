#  Copyright (c) 2026: NexOR Optimization SRL
#
#  Use of this source code is governed by an MIT-style license that can be found
#  in the LICENSE.md file or at https://opensource.org/licenses/MIT.

# Inline solving for the manager mimic: the real manager never solves (the
# workers do, over /api/solve-worker/v1), but the NexOR.jl tests run with
# NEXOR_INLINE_SOLVER=1 so the round trip needs no worker process.

import JSON
import MathOptInterface as MOI
import NexOR

function solve(dir)
    id = basename(dir)
    write_status(dir, Dict("id" => id, "status" => "running", "error" => nothing))
    try
        envelope = JSON.parsefile(joinpath(dir, "envelope.json"))
        solver = MOI.OptimizerWithAttributes(
            JSON.parse(JSON.json(envelope["solver"]), NexOR.OptimizerWithAttributes),
        )
        solution = solve_envelope(solver, dir)
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

function solve_envelope(envelope, solver, dir, log)
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
    has_values = MOI.get(optimizer, MOI.PrimalStatus()) != MOI.NO_SOLUTION
    primal = nothing
    if has_values
        primal = [
            MOI.get(optimizer, MOI.VariablePrimal(), index_map[vi]) for
            vi in MOI.get(mof, MOI.ListOfVariableIndices())
        ]
    end
    return Dict(
        "api_version" => "1",
        "attributes" => NexOR.solution_attributes(optimizer),
        "primal" => primal,
        "log" => log === nothing ? nothing : first(log, 100_000),
        "metering" => Dict("wall_seconds" => wall_seconds, "cpu_seconds" => nothing),
    )
end
