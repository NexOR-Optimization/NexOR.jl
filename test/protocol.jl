#  Copyright (c) 2026: NexOR Optimization SRL
#
#  Use of this source code is governed by an MIT-style license that can be found
#  in the LICENSE.md file or at https://opensource.org/licenses/MIT.

module ProtocolTests
using Test
using JuMP
import HiGHS
import HTTP
import JSON
import NexOR
import MathOptInterface as MOI

ENV["NEXOR_DATA_DIR"] = mktempdir()
ENV["NEXOR_API_TOKEN"] = "test-token"
module MiniServer
include(joinpath(dirname(@__DIR__), "server", "server.jl"))
end

function request(model, method, path; body = "")
    response = MiniServer.handle(
        HTTP.Request(
            method,
            "/solve/v1" * path,
            ["Authorization" => "Bearer test-token"],
            body,
        ),
    )
    return NexOR._response(response)
end

function remote(model)
    client = NexOR.Optimizer()
    MOI.set(client, MOI.RawOptimizerAttribute("solver"), "HiGHS")
    MOI.set(client, MOI.Silent(), true)
    MOI.set(client, MOI.TimeLimitSec(), 10.0)
    indices = MOI.copy_to(client, backend(model))
    return client, indices
end

@testset "string-valued optimizer attributes" begin
    withenv("NEXOR_SERVER_URL" => nothing) do
        @test get_attribute(Model(NexOR.Optimizer), "server_url") ==
              "https://api.nexoropt.com"
    end
    withenv("NEXOR_SERVER_URL" => "https://example.test", "NEXOR_API_KEY" => "test-key") do
        model = Model(NexOR.Optimizer)
        @test get_attribute(model, "server_url") == "https://example.test"
        @test get_attribute(model, "api_key") == "test-key"
    end
    model = Model(NexOR.Optimizer)
    for (name, value) in
        (("server_url", "http://localhost:8080"), ("api_key", "private-key"))
        for input in (value, SubString(value))
            set_attribute(model, name, input)
            @test get_attribute(model, name) == value
        end
    end
end

@testset "platform envelope and solve" begin
    model = Model()
    @variable(model, 0 <= x <= 4)
    @variable(model, 0 <= y <= 3)
    @constraint(model, x + y <= 5)
    @objective(model, Max, 2x + y)
    client, indices = remote(model)
    MOI.set(client, MOI.RawOptimizerAttribute("presolve"), "on")
    body = NexOR._submission(client)
    envelope = JSON.parse(body)
    @test envelope["solver"] == "highs-mof"
    @test envelope["problem_type"] == "opaque/1"
    @test envelope["options"]["time_limit_seconds"] == 10
    @test envelope["options"]["solver_options"]["highs-mof"]["silent"] == true
    @test envelope["options"]["solver_options"]["highs-mof"]["presolve"] == "on"
    @test endswith(body, "\"problem\":" * JSON.json(envelope["problem"]) * "}")
    NexOR._optimize!(client, request)
    @test MOI.get(client, MOI.TerminationStatus()) == MOI.OPTIMAL
    @test MOI.get(client, MOI.ObjectiveValue()) ≈ 9.0
    @test MOI.get(client, MOI.VariablePrimal(), indices[index(x)]) ≈ 4.0
    @test MOI.get(client, MOI.VariablePrimal(), indices[index(y)]) ≈ 1.0
    @test MOI.get(client, MOI.SolverName()) == "NexOR(HiGHS)"
    @test startswith(client.problem_id, "prb_")
    @test request(client, "GET", "/problems/$(client.problem_id)/status")["status"] ==
          "finished"
    # A failure after a success must clear the previous result.
    failed_request =
        (args...; kwargs...) -> Dict(
            "problem_id" => "prb_failed",
            "status" => "failed",
            "error" => Dict("code" => "solver_crash", "message" => "crashed"),
        )
    NexOR._optimize!(client, failed_request)
    @test MOI.get(client, MOI.TerminationStatus()) == MOI.OTHER_ERROR
    @test MOI.get(client, MOI.ResultCount()) == 0
    @test MOI.get(client, MOI.PrimalStatus()) == MOI.NO_SOLUTION
    @test MOI.get(client, MOI.RawStatusString()) == "solver_crash: crashed"
end

@testset "integer, infeasible and unbounded models" begin
    model = Model()
    @variable(model, x >= 2.5, Int)
    @objective(model, Min, x)
    client, indices = remote(model)
    NexOR._optimize!(client, request)
    @test MOI.get(client, MOI.ObjectiveValue()) ≈ 3.0
    @test MOI.get(client, MOI.VariablePrimal(), indices[index(x)]) ≈ 3.0

    model = Model()
    @variable(model, x <= 1)
    @constraint(model, x >= 2)
    client, _ = remote(model)
    NexOR._optimize!(client, request)
    @test MOI.get(client, MOI.TerminationStatus()) == MOI.INFEASIBLE
    @test MOI.get(client, MOI.DualStatus()) == MOI.INFEASIBILITY_CERTIFICATE
    @test MOI.get(client, MOI.PrimalStatus()) == MOI.NO_SOLUTION

    model = Model()
    @variable(model, x >= 0)
    @objective(model, Max, x)
    client, _ = remote(model)
    NexOR._optimize!(client, request)
    @test MOI.get(client, MOI.TerminationStatus()) == MOI.DUAL_INFEASIBLE
