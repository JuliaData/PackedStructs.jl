using EmulatedBitIntegers
using PackedStructs
using PackedStructs: Pack8, Pack16, Pack32, Pack64
using InteractiveUtils: code_llvm
using Test
using JET: AnyFrameModule, get_reports, report_package
using ExproniconLite: ExproniconLite
using Accessors: Accessors, @set, @reset
using ConstructionBase: ConstructionBase

# JET's findings vary substantially with the Julia / `Base` it's run against. Gate to Julia ≥ 1.12 to pin behavior to a recent baseline. On 1.12 (only) also ignore `Base`, because it flags a false positive inside `Base.similar(Vector{Expr}, ())` triggered (transitively) from `@packed` expansion; 1.13 doesn't have this issue.
@static if VERSION >= v"1.12"
@testset "JET" begin
    # ExproniconLite.jl (generated from Expronicon.jl) is not JET-clean, so exclude it from testing. This can be improved in the future, but as Expronicon.jl is proven in use, there is no urgency.
    ignored = (ExproniconLite |> AnyFrameModule, (@static VERSION < v"1.13" ? (Base |> AnyFrameModule,) : ())...)
    @test report_package(PackedStructs, ignored_modules=ignored) |> get_reports |> isempty
end
end

using PackedStructs: group
@testset "group" begin
    @test [4, 4] |> group == [2]
    @test [4, 4, 8] |> group == [2, 1]
    @test [4, 4, 8, 8] |> group == [2, 1, 1]
    @test [4, 4, 4, 4, 8] |> group == [2, 2, 1]
    @test [8, 8, 8, 8] |> group == [1, 1, 1, 1]
    @test [2, 2, 2, 2] |> group == [4]
    @test [3, 5] |> group == [2]
    @test [1, 7] |> group == [2]
    @test [1, 2, 5] |> group == [3]
    @test [1, 3, 4] |> group == [3]
    @test [1, 1, 1, 5] |> group == [4]
    @test [3, 3, 2] |> group == [3]
    @test [5, 3, 2, 6] |> group == [2, 2]
    @test [2, 2, 4, 6, 2] |> group == [3, 2]
    @test [6, 2, 4, 4] |> group == [2, 2]
    @test [2, 6] |> group == [2]
    @test [2, 2, 2, 2, 2, 2, 2, 2] |> group == [4, 4]
    @test [4, 4, 4, 4, 4, 4, 4, 4] |> group == [2, 2, 2, 2]
    @test [4, 4, 5, 3, 4, 4, 5, 3] |> group == [2, 2, 2, 2]
    @test [1, 3, 2, 2] |> group == [4]
    @test [6, 10] |> group == [2]
    @test [5, 3, 5, 3] |> group == [2, 2]
    @test [9, 7] |> group == [2]
    @test [7, 9, 3, 5] |> group == [2, 2]
    @test [10, 6, 4, 4, 6, 5, 3, 3, 5, 3, 5, 2] |> group == [2, 2, 8]
    @test [16, 6, 2, 4, 4] |> group == [1, 2, 2]
    @test [12, 4, 7, 1] |> group == [2, 2]
    @test [4, 4, 10, 6] |> group == [2, 2]
    @test [1, 2, 3, 2] |> group == [4]
    @test [3, 5, 8, 3, 5, 8] |> group == [2, 1, 2, 1]
    @test [8, 24] |> group == [2]
    @test [8, 24, 8] |> group == [1, 2]
    @test [8, 24, 24, 8] |> group == [2, 2]
    @test [24, 8, 8, 24] |> group == [2, 2]
    @test [4, 12, 5, 3, 7] |> group == [2, 2, 1] # auto-padded: (4,12)(5,3)(7) → 16+8+8 = 32 bits
    @test [128] |> group == [1]
    @test_throws ArgumentError [0, 8] |> group

    # `lone` flags fields that must be lone groups regardless of bitsize.
    @test group([4, 4], [false, false]) == [2]
    @test group([4, 4], [true,  false]) == [1, 1]
    @test group([4, 4], [false, true])  == [1, 1]
    @test group([4, 4, 4, 4], [false, true,  false, false]) == [1, 1, 2]
    @test group([4, 4, 4, 4], [false, false, true,  false]) == [2, 1, 1]
    # Two packable runs separated by a lone-flagged field.
    @test group([4, 4, 8, 4, 4], [false, false, true, false, false]) == [2, 1, 2]
end

