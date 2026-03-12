# Checker (bidirectional)

## Purpose

Bidirectional type checker with synth and check modes. Uses NbE for type equality via unification (which can solve metavariables). Tracks multiplicities for erasure checking. Reports typed holes. See [[../decisions/d04-bidirectional-checking]], [[../decisions/d05-universe-hierarchy]], [[../decisions/d15-eta-expansion]].

## Dependencies

- `Haruspex.Core` — term representation
- `Haruspex.Value` — value domain
- `Haruspex.Eval` — evaluation
- `Haruspex.Quote` — readback
- `Haruspex.Context` — typing context
- `Haruspex.Unify` — unification + meta solving

## Key types

```elixir
@type check_ctx :: %{
  context: Context.t(),           # typing context with multiplicities
  names: [atom()],                # parallel name list by de Bruijn level (from elaboration, for error messages)
  meta_state: MetaState.t(),      # meta context
  level_constraints: [Unify.level_constraint()],
  holes: [hole_report()]
}

@type hole_report :: %{
  span: Pentiment.Span.Byte.t(),
  expected_type: String.t(),       # pretty-printed
  bindings: [{atom(), String.t()}] # names and types in scope
}

@type check_result :: {:ok, Core.term(), Value.value()} | {:error, type_error()}
@type type_error ::
  {:type_mismatch, expected :: Value.value(), got :: Value.value(), Pentiment.Span.Byte.t()}
  | {:not_a_function, Value.value(), Pentiment.Span.Byte.t()}
  | {:not_a_pair, Value.value(), Pentiment.Span.Byte.t()}
  | {:unsolved_meta, Core.meta_id(), Value.value(), Pentiment.Span.Byte.t()}
  | {:multiplicity_violation, atom(), Pentiment.Span.Byte.t()}
  | {:universe_error, String.t(), Pentiment.Span.Byte.t()}
```

## Public API

```elixir
@spec synth(check_ctx(), Core.term()) :: {:ok, {Core.term(), Value.value()}} | {:error, type_error()}
@spec check(check_ctx(), Core.term(), Value.value()) :: {:ok, Core.term()} | {:error, type_error()}
@spec check_definition(check_ctx(), Core.term(), Core.term()) :: {:ok, check_ctx()} | {:error, type_error()}
  # check_definition(ctx, type_term, body_term)
```

## Core rules

### Synth mode (infer type)
```
synth(ctx, Var(ix)):
  type = Context.lookup(ctx, ix)
  check_multiplicity(ctx, ix)  # if erased, must be in erased position
  {:ok, {Var(ix), type}}

synth(ctx, Ann(e, ty)):
  ty_val = eval(ctx.env, ty)
  e' = check(ctx, e, ty_val)
  {:ok, {e', ty_val}}

synth(ctx, App(f, a)):
  {f', f_ty} = synth(ctx, f)
  case f_ty:
    VPi(mult, dom, env, cod):
      a' = check(ctx, a, dom)
      a_val = eval(ctx.env, a')
      {:ok, {App(f', a'), eval([a_val | env], cod)}}
    _ -> {:error, {:not_a_function, f_ty, span}}

synth(ctx, Fst(e)):
  {e', e_ty} = synth(ctx, e)
  case e_ty:
    VSigma(a, _, _): {:ok, {Fst(e'), a}}
    _ -> {:error, {:not_a_pair, e_ty, span}}

synth(ctx, Snd(e)):
  {e', e_ty} = synth(ctx, e)
  case e_ty:
    VSigma(a, env, b):
      fst_val = vfst(eval(ctx.env, e'))
      {:ok, {Snd(e'), eval([fst_val | env], b)}}

synth(ctx, Type(l)):
  {:ok, {Type(l), VType(LSucc(l))}}

synth(ctx, Pi(mult, dom, cod)):
  {dom', dom_level} = check_is_type(ctx, dom)
  ctx' = Context.extend(ctx, eval(ctx.env, dom'), mult)
  {cod', cod_level} = check_is_type(ctx', cod)
  result_level = LMax(dom_level, cod_level)
  {:ok, {Pi(mult, dom', cod'), VType(result_level)}}

synth(ctx, Lit(n)) when is_integer(n): {:ok, {Lit(n), VBuiltin(:Int)}}
synth(ctx, Lit(f)) when is_float(f):   {:ok, {Lit(f), VBuiltin(:Float)}}
# etc.

synth(ctx, Meta(id)):
  case MetaState.lookup(id):
    {:unsolved, type, _}: {:ok, {Meta(id), type}}
    {:solved, val}: synth(ctx, quote(ctx.level, val))
```

### Check mode (verify against expected type)
```
check(ctx, Lam(mult, body), VPi(pi_mult, dom, env, cod)):
  # mult must match pi_mult
  ctx' = Context.extend(ctx, dom, pi_mult)
  arg = fresh_var(ctx.level, dom)
  cod_val = eval([arg | env], cod)
  body' = check(ctx', body, cod_val)
  {:ok, Lam(mult, body')}

check(ctx, Pair(a, b), VSigma(fst_ty, env, snd_ty)):
  a' = check(ctx, a, fst_ty)
  a_val = eval(ctx.env, a')
  snd_ty_val = eval([a_val | env], snd_ty)
  b' = check(ctx, b, snd_ty_val)
  {:ok, Pair(a', b')}

check(ctx, Let(def, body), expected):
  {def', def_ty} = synth(ctx, def)
  def_val = eval(ctx.env, def')
  ctx' = Context.extend_def(ctx, def_ty, def_val)
  body' = check(ctx', body, expected)
  {:ok, Let(def', body')}

check(ctx, term, expected):
  # Fallback: synth and unify
  {term', inferred} = synth(ctx, term)
  unify(ctx.level, inferred, expected)
  {:ok, term'}
```

