# T03: What reduces in types? The decidability boundary

**Status**: Resolved → [[../decisions/d28-reduction-scope]]

**Blocks**: Tier 1 (NbE needs to know what to reduce)

## The question

For `Vec(a, 2 + 1)` to equal `Vec(a, 3)`, the NbE must reduce `2 + 1` during type checking. But which functions should reduce, and when?

## Sub-questions

1. **Built-in arithmetic**: Should `2 + 1` reduce to `3` during type checking? Almost certainly yes — without this, even basic dependent types are unusable. But this means the NbE needs delta-reduction rules for arithmetic.

2. **User-defined functions in types**: If a user writes:
   ```elixir
   def double(n : Nat) : Nat do add(n, n) end
   def foo(xs : Vec(a, double(3))) : Vec(a, 6) do xs end
   ```
   Does `double(3)` reduce to `6` during type checking? If not, this program doesn't type-check even though it's correct.

3. **Non-terminating functions**: If all functions reduce during checking:
   ```elixir
   def loop(x : Nat) : Nat do loop(x) end
   def foo(xs : Vec(a, loop(0))) : ... -- type checker loops forever
   ```
   Type checking becomes undecidable. Is this acceptable?

4. **The fuel question**: If you allow all functions to reduce, do you need a fuel/gas limit? Lean has `maxRecDepth`. Agda trusts termination checking. What does Haruspex do?

5. **@total and reduction**: One natural boundary: only `@total` functions reduce in types, since they're guaranteed to terminate. Non-total functions in type positions are opaque (they don't reduce, so `Vec(a, loop(0))` is a valid but opaque type). This is sound but restrictive — it means you need `@total` on any function used in a type index.

6. **Extern functions**: Do FFI functions reduce? They can't — there's no Haruspex body to evaluate. So `Vec(a, extern_add(1, 2))` would be opaque. Is this acceptable?

## Design space

| Approach | Precedent | Trade-off |
|----------|-----------|-----------|
| Reduce everything, no limit | Early Agda | Undecidable, checker can loop |
| Reduce everything, fuel limit | Lean 4 (`maxRecDepth`) | Practical, but fuel errors are confusing |
| Reduce only @total functions | Idris 2 (roughly) | Sound and decidable, but requires @total on index functions |
| Reduce builtins only | Minimal | Very limited dependent types |
| Reduce builtins + @total | Hybrid | Good starting point, extensible |

## The practical question

What programs do we want to type-check in the first few tiers?

- `Vec(a, 2 + 1) = Vec(a, 3)` — needs builtin reduction
- `Vec(a, add(succ(succ(zero)), succ(zero))) = Vec(a, succ(succ(succ(zero))))` — needs user-defined `add` to reduce
- `Vec(a, length(append(xs, ys))) = Vec(a, add(length(xs), length(ys)))` — needs `length` and `append` to reduce, plus the `add` commutativity lemma

The third case is where things get genuinely hard — it requires either reduction or explicit proofs. Most dependently typed languages handle this with a combination of reduction + explicit rewriting.

## Implications for other subsystems

- **NbE (eval)**: Needs to know which functions to unfold vs. leave as neutral
- **Core terms**: May need a `{:defined, name, args}` neutral form for functions that don't reduce
- **Checker**: Needs to decide when to unfold and when to leave opaque
- **Totality**: Becomes more important if it's the gateway to type-level reduction
- **Performance**: Unrestricted reduction can make type checking exponentially slow

## Decision needed

→ Will become **d28-reduction-scope** once resolved.
