#  Copyright (c) 2026: NexOR Optimization SRL
#
#  Use of this source code is governed by an MIT-style license that can be found
#  in the LICENSE.md file or at https://opensource.org/licenses/MIT.

module HTTPTests
using Test
using JuMP
import NexOR
import HTTP
import HiGHS

ENV["NEXOR_DATA_DIR"] = mktempdir()
ENV["NEXOR_API_TOKEN"] = "test-token"
ENV["NEXOR_API_KEY"] = "test-token"
ENV["NEXOR_SERVER_URL"] = "http://127.0.0.1:8752"
module MiniServer
include(joinpath(@__DIR__, "server", "server.jl"))
end

@testset "JuMP over HTTP" begin
    server = MiniServer.start("127.0.0.1", 8752)
    model = Model(NexOR.Optimizer)
    set_attribute(model, "solver", "HiGHS")
    set_silent(model)
    @variable(model, 0 <= x <= 4)
    @variable(model, 0 <= y <= 3)
    @constraint(model, x + y <= 5)
    @objective(model, Max, 2x + y)
    try
        optimize!(model)
        @test termination_status(model) == MOI.OPTIMAL
        @test objective_value(model) ≈ 9.0
        @test value(x) ≈ 4.0
        @test value(y) ≈ 1.0
        set_upper_bound(x, 3)
        optimize!(model)
        @test objective_value(model) ≈ 8.0
        @test value(x) ≈ 3.0
    finally
        close(server)
    end
    @test objective_value(model) ≈ 8.0
    @test value(x) ≈ 3.0
    @test occursin("OPTIMAL", sprint(print, solution_summary(model)))
end
end
