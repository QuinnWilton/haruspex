# Tier 5: Subsystem specification gaps

## Gaps to fill

### 1. ADTs (subsystems/12-adts.md)

- **Nested positivity**: the simplified `check_strictly_positive` returns `:ok` for nested types. Specify the full algorithm: when type `T` appears as a parameter to another type `F(T)`, check that `F` is strictly positive in that parameter position. For now, accept only if `T` doesn't appear in a negative (function domain) position within `F`'s definition.
- **GADT support boundary**: explicitly state that GADTs (constructors with different return type indices) ARE supported — this is required for `Vec` and `Fin`. The case tree compilation handles index unification at each split.
- **Universe level computation**: specify the algorithm for computing the universe level of an ADT from its parameters and constructor fields.

### 2. Records (subsystems/19-records.md)

- **Update type-checking for dependent fields**: when updating a field that other fields depend on, the dependent fields must be re-checked. If the dependency is on the updated field, this may require the user to provide new values for dependent fields too. Specify: `%{r | fst: new_val}` on a dependent record requires ALL dependent fields to be provided in the update.
- **Pattern matching syntax**: specify `%Point{x: x, y: y}` and partial matching `%Point{x: x}` (with `y` as wildcard).
- **Dot syntax elaboration**: `r.field` elaborates to a projection function application. Define the projection function for each field.

### 3. With-abstraction (subsystems/20-with-abstraction.md)

- **Abstraction algorithm**: add concrete pseudocode for the goal type generalization step. Walk `G`, compare sub-values to `e` using NbE conversion checking, replace with `Var(0)`, wrap in lambda.
- **Failure conditions**: list specific cases where abstraction fails (e.g., `e` under lambda that captures `e`'s free variables).

## Deliverable

Updated subsystem docs 12, 19, 20 with the above.
