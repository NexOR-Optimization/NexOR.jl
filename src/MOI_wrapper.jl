const MOF = MOI.FileFormats.MOF

# Customer-facing REST API prefix, shared with the Odoo manager
# (`erk_manager_solve_api`) so that switching from the direct kamal-nexor
# server (v1) to the authenticated manager (v2) is only a change of
# `server_url` and `api_key`.
const _API = "/api/optimization/v1"

const _TERMINAL_STATES = ("returned", "delivered", "failed", "cancelled")

"""
    Optimizer()

An `MOI.AbstractOptimizer` that sends the problem to a remote NexOR server
at `MOI.optimize!` and caches the returned solution so that all solution
queries are answered locally.

The model is stored in a `MOI.FileFormats.MOF.Model` filled through
`MOI.copy_to`; the incremental interface is not supported.

## Attributes

  * `"server_url"`: base URL of the server, defaults to
    `ENV["NEXOR_SERVER_URL"]` and `https://solve.nexoropt.com`.
  * `"api_key"`: bearer token, defaults to `ENV["NEXOR_API_KEY"]`.
  * `"solver"`: the remote solver, by name, e.g., `"HiGHS"` — the solver
    package only needs to be installed on the server, not locally. To tune
    solver parameters, an `MOI.OptimizerWithAttributes` (or a bare optimizer
    constructor) is also accepted, e.g.,
    `MOI.OptimizerWithAttributes(HiGHS.Optimizer, "presolve" => "on")`.
"""
mutable struct Optimizer <: MOI.AbstractOptimizer
    model::MOF.Model{Float64}
    server_url::String
    api_key::String
    solver::Union{Nothing,String,MOI.OptimizerWithAttributes}
    silent::Bool
    time_limit_sec::Union{Nothing,Float64}
    problem_id::Union{Nothing,String}
    summary::Any # `JuMP._SolutionSummary` of the remote solve, as a JSON dict
    primal::Vector{Float64}
end

function Optimizer()
    return Optimizer(
        MOF.Model(),
        get(ENV, "NEXOR_SERVER_URL", "https://solve.nexoropt.com"),
        get(ENV, "NEXOR_API_KEY", ""),
        nothing,
        false,
        nothing,
        nothing,
        nothing,
        Float64[],
    )
end

function MOI.is_empty(model::Optimizer)
    return MOI.is_empty(model.model) && model.summary === nothing
end

function MOI.empty!(model::Optimizer)
    MOI.empty!(model.model)
    model.problem_id = nothing
    model.summary = nothing
    empty!(model.primal)
    return
end

# The model interface: forward to the inner MOF model

function MOI.supports_constraint(
    model::Optimizer,
    F::Type{<:MOI.AbstractFunction},
    S::Type{<:MOI.AbstractSet},
)
    return MOI.supports_constraint(model.model, F, S)
end

function MOI.supports_add_constrained_variable(
    model::Optimizer,
    S::Type{<:MOI.AbstractScalarSet},
)
    return MOI.supports_add_constrained_variable(model.model, S)
end

function MOI.supports_add_constrained_variables(
    model::Optimizer,
    S::Type{<:MOI.AbstractVectorSet},
)
    return MOI.supports_add_constrained_variables(model.model, S)
end

# Resolve the ambiguity with the generic `(::MOI.ModelLike, ::Type{MOI.Reals})`
function MOI.supports_add_constrained_variables(model::Optimizer, S::Type{MOI.Reals})
    return MOI.supports_add_constrained_variables(model.model, S)
end

function MOI.supports(model::Optimizer, attr::MOI.AbstractModelAttribute)
    return MOI.supports(model.model, attr)
end

function MOI.supports(
    model::Optimizer,
    attr::MOI.AbstractVariableAttribute,
    ::Type{MOI.VariableIndex},
)
    return MOI.supports(model.model, attr, MOI.VariableIndex)
end

function MOI.supports(
    model::Optimizer,
    attr::MOI.AbstractConstraintAttribute,
    C::Type{<:MOI.ConstraintIndex},
)
    return MOI.supports(model.model, attr, C)
end

function MOI.get(model::Optimizer, attr::MOI.AbstractModelAttribute)
    return MOI.get(model.model, attr)
end

function MOI.get(
    model::Optimizer,
    attr::MOI.AbstractVariableAttribute,
    vi::MOI.VariableIndex,
)
    return MOI.get(model.model, attr, vi)
