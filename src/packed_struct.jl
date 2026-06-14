# Build the value expression for one slot in the rewritten `new(...)` call: `convert(T, v)` for a lone `pf`, or `Pack<B>(convert(T1, v1), …)` for a grouped one. `values` is one expression per user-visible field in `pf`.
function call_constructor(pf::APackedFields, values)
    args = (:(convert($(f.type), $v)) for (f, v) in zip(pf.fields, values))
    return length(pf) == 1 ? first(args) : Expr(:call, packtype(pf), args...)
end

build_packed_args(pfs, value_at) = [call_constructor(pf, (value_at(j) for j in r)) for (pf, r) in zip(pfs, ranges(length.(pfs)))]

# All `new` args are simple positional expressions: arity is known at macro time, split values per group and build the rewritten `new` call directly.
function rewrite_new_simple(values, pfs, n_public_fields)
    length(values) == n_public_fields || lazy"Expected $n_public_fields arguments to `new` (one per user-visible field), got $(length(values))." |> error
    return Expr(:call, :new, build_packed_args(pfs, i -> values[i])...)
end

# At least one `new` arg is splatted: materialize all values into a tuple at runtime via `tuple(values...)`, check the resulting length, then index per group. Mirrors how `Foo(x) = new(x...)` works for a non-packed struct.
function rewrite_new_splat(values, pfs, n_public_fields)
    tup = gensym(:newvals)
    err_prefix = "Expected $n_public_fields arguments to `new` (one per user-visible field), got "
    return quote
        $tup = tuple($(values...))
        length($tup) == $n_public_fields || error($err_prefix, length($tup), ".")
        $(Expr(:call, :new, build_packed_args(pfs, i -> :($tup[$i]))...))
    end
end

# Recursively rewrite every `new(v1, ..., vN)` call in `ex` into `new(packed_args...)` matching the rewritten field layout. The user writes `new` with one value per user-visible field, exactly as they would for a non-packed struct; we group the values per `pf` and wrap each group through `call_constructor`. Splatted forms like `new(x...)` are materialized through `tuple(...)` so the arity check happens at runtime.
rewrite_new(ex, _, _) = ex
function rewrite_new(ex::Expr, pfs, n_public_fields)
    if ex.head === :call && !isempty(ex.args) && ex.args[1] === :new
        values = [rewrite_new(a, pfs, n_public_fields) for a in ex.args[2:end]]
        return any(a -> a isa Expr && a.head === :..., values) ?
            rewrite_new_splat(values, pfs, n_public_fields) :
            rewrite_new_simple(values, pfs, n_public_fields)
    end
    return Expr(ex.head, (rewrite_new(a, pfs, n_public_fields) for a in ex.args)...)
end

function define_packed_struct!(s, pfs::Vector{<:APackedFields}, atype)
    s.typevars |> isempty || "Type variables in packed structs are not supported yet" |> error

    n_public_fields = sum(length, pfs; init=0)
    for c in s.constructors
        c.body = rewrite_new(c.body, pfs, n_public_fields)
    end

    s.supertype = atype

    # `i` indexes both `pfs` and `s.fields`: each grouped iteration deletes `length(pf)-1` entries from `s.fields`, so the next `pf` lines up with `s.fields[i+1]` in the shrunk vector.
    for (i, pf) in enumerate(pfs)
        isgroup(pf) || continue
        i_end = i + length(pf) - 1
        s.fields[i].name = Symbol("_packed_fields_", i)
        s.fields[i].type = packtype(pf)
        s.fields[i].isconst = all(f -> f.isconst, s.fields[i:i_end])
        # Drop the leading field's docstring so it doesn't get re-attributed to the private storage field. Public-field docs for grouped fields are reinjected into the struct's `DocStr` after the struct is defined (see `define_field_docs`); `line` is kept and points exactly at the first user-written field of the group.
        s.fields[i].doc = nothing
        deleteat!(s.fields, i+1 : i_end)
    end

    return s
end

# Flat iterator over the user-visible `Field`s across all groups, in source order.
publicfields(pfs) = (f for pf in pfs for f in pf.fields)

# Define an untyped outer constructor that converts each argument to its field type before forwarding to the group constructor. This mirrors the default constructor Julia normally defines.
function define_constructor(pfs::Vector{<:APackedFields}, name)
    args = [f.publicname for f in publicfields(pfs)]
    body = Expr(:call, name, (call_constructor(pf, (f.publicname for f in pf.fields)) for pf in pfs)...) |> inline
    return JLFunction(; name, args, body)
end

function define_propertynames(pfs::Vector{<:APackedFields}, atype)
    args = [:(x::$atype), Expr(:kw, :(private::Bool), false)]
    publics = Tuple(f.publicname for f in publicfields(pfs))
    privates = (Symbol("_packed_fields_", i) for (i, pf) in enumerate(Iterators.filter(isgroup, pfs))) |> Tuple
    body = :(private ? $((publics..., privates...)) : $publics) |> inline
    JLFunction(name=:(Base.propertynames); args, body)
end

