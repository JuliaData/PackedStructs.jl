"Allocate a zero-initialized `Memory{T}` of length `n`."
zeromem(::Type{T}, n::Integer) where T = fill!(Memory{T}(undef, n), zero(T))

"""
Smallest entry of `NATIVE_SIZES` at least as large as `n`, or `n` itself if it exceeds all of them.
"""
function nextnative(n::Integer)
    for s in NATIVE_SIZES
        n <= s && return s
    end
    return n
end

"Consecutive ranges with the given `lengths`, starting at 1."
ranges(lengths::AbstractVector{<:Integer}) = accumulate((prev, len) -> (p = last(prev))+1 : p+len, lengths; init=0:0)

"""
    group(bitsizes, lone=zeromem(Bool, length(bitsizes)))

Return the length of the groups of the grouped bitsizes.

The grouping is done according to the following requirements
- Native sizes are 8, 16, 32 and 64 bits. These are the register sizes which allow fast bit-wise operations.
- The bitsizes of the fields are a sequence of positive integers.
- Bitsizes above `MAX_NATIVE_SIZE` are allowed but force the field to be a lone group (it cannot fit any native primitive).
- A field flagged as `lone` is always a lone group regardless of its bitsize. Used for field types that can't share a packed primitive with anything else (e.g. references stored by a mutable struct field).
- Consecutive elements can be grouped together.
- A group's size is the smallest native size at least as large as the sum of the bitsizes in the group. The difference is padding.
- If a field is larger than the largest native size, it builds a single group and keeps its size.
- All elements must be part of a group.
- Among all groupings, we pick the one with the smallest total size; among those, the one with the most groups.
"""
function group(bitsizes::AbstractVector{Int}, lone::AbstractVector{Bool} = zeromem(Bool, length(bitsizes)))::AbstractVector{Int}
    all(>=(1), bitsizes) || "Field bit sizes must be positive integers." |> ArgumentError |> throw

    nfields = length(bitsizes)
    # [Dynamic-programming](https://en.wikipedia.org/wiki/Dynamic_programming) tables indexed by `i`, where each entry describes the best grouping of the tail `bitsizes[i:nfields]`. `ngroups[i]` is the number of groups in that grouping, `paddedbits[i]` its total padded bit size, and `headlength[i]` the length of its first (head) group (used for reconstruction after the loop). "Best" means minimum `paddedbits`, breaking ties by maximum `ngroups`.
    # `ngroups` and `paddedbits` get one extra slot at index `nfields+1` representing the empty suffix 0. This lets the inner loop read `paddedbits[i+k]` and `ngroups[i+k]` unconditionally when a candidate group reaches the end (`i+k = nfields+1`), avoiding a branch. `headlength` doesn't need this sentinel: the `k = 1` candidate always accepts, so every `headlength[i]` for `i in 1:nfields` is written before any read.
    ngroups = zeromem(Int, nfields+1)
    paddedbits = zeromem(Int, nfields+1)
    headlength = Memory{Int}(undef, nfields)

    for i in nfields:-1:1 # `i` is the tail start: we solve the subproblem for `bitsizes[i:nfields]`.
        bitsize = 0
        for k in 1:nfields-i+1 # `k` is the candidate head-group length, covering `bitsizes[i : i+k-1]`.
            bitsize += bitsizes[i+k-1] # running sum of `bitsizes[i : i+k-1]`
            # No larger `k` fits as a packable group; `k == 1` stays valid as a lone group regardless of size or lone-ness. The lone checks cover the head (`lone[i]`) and tail (`lone[i+k-1]`) of the candidate group; together with the inductive invariant that all interior fields were already accepted at smaller `k`, this rejects any candidate group containing a lone-flagged field.
            k > 1 && (bitsize > MAX_NATIVE_SIZE || lone[i] || lone[i+k-1]) && break
            newpaddedbits = nextnative(bitsize) + paddedbits[i+k]
            newgroups = ngroups[i+k] + 1
            # Discard unless first candidate, or strictly fewer padded bits, or same padded bits with more groups.
            ngroups[i] == 0 || newpaddedbits < paddedbits[i] || newpaddedbits == paddedbits[i] && newgroups > ngroups[i] || continue
            paddedbits[i] = newpaddedbits
            ngroups[i] = newgroups
            headlength[i] = k
        end
    end

    # Reconstruct the chosen grouping by following `headlength` forward from index 1.
    lengths = Memory{Int}(undef, ngroups[1])
    pos = 1
    for j in eachindex(lengths)
        pos += lengths[j] = headlength[pos]
    end
    return lengths
end

function group(s::JLStruct)
    isempty(s.fields) && return PackedFields[]
    # Mutable field types are heap-allocated boxes: the value stored in the parent is a pointer, not the inner bits. Packing a pointer alongside other fields' bits inside an opaque `Pack<B>` primitive would hide it from GC tracing. Flag each mutable as lone so the DP isolates it.
    lone = [f.type |> ismutabletype for f in s.fields]
    bitsizes = [l ? 8 * sizeof(Ptr) : bits(f.type) for (f, l) in zip(s.fields, lone)]
    group_lengths = group(bitsizes, lone)

    return [PackedFields(s.fields[range], sum(@view bitsizes[range]) |> nextnative) for range in ranges(group_lengths)]
end