end

@testset "HTTP request construction and result redirect" begin
    client = NexOR.Optimizer()
    MOI.set(client, MOI.RawOptimizerAttribute("server_url"), "http://localhost:8080/")
    MOI.set(client, MOI.RawOptimizerAttribute("api_key"), "private-key")
    calls = []
    transport = function (method, url, headers, body; kwargs...)
        push!(calls, (; method, url, headers, body, kwargs))
        if length(calls) == 1
            return HTTP.Response(
                302,
                ["Location" => "http://storage.local/result?signature=abc"],
            )
        end
        return HTTP.Response(200, ["Content-Type" => "application/json"], "{\"ok\":true}")
    end
    @test NexOR._request(client, "GET", "/problems/prb_x/result?inline=1"; transport)["ok"]
    @test calls[1].url == "http://localhost:8080/solve/v1/problems/prb_x/result?inline=1"
    @test ("Authorization" => "Bearer private-key") in calls[1].headers
    @test calls[2].url == "http://storage.local/result?signature=abc"
    @test isempty(calls[2].headers)
    @test calls[1].kwargs[:redirect] == false
    @test calls[2].kwargs[:redirect] == false
end

@testset "refusals and transport errors" begin
    model = Model()
    @variable(model, x)
    client, _ = remote(model)
    MOI.set(client, MOI.RawOptimizerAttribute("not_a_highs_option"), 1)
    NexOR._optimize!(client, request)
    @test MOI.get(client, MOI.TerminationStatus()) == MOI.INVALID_OPTION
    @test MOI.get(client, MOI.ResultCount()) == 0

    malformed_request = function (model, method, path; body = "")
        if method == "POST" && path == "/problems"
            envelope = JSON.parse(body)
            envelope["problem"] = Dict()
            body = JSON.json(envelope)
        end
        return request(model, method, path; body)
    end
    client, _ = remote(model)
    NexOR._optimize!(client, malformed_request)
    @test MOI.get(client, MOI.TerminationStatus()) == MOI.INVALID_MODEL
    @test startswith(MOI.get(client, MOI.RawStatusString()), "INVALID_PROBLEM:")

    result = Dict(
        "solution" => Dict(),
        "termination_status" => "INVALID_PROBLEM",
        "diagnostics" => Dict("warnings" => [Dict("message" => "bad model")]),
    )
    refusal =
        (model, method, path; kwargs...) ->
            method == "POST" ? Dict("problem_id" => "prb_refused", "status" => "finished") :
            result
    NexOR._optimize!(client, refusal)
    @test MOI.get(client, MOI.TerminationStatus()) == MOI.INVALID_MODEL
    @test MOI.get(client, MOI.RawStatusString()) == "INVALID_PROBLEM: bad model"

    response = MiniServer.handle(HTTP.Request("POST", "/solve/v1/problems", [], "{}"))
    @test response.status == 401
    @test_throws ErrorException(
        "NexOR server returned 401 unauthorized: Missing or invalid API key.",
    ) NexOR._response(response)
    @test_throws ErrorException("NexOR server returned 502: unavailable") NexOR._response(
        HTTP.Response(502, "unavailable"),
    )
    @test_throws ErrorException MOI.optimize!(NexOR.Optimizer())
    client, _ = remote(model)
    MOI.set(client, MOI.TimeLimitSec(), nothing)
    @test !haskey(JSON.parse(NexOR._submission(client))["options"], "time_limit_seconds")
    MOI.set(client, MOI.TimeLimitSec(), 0.25)
    @test JSON.parse(NexOR._submission(client))["options"]["time_limit_seconds"] == 1
    result["termination_status"] = "FUTURE_STATUS"
    delete!(result, "diagnostics")
    NexOR._optimize!(client, refusal)
    @test MOI.get(client, MOI.TerminationStatus()) == MOI.OTHER_ERROR
    @test MOI.get(client, MOI.RawStatusString()) == "FUTURE_STATUS"

    conic = Model()
    @variable(conic, v[1:2])
    @constraint(conic, v in SecondOrderCone())
    client, _ = remote(conic)
    NexOR._optimize!(client, request)
    @test MOI.get(client, MOI.TerminationStatus()) == MOI.INVALID_MODEL
    @test_throws ErrorException request(client, "POST", "/problems"; body = "{")
    @test_throws ErrorException request(client, "POST", "/problems"; body = "{}")
    @test_throws ErrorException request(client, "GET", "/problems/prb_missing/status")
    @test_throws ErrorException request(client, "GET", "/problems/prb_missing/result")
end
end