@emulate Int2 UInt5 Int9
@testset "basics" begin
    @packed struct Foo
        first::Int9
        second::UInt5
        third::Int2
    end

    x = Pack16{Tuple{Int9, UInt5, Int2}}(200 |> Int9, 17 |> UInt5, -1 |> Int2)
    @test x[1] === 200 |> Int9
    @test x[2] === 17 |> UInt5
    @test x[3] === -1 |> Int2
    # The outer struct constructor converts each argument to its field type, so untyped literals work just like for plain (non-`@packed`) structs.
    @test Foo(200, 17, -1) === Foo(Int9(200), UInt5(17), Int2(-1))
end

@testset "zero-field @packed struct" begin
    @packed struct EmptyImm end
    @packed mutable struct EmptyMut end
    @test EmptyImm() isa EmptyImm
    @test EmptyMut() isa EmptyMut
    @test sizeof(EmptyImm) == 0
    @test propertynames(EmptyImm()) === ()
    @test propertynames(EmptyMut()) === ()
    @test_throws ErrorException EmptyMut().bogus = 1
end

@emulate Int4

using BitIntegers
@define_integers 24

struct Wrapper24
    a::UInt24
end
struct Wrapper8
    b::UInt8
end
@testset "wrapper types" begin
    @packed struct WrapperTypes
        c::Wrapper24
        d::Wrapper8
    end
    w = WrapperTypes(Wrapper24(2^18), Wrapper8(17))
    @test w.c === Wrapper24(2^18)
    @test w.d === Wrapper8(17)
end

@emulate UInt3
struct InnerUInt5; a::UInt5 end
struct OuterUInt5; inner::InnerUInt5 end
struct WrapperUInt3; a::UInt3 end
@testset "nested wrapper" begin
    @packed struct NestedWrap
        x::OuterUInt5
        y::WrapperUInt3
    end
    nw = NestedWrap(OuterUInt5(InnerUInt5(7)), WrapperUInt3(2))
    @test nw.x === OuterUInt5(InnerUInt5(7))
    @test nw.y === WrapperUInt3(2)
    @test NestedWrap |> sizeof === 1
    @test fieldtypes(NestedWrap) == (Pack8{Tuple{OuterUInt5, WrapperUInt3}},)
end

struct PlainTwoInt2
    a::Int2
    b::Int2
end
@packed struct PackedTwoInt2
    a::Int2
    b::Int2
end
@testset "plain multi-field inner struct" begin
    @packed struct FourInt2Plain
        x::PlainTwoInt2
        y::PlainTwoInt2
    end
    f = FourInt2Plain(PlainTwoInt2(0, 1), PlainTwoInt2(-2, -1))
    @test f.x === PlainTwoInt2(0, 1)
    @test f.y === PlainTwoInt2(-2, -1)
    @test FourInt2Plain |> sizeof === 1
    @test fieldtypes(FourInt2Plain) == (Pack8{Tuple{PlainTwoInt2, PlainTwoInt2}},)
end

mutable struct MutableInner
    a::Int4
    b::Int4
end
@testset "mutable inner struct stored by reference" begin
    @packed struct OuterWithMutable
        head::Int8
        m::MutableInner
        tail::Int8
    end
    mi = MutableInner(1, -2)
    o = OuterWithMutable(7, mi, -3)
    @test o.head === Int8(7)
    @test o.tail === Int8(-3)
    # Reference equality: the mutable is stored as a pointer, not copied/packed.
    @test o.m === mi
    # The mutable field appears un-wrapped (no `Pack<B>`); `head` and `tail` are not packed together because the mutable splits them into separate runs.
    @test fieldtypes(OuterWithMutable) == (Int8, MutableInner, Int8)
    # Mutating through the original reference is visible through the outer struct.
    mi.a = Int4(3)
    @test o.m.a === Int4(3)
    @test sizeof(o) === 24
end

@testset "nested @packed" begin
    @test bits(PackedTwoInt2) === 4
    @test sizeof(PackedTwoInt2) === 1

    @packed struct FourInt2Packed
        x::PackedTwoInt2
        y::PackedTwoInt2
    end
    f = FourInt2Packed(PackedTwoInt2(0, 1), PackedTwoInt2(-2, -1))
    @test f.x === PackedTwoInt2(0, 1)
    @test f.y === PackedTwoInt2(-2, -1)
    @test FourInt2Packed |> sizeof === 1
    @test fieldtypes(FourInt2Packed) == (Pack8{Tuple{PackedTwoInt2, PackedTwoInt2}},)
end

