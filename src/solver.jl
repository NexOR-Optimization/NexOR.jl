#  Copyright (c) 2026: NexOR Optimization SRL
#
#  Use of this source code is governed by an MIT-style license that can be found
#  in the LICENSE.md file or at https://opensource.org/licenses/MIT.

# MOI.OptimizerWithAttributes expects a first argument that can be instantiated
# The difference here is that we expect a `String` naming the solver, so the
# solver package only needs to be installed where the solve runs. This spec
# serializes the remote solver id and options without loading that package.

# `@nonstruct` keeps JSON from encoding the abstract optimizer attributes
# field-by-field. `JSON.lower` defines the wire form below. This internal spec
# supplies the solver id and its namespace in the platform's submit options.
JSON.@nonstruct struct OptimizerWithAttributes
    optimizer::String
    params::Vector{Pair{MOI.AbstractOptimizerAttribute,Any}}
end

"""
    OptimizerWithAttributes(optimizer::String, params::Pair...)

Like `MOI.OptimizerWithAttributes` with the optimizer given by name, e.g.,
`NexOR.OptimizerWithAttributes("HiGHS", "presolve" => "on")`, so that the
solver package only needs to be installed on the server.
"""
function OptimizerWithAttributes(optimizer::String, args::Vararg{Pair,N}) where {N}
    params = Pair{MOI.AbstractOptimizerAttribute,Any}[MOI._to_param(arg) for arg in args]
    return OptimizerWithAttributes(optimizer, params)
end

function OptimizerWithAttributes(solver::MOI.OptimizerWithAttributes)
    return OptimizerWithAttributes(
        String(nameof(parentmodule(solver.optimizer_constructor))),
        solver.params,
    )
end

# Wire names of the non-raw optimizer attributes in the solver options.
_parameter_name(attr::MOI.RawOptimizerAttribute) = attr.name
_parameter_name(::MOI.Silent) = "silent"
_parameter_name(::MOI.TimeLimitSec) = "time_limit_seconds"
_parameter_name(::MOI.NumberOfThreads) = "threads"

function JSON.lower(solver::OptimizerWithAttributes)
    return Dict(
        # The catalog names of the manager are lowercase
        "name" => solver_id(solver.optimizer),
        "parameters" =>
            Dict(_parameter_name(attr) => value for (attr, value) in solver.params),
    )
end

# The platform's `highs` reads an expression grammar. MOF needs its own
# descriptor so a JuMP model cannot be sent to that incompatible solver.
solver_id(name::String) = lowercase(name) == "highs" ? "highs-mof" : lowercase(name)
