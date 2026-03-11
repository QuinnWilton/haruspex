# D16: Strict positivity for all inductive types

**Decision**: All inductive type declarations must satisfy the strict positivity condition.

**Rationale**: Without strict positivity, you can encode paradoxes. The classic example: `type Bad = mk(Bad -> Void)` allows constructing a term of type `Void` (the empty type), proving `False`. This is a fundamental soundness issue — if `False` is provable, every type is inhabited, and the type system provides no guarantees. Combined with `Type : Type` inconsistency ([[d05-universe-hierarchy]]), non-positive types would completely undermine the language.

**Mechanism**: The check is syntactic, performed when a `type` declaration is processed:
1. Walk each constructor's argument types
2. The type being defined may appear in argument types, but only in **strictly positive** positions
3. A position is strictly positive if it is: (a) the entire argument type, or (b) to the right of an arrow. It is **not** strictly positive if it appears to the left of an arrow (negative position)
4. Example: `type T = mk(T)` — OK (T in positive position). `type T = mk(T -> Int)` — rejected (T in negative position). `type T = mk((Int -> T) -> Int)` — rejected (T in negative-of-negative = positive, but not *strictly* positive in the nested sense; however standard strict positivity accepts this)

Actually, the standard strict positivity check:
- **Positive**: The defined type does not appear at all, or appears only as the target of arrows in constructor arguments
- **Negative**: The defined type appears to the left of an arrow — this is rejected
- Nested inductive occurrences (the type appears as an argument to another type constructor) require that the other type is also strictly positive in that parameter — this is a more advanced check deferred initially

**Cost**: ~50-100 LOC in the ADT checker. Non-negotiable for soundness.

See [[d18-totality-opt-in]], [[../subsystems/12-adts]].
