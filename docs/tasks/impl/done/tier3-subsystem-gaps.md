# Tier 3: Subsystem specification gaps

## Resolved gaps

### 1. Codegen (subsystems/09-codegen.md) — DONE

- **Complete builtin mapping table**: added all builtins from d26 with Elixir Kernel equivalents
- **Extern codegen rules**: added unapplied, fully-applied, and partially-applied extern compilation
- **Variable name recovery algorithm**: documented index → name mapping with user name preference and disambiguation
- **Fully-applied builtin optimization**: documented inlining for full application, capture for partial application
- **`compile_module` signature**: fixed to `[{atom(), Core.term(), Core.term()}]` (name, type, body) — subsystem doc had wrong 2-tuple
- **`eval` → `eval_expr` rename**: renamed to avoid collision with NbE `Eval` module
- **Removed `eval_program`**: unnecessary; `compile_module` + `Code.eval_quoted` covers this
- **Post-erasure compilation**: codegen now operates on erased core only, compilation rules simplified

### 2. Erasure (subsystems/14-erasure.md) — DONE

- **`Haruspex.Erase` pass**: added as dedicated pass between check and codegen, walking term+type in lockstep
- **Type reconstruction for App**: documented how the type is threaded to determine multiplicity
- **Postconditions**: documented what the erased output guarantees (no `:zero` lams, no type nodes, etc.)
- **`Spanned` handling**: strip and recurse
- **`Meta`/`InsertedMeta` handling**: raise `CompilerBug`
- **`Let` with type-level binding**: eliminate entirely

### 3. Queries (subsystems/15-queries.md) — DONE

- **Diagnostic type definition**: added `@type diagnostic` with severity, message, span
- **URI type**: added `@type uri :: String.t()` with format documentation
- **Error propagation**: documented `query!/3` short-circuit pattern and diagnostics aggregation
- **Optimize query**: noted as deferred to tier 9; codegen reads from check directly in tiers 3-8

### 4. Deferred (require systems from later tiers)

- **Cross-module query dependencies**: deferred to tier 4 (module system). Mechanism is standard roux dependency tracking via `query/3` — no special infrastructure needed.
- **`@total` body access via roux**: deferred to tier 7 (totality). Evaluator calls `query(db, :haruspex_check, {uri, name})` to get body. No circularity — check produces body, eval consumes other definitions' bodies.
- **Bool codegen**: deferred to tier 5 (ADTs). `VCon(:Bool, :true, [])` → `true` requires `Con`/`Case` codegen.
- **`Con`/`Case`/`Data` codegen**: deferred to tier 5 (ADTs). Core terms exist but can't be produced until ADT declarations are implemented.

## Deliverable

Updated subsystem docs 09-codegen.md, 14-erasure.md, and 15-queries.md.
