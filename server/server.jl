#  Copyright (c) 2026: NexOR Optimization SRL
#
#  Use of this source code is governed by an MIT-style license that can be found
#  in the LICENSE.md file or at https://opensource.org/licenses/MIT.

# Test mimic of the NexOR Odoo manager, for developing and testing this
# package against both of its APIs (nexor repo, dev-solve-v1-sc branch):
#
#   * the customer API, /api/optimization/v1 (erk_manager_solve_api):
#     submit returns immediately; the customer polls, or is called back on
#     an options.webhook. Used by NexOR.Optimizer.
#   * the worker API, /api/solve-worker/v1 (docs/worker-protocol.md):
#     workers register with the enrollment token, claim queued problems,
#     heartbeat and post results. Used by the kamal-solve worker.
#
# Like the real manager, this server never solves — except with
# NEXOR_INLINE_SOLVER=1 (the NexOR.jl tests), where submitted problems are
# solved in a task so the tests need no worker process. Simplifications
# versus the real manager are marked "mimic:" below.

import HTTP
import JSON
import NexOR
import Random
import SHA

include("common.jl")
include("solver.jl")

const API = "/api/optimization/v1"
const WORKER_API = "/api/solve-worker/v1"
const DATA_DIR = get(ENV, "NEXOR_DATA_DIR", joinpath(@__DIR__, "data"))
const API_TOKEN = get(ENV, "NEXOR_API_TOKEN", "")
const ENROLLMENT_TOKEN = get(ENV, "NEXOR_ENROLLMENT_TOKEN", "")
const PORT = parse(Int, get(ENV, "NEXOR_PORT", "8752"))
const INLINE_SOLVER = Ref(get(ENV, "NEXOR_INLINE_SOLVER", "") == "1")
const HEARTBEAT_INTERVAL = 30
# Signs outbound webhook deliveries; like the Odoo manager, deliveries fail
# closed when no secret is configured: never send an unsigned payload.
const WEBHOOK_SECRET = get(ENV, "NEXOR_WEBHOOK_SECRET", "")

# mimic: registered workers live in memory, `instance_key => info`, with the
# problem ids they hold; the real manager persists workers, tracks leases
# and re-queues on expiry.
const WORKERS = Dict{String,Dict{String,Any}}()

function json_response(payload; status = 200)
    return HTTP.Response(status, ["Content-Type" => "application/json"], JSON.json(payload))
end

function error_response(status, code, message)
    return json_response(
        Dict("error" => Dict("code" => code, "message" => message));
        status,
    )
end

problem_dir(id) = joinpath(DATA_DIR, id)

# Attempt references are derived from the problem reference — the mimic has
# exactly one live attempt per problem.
attempt_reference(id) = "att_" * chopprefix(id, "prb_")
attempt_problem(reference) = "prb_" * chopprefix(reference, "att_")

# Terminal webhook delivery, mimicking the Odoo manager (webhook_delivery.py):
# POST {problem, event, status, cost, solution_url} to options.webhook.url,
# signed with X-Solve-Signature. mimic: best effort, one shot — the real
# manager queues, retries with backoff and dead-letters.
function deliver_webhook(dir)
    envelope = JSON.parsefile(joinpath(dir, "envelope.json"))
    webhook = get(get(envelope, "options", Dict{String,Any}()), "webhook", nothing)
    webhook === nothing && return
    "terminal" in get(webhook, "events", ["terminal"]) || return
    isempty(WEBHOOK_SECRET) && return # fail closed: never send unsigned
    status = read_status(dir)
    id = status["id"]
    solved = isfile(joinpath(dir, "solution.json"))
    body = JSON.json(
        Dict(
            "problem" => id,
            "event" => "terminal",
            "status" =>
                solved ? JSON.parsefile(joinpath(dir, "solution.json"))["status"] :
                status["status"],
            "cost" => nothing, # no billing in the mimic
            "solution_url" => solved ? "$API/problems/$id/solution" : nothing,
        ),
    )
    signature = SHA.hmac_sha256(Vector{UInt8}(codeunits(WEBHOOK_SECRET)), body)
    response = HTTP.post(
        webhook["url"],
        [
            "Content-Type" => "application/json",
            "X-Solve-Event" => "terminal",
            "X-Solve-Signature" => "sha256=" * bytes2hex(signature),
        ],
        body;
        redirect = false,
        status_exception = false,
    )
    if response.status >= 300
        @warn "webhook delivery failed" id url = webhook["url"] response.status
    end
    return
