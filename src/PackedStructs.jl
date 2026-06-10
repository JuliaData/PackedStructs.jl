module PackedStructs

using EmulatedBitIntegers
using ExproniconLite

export @packed
VERSION >= v"1.11.0-DEV.469" && "public pack" |> Meta.parse |> eval

# `Memory{T}` (Julia ≥ 1.11) is preferred — it's a fixed-size, lower-overhead alternative to `Vector{T}` for the throwaway scratch buffers in the grouping algorithm and `Pack<B>` field staging. On the 1.10 LTS, fall back to `Vector{T}`: the call sites only use `(undef, n)` construction, indexing, and `fill!`, which both types share.
if VERSION < v"1.11"
    const Memory = Vector
end

# Register widths that typically support fast bit-wise operations. Used by both the grouping algorithm (to pick group sizes) and the `Pack<B>` primitive-type declarations in `packed_fields.jl`.
const NATIVE_SIZES = (8, 16, 32, 64)
const MAX_NATIVE_SIZE = maximum(NATIVE_SIZES)

inline(body) = Expr(:block, Expr(:meta, :inline), body)

"""
    pack(T::Type{<:Integer}, x) -> T

Pack the value `x` into a `T`-bit integer payload for storage in a `@packed` group.

Fallback methods handle:
- `Integer` `x`: zero-extended via [`EmulatedBitIntegers.zext`](@ref).
- Single-field `isbits` struct: recurses into the field.
- Multi-field `isbits` struct (other than `Tuple`/`NamedTuple`): concatenates fields by their logical [`bits`](@ref) widths, last field in the low bits.

Other packages can add methods for their own types to control how they are laid out in packed storage.
"""
pack(T::Type{<:Integer}, x::Integer) = zext(T, x)
function pack(T::Type{<:Integer}, x)
    ST = typeof(x)
    (isstructtype(ST) && !(ST <: Union{Tuple, NamedTuple})) || lazy"pack not implemented for type $ST" |> error
    n = fieldcount(ST)
    n == 1 && return pack(T, getfield(x, 1))
    result = zero(T)
    offset = 0
    for i in n:-1:1
        f = getfield(x, i)
        result |= pack(T, f) << offset
        offset += bits(f)
    end
    return result
end

include("packed_fields.jl")
include("group.jl")
include("packed_struct.jl")

macro packed(ex)
    packed(ex, __module__, __source__)
end

end