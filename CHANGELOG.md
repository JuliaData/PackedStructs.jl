# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.3.2]: https://github.com/PatrickHaecker/PackedStructs.jl/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/PatrickHaecker/PackedStructs.jl/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/PatrickHaecker/PackedStructs.jl/releases/tag/v0.3.0
