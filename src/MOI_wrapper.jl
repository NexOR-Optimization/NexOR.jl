const MOF = MOI.FileFormats.MOF

# The execution platform owns this API; Odoo owns admission and billing.
const _API = "/solve/v1"
const _TERMINAL_STATES = ("finished", "failed", "cancelled")

"""
    Optimizer()

An `MOI.AbstractOptimizer` that sends the problem to a remote NexOR server
at `MOI.optimize!` and caches the returned solution so that all solution
queries are answered locally.

The model is stored in a `MOI.Utilities.MockOptimizer` wrapping a
`MOI.FileFormats.MOF.Model`. It supports both incremental construction and
`MOI.copy_to`. The solution received from the server is loaded into the mock,
which then answers every solution query locally.

## Attributes

  * `"server_url"`: public API base URL, defaults to
    `ENV["NEXOR_SERVER_URL"]` and `https://api.nexoropt.com`. Execution and
    account requests use this same API, independently of where its services run.
  * `"api_key"`: bearer token, defaults to `ENV["NEXOR_API_KEY"]`.
  * `"solver"`: the remote solver, by name, e.g., `"HiGHS"` — the solver
    package only needs to be installed on the server, not locally. To tune
    solver parameters, an `OptimizerWithAttributes` is also accepted, e.g.,
    `NexOR.OptimizerWithAttributes("HiGHS", "presolve" => "on")`; its
    attributes are merged into the ones already set.

Every other optimizer attribute (`MOI.Silent`, `MOI.TimeLimitSec`, raw
attributes, ...) is stored in the solver spec and applied by the remote
solver.
"""
mutable struct Optimizer <: MOI.AbstractOptimizer
    model::MOI.Utilities.MockOptimizer{MOF.Model{Float64},Float64}
    server_url::String
    api_key::String
    solver::OptimizerWithAttributes
    problem_id::Union{Nothing,String}
    # `MockOptimizer` cannot store it (yet) and `JuMP.solution_summary`
    # requires it unconditionally
    raw_status::String
end

function Optimizer()
    model = Optimizer(
        # The mock serves the stored solution instead of evaluating it
        MOI.Utilities.MockOptimizer(
            MOF.Model();
            eval_objective_value = false,
            eval_dual_objective_value = false,
        ),
        get(ENV, "NEXOR_SERVER_URL", "https://api.nexoropt.com"),
        get(ENV, "NEXOR_API_KEY", ""),
        OptimizerWithAttributes("undef"),
        nothing,
        "optimize not called",
    )
    MOI.set(model.model, MOI.ResultCount(), 0)
    return model
end

MOI.is_empty(model::Optimizer) = MOI.is_empty(model.model)

function MOI.empty!(model::Optimizer)
    MOI.empty!(model.model)
    MOI.set(model.model, MOI.ResultCount(), 0)
    model.problem_id = nothing
    model.raw_status = "optimize not called"
    return
end

# The model interface: forward to the inner MOF model

function MOI.supports_incremental_interface(model::Optimizer)
    return MOI.supports_incremental_interface(model.model)
end

function _invalidate_solution!(model::Optimizer)
    if model.problem_id !== nothing
        model.problem_id = nothing
        _failed!(model, MOI.OPTIMIZE_NOT_CALLED, "optimize not called")
    end
    return
end

function MOI.add_variable(model::Optimizer)
    index = MOI.add_variable(model.model)
    _invalidate_solution!(model)
    return index
end

function MOI.add_constraint(
    model::Optimizer,
    func::MOI.AbstractFunction,
    set::MOI.AbstractSet,
)
    index = MOI.add_constraint(model.model, func, set)
    _invalidate_solution!(model)
    return index
end

MOI.is_valid(model::Optimizer, index::MOI.Index) = MOI.is_valid(model.model, index)

function MOI.delete(model::Optimizer, index::MOI.Index)
    MOI.delete(model.model, index)
    _invalidate_solution!(model)
    return
end

