#  Copyright (c) 2026: NexOR Optimization SRL
#
#  Use of this source code is governed by an MIT-style license that can be found
#  in the LICENSE.md file or at https://opensource.org/licenses/MIT.

# Helpers shared by server.jl and solver.jl. The two processes communicate
# through files in the problem directory, so status writes go through a
# temporary file + rename to stay atomic for concurrent readers.

function write_json(path, payload)
    tmp = path * ".tmp"
    write(tmp, JSON.json(payload))
    return mv(tmp, path; force = true)
end

write_status(dir, payload) = write_json(joinpath(dir, "status.json"), payload)

read_status(dir) = JSON.parsefile(joinpath(dir, "status.json"))

# The solver catalog: wire name (lowercase, as in the manager's solver
# catalog) to the Julia package implementing it. Adding a solver is one entry
# here plus the package in Project.toml.
solver_packages() = Dict("highs" => :HiGHS)

function solver_optimizer(name)
    package = Base.require(Main, solver_packages()[lowercase(name)])
    return getglobal(package, :Optimizer)
end
