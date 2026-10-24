#  Copyright (c) 2026: NexOR Optimization SRL
#
#  Use of this source code is governed by an MIT-style license that can be found
#  in the LICENSE.md file or at https://opensource.org/licenses/MIT.

# The solution wire format: the MOI solution attributes of the remote solve,
# by name, plus the primal value of each variable in the order of the
# variables of the MathOptFormat file. The client loads them into the
# `MOI.Utilities.MockOptimizer` of `NexOR.Optimizer`, so every solution
# query is answered locally by MOI itself — no getters to implement on
# either side. Attributes `MockOptimizer` cannot store yet (`SolveTimeSec`,
# ...) are simply not supported; `RawStatusString` is the one exception,
# carried outside the mock because `JuMP.solution_summary` requires it
# unconditionally.

const _SOLUTION_ATTRIBUTES = Dict{String,MOI.AbstractModelAttribute}(
    "termination_status" => MOI.TerminationStatus(),
    "primal_status" => MOI.PrimalStatus(),
    "dual_status" => MOI.DualStatus(),
    "result_count" => MOI.ResultCount(),
    "objective_value" => MOI.ObjectiveValue(),
    "dual_objective_value" => MOI.DualObjectiveValue(),
    "raw_status" => MOI.RawStatusString(),
)

function _status(::Type{E}, name::String) where {E}
    return instances(E)[findfirst(status -> string(status) == name, instances(E))]
end

_lift(::MOI.TerminationStatus, value) = _status(MOI.TerminationStatusCode, value)

function _lift(::Union{MOI.PrimalStatus,MOI.DualStatus}, value)
    return _status(MOI.ResultStatusCode, value)
end

_lift(::MOI.AbstractModelAttribute, value) = value

"""
    load_solution!(mock::MOI.Utilities.MockOptimizer, solution)

Load the `{"attributes": ..., "primal": ...}` solution of the wire into
`mock` so MOI can answer solution queries locally.
"""
function load_solution!(mock::MOI.Utilities.MockOptimizer, solution)
    for (name, value) in solution["attributes"]
        if name == "raw_status" # not storable in the mock, kept by the caller
            continue
        end
        attr = _SOLUTION_ATTRIBUTES[String(name)]
        MOI.set(mock, attr, _lift(attr, value))
    end
    primal = solution["primal"]
    if primal !== nothing
        variables = MOI.get(mock, MOI.ListOfVariableIndices())
        for (vi, value) in zip(variables, primal)
            MOI.set(mock, MOI.VariablePrimal(), vi, Float64(value))
        end
    end
    return
end
