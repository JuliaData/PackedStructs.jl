# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Breaking:** require `EmulatedBitIntegers` 0.6, where `bits(Bool) == 1`. A `Bool` field now contributes 1 bit instead of 8 to its group. This can change `sizeof` and field layout, including for nested structs. A `Bool` in a group by itself still occupies one byte.

### Fixed

- A `Bool` field that shares a group with other fields no longer throws `bitcast: argument size does not match size of target type` on construction.
- A `Pad` field that ends up alone in its group now occupies the group's native width. Previously its bits were dropped, the outer constructor required a `Pad` argument, and two such pads failed with a duplicate field name `_`.
- `Pad{N}` with `N > 64` now throws an `ArgumentError` at macro expansion instead of silently occupying no bits.
- `propertynames(x, true)` no longer lists internal storage slots. `getproperty` throws a field error for internal storage slots and unknown property names.

## [0.3.2] - 2026-09-21

### Changed

- Allow `EmulatedBitIntegers` 0.5 alongside 0.4.

## [0.3.1] - 2026-06-29

### Added

- `Pad{N}` field type for explicit padding. A `_::Pad{N}` field reserves `N` zero bits in the layout and is hidden from the constructor, `propertynames`, `getproperty`/`setproperty!` and `show`.

## [0.3.0] - 2026-06-25

Initial release of `PackedStructs` as a standalone package, extracted from a monorepo.

### Added

- `@packed` macro that lays out struct fields without padding between them, grouping them into native-sized primitives.
- `pack` as the documented extension point for teaching `@packed` about non-`Integer` primitive types.
- `Base.setindex`-style immutable field replacement and `setproperty!` for mutable packed structs.
- `Accessors.jl` support through a `ConstructionBase` package extension.
- Precompilation of the common code paths via `PrecompileTools`.

[Unreleased]: https://github.com/PatrickHaecker/PackedStructs.jl/compare/v0.3.2...HEAD
[0.3.2]: https://github.com/PatrickHaecker/PackedStructs.jl/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/PatrickHaecker/PackedStructs.jl/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/PatrickHaecker/PackedStructs.jl/releases/tag/v0.3.0
