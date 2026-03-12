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
- Maintain a stack of `{name, de_bruijn_level}` pairs
- When entering a binder (lambda, let, pi), push `{name, current_level}` and increment level
- Also append the name to `name_list` (indexed by de Bruijn level) — this list is passed to the checker for error message name recovery
- Variable lookup: scan stack from top, return index = `current_level - bound_level - 1`
- Unbound variable → error with span

### Name shadowing
When a name is pushed that already exists in the name stack, both entries coexist. Lookup scans from the top and returns the most recent (innermost) binding. The `name_list` appends the name regardless of shadowing, since it is indexed by de Bruijn level, not by name. This means `name_list` may contain duplicate names at different levels — the pretty-printer handles this by appending primes (`x'`, `x''`).

### Implicit argument insertion
When elaborating `f(x)` where `f : {a : Type} -> a -> a`:
1. Elaborate `f` → synth its type
2. Count leading implicit Pi parameters
3. For each implicit param, insert `InsertedMeta(fresh_id, mask)`
4. Apply the function to the inserted metas, then to the explicit argument `x`
5. Result: `App(App(f, InsertedMeta(?a, mask)), x)`

### Binding mask construction

When creating `InsertedMeta(id, mask)`, the mask determines which context variables the meta may depend on:
- `mask` is `[boolean()]` of length `ctx.level`
- `mask[i] = true` if level `i` is a lambda-bound variable (not let-bound) accessible at the insertion point
- `mask[i] = false` for let-bound variables (their values are already determined)
- The mask is used during meta solving to ensure solutions only reference variables that are in scope at the meta's insertion site

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

### Mutual block elaboration

For `mutual do def f ...; def g ... end`:
1. **Phase 1 — signatures**: elaborate all type signatures in order, producing core type terms
2. **Phase 2 — context extension**: evaluate all type terms to values, push all `{name, type_value}` pairs into the context simultaneously
3. **Phase 3 — bodies**: elaborate all bodies with the extended context — each body can reference all names in the mutual block

Each body is elaborated as if the full mutual group is in scope. The checker then type-checks each body against its declared type.

### Recursion detection

There is no explicit recursion detection. Every `def` with a type annotation is treated as potentially recursive — its name is added to context before body elaboration (per d25). This means a single `def` is handled as a mutual block of size 1. Non-recursive defs that omit the type annotation use pure bidirectional inference without self-reference.

### Auto-implicit resolution (d24)

When a `variable {a : Type}` declaration is in scope and the elaborator encounters `def f(x : a) : a do x end`:
1. Scan the function signature for free type variables
2. Match each free type variable against declared auto-implicit names
3. For each match, prepend an implicit parameter to the function's parameter list
4. Auto-implicits are inserted in declaration order, before explicit parameters
5. Result: `def f({a : Type}, x : a) : a do x end`

This is a surface-level transformation performed before the signature is elaborated to core terms.

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
