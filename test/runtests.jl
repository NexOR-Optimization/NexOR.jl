#  Copyright (c) 2026: NexOR Optimization SRL
#
#  Use of this source code is governed by an MIT-style license that can be found
#  in the LICENSE.md file or at https://opensource.org/licenses/MIT.

# The tests run the real solve server (../server, deployed by kamal-solve)
# in-process: NEXOR_INLINE_SOLVER makes it solve in a task (with the solver
# deps of this test environment) instead of spawning a fresh Julia per problem.
ENV["NEXOR_INLINE_SOLVER"] = "1"
ENV["NEXOR_DATA_DIR"] = mktempdir()
ENV["NEXOR_API_TOKEN"] = "test-token"
ENV["NEXOR_API_KEY"] = "test-token"
ENV["NEXOR_SERVER_URL"] = "http://127.0.0.1:8752"
ENV["NEXOR_WEBHOOK_SECRET"] = "hook-secret"
ENV["NEXOR_ENROLLMENT_TOKEN"] = "enroll-token"

import HiGHS
import HTTP
import JSON
import SHA
using JuMP
import NexOR
using Test

include(joinpath(dirname(@__DIR__), "server", "server.jl"))
isdefined(@__MODULE__, :SERVER) && close(SERVER) # allow re-include in a REPL
const SERVER = start("127.0.0.1", 8752)

const URL = ENV["NEXOR_SERVER_URL"] * "/api/optimization/v1"
const HEADERS =
    ["Content-Type" => "application/json", "Authorization" => "Bearer test-token"]

function highs_model()
    model = JuMP.Model(NexOR.Optimizer)
    # By name: the solver package is only needed on the server
    JuMP.set_attribute(model, "solver", "HiGHS")
    JuMP.set_silent(model)
    return model
end

function lp()
    model = Model()
    @variable(model, 0 <= x <= 4)
    @variable(model, 0 <= y <= 3)
    @constraint(model, x + y <= 5)
    @objective(model, Max, 2x + y)
    return model
end

@testset "lp" begin
    model = lp()
    set_optimizer(model, NexOR.Optimizer)
    set_silent(model)
    set_attribute(
        model,
        "solver",
        NexOR.OptimizerWithAttributes("HiGHS", "presolve" => "on"),
    )
    set_time_limit_sec(model, 10.0)
    optimize!(model)
    @test termination_status(model) == JuMP.MOI.OPTIMAL
    @test primal_status(model) == JuMP.MOI.FEASIBLE_POINT
    @test result_count(model) == 1
    @test objective_value(model) ≈ 9.0
    @test value(model[:x]) ≈ 4.0
    @test value(model[:y]) ≈ 1.0
    @test solver_name(model) == "NexOR(HiGHS)"
    # What reached the server: the solver spec of the submit envelope
    nexor = unsafe_backend(model)
    envelope =
        JSON.parsefile(joinpath(ENV["NEXOR_DATA_DIR"], nexor.problem_id, "envelope.json"))
    spec = envelope["solver"] # the SolverSpec of the manager's envelope
    @test spec["name"] == "highs"
    @test spec["parameters"]["presolve"] == "on"
    @test spec["parameters"]["silent"] == true
    @test spec["parameters"]["time_limit_seconds"] == 10.0
    # and it round-trips into the type the solve builds its optimizer from
    solver = JSON.parse(JSON.json(spec), NexOR.OptimizerWithAttributes)
    @test solver.optimizer == "highs"
    @test (JuMP.MOI.Silent() => true) in solver.params
    @test (JuMP.MOI.TimeLimitSec() => 10.0) in solver.params
    @test (JuMP.MOI.RawOptimizerAttribute("presolve") => "on") in solver.params
end

function milp()
    model = Model()
    @variable(model, x >= 2.5, Int)
    @objective(model, Min, x)
    return model
end