function MOI.modify(
    model::Optimizer,
    index::MOI.ConstraintIndex,
    change::MOI.AbstractFunctionModification,
)
    MOI.modify(model.model, index, change)
    _invalidate_solution!(model)
    return
end

function MOI.modify(
    model::Optimizer,
    attr::MOI.ObjectiveFunction,
    change::MOI.AbstractFunctionModification,
)
    MOI.modify(model.model, attr, change)
    _invalidate_solution!(model)
    return
end

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

function MOI.get(model::Optimizer, type::Type{<:MOI.Index}, name::String)
    return MOI.get(model.model, type, name)
end

function MOI.set(model::Optimizer, attr::MOI.AbstractModelAttribute, value)
    MOI.set(model.model, attr, value)
    _invalidate_solution!(model)
    return
end

function MOI.set(
    model::Optimizer,
    attr::MOI.AbstractVariableAttribute,
    index::MOI.VariableIndex,
    value,
)
    MOI.set(model.model, attr, index, value)
    _invalidate_solution!(model)
    return
end

function MOI.set(
    model::Optimizer,
    attr::MOI.AbstractConstraintAttribute,
    index::MOI.ConstraintIndex,
    value,
)
    MOI.set(model.model, attr, index, value)
    _invalidate_solution!(model)
    return
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
    MOI.empty!(dest)
    return MOI.copy_to(dest.model, src)
end

# Optimizer attributes: except "solver", "server_url" and "api_key", they are
# all stored in the solver spec `model.solver` and applied remotely.

function _find(solver::OptimizerWithAttributes, attr::MOI.AbstractOptimizerAttribute)
    return findfirst(param -> param.first == attr, solver.params)
end

function _set!(solver::OptimizerWithAttributes, attr::MOI.AbstractOptimizerAttribute, value)
    index = _find(solver, attr)
    if index === nothing
        push!(solver.params, attr => value)
    else
        solver.params[index] = attr => value
    end
    return
end

# Any optimizer attribute can be set: it goes to the solver spec. `supports`
# and `get` are only claimed for the usual tunables though: answering `true`
# for everything would also claim attributes like
# `MOI.Bridges.ListOfNonstandardBridges` that MOI itself queries and expects
# from its own fallbacks.
function MOI.set(model::Optimizer, attr::MOI.AbstractOptimizerAttribute, value)
    _set!(model.solver, attr, value)
    return
end

const _TUNABLES = Union{MOI.Silent,MOI.TimeLimitSec,MOI.NumberOfThreads}

MOI.supports(::Optimizer, ::_TUNABLES) = true

MOI.supports(::Optimizer, ::MOI.RawOptimizerAttribute) = true

_default(::MOI.Silent) = false # `false` and `nothing` when unset, as documented
_default(::MOI.AbstractOptimizerAttribute) = nothing

function MOI.get(model::Optimizer, attr::_TUNABLES)
    index = _find(model.solver, attr)
    return index === nothing ? _default(attr) : model.solver.params[index].second
end

function MOI.set(model::Optimizer, attr::MOI.TimeLimitSec, value::Union{Nothing,Real})
    if value === nothing # unset, as documented by `MOI.TimeLimitSec`
        index = _find(model.solver, attr)
        index === nothing || deleteat!(model.solver.params, index)
    else
        _set!(model.solver, attr, Float64(value))
    end
    return
end

function MOI.get(model::Optimizer, attr::MOI.RawOptimizerAttribute)
    if attr.name == "solver"
        return model.solver
    elseif attr.name == "server_url" || attr.name == "api_key"
        return getfield(model, Symbol(attr.name))
    end
    index = _find(model.solver, attr)
    if index === nothing
        throw(MOI.GetAttributeNotAllowed(attr, "the attribute is not set"))
    end
    return model.solver.params[index].second
end

