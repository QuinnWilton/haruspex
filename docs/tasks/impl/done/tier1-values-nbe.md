# Tier 1: Values and NbE

**Modules**: `Haruspex.Value`, `Haruspex.Eval`, `Haruspex.Quote`
**Subsystem doc**: [[../../subsystems/05-values-nbe]]
**Decisions**: d03 (NbE), d15 (eta-expansion), d26 (builtins), d28 (reduction scope)

## Scope

Implement the value domain, evaluation (core → value), and type-directed readback (value → core) with eta-expansion.

## Implementation

### Value type

```elixir
@type value ::
  {:vlam, mult(), env(), Core.term()}
  | {:vpi, mult(), value(), env(), Core.term()}
  | {:vsigma, value(), env(), Core.term()}
  | {:vpair, value(), value()}
  | {:vtype, Core.level()}
  | {:vlit, Core.literal()}
  | {:vbuiltin, atom() | {atom(), [value()]}}    # fully or partially applied builtin
  | {:vextern, module(), atom(), arity()}         # from d27 — always opaque
  | {:vneutral, value(), neutral()}

@type neutral ::
  {:nvar, lvl()}
  | {:napp, neutral(), value()}
  | {:nfst, neutral()}
  | {:nsnd, neutral()}
  | {:nmeta, Core.meta_id()}
  | {:ndef, atom(), [value()]}                    # from d28 — opaque defined function
```

### Evaluation

- `eval(env, term)` — environment is a list with most recent binding at head
- Meta lookup: consult `MetaState` (passed as parameter or process dictionary). Solved metas evaluate to their solution. Unsolved metas produce `VNeutral(_, NMeta(id))`.
- Builtins: evaluate to `VBuiltin(atom)`. Application via `vapp` triggers delta-reduction when fully applied to literal values.

### Delta reduction (d26)

```elixir
vapp(VBuiltin(:add), VLit(a))                    → VBuiltin({:add, [VLit(a)]})  # partial
vapp(VBuiltin({:add, [VLit(a)]}), VLit(b))       → VLit(a + b)                 # reduce
vapp(VBuiltin(:add), VNeutral(_, n))              → VNeutral(_, NApp(NBuiltin(:add), n))  # stuck
```

Full delta table:
| Builtin | Args | Result |
|---------|------|--------|
| `:add` | `VLit(a), VLit(b)` | `VLit(a + b)` |
| `:sub` | `VLit(a), VLit(b)` | `VLit(a - b)` |
| `:mul` | `VLit(a), VLit(b)` | `VLit(a * b)` |
| `:div` | `VLit(a), VLit(b)` | `VLit(div(a, b))` |
| `:neg` | `VLit(a)` | `VLit(-a)` |
| `:eq`  | `VLit(a), VLit(b)` | `VCon(:Bool, a == b && :true \|\| :false, [])` |
| `:lt`  | `VLit(a), VLit(b)` | `VCon(:Bool, a < b && :true \|\| :false, [])` |
| (float ops analogous) | | |

Division by zero: `div(a, 0)` produces a stuck neutral `VNeutral(_, ...)` rather than crashing. This is safe because division by zero in a type index is a logical error, not a runtime error.

### Function unfolding (d28)

- `@total` function calls: retrieve body from definition context, evaluate with args. Decrement fuel counter. If fuel exhausted → stuck neutral `VNeutral(_, NDef(name, args))`.
- Non-`@total` function calls: always stuck neutral.
- Extern calls: always stuck neutral (d27).

Fuel is passed as a parameter to `eval`, default 1000, per-definition.

### Readback

Type-directed readback with eta-expansion (d15):
- At Pi type: eta-expand neutrals to lambdas
- At Sigma type: eta-expand neutrals to pairs
- Otherwise: structural readback

### Specification gaps to resolve

1. **MetaState threading**: pass `MetaState` as an explicit parameter to `eval`, not via process dictionary. This keeps evaluation pure and testable.
2. **Definition context**: `@total` function bodies are retrieved from a definition map passed to `eval`. For Tier 1, this map is empty — no user-defined functions yet. The infrastructure exists for Tier 2+.
3. **Neutral builtins**: partially applied builtins that encounter a neutral argument become stuck: `VNeutral(result_type, NApp(NApp(NBuiltin(:add), n), VLit(3)))`.

### Public API

```elixir
@spec eval(eval_ctx(), Core.term()) :: value()
@spec quote(lvl(), value(), value()) :: Core.term()
@spec quote_untyped(lvl(), value()) :: Core.term()
@spec vapp(value(), value()) :: value()
@spec vfst(value()) :: value()
@spec vsnd(value()) :: value()
@spec fresh_var(lvl(), value()) :: value()

@type eval_ctx :: %{
  env: env(),
  meta_state: MetaState.t(),
  defs: %{atom() => {Core.term(), boolean()}},  # name → {body, total?}
  fuel: non_neg_integer()
}
```

## Testing strategy

### Unit tests (`test/haruspex/eval_test.exs`, `test/haruspex/quote_test.exs`)

- **Eval**: each term form evaluates correctly
  - `Var(0)` in `[VLit(42)]` → `VLit(42)`
  - `Lam` → `VLam` closure
  - `App(Lam(_, body), arg)` → `eval([arg | env], body)` (beta reduction)
  - `Lit(42)` → `VLit(42)`
  - `Builtin(:Int)` → `VBuiltin(:Int)`
  - `Fst(Pair(a, b))` → `a`
  - `Let(def, body)` → `eval([eval(def) | env], body)`
- **Delta reduction**: `add(2, 3)` → `VLit(5)`, `mul(4, 5)` → `VLit(20)`, etc.
- **Partial application**: `add(2)` → partial builtin, `add(2)(3)` → `VLit(5)`
- **Stuck terms**: `add(x, 3)` where `x` is neutral → neutral
- **Division by zero**: `div(1, 0)` → stuck neutral, not crash
- **Quote**: readback at each type
  - `quote(VLit(42), VBuiltin(:Int))` → `Lit(42)`
  - `quote(VLam(...), VPi(...))` → `Lam(...)`
  - Eta: `quote(neutral_f, VPi(A, B))` → `Lam(App(neutral_f, Var(0)))` (eta-expanded)
  - Eta for Sigma: `quote(neutral_p, VSigma(A, B))` → `Pair(Fst(neutral_p), Snd(neutral_p))`
- **Level-to-index**: `NVar(level)` → `Var(depth - level - 1)`

### Property tests

- **NbE stability**: for well-typed closed terms, `eval` then `quote` produces a term in normal form (applying again is identity: `quote(eval(quote(eval(t)))) == quote(eval(t))`)
- **Eta laws**: `quote(eval(f), Pi(A, B))` is always a `Lam(...)` regardless of whether `f` evaluates to a lambda or neutral
- **Delta correctness**: for all integer pairs `(a, b)` where `b != 0`: `eval(App(App(Builtin(:add), Lit(a)), Lit(b)))` = `VLit(a + b)`, and similarly for other ops

### Negative tests

- Unsolved meta during eval → `VNeutral(_, NMeta(id))`
- Out-of-bounds env index → should not happen (test that well-scoped terms don't trigger this)

## Verification

```bash
mix test test/haruspex/eval_test.exs test/haruspex/quote_test.exs
mix format --check-formatted
mix dialyzer
```
