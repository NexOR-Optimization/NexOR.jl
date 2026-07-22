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
# `JSON.lower`/`JSON.lift` pair below, which keys parameters by their
# protocol name (`{"optimizer": "HiGHS", "params": {"silent": true}}`).
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
    params =
        Pair{MOI.AbstractOptimizerAttribute,Any}[MOI._to_param(arg) for arg in args]
    return OptimizerWithAttributes(optimizer, params)
end

function OptimizerWithAttributes(solver::MOI.OptimizerWithAttributes)
    return OptimizerWithAttributes(
        String(nameof(parentmodule(solver.optimizer_constructor))),
        solver.params,
    )
end

# Wire names of the non-raw optimizer attributes, as in the manager's catalog
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
        "optimizer" => solver.optimizer,
        "params" => Dict(
            _parameter_name(attr) => value for (attr, value) in solver.params
        ),
    )
end

function JSON.lift(::Type{OptimizerWithAttributes}, x)
    return OptimizerWithAttributes(
        String(x["optimizer"]),
        Pair{MOI.AbstractOptimizerAttribute,Any}[
            _parameter(String(name)) => value for (name, value) in x["params"]
        ],
    )
end

# The solver catalog of the server: wire name (case-insensitive) to the Julia
# package implementing it. Adding a solver is one entry here plus the package
# in server/Project.toml.
const SOLVER_PACKAGES = Dict("highs" => :HiGHS)

"""
    MOI.OptimizerWithAttributes(solver::OptimizerWithAttributes)

Resolve the solver name to the installed solver package and return the
equivalent `MOI.OptimizerWithAttributes`. Only usable where the package is
installed, i.e., on the server.
"""
function MOI.OptimizerWithAttributes(solver::OptimizerWithAttributes)
    package = Base.require(Main, SOLVER_PACKAGES[lowercase(solver.optimizer)])
    return MOI.OptimizerWithAttributes(getglobal(package, :Optimizer), solver.params)
end
