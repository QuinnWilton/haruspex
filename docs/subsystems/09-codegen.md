# Codegen

## Purpose

Transforms fully elaborated core terms into Elixir quoted AST for compilation to BEAM. Type and multiplicity erasure are handled by `Haruspex.Erase` before codegen runs; codegen operates on erased core terms only. See [[../decisions/d19-erasure-annotations]].

## Dependencies

- `Haruspex.Core` — core term input
- `Haruspex.Erase` — erasure pass (type removal, multiplicity erasure)

## Key types

```elixir
@type elixir_ast :: Macro.t()  # Elixir's quoted AST format
```

## Public API

```elixir
@spec compile_module(atom(), :all | [atom()], [{atom(), Core.term(), Core.term()}], map()) :: elixir_ast()
  # compile_module(module_name, exports, [{name, type, body}], options)
@spec compile_expr(Core.term()) :: elixir_ast()
@spec eval_expr(Core.term()) :: term()
```

## Erasure pass (`Haruspex.Erase`)

Erasure runs before codegen, walking each term alongside its type. It produces an erased core where codegen never encounters erasure concerns.

```elixir
@spec erase(Core.term(), Core.term()) :: Core.term()
```

Rules:
1. `Lam(:zero, body)` with type `Pi(:zero, dom, cod)` — unwrap: return `erase(body, cod)`
2. `Lam(:omega, body)` with type `Pi(:omega, dom, cod)` — keep: `{:lam, :omega, erase(body, cod)}`
3. `App(f, a)` where `f`'s type is `Pi(:zero, dom, cod)` — skip argument: `erase(f, Pi(:zero, dom, cod))`
4. `App(f, a)` where `f`'s type is `Pi(:omega, dom, cod)` — keep: `{:app, erase(f, type_of_f), erase(a, dom)}`
5. `Pi(_, _, _)` → `{:erased}`
6. `Sigma(_, _)` → `{:erased}`
7. `Type(_)` → `{:erased}`
8. `Meta(id)` → raise `Haruspex.CompilerBug` ("unsolved meta reached erasure")
9. `InsertedMeta(id, mask)` → raise `Haruspex.CompilerBug` ("unsolved inserted meta reached erasure")
10. `Spanned(span, inner)` → `erase(inner, type)` (strip span, recurse)
11. `Let(def, body)` — erase both, preserving the let binding
12. All other terms (`Var`, `Lit`, `Builtin`, `Extern`, `Pair`, `Fst`, `Snd`) — recurse structurally

After erasure, the term contains no `:zero` lams, no type-level nodes, no spans, and no metas.

## Compilation rules (post-erasure)

After erasure, codegen is a straightforward structural translation:

```
compile(Var(ix))            → variable reference (index to name via context)
compile(Lam(:omega, body))  → fn(var -> compile(body))
compile(App(f, a))          → compile(f).(compile(a))
compile(Let(def, body))     → (fn var -> compile(body)).(compile(def))
compile(Lit(v))             → v
compile(Builtin(op))        → see builtin mapping table
compile(Extern(mod, f, a))  → &mod.f/a
compile(Pair(a, b))         → {compile(a), compile(b)}
compile(Fst(e))             → elem(compile(e), 0)
compile(Snd(e))             → elem(compile(e), 1)
compile({:erased})          → not emitted (dead code after erasure)
```

Note: `Con`, `Case`, `Data` terms are added in tier 5 (ADTs).

## Builtin mapping table

| Builtin | Elixir equivalent | Arity |
|---------|-------------------|-------|
| `:add` | `Kernel.+/2` | 2 |
| `:sub` | `Kernel.-/2` | 2 |
| `:mul` | `Kernel.*/2` | 2 |
| `:div` | `Kernel.div/2` | 2 |
| `:eq` | `Kernel.==/2` | 2 |
| `:lt` | `Kernel.</2` | 2 |
| `:gt` | `Kernel.>/2` | 2 |
| `:neg` | `Kernel.-/1` | 1 |
| `:not` | `Kernel.not/1` | 1 |
| `:and` | `Kernel.and/2` | 2 |
| `:or` | `Kernel.or/2` | 2 |

## Fully-applied builtin optimization

When a builtin is fully applied (all arguments present, non-higher-order position), inline the operator directly:
- `App(App(Builtin(:add), a), b)` → `Kernel.+(compile(a), compile(b))`
- `App(Builtin(:neg), a)` → `Kernel.-(compile(a))`

When partially applied or in higher-order position, emit a function capture:
- `Builtin(:add)` → `&Kernel.+/2`
- `App(Builtin(:add), a)` → `fn b -> Kernel.+(compile(a), b) end`

## Extern compilation

- Unapplied: `Extern(mod, fun, arity)` → `&mod.fun/arity`
- Fully applied: `App(...App(Extern(mod, fun, n), a1)..., an)` → `mod.fun(compile(a1), ..., compile(an))`
- Partially applied: wrap remaining args in a lambda

## Variable name recovery

Codegen maintains a name context mapping de Bruijn indices to variable names:
1. If the elaboration context has a user-provided name for the binding, use it (e.g., `x`, `xs`)
2. Otherwise, generate `_v0`, `_v1`, etc.
3. Names are disambiguated by appending a numeric suffix if shadowed

## Module compilation

- Each definition becomes `def` (if name is in exports list or exports = `:all`) or `defp` (if private)
- Definitions are erased, then compiled, then wrapped in `defmodule`

## Implementation notes

- Elixir quoted AST uses `{name, meta, args}` triple format
- `eval_expr/1` compiles the expression, then calls `Code.eval_quoted/1` and returns the result value

## Testing strategy

- **Unit tests**: each compilation rule individually
- **Integration**: end-to-end: source → parse → elaborate → check → erase → codegen → eval
- **Property tests**: compiled code produces same results as NbE evaluation (for total, terminating functions)
- **Erasure tests**: programs with erased arguments compile to code that doesn't reference them
