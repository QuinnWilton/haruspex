# D06: Constrain for refinement type discharge

**Decision**: Use constrain's Horn clause solver for refinement type discharge via `Constrain.entails?/2`.

**Rationale**: Constrain already solves Elixir's guard-subset predicates via Horn clauses. Refinement predicates `{x : T | P(x)}` where P uses guards map directly to constrain's expression format. Reusing an existing workspace library avoids building a custom SMT-like solver.

**Mechanism**: Refinement predicates translate to constrain expressions: `{:gt, {:var, :x}, {:lit, 0}}` for `x > 0`, `{:neq, {:var, :y}, {:lit, 0}}` for `y != 0`. Discharge uses three-valued logic: `:yes` -> accept, `:no` -> type error with explanation, `:unknown` -> require explicit proof/assertion. Assumptions are gathered from pattern matches, guards, and upstream refinements in scope.

**Trade-off**: Constrain's Horn clause solver is less powerful than a full SMT solver -- it can't handle arbitrary arithmetic reasoning. For the guard-subset fragment this is sufficient. Complex arithmetic refinements may require explicit assertions.

See [[d19-erasure-annotations]], [[../subsystems/11-refinements]].