end

function MOI.get(
    model::Optimizer,
    attr::MOI.AbstractConstraintAttribute,
    ci::MOI.ConstraintIndex,
)
    return MOI.get(model.model, attr, ci)
end

function MOI.copy_to(dest::Optimizer, src::MOI.ModelLike)
    return MOI.copy_to(dest.model, src)
end

# Optimizer attributes

MOI.supports(::Optimizer, ::MOI.Silent) = true

MOI.get(model::Optimizer, ::MOI.Silent) = model.silent

function MOI.set(model::Optimizer, ::MOI.Silent, value::Bool)
    model.silent = value
    return
end

MOI.supports(::Optimizer, ::MOI.TimeLimitSec) = true

MOI.get(model::Optimizer, ::MOI.TimeLimitSec) = model.time_limit_sec

function MOI.set(model::Optimizer, ::MOI.TimeLimitSec, value::Union{Nothing,Real})
    model.time_limit_sec = value === nothing ? nothing : Float64(value)
    return
end

const _RAW_FIELDS =
    Dict("solver" => :solver, "server_url" => :server_url, "api_key" => :api_key)

function _raw_field(attr::MOI.RawOptimizerAttribute)
    field = get(_RAW_FIELDS, attr.name, nothing)
    if field === nothing
        throw(
            MOI.UnsupportedAttribute(
                attr,
                "NexOR.Optimizer only supports the raw attributes " *
                join(["\"$name\"" for name in sort!(collect(keys(_RAW_FIELDS)))], ", ") *
                ".",
            ),
        )
    end
    return field
end

function MOI.supports(::Optimizer, attr::MOI.RawOptimizerAttribute)
    return haskey(_RAW_FIELDS, attr.name)
end

function MOI.get(model::Optimizer, attr::MOI.RawOptimizerAttribute)
    return getfield(model, _raw_field(attr))
end

function MOI.set(model::Optimizer, attr::MOI.RawOptimizerAttribute, value)
    if attr.name == "solver"
        if value isa AbstractString
            value = String(value)
        end
    end
    setfield!(model, _raw_field(attr), value)
    return
end

# The solve: serialize, submit, poll, fetch and cache

# The wire name is lowercase, matching the manager's solver catalog.
_solver_name(solver::String) = lowercase(solver)

function _solver_name(solver::MOI.OptimizerWithAttributes)
    return lowercase(String(nameof(parentmodule(solver.optimizer_constructor))))
end

_parameter_name(attr::MOI.RawOptimizerAttribute) = attr.name
_parameter_name(::MOI.Silent) = "silent"
_parameter_name(::MOI.TimeLimitSec) = "time_limit_seconds"
_parameter_name(::MOI.NumberOfThreads) = "threads"

_solver_parameters(::String) = Dict{String,Any}()

function _solver_parameters(solver::MOI.OptimizerWithAttributes)
    return Dict{String,Any}(
        _parameter_name(attr) => value for (attr, value) in solver.params
    )
end

function _solver_spec(model::Optimizer)
    parameters = _solver_parameters(model.solver)
    if model.silent
        parameters["silent"] = true
    end
    if model.time_limit_sec !== nothing && !haskey(parameters, "time_limit_seconds")
        parameters["time_limit_seconds"] = model.time_limit_sec
    end
    return Dict{String,Any}("name" => _solver_name(model.solver), "parameters" => parameters)
end

function _problem(model::Optimizer)
    io = IOBuffer()
    write(io, model.model)
    return JSON.parse(String(take!(io)))
end

