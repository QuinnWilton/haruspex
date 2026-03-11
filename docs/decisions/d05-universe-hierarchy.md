# D05: Stratified universe hierarchy

**Decision**: Use a stratified universe hierarchy `Type 0 : Type 1 : Type 2 : ...` with universe polymorphism and cumulativity, rather than `Type : Type`.

**Rationale**: `Type : Type` is inconsistent — it allows encoding Girard's paradox, the type-theoretic analogue of Russell's paradox. This means the type system can prove `False`, which undermines the guarantees that totality checking ([[d18-totality-opt-in]]) and strict positivity ([[d16-strict-positivity]]) provide. For a language aspiring to full rigor, consistency of the type system is fundamental. The inconsistency also means that erased proofs ([[d19-erasure-annotations]]) could be unsound — you could construct a "proof" of anything and erase it.

**Mechanism**:

1. **Stratification**: `Type 0 : Type 1 : Type 1 : Type 2 : ...` Each universe level contains all types from lower levels. `Int : Type 0`, `Type 0 : Type 1`, etc.

2. **Universe polymorphism**: User-written `Type` desugars to `Type(?l)` where `?l` is a fresh universe level variable. During checking, constraints of the form `?l = max(?l1, ?l2) + 1` are collected. After checking each definition, the level solver ([[../subsystems/06-unification]]) finds a minimal assignment.

3. **Cumulativity**: `Type n` is a subtype of `Type (n+1)`. A value at `Type 0` can be used where `Type 1` is expected. Implemented in the conversion checker: when comparing `Type n` with `Type m`, generate the constraint `n ≤ m` rather than requiring strict equality.

4. **Pi rule**: `Π(x : A).B` where `A : Type i` and `B : Type j` lives at `Type (max i j)`.

**Trade-off**: Universe errors can be confusing. Good error messages are essential — when a level constraint is unsatisfiable, the error should explain which types caused the conflict and suggest where to add explicit level annotations (if needed).

**User-facing**: In most code, users never write universe levels. `Type` means "some type at an inferred level." Explicit levels (`Type 0`, `Type 1`) are available for the rare cases where inference is insufficient.

**Cost**: ~100 LOC for level variables and constraint collection in the checker. ~150 LOC for the level solver. The main complexity is threading level constraints through checking without cluttering the core algorithm.

**Comparison**: Agda uses a similar approach. Coq uses a more elaborate system with algebraic universes. Idris 2 uses `Type : Type` (inconsistent) as a pragmatic choice. We follow Agda's approach because we want full rigor.

See [[../subsystems/06-unification]] (LevelSolver section).
