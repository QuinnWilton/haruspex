# Tier 2: Mutual blocks

**Module**: `Haruspex.Mutual`
**Subsystem doc**: referenced in [[../../subsystems/07-elaboration]]
**Decisions**: d25 (mutual blocks)

## Scope

Implement mutual block signature collection and cross-reference checking. Single `def` recursion uses the same machinery (mutual block of size 1).

## Implementation

### Signature collection

1. Elaborate all type signatures in the mutual block
2. Add all `{name, type_value}` pairs to the typing context
3. Return the extended context for body elaboration

### Cross-reference checking

After all bodies are checked, verify that all names in the mutual block were actually used by at least one other member (warning if a name in a `mutual` block is not referenced by any sibling — it should be a standalone `def` instead).

### Roux entity

A mutual block creates a `Haruspex.MutualGroup` entity:

```elixir
defentity Haruspex.MutualGroup do
  identity [:uri, :group_id]
  field :definitions  # [atom()] — names in the group
end
```

### Public API

```elixir
@spec collect_signatures(elab_ctx(), [AST.def_node()]) :: {:ok, elab_ctx(), [{atom(), Core.term()}]} | {:error, elab_error()}
@spec check_mutual_block(check_ctx(), [{atom(), Core.term(), Core.term()}]) :: {:ok, check_ctx()} | {:error, type_error()}
  # check_mutual_block(ctx, [{name, type, body}])
```

## Testing strategy

### Unit tests (`test/haruspex/mutual_test.exs`)

- Self-recursion: single `def f(x : A) : B do f(x) end` — `f` is in scope during body elaboration
- Mutual pair: `even` and `odd` both in scope during each other's bodies
- Type signature required: mutual block member without type annotation → error
- Standalone warning: mutual block member not referenced by siblings → warning

### Integration tests

- Even/odd example from d25 type-checks
- Self-recursive length function type-checks
- Mutual block with 3+ members

## Verification

```bash
mix test test/haruspex/mutual_test.exs
mix format --check-formatted
mix dialyzer
```
