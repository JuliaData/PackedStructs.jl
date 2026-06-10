function cumsum_reverse_off_by_one(x::NTuple{N, T}, init::T) where {N, T}
    y = Memory{T}(undef, N)
    y[end] = init
    for i in N-1 : -1 : 1
        y[i] = x[i+1] + y[i+1]
    end
    return y
end

struct Field
    name::Symbol
    publicname::Symbol
    type::DataType
    bitoffset::Int
    isconst::Bool
end

abstract type APackedFields end
struct PackedFields{L} <: APackedFields
    supporttype::Symbol
    signedsupporttype::Symbol
    bits::Int
    fieldtypes::NTuple{L, DataType}
    fields::NTuple{L, Field}
end
function PackedFields{L}(fields::Vector{JLField}, nbits::Int) where L
    supporttype = Symbol("UInt", nbits)
    signedsupporttype = Symbol("Int", nbits)
    fieldnames = ntuple(i -> Symbol("_", i), Val(L))
    fieldrealnames = NTuple{L}(f.name for f in fields)
    fieldtypes = NTuple{L}(f.type for f in fields)
    fieldbitsizes = NTuple{L}(f.type |> bits for f in fields)
    fieldbitoffsets = cumsum_reverse_off_by_one(fieldbitsizes, 0)
    fieldconsts = NTuple{L}(f.isconst for f in fields)

    fieldobjects = NTuple{L}(Field(n, r, t, o, c) for (n, r, t, o, c) in zip(fieldnames, fieldrealnames, fieldtypes, fieldbitoffsets, fieldconsts))
    PackedFields{L}(supporttype, signedsupporttype, nbits, fieldtypes, fieldobjects)
end
PackedFields(fields::Vector{JLField}, bits::Integer) = PackedFields{fields |> length}(fields, convert(Int, bits))
isgroup(x::PackedFields{L}) where L = L > 1
Base.length(x::PackedFields{L}) where L = L

# Symbol of the parametric primitive type for a given total bit width, e.g. `Pack8`. Construction and `getindex` methods exist only for tuple parameterizations that some `@packed` struct has produced; `Pack<B>` is an internal storage primitive, not a standalone container.
packname(nbits::Integer) = Symbol("Pack", nbits)
# Symbol of the parametric abstract supertype for a given total bit width, e.g. `APack8`. Declared alongside the primitive type so users can specialize behavior on `APack<B>{Tuple{…}}`.
packabsname(nbits::Integer) = Symbol("A", packname(nbits))
# Concrete type expression for this packing: `PackedStructs.Pack<B>{Tuple{T1, …, TL}}` for groups, or the lone field's type for non-groups. The `Pack<B>` reference is module-qualified so the expression resolves correctly when spliced into the caller's module.
packtype(pf::PackedFields{1}) = pf.fieldtypes[1]
packtype(pf::PackedFields{L}) where L = :($PackedStructs.$(packname(pf.bits)){Tuple{$(pf.fieldtypes...)}})

# Pre-declare the parametric primitive and its abstract supertype for each native width. `NATIVE_SIZES` fully determines which group widths can occur, so `create_packed_fields!` only needs to dedup methods per concrete tuple parameterization — never the types themselves.
for nbits in NATIVE_SIZES
    @eval begin
        abstract type $(packabsname(nbits)){T<:Tuple} end
        primitive type $(packname(nbits)){T<:Tuple} <: $(packabsname(nbits)){T} $nbits end
        # `bits` reports logical content, so peel past the per-group padding by summing the tuple parameter.
        EmulatedBitIntegers.bits(::Type{<:$(packabsname(nbits)){T}}) where T<:Tuple = sum(EmulatedBitIntegers.bits, fieldtypes(T))
        # `Pack<B>` is a primitive non-Integer type, so the generic struct fallback of `pack` doesn't apply. Route through the matching unsigned so nested `@packed` fields zero-extend correctly when used as a field of an outer `@packed`. The padding bits (above the logical width) are 0 by construction in our constructor.
        pack(T::Type{<:Integer}, x::$(packabsname(nbits)){<:Tuple}) = pack(T, reinterpret($(Symbol("UInt", nbits)), x))
    end
end

# Look up the concrete `Pack<B>` storage primitive for a packed group of `nbits` bits. Generated from `NATIVE_SIZES` so it stays in sync with the declarations above; a non-native `nbits` raises a clear error rather than failing later in name lookup. Use a comprehension instead of a generator to avoid a JET finding.
let branches = [:(nbits == $b && return $(b |> packname)) for b in NATIVE_SIZES]
    @eval function packstorage(nbits::Integer)
        $(branches...)
        error(lazy"no `Pack<B>` type for $nbits bits; supported widths are $NATIVE_SIZES")
    end
end
packstorage(nbits::Integer, param::Type{<:Tuple}) = packstorage(nbits){param}

function define_constructor(pf::APackedFields)
    T = packtype(pf)
    args = [:($(Symbol("_", i))::$Ti) for (i, Ti) in enumerate(pf.fieldtypes)]
    # Invariant on the result: every bit above `sum(bits, fields)` is zero. Two equal-valued constructions therefore produce bit-identical `Pack<B>` payloads, which is what gives `==`/`hash`/`deepcopy` parity with plain structs. Rests on the `pack` contract that `pack(T, x)` places `x`'s bits in the low `bits(typeof(x))` bits of `T` with zeros above; the default methods (`zext` for integers, recursive struct fallback) satisfy this. A custom `pack` override that leaks bits above its field's width silently breaks the invariant.
    shifts = (:(PackedStructs.pack($(pf.supporttype), $(f.name)) << $(f.bitoffset)) for f in pf.fields)
    body = :(reinterpret($T, |($(shifts...)))) |> inline
    return JLFunction(name=T; args, body)