@testset "milp" begin
    model = milp()
    set_optimizer(model, NexOR.Optimizer)
    set_attribute(model, "solver", "highs")
    JuMP.optimize!(model)
    @test JuMP.termination_status(model) == JuMP.MOI.OPTIMAL
    @test JuMP.objective_value(model) ≈ 3.0
    @test JuMP.value(model[:x]) ≈ 3.0
end

@testset "resolve" begin
    model = highs_model()
    JuMP.@variable(model, 0 <= x <= 2)
    JuMP.@objective(model, Max, x)
    JuMP.optimize!(model)
    @test JuMP.value(x) ≈ 2.0
    JuMP.set_upper_bound(x, 3)
    JuMP.optimize!(model)
    @test JuMP.value(x) ≈ 3.0
end

@testset "infeasible" begin
    model = highs_model()
    JuMP.@variable(model, x <= 1)
    JuMP.@constraint(model, x >= 2)
    JuMP.optimize!(model)
    @test JuMP.termination_status(model) == JuMP.MOI.INFEASIBLE
    @test JuMP.primal_status(model) == JuMP.MOI.NO_SOLUTION
    @test !JuMP.has_values(model)
end

@testset "unbounded" begin
    model = highs_model()
    JuMP.@variable(model, x >= 0)
    JuMP.@objective(model, Max, x)
    JuMP.optimize!(model)
    @test JuMP.termination_status(model) == JuMP.MOI.DUAL_INFEASIBLE
end

@testset "unknown solver" begin
    model = Model(NexOR.Optimizer)
    set_attribute(model, "solver", "Dummy")
    @variable(model, x)
    err = ErrorException(
        "NexOR server returned 422 unknown_solver: Available solvers: \"highs\".",
    )
    @test_throws err JuMP.optimize!(model)
end

@testset "solver name and failed solve" begin
    model = Model(NexOR.Optimizer)
    @test solver_name(model) == "NexOR(undef)"
    # An option HiGHS rejects: the worker fails after the problem is accepted
    set_attribute(
        model,
        "solver",
        NexOR.OptimizerWithAttributes("HiGHS", "not_a_highs_option" => 1),
    )
    @test solver_name(model) == "NexOR(HiGHS)" # known before any solve
    @variable(model, x)
    optimize!(model)
    @test termination_status(model) == JuMP.MOI.OTHER_ERROR
    @test startswith(raw_status(model), "worker_error")
    # The summary of a failed solve carries no solver entry: the name must
    # come from the solver spec, not from the summary
    @test solver_name(model) == "NexOR(HiGHS)"
end

@testset "attributes" begin
    model = JuMP.Model(NexOR.Optimizer)
    @test JuMP.get_attribute(model, "server_url") == ENV["NEXOR_SERVER_URL"]
    @test JuMP.get_attribute(model, "api_key") == "test-token"
    JuMP.set_attribute(model, "api_key", "wrong")
    JuMP.set_attribute(model, "solver", "HiGHS")
    JuMP.@variable(model, x)
    err =
        ErrorException("NexOR server returned 401 invalid_key: Missing or invalid API key.")
    @test_throws err JuMP.optimize!(model)
end

@testset "server protocol" begin
    @test HTTP.get("$URL/health").status == 200 # no token needed
    response = HTTP.get(
        "$URL/problems/prb_x",
        ["Authorization" => "Bearer wrong"];
        status_exception = false,
    )
    @test response.status == 401
    @test HTTP.post("$URL/problems", HEADERS, "{"; status_exception = false).status == 400
    response = HTTP.post(
        "$URL/problems",
        HEADERS,
        JSON.json(Dict("api_version" => "1"));
        status_exception = false,
    )
    @test response.status == 422
    @test HTTP.get("$URL/problems/prb_missing", HEADERS; status_exception = false).status ==
          404
    # A structurally broken problem must end in a terminal failure, not hang
    envelope = Dict(
        "api_version" => "1",
        "problem" => Dict("garbage" => true),
        "solver" => NexOR.OptimizerWithAttributes("HiGHS"),
    )
    response = HTTP.post("$URL/problems", HEADERS, JSON.json(envelope))
    @test response.status == 201
    id = JSON.parse(String(response.body))["id"]
    problem = nothing
    for _ = 1:100
        problem = JSON.parse(String(HTTP.get("$URL/problems/$id", HEADERS).body))
        problem["status"] == "failed" && break
        sleep(0.1)
    end
    @test problem["status"] == "failed"
    @test problem["error"]["code"] == "worker_error"