function define_getproperty(pfs::Vector{<:APackedFields}, atype)
    args = [:(x::$atype), :(s::Symbol)]
    getters = Iterators.flatmap(enumerate(pfs)) do (i, pf)
        if isgroup(pf)
            return (:(s === $(f.publicname |> QuoteNode) && return getfield(x, $i)[$j]) for (j, f) in enumerate(pf.fields))
        else
            # Use an unnecessary loop to get the same type as above for type-stable flattening.
            return (:(s === $(f.publicname |> QuoteNode) && return getfield(x, s)) for f in pf.fields)
        end
    end
    body = Expr(:block, getters...) |> inline
    JLFunction(name=:(Base.getproperty); args, body)
end

# Branch body for one public field in `setproperty!`: const fields error with the field name; lone fields fall through to `setfield!` (compiler folds this to the default after constant prop on `s`); grouped fields rebuild the `Pack<B>` slot with one entry replaced — repeated `getfield(x, $g)[k]` decodes the same loaded packed primitive, so CSE collapses the cost to a few bitmask ops.
function set_branch(g::Int, pf::APackedFields, j::Int, f::Field)
    qn = f.publicname |> QuoteNode
    # Mimic Julia's own const-write message verbatim so user-level error handling behaves identically across plain and `@packed` mutable structs.
    f.isconst && return :(s === $qn && error("setfield!: const field .", s, " of type ", typeof(x), " cannot be changed"))
    isgroup(pf) || return :(s === $qn && return setfield!(x, s, convert($(f.type), v)))
    pack_args = (k == j ? :(convert($(pf.fields[k].type), v)) : :(getfield(x, $g)[$k]) for k in 1:length(pf))
    return :(s === $qn && return setfield!(x, $g, $(Expr(:call, packtype(pf), pack_args...))))
end

function define_setproperty(pfs::Vector{<:APackedFields}, atype, ismutable::Bool)
    args = [:(x::$atype), :(s::Symbol), :v]
    if !ismutable
        body = :(error("setfield!: immutable struct of type ", typeof(x), " cannot be changed")) |> inline
        return JLFunction(name=:(Base.setproperty!); args, body)
    end
    setters = Iterators.flatmap(enumerate(pfs)) do (g, pf)
        return (set_branch(g, pf, j, f) for (j, f) in enumerate(pf.fields))
    end
    body = Expr(:block, setters..., :(error("type ", typeof(x), " has no field ", s))) |> inline
    return JLFunction(name=:(Base.setproperty!); args, body)
end

# Print as `TypeName(v1, v2, …)` driven by `propertynames` so grouped fields appear under the names the user wrote rather than the `_packed_fields_N` storage slots. Only defined when grouping actually happened; otherwise Julia's `show_default` already produces the same output via `fieldnames`.
function define_show(pfs::Vector{<:APackedFields}, atype)
    args = [:(io::IO), :(x::$atype)]
    body = Expr(:block, :(show(io, typeof(x))), :(print(io, '(')))
    for (i, f) in enumerate(publicfields(pfs))
        i == 1 || push!(body.args, :(print(io, ", ")))
        push!(body.args, :(show(io, getproperty(x, $(f.publicname |> QuoteNode)))))
    end
    push!(body.args, :(print(io, ')')))
    JLFunction(name=:(Base.show); args, body=inline(body))
end

# `ConstructionBase.getproperties(x)` defaults to one entry per `fieldname`, which would show the private `_packed_fields_N` storage slots. We override it to return a NamedTuple keyed by `propertynames` in constructor-argument order. `ConstructionBase.setproperties` also has to be overridden: its default `setproperties_object` refuses to run when `propertynames` differs from `fieldnames` (it can't safely guess the right constructor call). The override rebuilds the struct through the outer constructor `@packed` defines, which is the same path direct construction and `setproperty!` use. `cb` is the loaded `ConstructionBase` module (spliced as a value so the method definitions resolve without the caller importing `ConstructionBase`).
function define_constructionbase_methods(cb::Module, pfs::Vector{<:APackedFields}, atype, structname::Symbol, src::LineNumberNode)
    # `Expr(:tuple, Expr(:parameters, kw...))` is the AST for the surface form `(; a=…, b=…)`, which evaluates to a `NamedTuple` for any number of `kw` entries — including zero, where it produces `NamedTuple()` rather than the empty `Tuple` that `Expr(:tuple)` alone would yield. This keeps the override valid for zero-public-field `@packed` structs without a special case.
    nt = Expr(:tuple, Expr(:parameters, (Expr(:kw, f.publicname, :(x.$(f.publicname))) for f in publicfields(pfs))...))
    getproperties = Expr(:., cb, QuoteNode(:getproperties))
    setproperties = Expr(:., cb, QuoteNode(:setproperties))

    f_getproperties = Expr(:function,
                Expr(:call, getproperties, :(x::$atype)),
                Expr(:block, src, Expr(:meta, :inline), nt))

    # Splatting a NamedTuple iterates its values in declaration order, matching the outer constructor's argument order. An extra key in `patch` (i.e. not a public field) survives the `merge` and lands as a surplus positional argument, which the constructor rejects with a `MethodError` — same observable behavior as the ConstructionBase default for non-packed structs with an unknown patch key.
    f_setproperties = Expr(:function,
                Expr(:call, setproperties, :(x::$atype), :(patch::NamedTuple)),
                Expr(:block, src, Expr(:meta, :inline),
                     :($structname(merge($getproperties(x), patch)...))))

    return Expr(:block, f_getproperties, f_setproperties)