@testset "two packed runs" begin
    @packed struct TwoPackedFields
        a::UInt3
        b::UInt5
        c::UInt8
        d::UInt3
        e::UInt5
        f::UInt8
    end
    tpf = TwoPackedFields(1, 2, 3, 4, 5, 6)
    @test tpf.a === 1 |> UInt3 && tpf.b === 2 |> UInt5 && tpf.c === 3 |> UInt8 && tpf.d === 4 |> UInt3 && tpf.e === 5 |> UInt5 && tpf.f === 6 |> UInt8
    @test TwoPackedFields |> sizeof === 4
    @test fieldtypes(TwoPackedFields) == (Pack8{Tuple{UInt3, UInt5}}, UInt8, Pack8{Tuple{UInt3, UInt5}}, UInt8)
end

@emulate UInt10
@testset "single Pack32 group" begin
    @packed struct ThreeTens
        a::UInt10
        b::UInt10
        c::UInt10
    end
    t = ThreeTens(1, 2, 3)
    @test t.a === 1 |> UInt10 && t.b === 2 |> UInt10 && t.c === 3 |> UInt10
    @test ThreeTens |> sizeof === 4
    @test fieldtypes(ThreeTens) == (Pack32{Tuple{UInt10, UInt10, UInt10}},)
end

@emulate UInt30 UInt33
@testset "single Pack64 group" begin
    @packed struct WideTwo
        a::UInt33
        b::UInt30
    end
    w = WideTwo(5, 7)
    @test w.a === 5 |> UInt33 && w.b === 7 |> UInt30
    @test WideTwo |> sizeof === 8
    @test fieldtypes(WideTwo) == (Pack64{Tuple{UInt33, UInt30}},)
end

@testset "padding bits are zero" begin
    # Unsigned padded group: ThreeTens packs 3×UInt10 = 30 logical bits into Pack32 with 2 padding bits.
    @test reinterpret(UInt32, getfield(ThreeTens(0, 0, 0), 1)) === 0x00000000
    @test reinterpret(UInt32, getfield(ThreeTens(2^10-1, 2^10-1, 2^10-1), 1)) === 0x3fffffff

    # Mixed signed/unsigned padded group: Int9 + UInt5 = 14 logical bits in Pack16 with 2 padding bits. Negative values exercise that sign-extension on EmulatedBitIntegers does not leak into padding.
    @packed struct PadSigned
        a::Int9
        b::UInt5
    end
    @test reinterpret(UInt16, getfield(PadSigned(0, 0), 1)) === 0x0000
    @test reinterpret(UInt16, getfield(PadSigned(Int9(-1), UInt5(31)), 1)) === 0x3fff

    # Hash/== parity rests on the zero-padding invariant: two independent equal-valued constructions must compare and hash identically.
    @test ThreeTens(2^10-1, 2^10-1, 2^10-1) == ThreeTens(2^10-1, 2^10-1, 2^10-1)
    @test hash(PadSigned(Int9(-1), UInt5(31))) == hash(PadSigned(Int9(-1), UInt5(31)))
end

@emulate UInt22
@testset "propertynames" begin
    @packed struct PropertyNames
        a1::UInt10
        a2::UInt22
        a3::Int8
        a4::Int8
    end
    p = PropertyNames(1, 2, 3, 4)
    @test propertynames(p) == (:a1, :a2, :a3, :a4)
    @test propertynames(p, true) == (:a1, :a2, :a3, :a4, :_packed_fields_1)
end

# Reference: four `Int2` fields directly in a `@packed` struct.
@packed struct FlatFour
    a::Int2
    b::Int2
    c::Int2
    d::Int2
end
@packed struct NestedPlainFour
    p::PlainTwoInt2
    q::PlainTwoInt2
end
@packed struct NestedPackedFour
    p::PackedTwoInt2
    q::PackedTwoInt2
end
# Extract just the function body's IR text, stripped of names/SSA numbers/parameter labels so two functions with the same operation sequence compare equal regardless of which struct they came from.
function normalized_llvm(f, types)
    io = IOBuffer()
    code_llvm(io, f, types; debuginfo=:none, optimize=true)
    s = io |> take! |> String
    # Under `--code-coverage`, every source line is instrumented with an
    # `atomicrmw add` counter increment. A nested accessor spans more source lines
    # than its flat equivalent, so it gets more such increments; dropping them lets
    # the comparison reflect only the computed IR, with or without coverage.
    s = replace(s, r"^.*atomicrmw add ptr inttoptr.*\n"m => "")
    s = replace(s, r"define [^{]*\{" => "define {")
    s = replace(s, r"%\d+" => "%v")
    s = replace(s, r"%\"x::[^\"]+\"" => "%x")
    s = replace(s, r";.*" => "")
    s = replace(s, r"\n\s*\n" => "\n")
    return strip(s)