function MOI.set(model::Optimizer, attr::MOI.RawOptimizerAttribute, value)
    if attr.name == "solver"
        if value isa AbstractString
            value = OptimizerWithAttributes(String(value))
        elseif value isa MOI.OptimizerWithAttributes
            value = OptimizerWithAttributes(value)
        end
        # Take the new solver name but merge its attributes into the ones
        # already set on this optimizer
        solver = OptimizerWithAttributes(value.optimizer, copy(model.solver.params))
        for (param, param_value) in value.params
            _set!(solver, param, param_value)
        end
        model.solver = solver
    elseif attr.name == "server_url" || attr.name == "api_key"
        setfield!(model, Symbol(attr.name), String(value))
    else
        _set!(model.solver, attr, value)
    end
    return
end

# The solve: serialize, submit, poll, fetch and cache

function _problem(model::Optimizer)
    io = IOBuffer()
    write(io, model.model.inner_model)
    return JSON.parse(String(take!(io)))
end

function MOI.optimize!(model::Optimizer)
    if model.solver.optimizer == "undef"
        error(
            "The remote solver is not set. Set it by name with " *
            "`set_attribute(model, \"solver\", \"HiGHS\")`, or, to tune its " *
            "parameters, with " *
            "`set_attribute(model, \"solver\", NexOR.OptimizerWithAttributes(\"HiGHS\", ...))`.",
        )
    end
    return _optimize!(model, _request)
end

function _submission(model::Optimizer)
    spec = JSON.lower(model.solver)
    options = Dict{String,Any}("solver_options" => Dict(spec["name"] => spec["parameters"]))
    limit = get(spec["parameters"], "time_limit_seconds", nothing)
    if limit !== nothing
        options["time_limit_seconds"] = max(1, ceil(Int, limit))
    end
    # The platform streams everything after this final member to storage.
    return JSON.json((;
        api_version = "1",
        problem_type = "opaque/1",
        solver = spec["name"],
        options,
        problem = _problem(model),
    ))
end

function _failed!(model::Optimizer, status::MOI.TerminationStatusCode, message)
    MOI.set(model.model, MOI.TerminationStatus(), status)
    MOI.set(model.model, MOI.ResultCount(), 0)
    MOI.set(model.model, MOI.PrimalStatus(), MOI.NO_SOLUTION)
    MOI.set(model.model, MOI.DualStatus(), MOI.NO_SOLUTION)
    model.raw_status = message
    return
end

function _optimize!(model::Optimizer, request)
    _failed!(model, MOI.OPTIMIZE_NOT_CALLED, "optimize not called")
    problem = request(model, "POST", "/problems"; body = _submission(model))
    model.problem_id = problem["problem_id"]
    while !(problem["status"] in _TERMINAL_STATES)
        problem =
            request(model, "POST", "/problems/$(model.problem_id)/wait?timeout_seconds=60")
    end
    if problem["status"] != "finished"
        err = problem["error"]
        message = err === nothing ? problem["status"] : "$(err["code"]): $(err["message"])"
        _failed!(model, MOI.OTHER_ERROR, message)
        return
    end
    result = request(model, "GET", "/problems/$(model.problem_id)/result?inline=1")
    solution = result["solution"]
    # Runner refusals can have no MOI body (for example, invalid options).
    if !haskey(solution, "attributes")
        status = result["termination_status"]
        code =
            status == "INVALID_PROBLEM" ? MOI.INVALID_MODEL :
            get(
                Dict(string(s) => s for s in instances(MOI.TerminationStatusCode)),
                status,
                MOI.OTHER_ERROR,
            )
        warnings = get(get(result, "diagnostics", Dict()), "warnings", [])
        message = join([w["message"] for w in warnings], "; ")
        _failed!(model, code, isempty(message) ? status : "$status: $message")
        return
    end
    load_solution!(model.model, solution)
    model.raw_status = get(solution["attributes"], "raw_status", "")
    log = get(solution, "log", nothing)
    if !MOI.get(model, MOI.Silent()) && log isa String
        print(log)
    end
    return
end

# Solution attributes: every query is answered by the mock through the
# generic forwards above; only the two attributes the mock cannot answer are
# implemented here.

MOI.get(model::Optimizer, ::MOI.SolverName) = "NexOR($(model.solver.optimizer))"

MOI.get(model::Optimizer, ::MOI.RawStatusString) = model.raw_status