function MOI.optimize!(model::Optimizer)
    if model.solver === nothing
        error(
            "The remote solver is not set. Set it by name with " *
            "`set_attribute(model, \"solver\", \"HiGHS\")`, or, to tune its " *
            "parameters, with " *
            "`set_attribute(model, \"solver\", optimizer_with_attributes(HiGHS.Optimizer, ...))`.",
        )
    end
    envelope = Dict{String,Any}(
        "api_version" => "1",
        "problem" => _problem(model),
        "solver" => _solver_spec(model),
    )
    problem = _request(model, "POST", "/problems"; body = JSON.json(envelope))
    model.problem_id = problem["id"]
    while !(problem["status"] in _TERMINAL_STATES)
        sleep(0.1)
        problem = _request(model, "GET", "/problems/$(model.problem_id)")
    end
    if problem["status"] == "failed" || problem["status"] == "cancelled"
        err = problem["error"]
        model.summary = Dict{String,Any}(
            "termination_status" => "OTHER_ERROR",
            "primal_status" => "NO_SOLUTION",
            "dual_status" => "NO_SOLUTION",
            "result_count" => 0,
            "raw_status" => err === nothing ? problem["status"] :
                            "$(err["code"]): $(err["message"])",
        )
        return
    end
    delivery = _request(model, "GET", "/problems/$(model.problem_id)/solution")
    solution = delivery["solution"] # the Solution Envelope v1
    model.summary = solution["solution"]["summary"]
    primal = solution["solution"]["primal"]
    model.primal = primal === nothing ? Float64[] : Float64.(primal)
    if !model.silent && solution["log"] isa String
        print(solution["log"])
    end
    return
end

# Solution attributes: served from the cached summary, never from the server

function MOI.get(model::Optimizer, ::MOI.SolverName)
    if model.summary === nothing
        return "NexOR"
    end
    return "NexOR($(model.summary["solver"]))"
end

function _summary(model::Optimizer)
    if model.summary === nothing
        throw(MOI.OptimizeNotCalled())
    end
    return model.summary
end

function _field(model::Optimizer, attr::MOI.AnyAttribute, key::String)
    value = get(_summary(model), key, nothing)
    if value === nothing
        throw(MOI.GetAttributeNotAllowed(attr, "not provided by the remote solver"))
    end
    return value
end

function _status(::Type{E}, name::String) where {E}
    return instances(E)[findfirst(x -> string(x) == name, instances(E))]
end

_scalar(value::Real) = Float64(value)
_scalar(value::Vector) = Float64.(value)

function MOI.get(model::Optimizer, ::MOI.TerminationStatus)
    if model.summary === nothing
        return MOI.OPTIMIZE_NOT_CALLED
    end
    return _status(MOI.TerminationStatusCode, model.summary["termination_status"])
end

function MOI.get(model::Optimizer, attr::MOI.PrimalStatus)
    if model.summary === nothing || attr.result_index != 1
        return MOI.NO_SOLUTION
    end
    return _status(MOI.ResultStatusCode, model.summary["primal_status"])
end

function MOI.get(model::Optimizer, attr::MOI.DualStatus)
    if model.summary === nothing || attr.result_index != 1
        return MOI.NO_SOLUTION
    end
    return _status(MOI.ResultStatusCode, model.summary["dual_status"])
end

function MOI.get(model::Optimizer, ::MOI.ResultCount)
    return model.summary === nothing ? 0 : Int(model.summary["result_count"])
end

function MOI.get(model::Optimizer, ::MOI.RawStatusString)
    return _summary(model)["raw_status"]::String
end

function MOI.get(model::Optimizer, attr::MOI.ObjectiveValue)
    MOI.check_result_index_bounds(model, attr)
    return _scalar(_field(model, attr, "objective_value"))
end

function MOI.get(model::Optimizer, attr::MOI.ObjectiveBound)
    return _scalar(_field(model, attr, "objective_bound"))
end

function MOI.get(model::Optimizer, attr::MOI.RelativeGap)
    return Float64(_field(model, attr, "relative_gap"))
end

function MOI.get(model::Optimizer, attr::MOI.DualObjectiveValue)
    MOI.check_result_index_bounds(model, attr)
    return Float64(_field(model, attr, "dual_objective_value"))
end

function MOI.get(model::Optimizer, attr::MOI.SolveTimeSec)
    return Float64(_field(model, attr, "solve_time"))
end

function MOI.get(model::Optimizer, attr::MOI.BarrierIterations)
    return Int(_field(model, attr, "barrier_iterations"))
end

function MOI.get(model::Optimizer, attr::MOI.SimplexIterations)
    return Int(_field(model, attr, "simplex_iterations"))
end

function MOI.get(model::Optimizer, attr::MOI.NodeCount)
    return Int(_field(model, attr, "node_count"))
end

function MOI.get(model::Optimizer, attr::MOI.VariablePrimal, vi::MOI.VariableIndex)
    MOI.check_result_index_bounds(model, attr)
    if isempty(model.primal) # the result has no primal, e.g., a dual certificate
        throw(MOI.ResultIndexBoundsError(attr, 0))
    end
    return model.primal[vi.value]
end