end
# Flat, nested-plain, and nested-packed accessors compile to identical IR. That
# equality holds only once codegen is optimal, which (as for the `performance
# invariants` testset below) is from Julia 1.11 on.
@static if VERSION >= v"1.11"
@testset "nested-struct getproperty matches flat codegen" begin
    for (flat_acc, nested_acc) in (
        (x -> x.a, x -> x.p.a),
        (x -> x.b, x -> x.p.b),
        (x -> x.c, x -> x.q.a),
        (x -> x.d, x -> x.q.b),
    )
        flat   = normalized_llvm(flat_acc,   (FlatFour,))
        plain  = normalized_llvm(nested_acc, (NestedPlainFour,))
        packed = normalized_llvm(nested_acc, (NestedPackedFour,))
        @test flat == plain
        @test flat == packed
    end
end
end

@testset "odd total byte size" begin
    # Groups are padded to a native size individually, but the overall struct just lays its groups out as regular fields: a 3-byte total is fine and natural here.
    @packed struct ThreeBytes
        a::Int4
        b::Int4
        c::Int8
        d::Int8
    end
    @test sizeof(ThreeBytes) === 3
    @test fieldtypes(ThreeBytes) == (Pack8{Tuple{Int4, Int4}}, Int8, Int8)
    t = ThreeBytes(1, -2, 3, 4)
    @test t.a === Int4(1) && t.b === Int4(-2) && t.c === Int8(3) && t.d === Int8(4)
end

@testset "field wider than 64 bits stays lone" begin
    # `bits(UInt128) == 128` exceeds the largest native pack width (64). The field is kept as a lone group (no `Pack<B>` wrapper) and stored as the field type itself.
    @packed struct Lone128
        x::UInt128
    end
    @test sizeof(Lone128) === 16
    @test fieldtypes(Lone128) == (UInt128,)
    v = UInt128(2)^100
    @test Lone128(v).x === v
end

@emulate Int6 Int5
@testset "constructors" begin
    @testset "outer constructors defined after the `@packed` block" begin
        @packed struct Range6
            lo::Int6
            hi::Int6
        end
        Range6(both::Integer) = Range6(both, both)
        Range6(t::Tuple) = Range6(t...)

        r = Range6(5)
        @test r.lo === Int6(5) && r.hi === Int6(5)

        r2 = Range6((1, 7))
        @test r2.lo === Int6(1) && r2.hi === Int6(7)

        # Auto-generated all-fields constructor still works alongside user ones.
        r3 = Range6(2, 3)
        @test r3.lo === Int6(2) && r3.hi === Int6(3)
    end

    @testset "user inner constructors with `new`" begin
        # Inner constructor across a grouped pair: `new(a, b)` should be rewritten to `new(Pack8(convert(Int5, a), convert(UInt3, b)))`.
        @packed struct Pair53
            a::Int5
            b::UInt3
            Pair53(a) = new(a, 2a)
            function Pair53(a, b)
                a > 0 || "a must be positive" |> error
                return new(a, b)
            end
        end
        # The rewrite actually packs the two fields into a single Pack8 (size 1 byte rather than 2 for an unpacked struct of the same shape).
        @test sizeof(Pair53) === 1
        @test fieldtypes(Pair53) == (Pack8{Tuple{Int5, UInt3}},)
        p1 = Pair53(3)
        @test p1.a === Int5(3) && p1.b === UInt3(6)
        p2 = Pair53(1, 4)
        @test p2.a === Int5(1) && p2.b === UInt3(4)
        @test_throws ErrorException Pair53(-1, 0)

        # Inner constructor across mixed groups: one Pack8 pair followed by a lone Int8. `new(t...)` exercises the splat path: arity is checked at runtime through a tuple materialization.
        @packed struct Mixed
            a::Int5
            b::UInt3
            c::Int8
            Mixed(t::Tuple) = new(t...)
        end
        # `a` and `b` are packed into a single Pack8; `c` stays lone. Verifies the splat-rewrite splits the runtime tuple across groups correctly, which a plain struct of the same shape wouldn't do.
        @test sizeof(Mixed) === 2
        @test fieldtypes(Mixed) == (Pack8{Tuple{Int5, UInt3}}, Int8)
        m = Mixed((1, 2, -3))
        @test m.a === Int5(1) && m.b === UInt3(2) && m.c === Int8(-3)
        @test_throws ErrorException Mixed((1, 2))
        # Default convert-doing outer is suppressed when the user provides any inner constructor (mirroring Julia for non-packed structs).
        @test_throws MethodError Mixed(1, 2, -3)
    end

    @testset "inner-constructor rewriting rejects bad `new` forms" begin
        # Wrong arity to `new`.
        @test_throws ErrorException @macroexpand @packed struct BadArity
            a::Int6
            b::Int6
            BadArity() = new()
        end
    end