end

# -- the customer API --------------------------------------------------------

function submit(request)
    envelope = try
        JSON.parse(String(request.body))
    catch
        return error_response(400, "invalid_json", "Body is not valid JSON.")
    end
    for key in ("api_version", "problem", "solver")
        if !haskey(envelope, key)
            return error_response(422, "invalid_envelope", "Missing field \"$key\".")
        end
    end
    if envelope["api_version"] != "1"
        return error_response(422, "invalid_envelope", "api_version must be \"1\".")
    end
    solver = envelope["solver"]
    if !(solver isa AbstractDict) || !haskey(solver, "name")
        return error_response(422, "invalid_envelope", "solver must be a SolverSpec.")
    end
    if !haskey(NexOR.SOLVER_PACKAGES, lowercase(solver["name"]))
        available = join(sort!(collect(keys(NexOR.SOLVER_PACKAGES))), "\", \"")
        return error_response(422, "unknown_solver", "Available solvers: \"$available\".")
    end
    webhook = get(get(envelope, "options", Dict{String,Any}()), "webhook", nothing)
    if webhook !== nothing && !startswith(get(webhook, "url", ""), r"https?://")
        return error_response(422, "invalid_envelope", "webhook must have an http(s) url.")
    end
    id = "prb_" * Random.randstring("abcdefghijklmnopqrstuvwxyz0123456789", 16)
    dir = problem_dir(id)
    mkpath(dir)
    write_json(joinpath(dir, "envelope.json"), envelope)
    write_status(dir, Dict("id" => id, "status" => "queued", "error" => nothing))
    if INLINE_SOLVER[]
        Threads.@spawn begin
            try
                solve(dir)
            catch # solve() already recorded the failure in status.json
            end
            deliver_webhook(dir)
        end
    end # else: the problem stays queued until a worker claims it
    return json_response(Dict("id" => id, "status" => "queued"); status = 201)
end

function get_problem(request)
    id = HTTP.getparams(request)["id"]
    dir = problem_dir(id)
    if !occursin(r"^prb_[0-9a-z]+$", id) || !isdir(dir)
        return error_response(404, "not_found", "No such problem.")
    end
    status = read_status(dir)
    status["solution_url"] =
        isfile(joinpath(dir, "solution.json")) ? "$API/problems/$id/solution" : nothing
    return json_response(status)
end

function get_solution(request)
    id = HTTP.getparams(request)["id"]
    path = joinpath(problem_dir(id), "solution.json")
    if !occursin(r"^prb_[0-9a-z]+$", id) || !isfile(path)
        return error_response(404, "not_found", "No solution for this problem.")
    end
    solution = JSON.parsefile(path)
    return json_response(
        Dict("id" => id, "status" => solution["status"], "solution" => solution),
    )
end

# -- the worker API (docs/worker-protocol.md) --------------------------------

