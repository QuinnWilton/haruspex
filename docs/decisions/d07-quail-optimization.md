# D07: Quail for e-graph optimization

**Decision**: Use quail's e-graph equality saturation for optimization, following Lark's proven pattern.

**Rationale**: E-graphs handle the phase ordering problem naturally -- all rewrites are applied simultaneously, and the best program is extracted according to a cost model. Quail is already battle-tested in Lark. The lower/saturate/extract/lift pipeline cleanly separates optimization from AST and type concerns.

**Mechanism**: The optimizer has four phases:
1. **Lower**: Strip spans and type annotations from core terms, convert to quail's flat IR
2. **Saturate**: Apply rewrite rules via `Quail.Rewrite.rewrite/3` and `birewrite/3`
3. **Extract**: Find the lowest-cost equivalent program via `Quail.Extract`
4. **Lift**: Convert flat IR back to core terms with dummy spans

Rule categories: arithmetic identities, boolean simplification, conditional optimization, dependent-type-aware rewrites (e.g., erased terms -> unit).

See [[d11-phase-separated-optimizer]], [[../subsystems/10-optimizer]].
