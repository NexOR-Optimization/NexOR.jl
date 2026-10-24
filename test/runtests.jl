#  Copyright (c) 2026: NexOR Optimization SRL
#
#  Use of this source code is governed by an MIT-style license that can be found
#  in the LICENSE.md file or at https://opensource.org/licenses/MIT.

if get(ENV, "NEXOR_TEST_PRODUCTION", "") == "1"
    include("production.jl")
end

include("protocol.jl")
include("http.jl")
