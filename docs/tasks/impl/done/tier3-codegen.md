# Tier 3: Codegen

**Modules**: `Haruspex.Erase`, `Haruspex.Codegen`
**Subsystem docs**: [[../../subsystems/09-codegen]], [[../../subsystems/14-erasure]]
**Decisions**: d19 (erasure), d26 (builtins), d27 (externs)

## Scope

Implement the erasure pass (`Haruspex.Erase`) and core term → Elixir quoted AST compilation (`Haruspex.Codegen`). Erasure removes all type-level and zero-multiplicity terms; codegen translates the erased core to Elixir quoted AST.

## Implementation

### Erasure pass (`Haruspex.Erase`)

Walks a checked core term alongside its type, producing an erased core term.

```elixir
@spec erase(Core.term(), Core.term()) :: Core.term()
```

| Input | Type | Output |
|-------|------|--------|
| `Lam(:zero, body)` | `Pi(:zero, dom, cod)` | `erase(body, cod)` — unwrap |
| `Lam(:omega, body)` | `Pi(:omega, dom, cod)` | `{:lam, :omega, erase(body, cod)}` |
| `App(f, a)` | result type | if `f` has type `Pi(:zero, _, cod)`: `erase(f, ...)` — skip arg |
| `App(f, a)` | result type | if `f` has type `Pi(:omega, dom, cod)`: `{:app, erase(f, ...), erase(a, dom)}` |
| `Pi(_, _, _)` | any | `{:erased}` |
| `Sigma(_, _)` | any | `{:erased}` |
| `Type(_)` | any | `{:erased}` |
| `Meta(id)` | any | raise `CompilerBug` |
| `InsertedMeta(id, mask)` | any | raise `CompilerBug` |
| `Spanned(span, inner)` | any | `erase(inner, type)` |
| `Let(def, body)` | any | if def's type is type-level: eliminate let, erase body only. Otherwise: `{:let, erase(def, def_type), erase(body, body_type)}` |
| `Var`, `Lit`, `Builtin`, `Extern`, `Pair`, `Fst`, `Snd` | any | recurse structurally |

The erasure pass threads types through the traversal. For `App(f, a)`, it synthesizes `f`'s type to determine the Pi's multiplicity. This synthesis is lightweight — it follows the same structural recursion as the term.

### Compilation rules (post-erasure)

| Erased core term | Elixir AST |
|------------------|-----------|
| `Var(ix)` | Variable name from codegen context |
| `Lam(:omega, body)` | `fn(var -> compile(body))` |
| `App(f, a)` | `compile(f).(compile(a))` |
| `Let(def, body)` | `(fn var -> compile(body)).(compile(def))` |
| `Lit(v)` | `v` |
| `Builtin(:add)` | `&Kernel.+/2` |
| `Builtin(:sub)` | `&Kernel.-/2` |
| `Builtin(:mul)` | `&Kernel.*/2` |
| `Builtin(:div)` | `&Kernel.div/2` |
| `Builtin(:eq)` | `&Kernel.==/2` |
| `Builtin(:lt)` | `&Kernel.</2` |
| `Builtin(:gt)` | `&Kernel.>/2` |
| `Builtin(:neg)` | `&Kernel.-/1` |
| `Builtin(:not)` | `&Kernel.not/1` |
| `Builtin(:and)` | `&Kernel.and/2` |
| `Builtin(:or)` | `&Kernel.or/2` |
| `Extern(mod, fun, arity)` | `&mod.fun/arity` |
| `Pair(a, b)` | `{compile(a), compile(b)}` |
| `Fst(e)` | `elem(compile(e), 0)` |
| `Snd(e)` | `elem(compile(e), 1)` |
| `{:erased}` | not emitted |

### Fully-applied builtin optimization

When a builtin is fully applied in a non-higher-order position, inline the operator:
- `App(App(Builtin(:add), a), b)` → `Kernel.+(compile(a), compile(b))` (not `(&Kernel.+/2).(a).(b)`)
- `App(Builtin(:neg), a)` → `Kernel.-(compile(a))`

