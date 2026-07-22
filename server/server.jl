#  Copyright (c) 2026: NexOR Optimization SRL
#
#  Use of this source code is governed by an MIT-style license that can be found
#  in the LICENSE.md file or at https://opensource.org/licenses/MIT.

# HTTP server implementing the customer-facing subset of the NexOR
# optimization API (the same /api/optimization/v1 surface as the Odoo
# manager's erk_manager_solve_api, so NexOR.Optimizer only changes its
# server_url/api_key when the manager takes over in v2).
#
# Each submitted problem gets a directory under NEXOR_DATA_DIR holding
# envelope.json / status.json / solution.json, and is solved by a spawned
# `julia server.jl <dir>` process (this same file, in its solver role) — or
# in-process when NEXOR_INLINE_SOLVER=1 (used by the NexOR.jl tests to avoid
# Julia startup per solve).

import HTTP
import JSON
import NexOR
import Random
import SHA

include("common.jl")

const API = "/api/optimization/v1"
const DATA_DIR = get(ENV, "NEXOR_DATA_DIR", joinpath(@__DIR__, "data"))
const API_TOKEN = get(ENV, "NEXOR_API_TOKEN", "")
const PORT = parse(Int, get(ENV, "NEXOR_PORT", "8752"))
const INLINE_SOLVER = get(ENV, "NEXOR_INLINE_SOLVER", "") == "1"
# Signs outbound webhook deliveries; like the Odoo manager, deliveries fail
# closed when no secret is configured: never send an unsigned payload.
const WEBHOOK_SECRET = get(ENV, "NEXOR_WEBHOOK_SECRET", "")

include("solver.jl")

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

# Terminal webhook delivery, mimicking the Odoo manager (webhook_delivery.py):
# POST {problem, event, status, cost, solution_url} to options.webhook.url,
# signed with X-Solve-Signature. Best effort, one shot (the manager's
# retry/backoff queue is out of scope for this test server); called by the
# serving process — delivery is the manager's job, never the worker's.
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
            "status" => solved ?
                        JSON.parsefile(joinpath(dir, "solution.json"))["status"] :
                        status["status"],
            "cost" => nothing, # no billing in v1
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

function spawn_solver(dir)
    log = joinpath(dir, "worker.log")
    command = `$(Base.julia_cmd()) --project=$(@__DIR__) $(@__FILE__) $dir`
    process = run(pipeline(command; stdout = log, stderr = log); wait = false)
    Threads.@spawn begin
        wait(process)
        status = read_status(dir)
        if status["status"] in ("queued", "running") # died without reporting
            # Carry the evidence to the client: exit code, kill signal (9
            # betrays the OOM killer) and the tail of the process output
            tail = isfile(log) ? last(read(log, String), 2_000) : ""
            write_status(
                dir,
                Dict(
                    "id" => status["id"],
                    "status" => "failed",
                    "error" => Dict(
                        "code" => "worker_crashed",
                        "message" =>
                            "Solver process exited (exitcode=$(process.exitcode), termsignal=$(process.termsignal)) without returning a solution.\n" *
                            tail,
                    ),
                ),
            )
        end
        deliver_webhook(dir)
    end
    return
end

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
    webhook = get(get(envelope, "options", Dict{String,Any}()), "webhook", nothing)
    if webhook !== nothing && !startswith(get(webhook, "url", ""), r"https?://")
        return error_response(422, "invalid_envelope", "webhook must have an http(s) url.")
    end
    solver = try
        JSON.parse(envelope["solver"], NexOR.OptimizerWithAttributes)
    catch
        return error_response(
            422,
            "invalid_envelope",
            "solver is not a JSON OptimizerWithAttributes.",
        )
    end
    if !haskey(NexOR.SOLVER_PACKAGES, lowercase(solver.optimizer))
        available = join(sort!(collect(keys(NexOR.SOLVER_PACKAGES))), "\", \"")
        return error_response(422, "unknown_solver", "Available solvers: \"$available\".")
    end
    id = "prb_" * Random.randstring("abcdefghijklmnopqrstuvwxyz0123456789", 16)
    dir = problem_dir(id)
    mkpath(dir)
    write_json(joinpath(dir, "envelope.json"), envelope)
    write_status(dir, Dict("id" => id, "status" => "queued", "error" => nothing))
    if INLINE_SOLVER
        Threads.@spawn begin
            try
                solve(dir)
            catch # solve() already recorded the failure in status.json
            end
            deliver_webhook(dir)
        end
    else
        spawn_solver(dir)
    end
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

const ROUTER = HTTP.Router()
HTTP.register!(ROUTER, "GET", "$API/health", _ -> json_response(Dict("status" => "ok")))
HTTP.register!(ROUTER, "POST", "$API/problems", submit)
HTTP.register!(ROUTER, "GET", "$API/problems/{id}", get_problem)
HTTP.register!(ROUTER, "GET", "$API/problems/{id}/solution", get_solution)

function handle(request)
    if request.target != "$API/health" &&
       !isempty(API_TOKEN) &&
       HTTP.header(request, "Authorization") != "Bearer $API_TOKEN"
        return error_response(401, "invalid_key", "Missing or invalid API key.")
    end
    return ROUTER(request)
end

function start(host = "0.0.0.0", port = PORT)
    mkpath(DATA_DIR)
    return HTTP.serve!(handle, host, port)
end

if abspath(PROGRAM_FILE) == @__FILE__
    if isempty(ARGS) # serve; with a problem directory argument, solve it
        wait(start())
    else
        solve(ARGS[1])
    end
end
