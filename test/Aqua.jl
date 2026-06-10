using Aqua

@testset "Aqua.jl" begin
    # Deactivate Aqua tests on Julia 1.10 until EmulatedBitIntegers.jl is registered in the General registry.
    VERSION >= v"1.11" && Aqua.test_all(PackedStructs)
end