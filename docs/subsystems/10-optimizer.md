# Optimizer

## Purpose

E-graph-based optimization using quail, following Lark's lower/saturate/extract/lift pipeline. Operates on core terms after type checking, before codegen. Optimization boundaries are at function definitions. See [[../decisions/d07-quail-optimization]], [[../decisions/d11-phase-separated-optimizer]].

## Dependencies

- `Haruspex.Core` — core term representation
- `quail` — e-graph equality saturation engine

## Key types

```elixir
# Flat IR for the e-graph (no spans, no types)
@type ir_node ::
  {:ir_var, non_neg_integer()}
  | {:ir_lit, term()}
  | {:ir_app, ir_node(), ir_node()}
  | {:ir_lam, ir_node()}
  | {:ir_let, ir_node(), ir_node()}
  | {:ir_builtin, atom(), [ir_node()]}
  | {:ir_pair, ir_node(), ir_node()}
  | {:ir_fst, ir_node()}
  | {:ir_snd, ir_node()}
  | {:ir_case, ir_node(), [{atom(), non_neg_integer(), ir_node()}]}
  | {:ir_con, atom(), [ir_node()]}
```

## Public API

```elixir
@spec optimize(Core.term()) :: Core.term()
@spec optimize_program([{atom(), Core.term()}]) :: [{atom(), Core.term()}]
```

## Pipeline

```
Core term
  │
  ▼
┌───────┐
│ Lower │  Strip spans, types, universe levels
└───┬───┘  → flat IR
    │
    ▼
┌────────────┐
│ Saturate   │  Apply rewrite rules via Quail.Rewrite
└───┬────────┘  → e-graph with equivalences
    │
    ▼
┌──────────┐
│ Extract  │  Quail.Extract behaviour → lowest-cost IR
└───┬──────┘
    │
    ▼
┌──────┐
│ Lift │  IR → Core terms with dummy spans
└──────┘
```

## Rewrite rules

Categories:
- **Arithmetic**: `x + 0 → x`, `x * 1 → x`, `x * 0 → 0`, constant folding
- **Boolean**: `not(not(x)) → x`, `x && true → x`, `x || false → x`
- **Conditional**: `if true do a else b → a`, `if false do a else b → b`
- **Application**: `(fn x -> body)(arg) → body[arg/x]` (beta reduction)

## Cost model

Implements `Quail.Extract` behaviour:
- Each node has a base cost (lit: 1, var: 1, app: 2, lam: 3, builtin: 2, etc.)
- Total cost is sum of children costs + base cost
- Preference: fewer nodes, smaller constants, simpler control flow

## Implementation notes

- Each function body is optimized independently (not cross-function)
- Optimization is optional — the compile pipeline works without it
- Dummy spans in lift: `Pentiment.Span.Byte.empty()` or similar
- Beta reduction in e-graph: careful with variable binding — may need to represent substitution explicitly in IR

## Testing strategy

- **Unit tests**: Lower/lift roundtrip preserves semantics, individual rules apply correctly
- **Integration**: Optimized programs produce same results as unoptimized
- **Property tests**: Optimization never changes program behavior (for terminating programs)
