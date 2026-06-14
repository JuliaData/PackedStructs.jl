module PackedStructsConstructionBaseExt

using PackedStructs: PackedStructs
using ConstructionBase: ConstructionBase

# Signals to `@packed` (via `PackedStructs.constructionbase_module`) that `ConstructionBase` is available, so the macro registers per-struct `ConstructionBase.getproperties` methods at expansion time. Each `@packed` invocation after this method is in effect picks it up; structs defined before `ConstructionBase` was loaded are not retroactively patched.
PackedStructs.constructionbase_module() = ConstructionBase

end
