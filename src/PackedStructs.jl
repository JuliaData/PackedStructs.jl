module PackedStructs

using EmulatedBitIntegers
using ExproniconLite
using PrecompileTools: @compile_workload

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

Add a method for a custom type to teach `@packed` how to lay it out. The contract:

1. Return a `T` whose low `bits(typeof(x))` bits hold the value and whose higher bits are zero. The group constructor `|`s shifted results together, so a stray high bit corrupts the neighboring field.
2. `EmulatedBitIntegers.bits(typeof(x))` and `EmulatedBitIntegers.storagetypeof(typeof(x))` must be defined for primitive types so the read path (`getindex` on the `Pack<B>` slot) can size and reinterpret the extracted bits.
3. Reads are *not* user-extensible: a primitive type is read back via `reinterpret(T, …)` on its `storagetypeof`; a struct is read back field-by-field with `Expr(:new, T, …)`. A custom `pack` must produce a bit pattern matching that fixed reverse operation. Reordering, custom encoding, or padding semantics that diverge from field-by-field recursion are silently wrong on read.

The safe scope is therefore primitive non-`Integer` types whose bits are their value (e.g. `Float16`/`Float32`/`Float64`, `Char`). For custom *struct* layouts, register `bits` on the inner field type instead of overriding `pack`.

See the "Extending `pack`" section of the README for a worked `Float32` example.
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

# The macro pipeline (`packed`, `group`, `create_packed_fields!`, `create_packed_struct!`, and the per-method builders) is inference-heavy and runs in the *user's* module at expansion time, so without this a downstream session pays multiple seconds compiling it on the first `@packed`. Expanding a few representative structs here caches that machinery into the precompile image. The generated per-type methods (the user's `Pack<B>{…}` constructor, `getproperty`, …) can't be precompiled in advance since they depend on user types, but the code that *builds* them can.
@compile_workload begin
    precompile(Tuple{typeof(packed), Expr, Module, LineNumberNode})

    @eval module _PrecompileWorkload
        using EmulatedBitIntegers
        using PackedStructs

        @emulate Int3 Int4 Int5

        # Immutable grouped struct: grouping, group constructor, `getindex`,
        # `getproperty`, `show`.
        @packed struct _Imm
            a::Int4
            b::Int4
        end
        let x = _Imm(1, 2)
            x.a, x.b
            repr(x)
        end

        # Mutable grouped struct: the grouped `setproperty!` branch.
        @packed mutable struct _Mut
            a::Int4
            b::Int4
        end
        let x = _Mut(0, 0)
            x.a = 1
            x.b = 2
        end

        # Inner constructor with `new(...)`: the `rewrite_new` path.
        @packed struct _Inner
            hi::Int5
            lo::Int3
            _Inner(a, b) = new(a, b)
        end
        _Inner(1, 1)

        # Nested isbits struct field: recursive unpack via `Expr(:new)`.
        struct _Wrap
            v::Int4
        end
        @packed struct _Nested
            w::_Wrap
            t::Int4
        end
        _Nested(_Wrap(Int4(1)), Int4(2)).w
    end
end

end
