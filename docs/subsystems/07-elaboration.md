# Elaboration

## Purpose

Transforms surface AST into core terms. This is the sole bridge between human-readable surface syntax and the machine-oriented core calculus. Performs name resolution, de Bruijn indexing, implicit argument insertion, hole creation, universe elaboration, and multiplicity tracking. See [[../decisions/d08-elaboration-boundary]], [[../decisions/d14-implicits-from-start]], [[../decisions/d17-typed-holes]].

## Dependencies

- `Haruspex.AST` — surface input
- `Haruspex.Core` — core output
- `Haruspex.Context` — scope tracking
- `Haruspex.Unify.MetaState` — fresh meta allocation

## Key types

```elixir
@type elab_ctx :: %{
  names: [{atom(), ix()}],          # name-to-index mapping (stack)
  name_list: [atom()],              # parallel name list by de Bruijn level (for error recovery)
  level: non_neg_integer(),         # current binding depth
  holes: [hole_info()],             # accumulated hole metas
  meta_state: MetaState.t()         # reference to meta context
}

@type hole_info :: %{
  meta_id: Core.meta_id(),
  span: Pentiment.Span.Byte.t(),
  context_snapshot: [{atom(), Value.value()}]
}

@type elab_result :: {:ok, Core.term()} | {:error, elab_error()}
@type elab_error ::
  {:unbound_variable, atom(), Pentiment.Span.Byte.t()}
  | {:ambiguous_reference, atom(), Pentiment.Span.Byte.t()}
```

## Public API

```elixir
@spec elaborate(elab_ctx(), AST.expr()) :: elab_result()
@spec elaborate_def(elab_ctx(), AST.def_node()) :: {:ok, {Core.term(), Core.term()}} | {:error, elab_error()}
  # Returns {elaborated_type, elaborated_body}
@spec elaborate_type_expr(elab_ctx(), AST.type_expr()) :: elab_result()
```

## Algorithm

### Name resolution
- Maintain a stack of `{name, de_bruijn_index}` pairs
- When entering a binder (lambda, let, pi), push `{name, current_level}` and increment level
- Also append the name to `name_list` (indexed by de Bruijn level) — this list is passed to the checker for error message name recovery
- Variable lookup: scan stack from top, return index = `current_level - bound_level - 1`
- Unbound variable → error with span

### Implicit argument insertion
When elaborating `f(x)` where `f : {a : Type} -> a -> a`:
1. Elaborate `f` → synth its type
2. Count leading implicit Pi parameters
3. For each implicit param, insert `InsertedMeta(fresh_id, mask)`
4. Apply the function to the inserted metas, then to the explicit argument `x`
5. Result: `App(App(f, InsertedMeta(?a, mask)), x)`

### Hole creation
- `_` in source → `Meta(fresh_id)` in core
- Tag the meta as a "hole" in MetaState (distinct from implicit metas)
- Record span + context snapshot for later reporting

### Universe elaboration
- Bare `Type` → `Type(LVar(fresh_level_var))`
- `Type 0` → `Type(LLit(0))`

### Multiplicity
- `(0 x : T)` → Pi/Lam with mult = :zero
- Default multiplicity is :omega (unrestricted)

### Self-recursion
A `def` with a type annotation is treated as a mutual block of size 1:
1. Elaborate the type signature
2. Add the function name and type to the context (push onto `names`, extend typing context)
3. Elaborate the body — the function's own name resolves to a de Bruijn index
4. Check the body against the declared type

A type annotation is required for recursive functions. Non-recursive functions without annotations can have their types inferred via bidirectional checking. There is no fixpoint combinator — recursion is top-level only.

See [[../decisions/d25-mutual-blocks]] for the general mutual block mechanism.

## Implementation notes

- Elaboration is a recursive descent over the AST, producing core terms bottom-up
- Binary operators elaborate to `App(App(Builtin(op), lhs), rhs)`
- Pipeline `x |> f` desugars to `App(f, x)`
- `let x = e1 in e2` → `Let(elaborate(e1), elaborate_with_binding(x, e2))`
- Type annotations `(e : T)` → elaborate both, return `Ann(e_core, T_core)`

## Testing strategy

- **Unit tests**: Name resolution (correct indices), implicit insertion (correct meta count), hole creation
- **Property tests**: Elaboration of well-formed AST never crashes; every meta in output has a corresponding MetaState entry
- **Integration**: Full surface programs elaborate to expected core shapes
