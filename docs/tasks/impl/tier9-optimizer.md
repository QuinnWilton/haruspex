# Tier 9: Optimization

**Modules**: `Haruspex.Optimizer`, `Haruspex.Optimizer.Lower`, `Haruspex.Optimizer.Lift`, `Haruspex.Optimizer.Rules`, `Haruspex.Optimizer.Cost`
**Subsystem doc**: [[../../subsystems/10-optimizer]]
**Decisions**: d07 (quail), d11 (phase-separated)

## Scope

Implement e-graph optimization via quail: lower core to flat IR, saturate with rewrite rules, extract optimal program, lift back to core.

## Implementation

### Four-phase pipeline

1. **Lower**: `Core.term → IR.node` — flatten to e-graph-friendly representation. De Bruijn indices preserved. Builtins and literals are IR leaves.
2. **Saturate**: apply rewrite rules (arithmetic identities, boolean simplification, conditional folding, beta reduction) until fixpoint or iteration limit
3. **Extract**: use cost model to select optimal representative from each e-class
4. **Lift**: `IR.node → Core.term` — reconstruct core terms with dummy spans

### Rewrite rules

- Arithmetic: `x + 0 → x`, `x * 1 → x`, `x * 0 → 0`, `x - x → 0`
- Boolean: `not(not(x)) → x`, `true and x → x`, `false or x → x`
- Conditional: `if true then a else b → a`, `if false then a else b → b`
- Beta: `(fn x -> body)(arg) → body[x := arg]` — requires careful substitution in IR

### Cost model

Base costs: `lit: 1, var: 1, app: 2, lam: 3, builtin: 2, case: 3, con: 2`. Total cost = sum of children + base.

### Specification gaps to resolve

- **Beta reduction in IR**: represent substitution explicitly as an IR node `{:subst, body, var, replacement}` that the extractor resolves. This avoids variable capture issues during saturation.
- **Iteration limit**: max 100 saturation iterations. E-graph size limit: 10000 nodes.
- **Per-function**: each function body optimized independently.

## Testing strategy

### Unit tests (`test/haruspex/optimizer_test.exs`)

- **Lower/lift roundtrip**: `lift(lower(t))` semantically equivalent to `t`
- **Arithmetic rules**: `x + 0` optimizes to `x`
- **Boolean rules**: `not(not(x))` optimizes to `x`
- **Conditional folding**: `if true then a else b` optimizes to `a`
- **Beta reduction**: `(fn x -> x + 1)(5)` optimizes to `6`
- **Cost model**: simpler terms preferred over complex equivalents

### Property tests

- **Semantics preservation**: for terminating programs, `eval(optimize(t))` equals `eval(t)`

### Integration tests

- Optimize a function with redundant arithmetic, verify codegen produces simpler output

## Verification

```bash
mix test test/haruspex/optimizer_test.exs
mix format --check-formatted
mix dialyzer
```