When partially applied, emit a closure:
- `App(Builtin(:add), a)` → `fn b -> Kernel.+(compile(a), b) end`

### Fully-applied extern optimization

Same pattern as builtins:
- `App(...App(Extern(mod, fun, n), a1)..., an)` → `mod.fun(compile(a1), ..., compile(an))`
- Partially applied: wrap remaining args in a lambda

### Module compilation

```elixir
@spec compile_module(atom(), :all | [atom()], [{atom(), Core.term(), Core.term()}], map()) :: Macro.t()
```

- Each definition is erased (using its type), then compiled
- Becomes `def` (if exported) or `defp` (if private)
- Variable names recovered from codegen context: user names when available, `_v0`, `_v1` fallback
- Shadowed names disambiguated with numeric suffix

### Public API

```elixir
@spec compile_module(atom(), :all | [atom()], [{atom(), Core.term(), Core.term()}], map()) :: Macro.t()
@spec compile_expr(Core.term()) :: Macro.t()
@spec eval_expr(Core.term()) :: term()
```

## Testing strategy

### Unit tests — Erase (`test/haruspex/erase_test.exs`)

- `:zero` lambda with `Pi(:zero, ...)` type → body only, lambda removed
- `:omega` lambda preserved
- `:zero` application skipped — argument not in output
- `:omega` application preserved
- `Pi`, `Sigma`, `Type` → `{:erased}`
- `Spanned` wrapper stripped, inner term erased
- `Meta(id)` → raises `CompilerBug`
- `InsertedMeta(id, mask)` → raises `CompilerBug`
- `Let` with type-level binding → let eliminated, body erased
- `Let` with runtime binding → let preserved, both sides erased
- Nested erasure: `fn({a : Type}, {b : Type}, x : a, y : b)` → two params after erasure
- Interleaved erasure: erased and non-erased args in alternating positions

### Property tests — Erase

- **No `:zero` lams**: output of `erase/2` never contains `{:lam, :zero, _}`
- **No type nodes**: output never contains `{:pi, _, _, _}`, `{:sigma, _, _}`, `{:type, _}`
- **No spans**: output never contains `{:spanned, _, _}`
- **No metas**: output never contains `{:meta, _}` or `{:inserted_meta, _, _}`

### Unit tests — Codegen (`test/haruspex/codegen_test.exs`)

- Each compilation rule individually: literal, variable, lambda, application, let, pair, projections
- Builtin mapping: each builtin maps to correct Kernel function
- Fully-applied builtin inlining: `add(1, 2)` → `1 + 2` not `(&Kernel.+/2).(1).(2)`
- Partially-applied builtin: `App(Builtin(:add), x)` → `fn b -> x + b end`
- Extern compilation: `Extern(:math, :sqrt, 1)` → `&:math.sqrt/1`
- Fully-applied extern: `App(Extern(:math, :sqrt, 1), x)` → `:math.sqrt(x)`
- Module compilation: `def` vs `defp` based on exports
- `{:erased}` nodes not emitted

### Property tests — Codegen

- **Semantics preservation**: for total, terminating functions: `eval_expr(term)` equals `Haruspex.Eval.eval([], term)` evaluated to a literal (NbE and codegen agree)
- **Erasure completeness**: compiled Elixir AST never references erased variables

### Integration tests

- End-to-end: `def add(x : Int, y : Int) : Int do x + y end` → parse → elaborate → check → erase → codegen → `Code.eval_quoted` → call `add(1, 2)` → `3`
- Polymorphic identity: `def id({a : Type}, x : a) : a do x end` → compiles to `def id(x), do: x` (type param erased)
- Multiple erased params: `def const({a : Type}, {b : Type}, x : a, y : b) : a do x end` → compiles to `def const(x, y), do: x`

## Verification

```bash
mix test test/haruspex/erase_test.exs test/haruspex/codegen_test.exs
mix format --check-formatted
mix dialyzer
```
