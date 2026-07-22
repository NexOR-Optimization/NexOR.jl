#  Copyright (c) 2026: NexOR Optimization SRL
#
#  Use of this source code is governed by an MIT-style license that can be found
#  in the LICENSE.md file or at https://opensource.org/licenses/MIT.

module NexOR

import JSON
import MathOptInterface as MOI

include("solver.jl")
include("http.jl")
include("MOI_wrapper.jl")

end # module NexOR
