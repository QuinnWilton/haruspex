# D10: One roux entity per top-level definition

**Decision**: Each top-level definition is a roux entity with identity `[:uri, :name]`, enabling field-level change tracking.

**Rationale**: Field-level change tracking is the key to precise incrementality. When only a function's body changes (but its type signature doesn't), downstream queries that depend only on the type are not re-executed. This is the "early cutoff" optimization in roux. Using `[:uri, :name]` as identity (rather than just `[:name]`) avoids collisions across files -- a bug Lark encountered with `[:name]`-only identity.

**Mechanism**: The parse query creates `Haruspex.Definition` entities with fields: `:type` (the declared type annotation), `:body` (the function body AST), `:total?` (whether `@total` is present), `:erased_params` (list of 0-multiplicity parameter indices). Downstream queries read individual fields, so a body-only edit doesn't invalidate the type-check of dependents that only read the type field.

See [[../subsystems/15-queries]].
