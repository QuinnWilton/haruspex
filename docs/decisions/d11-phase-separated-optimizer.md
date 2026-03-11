# D11: Phase-separated optimizer pipeline

**Decision**: The optimizer uses a four-phase pipeline (lower/saturate/extract/lift) with optimization boundaries at function definitions.

**Rationale**: Separating lowering from optimization from lifting keeps each phase simple and testable. Spans and type annotations are noise during optimization -- stripping them in the lower phase means rewrite rules don't need to handle them. Restoring dummy spans in the lift phase is straightforward. Function boundaries as optimization scope prevent cross-function rewrites that could interfere with incrementality.

**Mechanism**:
1. **Lower** (`Haruspex.Optimizer.Lower`): Core terms -> flat IR. Strips spans, type annotations, and universe levels. Each function body is lowered independently.
2. **Saturate** (`Haruspex.Optimizer.Rules`): Apply rewrite rules to the e-graph. Rules are grouped by category (arithmetic, boolean, conditional).
3. **Extract** (`Haruspex.Optimizer.Cost`): Implements `Quail.Extract` behaviour. Cost model favors fewer operations, smaller constants, and simpler control flow.
4. **Lift** (`Haruspex.Optimizer.Lift`): Flat IR -> core terms. Assigns dummy spans (`Pentiment.Span.Byte.empty()`).

See [[d07-quail-optimization]], [[../subsystems/10-optimizer]].
