#  Copyright (c) 2026: NexOR Optimization SRL
#
#  Use of this source code is governed by an MIT-style license that can be found
#  in the LICENSE.md file or at https://opensource.org/licenses/MIT.

# MOI.OptimizerWithAttributes expects a first argument that can be instantiated
# The difference here is that we expect a `String` naming the solver, so the
# solver package only needs to be installed where the solve runs: the server
# parses the wire form back with `JSON.parse(body, OptimizerWithAttributes)`
# and resolves the name with `MOI.OptimizerWithAttributes(solver)`.

# `@nonstruct` because `params` has an abstract element type that JSON could
# not reconstruct field-by-field: the wire form is instead defined by the
# `JSON.lower`/`JSON.lift` pair below. This internal spec supplies the
# solver id and its namespace in the platform's submit options.
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

const _NAMED_PARAMETERS = Dict{String,MOI.AbstractOptimizerAttribute}(
    "silent" => MOI.Silent(),
    "time_limit_seconds" => MOI.TimeLimitSec(),
    "threads" => MOI.NumberOfThreads(),
)

function _parameter(name::String)
    return get(_NAMED_PARAMETERS, name, MOI.RawOptimizerAttribute(name))
end

function JSON.lower(solver::OptimizerWithAttributes)
    return Dict(
        # The catalog names of the manager are lowercase
        "name" => solver_id(solver.optimizer),
        "parameters" =>
            Dict(_parameter_name(attr) => value for (attr, value) in solver.params),
    )
end

function JSON.lift(::Type{OptimizerWithAttributes}, x)
    return OptimizerWithAttributes(
        String(x["name"]),
        Pair{MOI.AbstractOptimizerAttribute,Any}[
            _parameter(String(name)) => value for (name, value) in x["parameters"]
        ],
    )
end

# Process solver ids and the Julia packages implementing them. Adding an
# engine also needs a platform descriptor and a solver image dependency.
const SOLVER_PACKAGES = Dict("highs-mof" => :HiGHS)

# The platform's `highs` reads an expression grammar. MOF needs its own
# descriptor so a JuMP model cannot be sent to that incompatible solver.
solver_id(name::String) = lowercase(name) == "highs" ? "highs-mof" : lowercase(name)

"""
    MOI.OptimizerWithAttributes(solver::OptimizerWithAttributes)

Resolve the solver name to the installed solver package and return the
equivalent `MOI.OptimizerWithAttributes`. Only usable where the package is
installed, i.e., on the server.
"""
function MOI.OptimizerWithAttributes(solver::OptimizerWithAttributes)
    package = Base.require(Main, SOLVER_PACKAGES[solver_id(solver.optimizer)])
    return MOI.OptimizerWithAttributes(getglobal(package, :Optimizer), solver.params)
end
