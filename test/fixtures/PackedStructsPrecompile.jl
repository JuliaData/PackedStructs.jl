module PackedStructsPrecompile

using PackedStructs: @packed, Pad

@packed struct PaddedFlag
    flag::Bool
    _::Pad{7}
end

@packed mutable struct PaddedPair
    first::Bool
    second::Bool
    _::Pad{8}
end

@assert PaddedFlag(1).flag === true
@assert (PaddedPair(1, 0).first, PaddedPair(1, 0).second) === (true, false)

end
