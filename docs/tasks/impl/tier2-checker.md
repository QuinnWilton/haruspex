# Tier 2: Checker

**Module**: `Haruspex.Check`
**Subsystem doc**: [[../../subsystems/08-checker]]
**Decisions**: d04 (bidirectional), d05 (universes), d19 (erasure), d26 (builtins)

## Scope

Implement the bidirectional type checker with synth/check modes, multiplicity tracking, literal typing, and post-definition processing (hole reports, level solving, zonking).

## Implementation

### Synth mode

Infer the type of a core term:

- `Var(ix)` → lookup type in context, check multiplicity
- `App(f, a)` → synth `f`, expect Pi type, check `a` against domain, return codomain
- `Fst(e)` → synth `e`, expect Sigma, return first component type
- `Snd(e)` → synth `e`, expect Sigma, return second component type (applied to fst)
- `Type(l)` → return `VType(LSucc(l))`
- `Pi(m, dom, cod)` → check dom is Type, check cod is Type in extended context, return Type at max level
- `Sigma(a, b)` → analogous to Pi
- `Lit(n) when is_integer(n)` → `{Lit(n), VBuiltin(:Int)}` (d26)
- `Lit(f) when is_float(f)` → `{Lit(f), VBuiltin(:Float)}` (d26)
- `Lit(s) when is_binary(s)` → `{Lit(s), VBuiltin(:String)}` (d26)
- `Lit(a) when is_atom(a)` → `{Lit(a), VBuiltin(:Atom)}` (d26)
- `Builtin(:Int)` → `{Builtin(:Int), VType(LLit(0))}` (d26)
- `Builtin(:add)` → `{Builtin(:add), VPi(:omega, VBuiltin(:Int), _, Pi(:omega, VBuiltin(:Int), _, VBuiltin(:Int)))}` (d26)
- `Meta(id)` → lookup type in MetaState, return it
- `Extern(mod, fun, arity)` → lookup declared type (from context), return it

### Check mode

Verify a term against an expected type:

- `Lam(m, body)` against `VPi(pm, dom, env, cod)` → check multiplicities match, extend context, check body against codomain
- `Pair(a, b)` against `VSigma(fst_ty, env, snd_ty)` → check a against fst_ty, check b against snd_ty (applied to a's value)
- `Let(def, body)` against expected → synth def, extend context with definition, check body
- Fallback: synth the term, unify inferred type with expected type

### Multiplicity tracking

- On `synth(Var(ix))`: call `Context.use_var(ctx, ix)` to increment usage
- At lambda scope exit: check that the bound variable's usage matches its multiplicity
- `:zero` bindings: usage must be 0 (erased — cannot be used computationally)
- `:omega` bindings: any usage count is fine

### Post-definition processing

After checking a definition:
1. Collect unsolved hole metas → hole reports (informational)
2. Collect unsolved implicit metas → "could not infer" errors
3. Run `LevelSolver.solve()` on level constraints
4. Zonk: substitute all solved metas in the elaborated term

### Public API

```elixir
@spec synth(check_ctx(), Core.term()) :: {:ok, {Core.term(), Value.value()}, check_ctx()} | {:error, type_error()}
@spec check(check_ctx(), Core.term(), Value.value()) :: {:ok, Core.term(), check_ctx()} | {:error, type_error()}
@spec check_definition(check_ctx(), atom(), Core.term(), Core.term()) :: {:ok, check_ctx()} | {:error, type_error()}
```

Note: `check_ctx` is threaded (contains mutable MetaState, usage counters, level constraints).

### Implicit argument insertion

When checking/synthesizing `App(f, args)` where `f` has type `Pi(:zero, dom, cod)`:
1. The `:zero` multiplicity signals an implicit parameter
2. Create `InsertedMeta(fresh_id, mask)` with mask from current context
3. Apply `f` to the inserted meta
4. Continue checking remaining args against the codomain

This was deferred from tier2-elaboration because it requires the synthesized type
of the function to determine implicit positions.

## Testing strategy

### Unit tests (`test/haruspex/check_test.exs`)

**Synth rules:**
- `Var(0)` in context with `Int` → synth `Int`
- `Lit(42)` → synth `Int`
- `Lit(3.14)` → synth `Float`
- `Lit("hello")` → synth `String`
- `Lit(:foo)` → synth `Atom`
- `Builtin(:Int)` → synth `Type 0`
- `Type(LLit(0))` → synth `Type 1`
- `App(Lam(:omega, Var(0)), Lit(42))` → synth `Int`
- `Fst(Pair(Lit(1), Lit(2)))` → synth `Int`
- `Pi(:omega, Builtin(:Int), Builtin(:Int))` → synth `Type 0`
- `Builtin(:add)` → synth `Int -> Int -> Int`

**Check rules:**
- `Lam(:omega, Var(0))` checks against `Pi(:omega, Int, Int)` → ok
- `Pair(Lit(1), Lit(2))` checks against `Sigma(Int, Int)` → ok
- `Let(Lit(1), Var(0))` checks against `Int` → ok
- Fallback: `Lit(42)` checks against `Int` → ok (synth + unify)

**Type errors:**
- `App(Lit(42), Lit(1))` → `{:error, {:not_a_function, VBuiltin(:Int), span}}`
- `Fst(Lit(42))` → `{:error, {:not_a_pair, VBuiltin(:Int), span}}`
- `Lam(:omega, Var(0))` against `Int` → type mismatch (expected Int, got Pi)

- **Implicit insertion**: `f(42)` where `f : {a : Type} -> a -> a` → inserts meta for `a`, resolves to `Int`

**Multiplicity:**
- `:zero` binding used computationally → `{:error, {:multiplicity_violation, name, span}}`
- `:zero` binding used in type position → ok
- `:omega` binding used multiple times → ok
- `:omega` binding unused → ok

**Post-processing:**
- Unsolved implicit meta → "could not infer" error
- Unsolved hole meta → hole report with expected type and bindings
- Level solving succeeds for simple programs
- Zonking replaces solved metas with their solutions

### Property tests

- **Type preservation**: if `synth(t) = T`, then `check(t, T)` succeeds
- **Determinism**: same input → same output (given same MetaState)
- **Well-typed terms check**: randomly generated well-typed terms always succeed

### Integration tests

- Identity function: `def id({a : Type}, x : a) : a do x end` — type-checks with implicit solved
- Constant function: `def const({a : Type}, {b : Type}, x : a, y : b) : a do x end`
- Addition: `def add(x : Int, y : Int) : Int do x + y end`
- Type error: `def bad(x : Int) : String do x end` → mismatch error with readable message
- Hole: `def f(x : Int) : Int do _ end` → hole report showing `expected: Int, bindings: [x : Int]`

## Deferred to tier 3

### Source spans on checker errors
All checker error tuples currently omit source spans (e.g., `{:type_mismatch, expected, got}`
rather than `{:type_mismatch, expected, got, span}`). Spans are provided externally via
`render_opts` at error rendering time. To support richer error messages, consider threading
spans through the checker to attach them at the point of error.

### Computational vs non-computational position tracking
The spec calls for distinguishing computational and type-level positions for multiplicity
checking (`:zero` bindings should be usable in type positions but not computational ones).
Currently all variable uses are treated uniformly. This requires tracking a "position mode"
through the checker.

### Ann and Extern synth rules
`Ann(e, ty)` (type annotation as a core term) and `Extern(mod, fun, arity)` synth rules
are not yet implemented. These are needed when the core language includes these constructs.

## Verification

```bash
mix test test/haruspex/check_test.exs
mix format --check-formatted
mix dialyzer
```