end

function define_getindex(pf::APackedFields)
    T = packtype(pf)
    # The `x` argument name is referenced by symbol `:x` inside `unpack_field_expr`; keep the two in sync.
    args = [:(x::$T), :(i::Integer)]

    cases = (:(i == $j && return $(unpack_field_expr(f.type, pf, f.bitoffset))) for (j, f) in enumerate(pf.fields))

    body = Expr(:block, cases...) |> inline
    JLFunction(name=:(Base.getindex); args, body)
end

# Build the right-hand side of a `getindex` case: extract the field of type `type` at bit `bitoffset` from the packed group `x` described by `pf`. The hardcoded `:x` must match the argument name in `define_getindex`. Struct-typed fields recurse, bottoming out at primitive types.
function unpack_field_expr(type::Type, pf::APackedFields, bitoffset)
    return if isprimitivetype(type)
        # Use the same signedness for the support type as for the field to always get the correct right shift, e.g. for negative numbers.
        supporttype = type <: Signed ? pf.signedsupporttype : pf.supporttype
        storagetype = type |> storagetypeof
        lshift = pf.bits - (bitoffset + bits(type))
        rshift = pf.bits - bits(type)
        # Note that the fields in a group fill (ignoring padding) from most significant to least significant bit. So the "start of the group" is MSB and the "end of the group" is LSB (`bitoffset == 0`).
        # An unsigned type at the end of a group can be extracted with a single operation as the sign is known, whereas the signed type needs two operations (shift left and arithmetic shift right).
        # `@code_native` shows:
        # - the two shifts are optimized to a masking with `and` for an unsigned variable at the end of a group.
        # - the two shifts are optimized to one shift for a variable at the start of a group.
        # There is no reason to implement the same optimization twice, so keep it simple here.
        extracted = :(reinterpret($supporttype, x) << $lshift >> $rshift)
        # Compare the storage primitive's actual width (`8 * sizeof`) against the support type's width. `bits(storagetype)` would be wrong here: for packed primitives like `Pack8{Tuple{Int2,Int2}}` it returns the logical bit count (sum of inner field widths), not the underlying primitive's width.
        if 8 * sizeof(storagetype) < pf.bits
            :(reinterpret($type, Core.trunc_int($storagetype, $extracted)))
        else
            :(reinterpret($type, $extracted))
        end
    elseif isbitstype(type) && !(type <: Union{Tuple, NamedTuple})
        # Non-tuple `isbits` struct (including single-field wrappers): build the value field-by-field, recursing into each field at its bit position within `type`. `isbits` rules out mutable structs, abstract types, `Union`s, and types with non-bits fields like `Array`. The `Union{Tuple, NamedTuple}` guard rejects tuples and named tuples, which `isstructtype` would accept but `Expr(:new)` cannot construct (tuples are built via `Core.tuple`).
        # We use `Expr(:new, …)` to construct without running user code: it is the lowered form of the `new(...)` keyword from inner constructors and bypasses all constructors (inner and outer), including the implicit `convert` calls that the default constructor would otherwise insert — so each `field_args[i]` must already have type `fieldtype(type, i)` exactly. See https://docs.julialang.org/en/v1/devdocs/ast/#Surface-syntax-AST (`:new` head) and https://docs.julialang.org/en/v1/manual/constructors/#Incomplete-Initialization. That's safe here because the bits were validated by whatever constructor produced them on the write path (there is no `setfield!` into the packed group), so re-running the constructor on read would only re-check invariants the bits already satisfy.
        # Alternatives considered:
        # - `Expr(:call, type, …)`: re-runs the user constructor. Adds unnecessary work, and any side effects in user code would fire on every read.
        # - `reinterpret(type, bits)` on the whole struct: only correct when Julia's in-memory layout of `type` matches the packed bit layout. For sub-byte fields the struct is normally padded to alignment, so the layouts differ.
        field_types = fieldtypes(type)
        field_bits = map(bits, field_types)
        field_offsets = cumsum_reverse_off_by_one(field_bits, 0)
        field_args = map(field_types, field_offsets) do t, o
            unpack_field_expr(t, pf, bitoffset + o)
        end
        Expr(:new, type, field_args...)
    else
        error(lazy"@packed field type $type is not supported: only primitive types and `isbits` non-tuple struct types can be packed.")
    end
end

function create_packed_fields!(exprs, pfs::AbstractVector{<:APackedFields}, source::LineNumberNode)
    for pf in unique(pf -> pf.fieldtypes, Iterators.filter(isgroup, pfs))
        param = Tuple{pf.fieldtypes...}
        T = packstorage(pf.bits, param)
        # Guard at evaluation time: a second `@packed` in the same module can't see methods another expansion only pushed into `exprs`, so `hasmethod` here would not work. Wrap the defs so they only run if no prior block already defined them.
        defs = (codegen_ast(linewrap!(define_constructor(pf), source)),
                codegen_ast(linewrap!(define_getindex(pf), source)))
        push!(exprs, :(hasmethod($T, $param) || begin $(defs...) end))
    end
end