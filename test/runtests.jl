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

import HiGHS
import HTTP
import JSON
import JuMP
import NexOR
using Test

include(joinpath(dirname(@__DIR__), "server", "server.jl"))
isdefined(@__MODULE__, :SERVER) && close(SERVER) # allow re-include in a REPL
const SERVER = start("127.0.0.1", 8752)

const URL = ENV["NEXOR_SERVER_URL"] * "/api/optimization/v1"
const HEADERS =
    ["Content-Type" => "application/json", "Authorization" => "Bearer test-token"]

# A solver whose lowercased module name is unknown to the server catalog.
module FakeGurobi
struct Optimizer end
end

function highs_model()
    model = JuMP.Model(NexOR.Optimizer)
    # By name: the solver package is only needed on the server
    JuMP.set_attribute(model, "solver", "HiGHS")
    JuMP.set_silent(model)
    return model
end

@testset "lp" begin
    model = highs_model()
    JuMP.set_attribute(
        model,
        "solver",
        JuMP.optimizer_with_attributes(HiGHS.Optimizer, "presolve" => "on"),
    )
    JuMP.set_time_limit_sec(model, 10.0)
    JuMP.@variable(model, 0 <= x <= 4)
    JuMP.@variable(model, 0 <= y <= 3)
    JuMP.@constraint(model, x + y <= 5)
    JuMP.@objective(model, Max, 2x + y)
    JuMP.optimize!(model)
    @test JuMP.termination_status(model) == JuMP.MOI.OPTIMAL
    @test JuMP.primal_status(model) == JuMP.MOI.FEASIBLE_POINT
    @test JuMP.result_count(model) == 1
    @test JuMP.objective_value(model) ≈ 9.0
    @test JuMP.value(x) ≈ 4.0
    @test JuMP.value(y) ≈ 1.0
    @test JuMP.solve_time(model) >= 0.0
    @test JuMP.solver_name(model) == "NexOR(HiGHS)"
    # What reached the server: the solver spec of the submit envelope
    nexor = JuMP.unsafe_backend(model)
    envelope = JSON.parsefile(
        joinpath(ENV["NEXOR_DATA_DIR"], nexor.problem_id, "envelope.json"),
    )
    @test envelope["solver"]["name"] == "highs"
    @test envelope["solver"]["parameters"]["presolve"] == "on"
    @test envelope["solver"]["parameters"]["silent"] == true
    @test envelope["solver"]["parameters"]["time_limit_seconds"] == 10.0
end

@testset "milp" begin
    model = highs_model()
    JuMP.@variable(model, x >= 2.5, Int)
    JuMP.@objective(model, Min, x)
    JuMP.optimize!(model)
    @test JuMP.termination_status(model) == JuMP.MOI.OPTIMAL
    @test JuMP.objective_value(model) ≈ 3.0
    @test JuMP.value(x) ≈ 3.0
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
    @test_throws JuMP.MOI.ResultIndexBoundsError JuMP.value(x)
end

@testset "unbounded" begin
    model = highs_model()
    JuMP.@variable(model, x >= 0)
    JuMP.@objective(model, Max, x)
    JuMP.optimize!(model)
    @test JuMP.termination_status(model) == JuMP.MOI.DUAL_INFEASIBLE
end

@testset "unknown solver" begin
    model = JuMP.Model(NexOR.Optimizer)
    JuMP.set_attribute(model, "solver", "Gurobi")
    JuMP.@variable(model, x)
    @test_throws ErrorException JuMP.optimize!(model)
    JuMP.set_attribute(model, "solver", FakeGurobi.Optimizer)
    @test_throws ErrorException JuMP.optimize!(model)
end

@testset "attributes" begin
    model = JuMP.Model(NexOR.Optimizer)
    @test JuMP.get_attribute(model, "server_url") == ENV["NEXOR_SERVER_URL"]
    @test JuMP.get_attribute(model, "api_key") == "test-token"
    JuMP.set_attribute(model, "api_key", "wrong")
    JuMP.set_attribute(model, "solver", HiGHS.Optimizer)
    JuMP.@variable(model, x)
    @test_throws ErrorException JuMP.optimize!(model) # 401 invalid_key
end

@testset "server protocol" begin
    @test HTTP.get("$URL/health").status == 200 # no token needed
    response = HTTP.get(
        "$URL/problems/prb_x",
        ["Authorization" => "Bearer wrong"];
        status_exception = false,
    )
    @test response.status == 401
    @test HTTP.post("$URL/problems", HEADERS, "{"; status_exception = false).status ==
          400
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
        "solver" => Dict("name" => "highs", "parameters" => Dict()),
    )
    response = HTTP.post("$URL/problems", HEADERS, JSON.json(envelope))
    @test response.status == 201
    id = JSON.parse(String(response.body))["id"]
    problem = nothing
    for _ in 1:100
        problem = JSON.parse(String(HTTP.get("$URL/problems/$id", HEADERS).body))
        problem["status"] == "failed" && break
        sleep(0.1)
    end
    @test problem["status"] == "failed"
    @test problem["error"]["code"] == "worker_error"
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
