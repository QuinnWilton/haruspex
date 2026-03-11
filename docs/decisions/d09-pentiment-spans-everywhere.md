# D09: Pentiment spans on all AST nodes

**Decision**: All AST nodes and diagnostics use `Pentiment.Span.Byte` for source positions.

**Rationale**: Consistent span representation across the entire compiler. Every node in the surface AST carries a span. Core terms carry spans for error reporting but spans are excluded from type equality and conversion checking -- two terms that differ only in spans are considered equal. This follows roux's convention and ensures that reformatting source code never invalidates cached type-checking results.

**Mechanism**: Surface AST nodes are tagged tuples `{tag, %Pentiment.Span.Byte{}, ...children}`. Core terms store spans in a sidecar (not in the main term structure) to keep conversion checking clean. Diagnostics carry the span of the offending term for precise editor highlighting.

**Cost**: ~10% overhead in AST node size. No impact on type checking performance since spans are excluded from comparison.

See [[../subsystems/03-ast]], [[../subsystems/04-core-terms]].
