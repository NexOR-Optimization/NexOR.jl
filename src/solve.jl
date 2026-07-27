#  Copyright (c) 2026: NexOR Optimization SRL
#
#  Use of this source code is governed by an MIT-style license that can be found
#  in the LICENSE.md file or at https://opensource.org/licenses/MIT.

# The solve itself, shared by the manager mimic (server/) and the worker
# (kamal-solve): build an MOI model from the MathOptFormat problem of a
# submit envelope, solve it with the requested solver, and return a
# Solution Envelope v1 (see the nexor repo, docs/worker-protocol.md §7).

"""
    solve_envelope(envelope, dir; log = nothing)

Solve the submit envelope `envelope` using `dir` as scratch space and
return the Solution Envelope v1 of the result. `log` is included in the
envelope, truncated to the 100000 characters the protocol allows.
"""
function solve_envelope(envelope, dir; log = nothing)
    # Resolving the solver may load its package, whose methods land in a
    # newer world than this running function: enter the solve through
    # invokelatest so it sees them.
    solver = MOI.OptimizerWithAttributes(
        JSON.parse(JSON.json(envelope["solver"]), OptimizerWithAttributes),
    )
    return Base.invokelatest(_solve_envelope, envelope, solver, dir, log)
end

function _solve_envelope(envelope, solver, dir, log)
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
    attributes = solution_attributes(optimizer)
    has_values = MOI.get(optimizer, MOI.PrimalStatus()) != MOI.NO_SOLUTION
    primal =
        has_values ?
        [
            MOI.get(optimizer, MOI.VariablePrimal(), index_map[vi]) for
            vi in MOI.get(mof, MOI.ListOfVariableIndices())
        ] : nothing
    return Dict(
        "api_version" => "1",
        # The MOI termination status verbatim; the manager adopts MOI's
        # vocabulary rather than projecting onto a coarser one
        "status" => attributes["termination_status"],
        "objective" => get(attributes, "objective_value", nothing),
        "solution" => Dict("attributes" => attributes, "primal" => primal),
        "log" => log === nothing ? nothing : first(log, 100_000),
        "metering" => Dict("wall_seconds" => wall_seconds, "cpu_seconds" => nothing),
    )
end
