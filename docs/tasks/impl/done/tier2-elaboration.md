# Tier 2: Elaboration

**Module**: `Haruspex.Elaborate`
**Subsystem doc**: [[../../subsystems/07-elaboration]]
**Decisions**: d08 (elaboration boundary), d14 (implicits), d17 (typed holes), d24 (auto-implicits), d25 (mutual blocks), d26 (builtins)

## Scope

Implement the surface AST → core term transformation: name resolution, de Bruijn indexing, implicit argument insertion, hole creation, auto-implicit insertion, builtin resolution, and operator desugaring.

## Implementation

### Name resolution

- Stack of `{name, de_bruijn_level}` pairs
- Variable lookup: scan from top, compute index = `current_level - bound_level - 1`
- Unbound variable → `{:error, {:unbound_variable, name, span}}`
- Builtin table (d26): `"Int" → {:builtin, :Int}`, `"add" → {:builtin, :add}`, etc.

### Implicit argument insertion

When elaborating `f(x)` where `f : {a : Type} -> a -> a`:
1. Synth type of `f`
2. Count leading implicit Pi parameters
3. For each, create `InsertedMeta(fresh_id, mask)` with mask from current context
4. Apply `f` to all inserted metas, then to explicit args

### Operator desugaring

- `x + y` → `App(App(Builtin(:add), x'), y')`
- `x |> f` → `App(f', x')`
- `-x` → `App(Builtin(:neg), x')`
- `if c then a else b` → elaborate as case on Bool (once ADTs exist); for now, keep as special form

### Self-recursion (d25)

For `def f(x : A) : B do body end`:
1. Elaborate type signature `Pi(:omega, A', B')`
2. Push `f` into context with this type
3. Elaborate body with `f` in scope
4. Pop `f` from context

### Mutual blocks (d25)

For `mutual do def f ...; def g ... end`:
1. Phase 1: elaborate all type signatures
2. Phase 2: push all names+types into context
3. Phase 3: elaborate all bodies

### Auto-implicits (d24)

For `variable {a : Type}` followed by `def f(x : a) : a do x end`:
1. Scan the signature for free variables matching auto-implicit names
2. Prepend implicit parameters for each match
3. Result: `def f({a : Type}, x : a) : a do x end`

### Implicit argument insertion (deferred to tier2-checker)

Implicit argument insertion requires type information to determine where implicit
parameters exist. The elaborator registers auto-implicits and resolves free type
variables, but actual meta insertion for implicit arguments happens during
bidirectional type checking. See tier2-checker.md.

### Holes (d17)

`_` → `Meta(fresh_id)` tagged as `:hole` in MetaState. Record span + context snapshot for reporting.

## Testing strategy

### Unit tests (`test/haruspex/elaborate_test.exs`)

- **Name resolution**: variable at correct de Bruijn index after binding
- **Shadowing**: inner binding shadows outer, correct indices
- **Builtins**: `Int` resolves to `{:builtin, :Int}`, `add` to `{:builtin, :add}`
- **Operator desugaring**: `x + y` → `App(App(Builtin(:add), x), y)`
- **Pipeline**: `x |> f` → `App(f, x)`
- **Lambda**: `fn(x) do x end` → `Lam(:omega, Var(0))`
- **Let**: `let x = 1 in x` → `Let(Lit(1), Var(0))`
- **Type annotation**: `(x : Int)` → `Ann(x, Builtin(:Int))`
- **Pi type**: `(x : Int) -> Int` → `Pi(:omega, Builtin(:Int), Builtin(:Int))`
- **Arrow type**: `Int -> Int` → `Pi(:omega, Builtin(:Int), Builtin(:Int))` with unused binding
- **Implicit param**: `{a : Type}` → Pi with `:zero` multiplicity
- **Implicit insertion**: `f(42)` where `f : {a : Type} -> a -> a` → inserts meta for `a`
- **Holes**: `_` → `Meta(id)` tagged as hole
- **Self-recursion**: `def f(x : Int) : Int do f(x) end` → body references `f` at correct index
- **Auto-implicits**: free type variable matching `variable` declaration → implicit param prepended
- **Mutual blocks**: both names in scope during body elaboration

### Negative tests

- Unbound variable → `{:error, {:unbound_variable, name, span}}`
- Ambiguous reference (if applicable) → error with span
- `@total` without `def` → error (parser level, but verify elaboration doesn't crash)

### Property tests

- **Well-scoped output**: all `Var(ix)` in elaborated core have `ix < context_depth`
- **Meta registration**: every `Meta(id)` and `InsertedMeta(id, _)` in output has a corresponding MetaState entry
- **Determinism**: same input → same output

### Integration tests

- Elaborate a complete function definition: `def add(x : Int, y : Int) : Int do x + y end`
- Elaborate a polymorphic function with implicit: `def id({a : Type}, x : a) : a do x end`
- Elaborate a recursive function: `def loop(x : Int) : Int do loop(x) end`

## Verification

```bash
mix test test/haruspex/elaborate_test.exs
mix format --check-formatted
mix dialyzer
```