### Post-definition processing
After checking a definition:
1. Collect unsolved hole-metas → hole reports (informational diagnostics)
2. Collect unsolved implicit metas → "could not infer" errors
3. Run `LevelSolver.solve()` on accumulated universe constraints
4. Zonk: substitute all solved metas in the elaborated term

## Error pretty-printing

Type errors carry values and spans but values contain de Bruijn indices, not names. The `names` list in `check_ctx` (populated by elaboration) maps de Bruijn levels back to user-chosen names.

### Pretty-printer (`Haruspex.Pretty`)

`Value → String` conversion using the name context:

- **Name recovery**: de Bruijn level `l` → `names[l]`. On shadowing, append primes: `x`, `x'`, `x''`.
- **Arrow sugar**: `VPi(:omega, dom, _, cod)` where the binding is unused → `dom -> cod` instead of `(x : dom) -> cod`.
- **Implicit braces**: `VPi` from an implicit parameter → `{a : Type} -> ...`.
- **Solved implicits**: elided by default in error messages, shown with a verbose flag.
- **Builtins**: `VBuiltin(:Int)` → `Int`, not `Builtin(:Int)`.

### Error rendering

Errors are rendered using pentiment spans for source context (underlined spans, margin annotations). The structure:

```elixir
@type rendered_error :: %{
  message: String.t(),                 # one-line summary
  span: Pentiment.Span.Byte.t(),       # primary location
  expected: String.t() | nil,          # pretty-printed expected type
  got: String.t() | nil,              # pretty-printed actual type
  notes: [String.t()],                # additional context or suggestions
}
```

## Implementation notes

### Computational vs non-computational positions

A position is **computational** if it contributes to the runtime value. This distinction determines where erased (`:zero` multiplicity) bindings may appear.

**Computational positions** (`:zero` bindings may NOT be used here):
- Function bodies
- Let definitions (the bound expression)
- Case scrutinees
- Case branch bodies
- Pair components
- Application arguments when the parameter has `:omega` multiplicity

**Non-computational positions** (`:zero` bindings may be used here):
- Type annotations
- Pi/Sigma domain and codomain (these are types)
- Arguments to `:zero` multiplicity parameters (erased positions)

### Usage tracking through scopes

- Each binding in the context has a usage counter, initialized to 0.
- `synth(Var(ix))` increments the usage counter for the binding at index `ix`.
- At lambda/let scope exit, check the innermost binding's usage against its multiplicity:
  - `:zero` — usage must be exactly 0
  - `:omega` — any usage count is permitted (including 0)
- Usage in nested scopes counts toward the enclosing binding. For example, if a lambda uses a variable from an outer scope, that outer variable's usage counter is incremented.

### Universe constraint generation

`check_is_type(ctx, term)` synthesizes the term's type and verifies it is `VType(l)` for some level `l`, returning the level. When `l` is a level variable, the checker records level constraints:
- Pi types: `{:eq, result_level, {:lmax, dom_level, cod_level}}` — the universe of a Pi type is the max of its domain and codomain universes.
- Sigma types: analogous to Pi.
- When checking `Type(l)` synthesizes `VType(LSucc(l))`, the successor relationship is structural (not a constraint).
- If `check_is_type` encounters a type that does not synthesize to `VType(_)`, it produces `{:error, {:universe_error, msg, span}}`.

### Implicit vs hole metas

Both implicit metas and hole metas are entries in MetaState, distinguished by their `kind` field:
- **Implicit metas** (`kind: :implicit`): created by `InsertedMeta` expansion during elaboration. At post-definition processing, unsolved implicit metas produce `{:error, {:unsolved_meta, id, type, span}}` — "could not infer implicit argument of type `T`".
- **Hole metas** (`kind: :hole`): created by `_` in source. At post-definition processing, unsolved hole metas produce informational hole reports (not errors), showing the expected type and available bindings at the hole's location.

### Zonking

Final pass that walks the elaborated core term, substituting solved metas with their solutions:

```
zonk(meta_state, term):
  case term:
    Meta(id) ->
      case lookup(meta_state, id):
        {:solved, val} -> zonk(meta_state, quote(level, val))
        {:unsolved, _, _, :implicit} -> error: "could not infer"
        {:unsolved, _, _, :hole} -> term  # leave as-is (or replace with placeholder for codegen)
    App(f, a) -> App(zonk(meta_state, f), zonk(meta_state, a))
    Lam(m, body) -> Lam(m, zonk(meta_state, body))
    Pi(m, dom, cod) -> Pi(m, zonk(meta_state, dom), zonk(meta_state, cod))
    # ... recurse into all sub-terms
    _ -> term  # Var, Lit, Builtin, Type are already zonked
```

## Testing strategy

- **Unit tests**: Each rule tested individually (var, app, lam, pi, let, lit, ann)
- **Integration**: Full programs type-check correctly; ill-typed programs produce expected errors
- **Property tests**: Well-typed terms check successfully; the checker is deterministic (same input → same output)
- **Hole tests**: Programs with `_` produce hole reports with correct types and context
- **Universe tests**: Polymorphic identity function gets correct universe levels
- **Multiplicity tests**: Using erased argument in computational position → error