end

@testset "worker protocol" begin
    INLINE_SOLVER[] = false # let problems queue so a worker can claim them
    problem = JSON.parse(
        """{"version":{"major":1,"minor":7},"variables":[{"name":"x"}],
            "objective":{"sense":"max","function":{"type":"Variable","name":"x"}},
            "constraints":[{"function":{"type":"Variable","name":"x"},
                            "set":{"type":"LessThan","upper":3.0}}]}""",
    )
    envelope = Dict(
        "api_version" => "1",
        "problem" => problem,
        "solver" => NexOR.OptimizerWithAttributes("HiGHS", MOI.Silent() => true),
    )
    response = HTTP.post("$URL/problems", HEADERS, JSON.json(envelope))
    id = JSON.parse(String(response.body))["id"]
    worker_url = ENV["NEXOR_SERVER_URL"] * "/api/solve-worker/v1"
    # register requires the enrollment token
    body = Dict(
        "enrollment_token" => "wrong",
        "name" => "test-worker",
        "instance_uid" => "test-worker-1",
        "solvers" => ["highs", "nosuchsolver"],
    )
    response = HTTP.post(
        "$worker_url/register",
        HEADERS,
        JSON.json(body);
        status_exception = false,
    )
    @test response.status == 401
    body["enrollment_token"] = "enroll-token"
    response = HTTP.post("$worker_url/register", HEADERS, JSON.json(body))
    @test response.status == 201
    registration = JSON.parse(String(response.body))
    @test registration["solvers"] == ["highs"] # unknown names are dropped
    @test registration["heartbeat_interval"] == 30
    key = registration["instance_key"]
    auth = ["Content-Type" => "application/json", "Authorization" => "Bearer $key"]
    # a wrong instance key is rejected
    @test HTTP.post(
        "$worker_url/claim",
        ["Authorization" => "Bearer wk_wrong"],
        "{}";
        status_exception = false,
    ).status == 401
    # claim the queued problem
    claimed = JSON.parse(String(HTTP.post("$worker_url/claim", auth, "{}").body))
    attempt = claimed["attempt"]
    @test attempt["problem_reference"] == id
    @test attempt["solver"] == "highs"
    @test attempt["envelope"]["problem"]["variables"] == [Dict("name" => "x")]
    @test claimed["more_available"] == false
    @test JSON.parse(String(HTTP.get("$URL/problems/$id", HEADERS).body))["status"] ==
          "claimed"
    # heartbeat echoes the cadence
    beat = JSON.parse(
        String(
            HTTP.post(
                "$worker_url/heartbeat",
                auth,
                JSON.json(Dict("attempts" => [Dict("reference" => attempt["reference"])])),
            ).body,
        ),
    )
    @test beat["order"] === nothing
    @test beat["cancel"] == []
    # solve like the real worker does and post the result
    scratch = mktempdir()
    solution = NexOR.solve_envelope(attempt["envelope"], scratch)
    reference = attempt["reference"]
    posted = JSON.parse(
        String(
            HTTP.post(
                "$worker_url/attempts/$reference/result",
                auth,
                JSON.json(Dict("solution" => solution)),
            ).body,
        ),
    )
    @test posted["accepted"] == true
    # the customer sees the returned solution
    delivered = JSON.parse(String(HTTP.get("$URL/problems/$id/solution", HEADERS).body))
    @test delivered["status"] == "optimal"
    @test delivered["solution"]["solution"]["primal"] == [3.0]
    # a second submission of the same attempt is dropped, not an error
    posted = JSON.parse(
        String(
            HTTP.post(
                "$worker_url/attempts/$reference/result",
                auth,
                JSON.json(Dict("solution" => solution)),
            ).body,
        ),
    )
    @test posted["accepted"] == false
    # a broken problem fails terminally with problem_failure
    response = HTTP.post("$URL/problems", HEADERS, JSON.json(envelope))
    failing = JSON.parse(String(response.body))["id"]
    attempt = JSON.parse(String(HTTP.post("$worker_url/claim", auth, "{}").body))["attempt"]
    @test attempt["problem_reference"] == failing
    HTTP.post(
        "$worker_url/attempts/$(attempt["reference"])/fail",
        auth,
        JSON.json(
            Dict(
                "error_code" => "invalid_model",
                "error_message" => "unreadable",
                "problem_failure" => true,
            ),
        ),
    )
    problem_state = JSON.parse(String(HTTP.get("$URL/problems/$failing", HEADERS).body))
    @test problem_state["status"] == "failed"
    @test problem_state["error"]["code"] == "invalid_model"
    # goodbye deregisters: the key stops working
    @test JSON.parse(String(HTTP.post("$worker_url/goodbye", auth, "{}").body))["ok"] ==
          true
    @test HTTP.post("$worker_url/claim", auth, "{}"; status_exception = false).status == 401
    INLINE_SOLVER[] = true
