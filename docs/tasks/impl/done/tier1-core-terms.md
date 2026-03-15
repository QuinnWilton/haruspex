# Tier 1: Core terms

**Module**: `Haruspex.Core`
**Subsystem doc**: [[../../subsystems/04-core-terms]]
**Decisions**: d02 (de Bruijn), d26 (builtins), d27 (externs), d28 (reduction scope)

## Scope

Implement the core term representation: de Bruijn indexed terms with metas, universe levels, multiplicities, literals, builtins, and externs.

## Implementation

### Term type

All term forms from the subsystem doc plus additions from decisions:

```elixir
@type term ::
  {:var, ix()}
  | {:lam, mult(), term()}
  | {:app, term(), term()}
  | {:pi, mult(), term(), term()}
  | {:sigma, term(), term()}
  | {:pair, term(), term()}
  | {:fst, term()}
  | {:snd, term()}
  | {:let, term(), term()}
  | {:type, level()}
  | {:lit, literal()}
  | {:builtin, atom()}
  | {:extern, module(), atom(), arity()}        # from d27
  | {:meta, meta_id()}
  | {:inserted_meta, meta_id(), [boolean()]}
```

ADT extensions (implemented in Tier 5, but types defined here):
```elixir
  | {:data, atom(), [term()]}
  | {:con, atom(), atom(), [term()]}
  | {:case, term(), [{atom(), non_neg_integer(), term()}]}
```

### Builtin atoms (d26)

Type builtins: `:Int`, `:Float`, `:String`, `:Atom`
Operation builtins: `:add`, `:sub`, `:mul`, `:div`, `:neg`, `:fadd`, `:fsub`, `:fmul`, `:fdiv`, `:eq`, `:neq`, `:lt`, `:gt`, `:lte`, `:gte`, `:and`, `:or`, `:not`

### Level type

```elixir
@type level :: {:lvar, non_neg_integer()} | {:llit, non_neg_integer()} | {:lmax, level(), level()} | {:lsucc, level()}
```

### Specification gaps to resolve

1. **Span storage**: use `{:spanned, Pentiment.Span.Byte.t(), term()}` wrapper nodes. Spans are optional and excluded from term equality — `{:spanned, _, t}` is equal to `t` for conversion checking purposes.
2. **Binding mask semantics**: `InsertedMeta(id, mask)` — mask length equals the current context depth at insertion point. `true` at position `i` means de Bruijn level `i` is accessible to the meta's solution. The meta is applied to the masked variables during expansion.
3. **Substitution**: `subst(term, ix, replacement)` with standard de Bruijn shifting. Out-of-bounds index during substitution is a bug (should not happen in well-formed terms).

### Public API

```elixir
@spec var(ix()) :: term()
@spec lam(mult(), term()) :: term()
@spec app(term(), term()) :: term()
@spec pi(mult(), term(), term()) :: term()
# ... constructors for all term forms

@spec subst(term(), ix(), term()) :: term()
@spec shift(term(), integer(), ix()) :: term()  # shift indices >= cutoff by amount
```

## Testing strategy

### Unit tests (`test/haruspex/core_test.exs`)

- Each constructor produces the correct tuple
- `subst/3`: substitute at index 0, substitute at higher indices, substitute under binders (shifting)
- `shift/3`: shifting free variables, not shifting bound variables, shifting under nested binders
- Span wrapper: `{:spanned, span, {:var, 0}}` — span is accessible but doesn't affect equality

### Property tests

- **Substitution identity**: `subst(t, ix, {:var, ix})` ≡ `t` (substituting a variable for itself is identity)
- **Shift roundtrip**: `shift(shift(t, n, 0), -n, 0)` ≡ `t` for closed terms
- **Well-formedness**: randomly generated well-scoped terms have all indices < context depth

### Negative tests

Not applicable — core terms are data, not validated at construction time.

## Verification

```bash
mix test test/haruspex/core_test.exs
mix format --check-formatted
mix dialyzer
```
