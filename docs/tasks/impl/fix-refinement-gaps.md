# Fix: refinement type gaps

**Priority**: medium — not blocking but limits expressiveness

## Gap 1: Pattern match assumption gathering

`Predicate.gather_assumptions/1` only extracts assumptions from `:vrefine` typed bindings. It does not extract equalities from pattern matches or guards.

For example, in `case n > 0 do true -> ... end`, the true branch should add `{:gt, {:var, :n}, {:lit, 0}}` as an assumption, but currently doesn't.

**Fix**: Extend `gather_assumptions` to inspect how bindings were introduced. This requires tracking in the Context whether a binding came from a case branch and what equalities that implies.

## Gap 2: Cross-definition refinement propagation in erasure

When a refined function calls another refined function (`need_pos(x)` where both take `{n : Int | n > 0}`), the erasure pass fails because `def_ref` doesn't carry type information. The erasure synth for `def_ref` returns `{:type, {:llit, 0}}` as a placeholder.

**Fix**: Thread definition types through the erasure pass (via a defs map or by looking up entity types), or erase cross-def calls in check mode where the type is known.

## Gap 3: Function call predicates

Predicates involving function calls like `length(xs) > 0` produce `:unknown` from the solver because they can't be translated to constrain's predicate language.

**Fix**: For `@total` functions with known reductions, evaluate the function at the predicate level. For general functions, this is fundamentally undecidable — `:unknown` is the correct answer.