function register(request)
    body = try
        JSON.parse(String(request.body))
    catch
        return error_response(400, "invalid_json", "Body is not valid JSON.")
    end
    for key in ("enrollment_token", "name", "instance_uid", "solvers")
        if !haskey(body, key)
            return error_response(400, "missing_field", "Missing field \"$key\".")
        end
    end
    if isempty(ENROLLMENT_TOKEN) || body["enrollment_token"] != ENROLLMENT_TOKEN
        return error_response(401, "invalid_enrollment_token", "Invalid enrollment token.")
    end
    # Re-registering an instance_uid reactivates it and issues a fresh key
    for (key, registered) in collect(WORKERS)
        if registered["instance_uid"] == body["instance_uid"]
            delete!(WORKERS, key)
        end
    end
    solvers = [s for s in body["solvers"] if haskey(NexOR.SOLVER_PACKAGES, lowercase(s))]
    key = "wk_" * Random.randstring("abcdefghijklmnopqrstuvwxyz0123456789", 32)
    WORKERS[key] = Dict{String,Any}(
        "instance_uid" => body["instance_uid"],
        "name" => body["name"],
        "solvers" => solvers,
        "slots" => get(body, "slots", 1),
        "attempts" => Set{String}(), # problem ids this worker holds
    )
    return json_response(
        Dict(
            "instance_key" => key,
            "worker_reference" => body["instance_uid"],
            "heartbeat_interval" => HEARTBEAT_INTERVAL,
            "solvers" => solvers,
        );
        status = 201,
    )
end

worker(request) = WORKERS[request.context[:worker_key]]

function claim(request)
    solvers = worker(request)["solvers"]
    queued = String[]
    for id in sort!(readdir(DATA_DIR))
        dir = problem_dir(id)
        isfile(joinpath(dir, "status.json")) || continue
        read_status(dir)["status"] == "queued" || continue
        envelope = JSON.parsefile(joinpath(dir, "envelope.json"))
        lowercase(envelope["solver"]["name"]) in solvers || continue
        push!(queued, id)
    end
    if isempty(queued)
        return json_response(Dict("attempt" => nothing, "more_available" => false))
    end
    id = first(queued)
    dir = problem_dir(id)
    write_status(dir, Dict("id" => id, "status" => "claimed", "error" => nothing))
    push!(worker(request)["attempts"], id)
    envelope = JSON.parsefile(joinpath(dir, "envelope.json"))
    parameters = get(envelope["solver"], "parameters", Dict{String,Any}())
    return json_response(
        Dict(
            "attempt" => Dict(
                "reference" => attempt_reference(id),
                "problem_reference" => id,
                "solver" => lowercase(envelope["solver"]["name"]),
                "machine_size" => "s", # mimic: a single machine size
                "effective_time_limit" => get(parameters, "time_limit_seconds", 300),
                "envelope" => envelope,
            ),
            "more_available" => length(queued) > 1,
        ),
    )
end

function heartbeat(request)
    # mimic: leases are not tracked, so heartbeats only echo the cadence and
    # never carry drain/stop orders or cancellations
    return json_response(
        Dict(
            "order" => nothing,
            "cancel" => String[],
            "heartbeat_interval" => HEARTBEAT_INTERVAL,
            "server_time" => string(time()),
        ),
    )
end

# The status vocabulary of the envelope is MOI's own
const _SOLUTION_STATUSES = string.(instances(NexOR.MOI.TerminationStatusCode))

function result(request)
    id = attempt_problem(HTTP.getparams(request)["reference"])
    dir = problem_dir(id)
    if !occursin(r"^prb_[0-9a-z]+$", id) || !isdir(dir)
        return error_response(404, "unknown_attempt", "No such attempt.")
    end
    if read_status(dir)["status"] != "claimed"
        # first result won already (or the attempt was reclaimed): safe to
        # retry, duplicates are dropped
        return json_response(Dict("accepted" => false))
    end
    if !(id in worker(request)["attempts"])
        return error_response(404, "unknown_attempt", "Not your attempt.")
    end
    body = try
        JSON.parse(String(request.body))
    catch
        return error_response(400, "invalid_json", "Body is not valid JSON.")
    end
    solution = get(body, "solution", nothing)
    if !(solution isa AbstractDict) ||
       get(solution, "api_version", nothing) != "1" ||
       !(get(solution, "status", nothing) in _SOLUTION_STATUSES) ||
       !(get(solution, "metering", nothing) isa AbstractDict)
        return error_response(422, "invalid_solution", "Not a Solution Envelope v1.")
    end
    write_json(joinpath(dir, "solution.json"), solution)
    write_status(dir, Dict("id" => id, "status" => "returned", "error" => nothing))
    delete!(worker(request)["attempts"], id)
    deliver_webhook(dir)
    return json_response(Dict("accepted" => true))
