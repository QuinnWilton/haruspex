# D22: With-abstraction for dependent case on intermediate values

**Decision**: Support `with`-clauses that let the user case-split on the result of a function call while the type system tracks the relationship between the scrutinee and the result.

**Rationale**: Dependent pattern matching frequently requires matching on computed values. For example, when filtering a vector, you need to inspect `p(x)` and have the type system know that in the `True` branch, `p(x) = True`. Without `with`, the user must manually abstract and prove equalities — extremely tedious and a major usability barrier. Agda and Idris 2 both have `with` as a core feature; Lean handles this via the equation compiler.

**Surface syntax**:
```elixir
def filter({a : Type}, p : a -> Bool, xs : Vec(a, n)) : (m : Nat ** Vec(a, m)) do
  case xs do
    vnil -> {zero, vnil}
    vcons(x, rest) ->
      with p(x) do
        true -> let {m, ys} = filter(p, rest) in {succ(m), vcons(x, ys)}
        false -> filter(p, rest)
      end
  end
end
```

**Mechanism**: `with expr do branches end` elaborates as follows:
1. Evaluate `expr` to get its type `T`
2. Abstract the current goal type over `expr` and its occurrences in the context
3. Case-split on the `with`-scrutinee, refining types in each branch
4. In each branch, the equation `expr = constructor_pattern` is available for rewriting types

In the core, `with` compiles to a `case` on the computed value, with the context suitably generalized. The key insight is that the type checker must abstract over the `with`-expression in the goal type *before* matching, so that matching can refine it.

**Nested with**: Multiple `with` expressions can be stacked:
```elixir
with f(x), g(y) do
  true, true -> ...
  true, false -> ...
  ...
end
```

**Trade-off**: With-abstraction is the most complex part of dependent pattern matching. The elaboration is subtle — abstracting over the scrutinee in the goal type can fail if the scrutinee appears in a position that can't be generalized. Good error messages are essential when this happens.

**Deferred initially**: The implementation plan includes basic `with` in Tier 5 alongside dependent pattern matching. Full with-abstraction (with nested with, and automatic abstraction) may be refined as usage patterns emerge.

See [[d16-strict-positivity]], [[../subsystems/12-adts]], [[../subsystems/20-with-abstraction]].
