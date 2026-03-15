# Tier 1: Typing context

**Module**: `Haruspex.Context`
**Subsystem doc**: referenced in [[../../subsystems/08-checker]] and [[../../subsystems/07-elaboration]]
**Decisions**: d19 (erasure annotations)

## Scope

Implement the typing context: a stack of bindings with types, multiplicities, and usage tracking.

## Implementation

### Context type

```elixir
@type t :: %__MODULE__{
  bindings: [binding()],
  level: non_neg_integer(),        # current de Bruijn level (= length of bindings)
  env: [Value.value()]             # parallel value environment for NbE
}

@type binding :: %{
  name: atom(),                    # user-chosen name (for error messages)
  type: Value.value(),             # type of the binding
  mult: Core.mult(),               # :zero or :omega
  usage: non_neg_integer(),        # computational uses (for multiplicity checking)
  definition: Value.value() | nil  # if let-bound, the value; nil for lambda-bound
}
```

### Public API

```elixir
@spec empty() :: t()
@spec extend(t(), atom(), Value.value(), Core.mult()) :: t()
  # push a new lambda/pi binding
@spec extend_def(t(), atom(), Value.value(), Core.mult(), Value.value()) :: t()
  # push a let-binding (with definition value)
@spec lookup_type(t(), Core.ix()) :: Value.value()
@spec lookup_name(t(), Core.ix()) :: atom()
@spec lookup_mult(t(), Core.ix()) :: Core.mult()
@spec use_var(t(), Core.ix()) :: t()
  # increment usage counter for computational use
@spec check_usage(t(), Core.ix()) :: :ok | {:error, {:multiplicity_violation, atom(), expected :: Core.mult(), got :: non_neg_integer()}}
  # verify usage matches multiplicity at end of scope
@spec names(t()) :: [atom()]
  # all names by de Bruijn level (for pretty-printing)
@spec level(t()) :: non_neg_integer()
@spec env(t()) :: [Value.value()]
```

### Specification gaps to resolve

1. **Usage checking scope**: `check_usage` is called at the end of each binder scope (lambda body, let body). For `:zero` bindings, usage must be 0. For `:omega`, any count is fine.
2. **Definition access**: let-bound variables are transparent — looking up a let-bound variable in NbE returns its definition value, enabling reduction through lets.
3. **Index-to-level conversion**: `lookup_type(ctx, ix)` converts index to level via `ctx.level - ix - 1`, then accesses `bindings[level]`.

## Testing strategy

### Unit tests (`test/haruspex/context_test.exs`)

- `empty()` has level 0, no bindings
- `extend` increases level, adds binding, extends env with fresh variable
- `extend_def` adds binding with definition value
- `lookup_type` at various indices after multiple extends
- `lookup_name` recovers correct names
- `use_var` increments usage
- `check_usage` passes for `:omega` with any usage, fails for `:zero` with non-zero usage
- Multiple extends + lookups: correct de Bruijn index → binding correspondence

### Property tests

- **Level invariant**: `level(ctx)` always equals `length(bindings(ctx))`
- **Env length**: `length(env(ctx))` always equals `level(ctx)`
- **Lookup bounds**: `lookup_type(ctx, ix)` for `0 <= ix < level(ctx)` never crashes

## Verification

```bash
mix test test/haruspex/context_test.exs
mix format --check-formatted
mix dialyzer
```