end

@testset "webhook" begin
    received = Channel{Any}(1)
    hook = HTTP.serve!("127.0.0.1", 8760) do request
        put!(received, (headers = Dict(request.headers), body = String(request.body)))
        return HTTP.Response(200)
    end
    problem = JSON.parse(
        """{"version":{"major":1,"minor":7},"variables":[{"name":"x"}],
            "objective":{"sense":"max","function":{"type":"Variable","name":"x"}},
            "constraints":[{"function":{"type":"Variable","name":"x"},
                            "set":{"type":"LessThan","upper":3.0}}]}""",
    )
    envelope = Dict(
        "api_version" => "1",
        "problem" => problem,
        "solver" => NexOR.OptimizerWithAttributes("HiGHS", MOI.Silent() => true),
        "options" => Dict("webhook" => Dict("url" => "http://127.0.0.1:8760/hook")),
    )
    response = HTTP.post("$URL/problems", HEADERS, JSON.json(envelope))
    @test response.status == 201
    id = JSON.parse(String(response.body))["id"]
    # The server calls back once the problem is terminal
    @test timedwait(() -> isready(received), 60.0) == :ok
    delivery = take!(received)
    payload = JSON.parse(delivery.body)
    @test payload["problem"] == id
    @test payload["event"] == "terminal"
    @test payload["status"] == "optimal"
    @test payload["solution_url"] == "/api/optimization/v1/problems/$id/solution"
    @test payload["cost"] === nothing
    @test delivery.headers["X-Solve-Event"] == "terminal"
    signature = SHA.hmac_sha256(Vector{UInt8}(codeunits("hook-secret")), delivery.body)
    @test delivery.headers["X-Solve-Signature"] == "sha256=" * bytes2hex(signature)
    close(hook)
    # A webhook without an http(s) url is rejected at intake
    envelope["options"]["webhook"]["url"] = "ftp://example.com/hook"
    response =
        HTTP.post("$URL/problems", HEADERS, JSON.json(envelope); status_exception = false)
    @test response.status == 422
end

@testset "cached solution outlives the server" begin
    model = highs_model()
    JuMP.@variable(model, 0 <= x <= 1)
    JuMP.@objective(model, Max, x)
    JuMP.optimize!(model)
    close(SERVER) # solution_summary and value must not query the server
    @test JuMP.objective_value(model) ≈ 1.0
    @test JuMP.value(x) ≈ 1.0
    summary = sprint(print, JuMP.solution_summary(model))
    @test occursin("NexOR(HiGHS)", summary)
    @test occursin("OPTIMAL", summary)
end
