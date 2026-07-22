#  Copyright (c) 2026: NexOR Optimization SRL
#
#  Use of this source code is governed by an MIT-style license that can be found
#  in the LICENSE.md file or at https://opensource.org/licenses/MIT.

# MOI.OptimizerWithAttributes expects a first argument that can be instantiated
# The difference here is that we expect a `String` otherwise it is equivalent

struct OptimizerWithAttributes
    optimizer::String
    params::Vector{Pair{MOI.AbstractOptimizerAttribute,Any}}
end

"""
    OptimizerWithAttributes(optimizer_constructor, params::Pair...)

Create an [`OptimizerWithAttributes`](@ref) with the parameters `params`.
"""
function OptimizerWithAttributes(
    optimizer::String,
    args::Vararg{Pair,N},
) where {N}
    params =
        Pair{MOI.AbstractOptimizerAttribute,Any}[MOI._to_param(arg) for arg in args]
    return OptimizerWithAttributes(optimizer, params)
end
