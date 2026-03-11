# D03: Normalization-by-evaluation for type equality

**Decision**: Use normalization-by-evaluation (NbE) to decide type equality. Types are evaluated to semantic values, then read back to normal-form terms for comparison.

**Rationale**: In a dependent type system, type checking requires deciding whether two types are equal — for example, whether `Vec(a, 2 + 1)` is the same type as `Vec(a, 3)`. NbE handles this naturally: both evaluate to `Vec(a, 3)` as values, so they compare equal after readback. NbE handles open terms correctly via neutral values (stuck computations like `x + 1` where `x` is a free variable). The alternative — reduction-based normalization — requires choosing a reduction strategy and worrying about termination.

**Mechanism**:

1. **Evaluation** (`eval : Env × Term → Value`): Interprets a core term in an environment of values. Applications reduce (beta), let-bindings substitute, stuck computations produce neutrals. See [[../subsystems/05-values-nbe]].

2. **Readback** (`quote : Level × Value → Term`): Converts a value back to a core term in normal form. Uses the current context depth (level) to convert de Bruijn levels back to indices. Type-directed readback performs eta-expansion ([[d15-eta-expansion]]).

3. **Conversion** (`conv : Level × Value × Value → bool`): Compares two values for equality. In practice, this is `quote(l, v1) == quote(l, v2)`, though it can be implemented more efficiently by comparing values directly and only quoting neutrals.

4. **Unification** extends conversion with metavariable solving — when a metavariable is encountered, it can be solved rather than just compared. See [[d14-implicits-from-start]], [[../subsystems/06-unification]].

**Key insight**: Values use de Bruijn *levels* (counting from bottom), not indices. This means extending the environment never requires shifting existing values. Readback converts `level` to `index` via `index = current_depth - level - 1`. See [[d02-debruijn-core]].

**Cost**: Two representations (terms and values) with conversion functions between them. This is standard in dependent type checkers and the code is straightforward. The value domain is ~100 LOC, eval ~100 LOC, quote ~80 LOC.
