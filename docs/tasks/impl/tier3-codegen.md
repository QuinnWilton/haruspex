# Tier 3: Codegen

**Module**: `Haruspex.Codegen`
**Subsystem doc**: [[../../subsystems/09-codegen]]
**Decisions**: d19 (erasure), d26 (builtins), d27 (externs)

## Scope

Implement core term → Elixir quoted AST compilation with type erasure, multiplicity erasure, and builtin mapping.

## Implementation

### Compilation rules

| Core term | Elixir AST |
|-----------|-----------|
| `Var(ix)` | Variable name from codegen context |
| `Lam(:omega, body)` | `fn(var -> compile(body))` |
| `Lam(:zero, body)` | `compile(body)` — skip erased lambda |
| `App(f, a)` | `apply(compile(f), compile(a))` — skip if erased arg |
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
| `Pi(_, _, _)` | erased (type-level only) |
| `Sigma(_, _)` | erased |
| `Type(_)` | erased |

### Erasure

- Type terms (`Pi`, `Sigma`, `Type`) → removed entirely
- `:zero` multiplicity lambdas → skip, don't emit parameter
- `:zero` multiplicity applications → skip, don't pass argument
- All metas must be solved before codegen — unsolved `Meta(id)` is a compiler bug

### Module compilation

```elixir
compile_module(name, exports, definitions, options) → Elixir quoted AST for defmodule
```

- Each definition becomes `def` (if exported) or `defp` (if private)
- Variable names recovered from a codegen context: `_v0`, `_v1`, ... (or user names when available)

### Fully applied builtin optimization

When a builtin is fully applied in a non-higher-order position, inline the operator:
- `App(App(Builtin(:add), a), b)` → `Kernel.+(compile(a), compile(b))` (not `(&Kernel.+/2).(a).(b)`)

### Public API

```elixir
@spec compile_module(atom(), :all | [atom()], [{atom(), Core.term(), Core.term()}], map()) :: Macro.t()
@spec compile_expr(Core.term()) :: Macro.t()
@spec eval_expr(Core.term()) :: term()
```

## Testing strategy

### Unit tests (`test/haruspex/codegen_test.exs`)

- Each compilation rule individually: literal, variable, lambda, application, let, pair, projections
- Builtin mapping: each builtin maps to correct Kernel function
- Erasure: `:zero` lambda produces code with one fewer parameter
- Erasure: `:zero` application skips the argument
- Fully-applied builtin inlining: `add(1, 2)` → `1 + 2` not `(&Kernel.+/2).(1).(2)`
- Extern compilation: `Extern(:math, :sqrt, 1)` → `&:math.sqrt/1`
- Module compilation: `def` vs `defp` based on exports

### Property tests

- **Semantics preservation**: for total, terminating functions: `eval_expr(term)` equals `eval([], term)` evaluated to a literal (NbE and codegen agree)
- **Erasure completeness**: compiled Elixir AST never references erased variables

### Integration tests

- End-to-end: `def add(x : Int, y : Int) : Int do x + y end` → parse → elaborate → check → codegen → `Code.eval_quoted` → call `add(1, 2)` → `3`
- Polymorphic identity: `def id({a : Type}, x : a) : a do x end` → compiles to `def id(x), do: x` (type param erased)

## Verification

```bash
mix test test/haruspex/codegen_test.exs
mix format --check-formatted
mix dialyzer
```