end

@testset "setproperty!" begin
    @testset "on mutable @packed" begin
        @packed mutable struct MutTriple
            a::Int4
            b::Int4
            c::Int8
        end
        m = MutTriple(1, 2, 3)
        # Grouped write updates only the targeted slot.
        m.a = 5
        @test m.a === Int4(5) && m.b === Int4(2) && m.c === Int8(3)
        m.b = -3
        @test m.a === Int4(5) && m.b === Int4(-3) && m.c === Int8(3)
        # Lone write works.
        m.c = 99
        @test m.a === Int4(5) && m.b === Int4(-3) && m.c === Int8(99)
        # Conversion via `convert(T, v)` happens on the write path.
        m.a = 0x01
        @test m.a === Int4(1)
        # Unknown field raises.
        @test_throws ErrorException setproperty!(m, :nope, 0)
    end

    @testset "respects `const` fields" begin
        @packed mutable struct MutWithConst
            const a::Int4
            b::Int4
        end
        m = MutWithConst(1, 2)
        m.b = -1
        @test m.b === Int4(-1)
        @test_throws ErrorException m.a = Int4(3)
    end

    @testset "errors on immutable @packed" begin
        @packed struct ImmPair
            a::Int4
            b::Int4
        end
        p = ImmPair(1, 2)
        @test_throws ErrorException p.a = Int4(3)
    end
end

# Capture LLVM IR of `f(::types...)` and return the lines containing actual operations: drop preamble (`define`/`declare`), labels, braces, comments, blank lines, the trailing `ret` (bookkeeping, not an operation — when the caller inlines `f`, only the operation lines remain), and `--code-coverage` counter increments (`atomicrmw add` into a fixed pointer) so the count is the same with or without coverage instrumentation.
function llvm_ops(f, types)
    io = IOBuffer()
    InteractiveUtils.code_llvm(io, f, types; debuginfo=:none, raw=false)
    lines = split(io |> take! |> String, "\n")
    filter(lines) do l
        !contains(l, r"^\s*($|;|define|declare|\}|\{\s*$|.+:\s*$|ret\b)") &&
            !contains(l, "atomicrmw add ptr inttoptr")
    end
end

# A `call` instruction targeting an LLVM intrinsic (`@llvm.ctpop`, `@llvm.memcpy`, …) is a single native instruction, not a runtime dispatch. Only flag calls into Julia runtime functions (`@j_*`, `@julia_*`, `@ijl_*`, `@jl_*`).
runtime_calls(ops) = count(l -> occursin("call ", l) && !occursin("@llvm.", l), ops)

@packed struct PerfImm
    a::Int4
    b::Int4
    c::Int8
end
@packed mutable struct PerfMut
    a::Int4
    b::Int4
    c::Int8
end
@packed struct PerfInnerPacked
    a::Int2
    b::Int2
end
@packed struct PerfNested
    p::PerfInnerPacked
    q::PerfInnerPacked
end