end

function fail(request)
    id = attempt_problem(HTTP.getparams(request)["reference"])
    dir = problem_dir(id)
    if !occursin(r"^prb_[0-9a-z]+$", id) ||
       !isdir(dir) ||
       !(id in worker(request)["attempts"])
        return error_response(404, "unknown_attempt", "No such attempt.")
    end
    body = try
        JSON.parse(String(request.body))
    catch
        return error_response(400, "invalid_json", "Body is not valid JSON.")
    end
    delete!(worker(request)["attempts"], id)
    if get(body, "problem_failure", false)
        # the model itself is broken: fail terminally, no retry
        write_status(
            dir,
            Dict(
                "id" => id,
                "status" => "failed",
                "error" => Dict(
                    "code" => get(body, "error_code", "worker_error"),
                    "message" => get(body, "error_message", ""),
                ),
            ),
        )
        deliver_webhook(dir)
    else # transient worker fault: re-queue (mimic: without a retry budget)
        write_status(dir, Dict("id" => id, "status" => "queued", "error" => nothing))
    end
    return json_response(Dict("ok" => true))
end

function goodbye(request)
    for id in worker(request)["attempts"] # release held work immediately
        write_status(
            problem_dir(id),
            Dict("id" => id, "status" => "queued", "error" => nothing),
        )
    end
    delete!(WORKERS, request.context[:worker_key])
    return json_response(Dict("ok" => true))
end

# -- routing and authentication ----------------------------------------------

const ROUTER = HTTP.Router()
HTTP.register!(ROUTER, "GET", "$API/health", _ -> json_response(Dict("status" => "ok")))
HTTP.register!(ROUTER, "POST", "$API/problems", submit)
HTTP.register!(ROUTER, "GET", "$API/problems/{id}", get_problem)
HTTP.register!(ROUTER, "GET", "$API/problems/{id}/solution", get_solution)
HTTP.register!(ROUTER, "POST", "$WORKER_API/register", register)
HTTP.register!(ROUTER, "POST", "$WORKER_API/claim", claim)
HTTP.register!(ROUTER, "POST", "$WORKER_API/heartbeat", heartbeat)
HTTP.register!(ROUTER, "POST", "$WORKER_API/attempts/{reference}/result", result)
HTTP.register!(ROUTER, "POST", "$WORKER_API/attempts/{reference}/fail", fail)
HTTP.register!(ROUTER, "POST", "$WORKER_API/goodbye", goodbye)

function handle(request)
    target = request.target
    if target == "$API/health" || target == "$WORKER_API/register"
        return ROUTER(request)
    end
    if startswith(target, WORKER_API) # worker calls carry the instance key
        key = chopprefix(HTTP.header(request, "Authorization"), "Bearer ")
        if !haskey(WORKERS, key)
            return error_response(401, "invalid_key", "Missing or invalid API key.")
        end
        request.context[:worker_key] = key
        return ROUTER(request)
    end
    if !isempty(API_TOKEN) && HTTP.header(request, "Authorization") != "Bearer $API_TOKEN"
        return error_response(401, "invalid_key", "Missing or invalid API key.")
    end
    return ROUTER(request)
end

function start(host = "0.0.0.0", port = PORT)
    mkpath(DATA_DIR)
    return HTTP.serve!(handle, host, port)
end

if abspath(PROGRAM_FILE) == @__FILE__
    wait(start())
end
