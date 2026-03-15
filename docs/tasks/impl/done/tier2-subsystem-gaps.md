# Tier 2: Subsystem specification gaps

**Subsystem docs**: 06-unification, 07-elaboration, 08-checker
**Decisions**: d04, d05, d08, d14, d17, d19, d24, d25, d26, d28

## Scope

Fill specification gaps in subsystem docs that block Tier 2 implementation. These are documentation tasks — update the subsystem docs before implementing.

## Gaps to fill

### 1. Unification (subsystems/06-unification.md)

- **Pattern check output**: define `check_pattern(spine) → {:ok, [lvl()]}` — returns the list of de Bruijn levels of the distinct bound variables in the spine
- **Abstract function**: define `abstract(rhs, [lvl()]) → Core.term()` — wraps `rhs` in lambdas binding the spine variables, converting levels to de Bruijn indices
- **Scope escape check**: syntactic walk of the RHS verifying all free variables are in the spine's level list
- **Unify_neutral**: structural comparison of neutral spines — same head, pairwise-unify arguments
- **Force semantics**: `force(val)` follows solved-meta chains. Cycle detection: if a meta points to itself, leave as unsolved (do not loop). Max chain depth: 100 (defensive, should never be hit in practice).
- **Level solver**: fixpoint iteration with max 100 iterations. Initialize level variables to `LLit(0)`. At each step, apply constraints to update assignments. Unsatisfiable constraints (e.g., `?l = ?l + 1`) produce `{:error, {:universe_cycle, ...}}`.

### 2. Elaboration (subsystems/07-elaboration.md)

- **Binding mask construction**: when creating `InsertedMeta(id, mask)`, mask is `[boolean()]` of length `ctx.level`. `mask[i] = true` if level `i` is a lambda-bound variable (not let-bound) accessible at the insertion point.
- **Auto-implicit resolution (d24)**: when elaborating `def f(x : a) : a do x end` and `variable {a : Type}` is in scope, the elaborator checks for free type variables in the signature that match auto-implicit names. For each match, prepend an implicit parameter `{a : Type}` to the function's parameter list. Auto-implicits are inserted in declaration order, before explicit parameters.
- **Name shadowing**: when a name is pushed that already exists in the name stack, both entries coexist. Lookup returns the most recent (innermost). The `name_list` (for error recovery) appends the name regardless, since it's indexed by de Bruijn level, not by name.
- **Mutual block elaboration**: elaborate all signatures first (phase 1), add all names+types to context (phase 2), then elaborate all bodies (phase 3). Each body can reference all names in the mutual block.
- **Recursion detection**: not explicit. Every `def` with a type annotation is treated as potentially recursive (its name is added to context before body elaboration, per d25). Non-recursive defs that omit the type annotation use pure bidirectional inference.

### 3. Checker (subsystems/08-checker.md)

- **Computational position**: a position is computational if it contributes to the runtime value. Computational positions: function bodies, let definitions, case scrutinees, case branch bodies, pair components, application arguments (when the parameter has `:omega` multiplicity). Non-computational: type annotations, Pi/Sigma domain/codomain (these are types), arguments to `:zero` multiplicity parameters.
- **Usage tracking through scopes**: usage counters are per-binding, incremented in `synth(Var(ix))`. At lambda/let scope exit, check the innermost binding's usage against its multiplicity. Usage in nested scopes counts toward the enclosing binding.
- **Universe constraint generation**: `check_is_type(ctx, term)` synthesizes the term's type and verifies it's `VType(l)`. If `l` is a level variable, record `{:leq, l, ...}` constraints. Pi types generate `{:eq, result_level, {:lmax, dom_level, cod_level}}`.
- **Implicit vs hole metas**: implicit metas are created by `InsertedMeta` expansion with a special tag in `MetaState`. Hole metas are created by `_` in source. At post-definition processing: unsolved implicit metas → "could not infer" error. Unsolved hole metas → informational hole report (not an error).
- **Zonking**: walk the term, replacing `Meta(id)` with `quote(solution)` for solved metas. If a meta is unsolved and is an implicit → error. If unsolved and is a hole → leave as-is (or replace with a placeholder for codegen).

### 4. MetaState (new section in subsystems/06-unification.md)

Define the meta context as a persistent data structure:

```elixir
@type t :: %{
  next_id: meta_id(),
  entries: %{meta_id() => meta_entry()}
}

@type meta_entry ::
  {:unsolved, type :: Value.value(), ctx_level :: non_neg_integer(), kind :: :implicit | :hole}
  | {:solved, Value.value()}
```

- `fresh_meta(state, type, level, kind)` → `{id, updated_state}`
- `solve(state, id, value)` → `updated_state` (error if already solved with different value)
- `lookup(state, id)` → `meta_entry()`
- `force(state, value)` → follow solved meta chains

MetaState is threaded explicitly through elaboration and checking (not process dictionary).

## Deliverable

Updated subsystem docs 06, 07, 08 with the above specifications. No code — just documentation.

## Verification

Review each subsystem doc for completeness against the gaps listed. Every algorithm should have enough detail to implement without guessing.
