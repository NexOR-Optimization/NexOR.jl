# Opt-in check of the deployed execution service and Odoo record projection.
module ProductionTests
using Test
using JuMP
import NexOR
import HTTP

get(ENV, "NEXOR_TEST_PRODUCTION", "") == "1" ||
    error("Set NEXOR_TEST_PRODUCTION=1 to submit the three production smoke-test jobs.")
const KEY = get(ENV, "NEXOR_API_KEY", "")
isempty(KEY) && error("Set NEXOR_API_KEY to the test customer's Solve API key.")
const PLATFORM_URL = get_attribute(Model(NexOR.Optimizer), "server_url")
PLATFORM_URL == "https://solve.nexoropt.com" ||
    error("This test expects https://solve.nexoropt.com; check NEXOR_SERVER_URL.")
const ODOO_URL = "https://www.nexoropt.com"

function business_view(id)
    headers = ["Authorization" => "Bearer $KEY"]
    edge = get(ENV, "NEXOR_ODOO_EDGE_SECRET", "")
    isempty(edge) || push!(headers, "X-NexOR-Edge" => edge)
    deadline = time() + 60
    while true
        response = HTTP.get(
            "$ODOO_URL/solve/v1/problems/$id",
            headers;
            redirect = false,
            status_exception = false,
            connect_timeout = 10,
            request_timeout = 15,
        )
        if response.status == 200
            view = NexOR._response(response)
            if view["status"] in ("finished", "failed", "cancelled") || time() >= deadline
                return view
            end
        elseif response.status != 404 || time() >= deadline
            return NexOR._response(response)
        end
        sleep(0.2)
    end
end

@testset "JuMP → production HiGHS → Odoo" begin
    # Check the account and its key before creating a billable execution.
    NexOR._request(NexOR.Optimizer(), "GET", "/account")
    for kind in (:lp, :mip, :infeasible)
        model = Model(NexOR.Optimizer)
        set_attribute(model, "solver", "HiGHS")
        set_silent(model)
        # The worker deadline includes cold Julia compilation and result encoding.
        set_time_limit_sec(model, 120)
        if kind == :lp
            @variable(model, 0 <= x <= 4)
            @variable(model, 0 <= y <= 3)
            @constraint(model, x + y <= 5)
            @objective(model, Max, 2x + y)
        elseif kind == :mip
            @variable(model, x >= 2.5, Int)
            @objective(model, Min, x)
        else
            @variable(model, x <= 1)
            @constraint(model, x >= 2)
        end
        optimize!(model)
        id = unsafe_backend(model).problem_id
        expected = kind == :infeasible ? MOI.INFEASIBLE : MOI.OPTIMAL
        termination_status(model) == expected || error(
            "Production $kind solve $id returned $(termination_status(model)): " *
            raw_status(model),
        )
        @test termination_status(model) == expected
        if kind == :infeasible
            @test !has_values(model)
        else
            @test objective_value(model) ≈ (kind == :lp ? 9.0 : 3.0)
        end
        view = business_view(id)
        @test view["problem_id"] == id
        @test view["status"] == "finished"
        @test view["solver_used"] == "highs-mof"
        @test view["termination_status"] == string(expected)
        println("Production Odoo problem ", id, ": ", view["termination_status"])
    end
end
end
