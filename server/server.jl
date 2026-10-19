#  Copyright (c) 2026: NexOR Optimization SRL
#
#  Use of this source code is governed by an MIT-style license that can be found
#  in the LICENSE.md file or at https://opensource.org/licenses/MIT.

# Minimal execution API mimic for NexOR.jl tests. Production dispatch and
# commercial policy belong to nexor-platform and Odoo.
import HTTP
import JSON
import HiGHS
import Random
import NexOR

include("common.jl")

const API = "/solve/v1"
const DATA_DIR = get(ENV, "NEXOR_DATA_DIR", joinpath(@__DIR__, "data"))
const API_TOKEN = get(ENV, "NEXOR_API_TOKEN", "")

json_response(body; status = 200) =
    HTTP.Response(status, ["Content-Type" => "application/json"], JSON.json(body))

error_response(status, code, message) =
    json_response(Dict("code" => code, "message" => message); status)

problem_dir(id) = joinpath(DATA_DIR, id)

function solve(dir)
    envelope = JSON.parsefile(joinpath(dir, "envelope.json"))
    id = envelope["solver"]
    options = get(get(envelope, "options", Dict()), "solver_options", Dict())
    solution = try
        NexOR.solve_problem(
            envelope["problem"],
            id,
            get(options, id, Dict());
            time_limit = get(get(envelope, "options", Dict()), "time_limit_seconds", Inf),
        )
    catch err
        if !(err isa NexOR.SolverInputError)
            write_status(
                dir,
                Dict(
                    "problem_id" => basename(dir),
                    "status" => "failed",
                    "error" => Dict(
                        "code" => "solver_crash",
                        "message" => sprint(showerror, err),
                    ),
                ),
            )
            return
        end
        NexOR.failure_solution(err)
    end
    write_json(
        joinpath(dir, "solution.json"),
        Dict(
            "schema" => "solution/1",
            "problem_type" => "opaque/1",
            "outcome" => solution["outcome"],
            "termination_status" => solution["termination_status"],
            "objective_value" => solution["objective_value"],
            "solution" => solution["body"],
            "solver_used" => id,
            "solver_version" => string(pkgversion(HiGHS)),
            "usage" => Dict("wall_seconds" => 0),
            "diagnostics" => solution["diagnostics"],
        ),
    )
    write_status(
        dir,
        Dict("problem_id" => basename(dir), "status" => "finished", "error" => nothing),
    )
    return
end

function submit(request)
    envelope = try
        JSON.parse(String(request.body))
    catch
        return error_response(400, "invalid_request", "Body is not valid JSON.")
    end
    if get(envelope, "api_version", nothing) != "1" || !haskey(envelope, "problem")
        return error_response(422, "invalid_envelope", "Expected api_version and problem.")
    end
    if get(envelope, "solver", nothing) != "highs-mof"
        return error_response(422, "solver_not_available", "Available solvers: highs-mof.")
    end
    id = "prb_" * Random.randstring("0123456789abcdef", 32)
    dir = problem_dir(id)
    mkpath(dir)
    status = Dict("problem_id" => id, "status" => "queued", "error" => nothing)
    write_json(joinpath(dir, "envelope.json"), envelope)
    write_status(dir, status)
    Threads.@spawn solve(dir)
    return json_response(status; status = 201)
end

function get_problem(request; wait_for_terminal = false)
    id = HTTP.getparams(request)["id"]
    if !occursin(r"^prb_[0-9a-f]{32}$", id) || !isdir(problem_dir(id))
        return error_response(404, "not_found", "No such problem.")
    end
    until = time() + (wait_for_terminal ? 60 : 0)
    status = read_status(problem_dir(id))
    while !(status["status"] in ("finished", "failed", "cancelled")) && time() < until
        sleep(0.01)
        status = read_status(problem_dir(id))
    end
    return json_response(status)
end

function get_result(request)
    id = HTTP.getparams(request)["id"]
    if !occursin(r"^prb_[0-9a-f]{32}$", id)
        return error_response(404, "not_found", "No such problem.")
    end
    path = joinpath(problem_dir(id), "solution.json")
    isfile(path) || return error_response(409, "result_not_available", "No result.")
    return json_response(JSON.parsefile(path))
end

const ROUTER = HTTP.Router()
HTTP.register!(ROUTER, "POST", "$API/problems", submit)
HTTP.register!(ROUTER, "GET", "$API/problems/{id}/status", get_problem)
HTTP.register!(
    ROUTER,
    "POST",
    "$API/problems/{id}/wait",
    request -> get_problem(request; wait_for_terminal = true),
)
HTTP.register!(ROUTER, "GET", "$API/problems/{id}/result", get_result)

function handle(request)
    if !isempty(API_TOKEN) && HTTP.header(request, "Authorization") != "Bearer $API_TOKEN"
        return error_response(401, "unauthorized", "Missing or invalid API key.")
    end
    return ROUTER(request)
end

start(host = "127.0.0.1", port = parse(Int, get(ENV, "NEXOR_PORT", "8752"))) =
    HTTP.serve!(handle, host, port)

if abspath(PROGRAM_FILE) == @__FILE__
    wait(start())
end
