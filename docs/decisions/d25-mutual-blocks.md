# D25: Mutual definition blocks

**Decision**: Support `mutual do ... end` blocks for mutually recursive definitions. Mutual blocks are checked as a unit and represented as a single roux entity group.

**Rationale**: Mutually recursive functions are common in any non-trivial program — tree traversals, parsers, interpreter evaluators. Without explicit mutual blocks, the compiler must either assume all definitions in a module are potentially mutual (expensive for incrementality) or require manual forward declarations (tedious). Agda, Lean, and Idris 2 all support mutual blocks. On the BEAM, mutual recursion within a module is free at runtime, so this is purely a type-checking concern.

**Surface syntax**:
```elixir
mutual do
  def even(n : Nat) : Bool do
    case n do
      zero -> true
      succ(m) -> odd(m)
    end
  end

  def odd(n : Nat) : Bool do
    case n do
      zero -> false
      succ(m) -> even(m)
    end
  end
end
```

**Mechanism**:
1. **Signature collection**: Before checking any body, elaborate all type signatures in the mutual block
2. **Context seeding**: Add all signatures to the typing context so each body can reference the others
3. **Body checking**: Check each body against its declared type
4. **Totality**: If any function in a mutual block is `@total`, *all* must decrease on a shared measure. The decreasing argument must be identified across the mutual group.

**Type signatures required**: All functions in a mutual block must have explicit type annotations. Without annotations, the checker can't seed the context before checking bodies. (This matches Agda and Idris 2 — mutual recursion requires signatures.)

**Roux integration**: A mutual block creates a single `Haruspex.MutualGroup` entity with identity `[:uri, :group_id]`. This ensures that changing any definition in the group invalidates the type checking of all definitions in the group — which is correct, since they depend on each other. See [[d10-entity-per-definition]].

**Mutual inductive types** (resolves [[../tasks/t09-mutual-inductive-types]]): `mutual do ... end` blocks accept `type` declarations alongside `def`:

```elixir
mutual do
  type Tree(a) do
    leaf(a)
    node(Forest(a))
  end

  type Forest(a) do
    nil
    cons(Tree(a), Forest(a))
  end
end
```

Joint positivity checking walks all types in the group together — a negative occurrence of *any* type in the mutual group in *any* constructor field rejects the entire group. Universe levels for all types in the group are constrained together and solved jointly. A mutual type group is a single roux entity, same as mutual function groups.

**Codegen**: Mutual definitions compile to separate Elixir functions in the same module. No special codegen needed — BEAM modules naturally support mutual calls.

**Self-recursion**: Single recursive functions don't need `mutual` — they are implicitly a mutual block of size 1. The elaboration mechanism is identical:

1. Elaborate the type signature `(x : A) -> B`
2. Add `f : (x : A) -> B` to the context before elaborating the body
3. Elaborate the body with `f` in scope (the reference gets a de Bruijn index)
4. Check the body against the declared type

This means a type annotation is required for any recursive function — the checker needs the type to seed the context before it sees the body. Non-recursive functions can still have their types inferred. Recursion is a top-level-only feature — there is no fixpoint combinator in the core calculus. Anonymous recursive functions are not supported (use a named `def` instead).

**Trade-off**: Mutual blocks sacrifice some incrementality (changing one function re-checks all). This is inherent — mutual definitions genuinely depend on each other. Keeping mutual blocks small is a best practice.

See [[d18-totality-opt-in]], [[d10-entity-per-definition]], [[../subsystems/15-queries]].