# Counts depend on several optimizations done in Julia and especially LLVM. The code seems to be optimum starting from Julia 1.11.
@static if VERSION >= v"1.11"
@testset "performance invariants" begin
    using InteractiveUtils

    read_a(x)       = x.a
    read_c(x)       = x.c
    read_pa(x)      = x.p.a
    write_a!(x, v)  = (x.a = v)
    write_c!(x, v)  = (x.c = v)
    build_imm(a, b, c) = PerfImm(a, b, c)

    # `(label, f, types, exact_ops)`. Counts are exact (calibrated on Julia 1.12.6 and 1.13.0-rc1; both produce identical IR). Any drift — up or down — is a regression worth investigating, so use `==` rather than `<=`. Mutable construction is excluded: it necessarily allocates (`@jl_gc_*` runtime call), which is the whole point of a mutable struct, not a regression to guard against.
    cases = [
        ("read grouped field",        read_a,    Tuple{PerfImm},          2),
        ("read lone field",           read_c,    Tuple{PerfImm},          2),
        ("read nested grouped field", read_pa,   Tuple{PerfNested},       2),
        ("write grouped field",       write_a!,  Tuple{PerfMut, Int4},    5),
        ("write lone field",          write_c!,  Tuple{PerfMut, Int8},    2),
        ("construct immutable",       build_imm, Tuple{Int4, Int4, Int8}, 5),
    ]

    for (label, f, types, exact_ops) in cases
        ops = llvm_ops(f, types)
        # No dispatch into runtime helpers — every operation must lower to native instructions or LLVM intrinsics. Also rules out allocations, which would surface as `@jl_gc_*` calls.
        @test runtime_calls(ops) == 0
        # Exact op count — any drift (up or down) signals a codegen change worth a look.
        VERSION >= v"1.11" && @test length(ops) == exact_ops
    end
end
end

"DocStruct top-level docstring"
@packed struct DocStruct
    "first grouped field"
    a::Int4
    "second grouped field"
    b::Int4
    "lone field doc"
    c::Int8
end

@testset "docstring and stacktrace preservation" begin
    # Struct-level docstring attaches to the type itself via `Core.@__doc__`, not the surrounding `begin…end` block.
    @test occursin("DocStruct top-level docstring", string(@doc DocStruct))
    # Per-field docs land in the struct's `DocStr.data[:fields]`. Grouped public fields no longer exist as Julia fields, so their docs are re-registered via `define_field_docs`; lone fields take the normal struct codegen path.
    fields = Base.Docs.meta(@__MODULE__)[Base.Docs.Binding(@__MODULE__, :DocStruct)].docs[Union{}].data[:fields]
    @test fields[:a] == "first grouped field"
    @test fields[:b] == "second grouped field"
    @test fields[:c] == "lone field doc"
    # `linewrap!` puts a `LineNumberNode` inside each generated method body so stack traces and `@which` point at the `@packed` call site rather than `none:?`.
    for m in (first(methods(Base.getproperty, Tuple{DocStruct, Symbol})),
              first(methods(Base.propertynames, Tuple{DocStruct})),
              first(methods(Base.setproperty!, Tuple{DocStruct, Symbol, Any})))
        @test occursin("runtests.jl", string(m.file))
        @test m.line > 0
    end
end

@packed struct AccImm
    a::Int4
    b::Int4
    c::Int8
end
@packed mutable struct AccMut
    a::Int4
    b::Int4
    c::Int8
end
@packed struct AccOuter
    head::Int8
    inner::AccImm
end
@packed struct AccEmpty end
@testset "Accessors / ConstructionBase" begin
    x = AccImm(1, 2, 3)
    # `getproperties` is keyed by user-visible field names, not the underlying `_packed_fields_N` storage slot.
    @test ConstructionBase.getproperties(x) === (a=Int4(1), b=Int4(2), c=Int8(3))
    @test ConstructionBase.constructorof(AccImm) === AccImm

    # `@set` on a grouped field rebuilds the `Pack<B>` slot with the new value; other group members stay.
    y = @set x.a = -3
    @test y === AccImm(-3, 2, 3)
    @test x === AccImm(1, 2, 3)  # original untouched

    # `@set` on the lone field doesn't touch the packed group.
    @test (@set x.c = 9) === AccImm(1, 2, 9)

    # Untyped RHS goes through the outer constructor's `convert`, just like direct construction.
    @test (@set x.b = 5) === AccImm(1, 5, 3)

    # Mutating accessor on a mutable still produces a fresh object (Accessors semantics).
    m = AccMut(1, 2, 3)
    @reset m.a = 7
    @test m.a === Int4(7) && m.b === Int4(2) && m.c === Int8(3)

    # Nested `@set` through a `@packed` field of another `@packed` struct.
    o = AccOuter(10, AccImm(1, 2, 3))
    @test (@set o.inner.a = -1) === AccOuter(10, AccImm(-1, 2, 3))
    @test (@set o.head = 20)    === AccOuter(20, AccImm(1, 2, 3))

    # Zero-field `@packed` struct: empty NamedTuple round-trips through `getproperties`/`setproperties`.
    @test ConstructionBase.getproperties(AccEmpty()) === NamedTuple()
    @test ConstructionBase.setproperties(AccEmpty(), NamedTuple()) === AccEmpty()
end

include("Aqua.jl")