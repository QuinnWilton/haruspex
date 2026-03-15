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

### Dictionary passing (tier 6: type classes)

Type class dictionaries introduce additional compilation rules:

```
compile(DictCon(class, fields))     → %ClassName{field1: compile(f1), ...}
compile(DictAccess(dict, method))   → compile(dict).method
compile(InstanceArg(var))           → variable reference (same as Var — instance args are regular params after erasure)
```

- **Class declarations** compile to `defmodule` containing a struct definition. Each method becomes a struct field. Superclass dictionaries become nested struct fields.
- **Instance declarations** compile to a module with a `__dict__/n` function that constructs the struct. Arity `n` equals the number of instance constraints (sub-dictionaries to receive).
- **Instance arguments** in function signatures compile to regular function parameters — dictionary passing is explicit in the generated Elixir.
- **Method calls** compile to field access on the dictionary struct followed by application: `dict.method(arg1, arg2)`.

### Dictionary inlining (tier 6: type classes)

When the dictionary at a call site is a compile-time constant (the instance was fully resolved during checking with no remaining flex variables), codegen inlines the dictionary:

1. Replace `DictAccess(dict, method)` with the concrete function value from the resolved instance.
2. If the method body is a builtin (e.g., `Eq(Int).eq` → `Kernel.==/2`), emit the builtin directly.
3. If the method body is a user-defined function, emit a direct call to the instance module's function.

Example: `eq(42, 43)` with `Eq(Int)` resolved → `Kernel.==(42, 43)` (no dictionary struct allocated, no field access at runtime).

Inlining is an optimization, not a correctness requirement. Polymorphic call sites where the dictionary is a runtime parameter must use field access.

### Protocol bridge codegen (tier 6: type classes)

When a single-parameter class is annotated with `@protocol`:

1. **Protocol generation**: emit `defprotocol ClassName` with `def method(value, ...)` for each class method. The first argument is the dispatched-on value (the class's type parameter).
2. **Implementation generation**: for each instance of the class, emit `defimpl ClassName, for: ElixirType` delegating to the instance's method implementations.
3. **Type mapping**: Haruspex types map to Elixir protocol dispatch types — `Int` → `Integer`, `Float` → `Float`, `String` → `BitString`, ADTs → their generated struct module.

The bridge is one-directional: Haruspex callers always use dictionary passing internally; the protocol exists for Elixir callers to use Haruspex-defined abstractions.

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
