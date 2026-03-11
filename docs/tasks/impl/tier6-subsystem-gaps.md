# Tier 6: Subsystem specification gaps

## Gaps to fill

### 1. Type classes (subsystems/18-type-classes.md)

- **Specificity comparison algorithm**: define `more_specific(inst_a, inst_b)` — attempt to unify A's head with B's head. If unification succeeds with B's variables as the flex side, A is more specific. If neither direction succeeds, they're incomparable.
- **Search depth counting**: depth increments on each recursive constraint resolution. Depth is per top-level search, not per constraint.
- **Default method implementation**: self-referential dictionaries are constructed in two passes. Pass 1: allocate struct with placeholders. Pass 2: fill in methods that reference the dictionary via the struct reference. In Elixir codegen, this is a simple `%EqDict{eq: fn(x, y) -> ... end}` — no laziness needed because Elixir closures capture by reference.
- **Instance database scoping**: instances from imported modules are added to the local instance database. Diamond imports: an instance from A is added once even if A is imported through B and C.
- **dict_builder type**: `dict_builder` takes a list of sub-dictionaries (one per instance constraint) and returns the dictionary value. Arity = length of constraints list.

### 2. Codegen extensions (subsystems/09-codegen.md)

- **Dictionary passing codegen**: add compilation rules for dictionary struct construction, field access, and instance argument passing
- **Dictionary inlining**: when the dictionary is a compile-time constant (solved implicit), inline field accesses to direct function calls
- **Protocol bridge codegen**: add `defprotocol` and `defimpl` generation rules

## Deliverable

Updated subsystem docs 18 and 09.