end

# Prepend a `LineNumberNode` to the function's body so stack traces and `@which` point at the `@packed` call site rather than `none:?`. The outer block's line nodes don't transfer into nested function defs — the line node must sit inside the function body.
linewrap!(jlf::JLFunction, src::LineNumberNode) = (jlf.body = Expr(:block, src, jlf.body); jlf)

# Collect public-field docstrings for fields that are about to be collapsed into a private storage slot. Lone fields keep their docstrings via the normal struct codegen path; grouped public fields no longer exist as Julia fields, so their docs must be re-registered explicitly (see `define_field_docs`).
function grouped_field_docs(s, pfs::Vector{<:APackedFields})
    docs = Dict{Symbol, Any}()
    i = 1
    for pf in pfs
        if isgroup(pf)
            for k in 1:length(pf)
                f = s.fields[i + k - 1]
                f.doc === nothing || (docs[f.name] = f.doc)
            end
        end
        i += length(pf)
    end
    return docs
end

# Register `docs` (a `name => docstring` dict) as per-field documentation on `name`'s `Base.Docs.MultiDoc` entry. Mirrors how Julia's own struct lowering populates `DocStr.data[:fields]`. Creates an empty-summary `DocStr` if no user-level docstring is attached, so `?Name` still renders the field docs.
function define_field_docs(name::Symbol, docs::Dict{Symbol, Any})
    isempty(docs) && return nothing
    return quote
        let b = Base.Docs.Binding(@__MODULE__, $(QuoteNode(name))),
            md = get!(Base.Docs.MultiDoc, Base.Docs.meta(@__MODULE__), b)
            if haskey(md.docs, Union{})
                merge!(get!(Dict{Symbol, Any}, md.docs[Union{}].data, :fields), $docs)
            else
                push!(md.order, Union{})
                md.docs[Union{}] = Base.Docs.DocStr(Core.svec(), nothing, Dict{Symbol, Any}(:fields => $docs))
            end
        end
    end
end

function create_packed_struct!(exprs, s, pfs::Vector{<:APackedFields}, source::LineNumberNode)
    atype = Symbol("A", s.name)
    supertype = something(s.supertype, :Any)
    push!(exprs, :(abstract type $atype <: $supertype end))

    field_docs = grouped_field_docs(s, pfs)

    # Mirror Julia: when the user provides any inner constructor, both the default inner *and* the default convert-doing outer are suppressed; the user is responsible for whichever constructors they want.
    # Wrap the struct in `Core.@__doc__` so a docstring on the `@packed struct` form attaches to the struct itself rather than the surrounding `begin…end` block (which `@doc` can't document).
    push!(exprs, :(Core.@__doc__ $(define_packed_struct!(s, pfs, atype) |> codegen_ast)))
    fd = define_field_docs(s.name, field_docs)
    isnothing(fd) || push!(exprs, fd)
    # When no grouping happened, the struct fields match the user-written ones and Julia's auto-generated outer has the same `(Any, …)` signature as ours — defining ours would overwrite it for no gain.
    isempty(s.constructors) && any(isgroup, pfs) && push!(exprs, linewrap!(define_constructor(pfs, s.name), source) |> codegen_ast)
    push!(exprs, linewrap!(define_propertynames(pfs, atype), source) |> codegen_ast)
    push!(exprs, linewrap!(define_getproperty(pfs, atype), source) |> codegen_ast)
    push!(exprs, linewrap!(define_setproperty(pfs, atype, s.ismutable), source) |> codegen_ast)
    # Skip when no grouping happened: `show_default` already prints the user-written field names since `fieldnames` matches.
    any(isgroup, pfs) && push!(exprs, linewrap!(define_show(pfs, atype), source) |> codegen_ast)
    hasmethod(constructionbase_module, Tuple{}) &&
        push!(exprs, define_constructionbase_methods(constructionbase_module(), pfs, atype, s.name, source))
end

function parse_struct(ex::Expr, m::Module)
    s = JLStruct(ex)
    # `JLStruct` keeps each field's type as the raw expression the user wrote (`Symbol`, qualified `Foo.Bar`, parametric `Vector{Int}`, …). Resolve it to the actual type so we can query its size.
    for f in s.fields
        f.type = Core.eval(m, f.type)
    end
    return s
end

function packed(ex::Expr, m::Module, source::LineNumberNode)
    s = parse_struct(ex, m)
    pfs = group(s)

    block = Expr(:escape, Expr(:block))
    exprs = block.args[1].args

    create_packed_fields!(exprs, pfs, source)
    create_packed_struct!(exprs, s, pfs, source)

    return block
end