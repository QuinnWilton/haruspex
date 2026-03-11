# Codegen

## Purpose

Transforms fully elaborated core terms into Elixir quoted AST for compilation to BEAM. Performs type erasure (removing all type-level terms) and multiplicity erasure (removing 0-multiplicity arguments). See [[../decisions/d19-erasure-annotations]].

## Dependencies

- `Haruspex.Core` — core term input

## Key types

```elixir
@type elixir_ast :: Macro.t()  # Elixir's quoted AST format
```

## Public API

```elixir
@spec compile_module(atom(), :all | [atom()], [{Core.term(), Core.term()}], map()) :: elixir_ast()
  # compile_module(module_name, exports, [{type, body}], options)
@spec compile_expr(Core.term()) :: elixir_ast()
@spec eval(Core.term()) :: term()
@spec eval_program([{atom(), Core.term(), Core.term()}]) :: %{atom() => term()}
```

## Erasure rules

1. **Type erasure**: `Pi`, `Sigma`, `Type`, type annotations → removed entirely
2. **Multiplicity erasure**:
   - `Lam(:zero, body)` → skip this lambda, compile body with one fewer parameter
   - `App(f, arg)` where the corresponding Pi has mult = :zero → skip this argument
3. **Meta erasure**: All metas must be solved before codegen; `Meta(id)` → error (should not occur)
4. **Universe erasure**: `Type(l)` → removed

## Compilation rules

```
compile(Var(ix))          → variable reference (index to name via context)
compile(Lam(:omega, body)) → fn(var -> compile(body))
compile(Lam(:zero, body))  → compile(body)  # skip erased lambda
compile(App(f, a))         → apply(compile(f), compile(a))  # unless erased
compile(Let(def, body))    → (fn var -> compile(body)).(compile(def))
compile(Lit(v))            → v
compile(Builtin(:add))     → &Kernel.+/2  or inline
compile(Pair(a, b))        → {compile(a), compile(b)}
compile(Fst(e))            → elem(compile(e), 0)
compile(Snd(e))            → elem(compile(e), 1)
compile(Con(type, ctor, args)) → {ctor, compile(arg1), ...}
compile(Case(scrut, branches)) → case compile(scrut) do ... end
```

## Implementation notes

- Variable names recovered from a codegen context (index → generated name like `_v0`, `_v1`)
- Elixir quoted AST uses `{name, meta, args}` triple format
- Module compilation wraps functions in `defmodule` + `def`
- Exports control which functions get `def` vs `defp`
- Builtins mapped to Elixir Kernel functions where possible

## Testing strategy

- **Unit tests**: Each compilation rule individually
- **Integration**: End-to-end: source → parse → elaborate → check → codegen → eval
- **Property tests**: Compiled code produces same results as NbE evaluation (for total, terminating functions)
- **Erasure tests**: Programs with erased arguments compile to code that doesn't reference them
