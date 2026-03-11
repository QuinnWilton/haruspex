# T09: Mutual inductive types

**Status**: Resolved — extended d25-mutual-blocks and subsystem 12-adts. Mutual types use `mutual do ... end`, joint positivity checking, joint universe solving.

**Blocks**: Tier 5 (ADTs)

## The question

Can two `type` declarations reference each other? e.g.:

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

## Sub-questions

1. **Joint positivity checking**: Both types must be checked for strict positivity simultaneously. `Tree` appears positively in `Forest` and vice versa — this is fine. But if `Tree` appeared negatively in `Forest` (e.g., `Forest(a) = f(Tree(a) -> Int)`), both should be rejected.

2. **Joint universe assignment**: Mutual types must live in the same universe or have compatible universe levels.

3. **Syntax**: Reuse `mutual do ... end` blocks for types? Or a separate `mutual type` syntax?

4. **Roux entities**: A mutual type group is a single entity (like mutual function groups).

## The likely answer

Extend `mutual do ... end` to allow `type` declarations alongside `def`. The positivity checker walks all types in the group together. This is a natural extension of d25.

## Resolution

→ Address during Tier 5. Extend d25-mutual-blocks and subsystem 12-adts.
