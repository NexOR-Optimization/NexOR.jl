#  Copyright (c) 2026: NexOR Optimization SRL
#
#  Use of this source code is governed by an MIT-style license that can be found
#  in the LICENSE.md file or at https://opensource.org/licenses/MIT.

module IncrementalTests

using Test
using JuMP
import NexOR
import MathOptInterface as MOI

@testset "incremental MOI interface" begin
    client = NexOR.Optimizer()
    @test MOI.supports_incremental_interface(client)
    @test MOI.get(client, MOI.ResultCount()) == 0
    MOI.Test.runtests(
        client,
        MOI.Test.Config(exclude = Any[MOI.optimize!]);
        include = [
            "test_model_Name_VariableName_ConstraintName",
            "test_model_is_valid",
            "test_model_delete",
            "test_modification_",
            "test_basic_ScalarAffineFunction_LessThan",
            "test_basic_VectorAffineFunction_Nonnegatives",
        ],
    )
end

@testset "direct JuMP construction, edits and serialization" begin
    client = NexOR.Optimizer()
    model = direct_model(client)
    set_attribute(model, "solver", "HiGHS")
    @test backend(model) === client
    @variable(model, 0 <= x <= 4, start = 1)
    @variable(model, y >= 0)
    @constraint(model, row, x + y <= 5)
    @objective(model, Max, 2x + y)
    @test variable_by_name(model, "x") == x
    @test constraint_by_name(model, "row") == row
    @test start_value(x) == 1
    set_start_value(x, 2)
    @test start_value(x) == 2
    set_upper_bound(x, 3)
    set_normalized_coefficient(row, y, 2)
    set_normalized_rhs(row, 6)
    set_objective_coefficient(model, x, 3)
    @test upper_bound(x) == 3
    @test normalized_coefficient(row, y) == 2
    @test normalized_rhs(row) == 6
    @test coefficient(objective_function(model), x) == 3

    # Store a solution, then exercise every edit path without an HTTP server.
    function solved!()
        client.problem_id = "prb_test"
        client.raw_status = "optimal"
        MOI.set(client.model, MOI.TerminationStatus(), MOI.OPTIMAL)
        MOI.set(client.model, MOI.ResultCount(), 1)
        return
    end
    function invalidated()
        @test client.problem_id === nothing
        @test MOI.get(client, MOI.TerminationStatus()) == MOI.OPTIMIZE_NOT_CALLED
        @test MOI.get(client, MOI.ResultCount()) == 0
        @test MOI.get(client, MOI.RawStatusString()) == "optimize not called"
        return
    end
    edits = (
        () -> @variable(model, z),
        () -> @constraint(model, x + y >= 1),
        () -> set_objective_sense(model, MOI.MIN_SENSE),
        () -> set_start_value(x, 3),
        () -> set_upper_bound(x, 2),
        () -> set_normalized_coefficient(row, y, 3),
        () -> set_objective_coefficient(model, x, 4),
        () -> delete(model, row),
    )
    for edit in edits
        solved!()
        edit()
        invalidated()
    end
    @test !is_valid(model, row)
    @test is_valid(model, x)
    @test length(NexOR._problem(client)["variables"]) == 3
    solved!()
    source = MOI.Utilities.Model{Float64}()
    source_x = MOI.add_variable(source)
    map = MOI.copy_to(client, source)
    @test MOI.is_valid(client, map[source_x])
    @test MOI.get(client, MOI.NumberOfVariables()) == 1
    invalidated()
    solved!()
    MOI.empty!(client)
    @test MOI.is_empty(client)
    invalidated()
end

end # module IncrementalTests
