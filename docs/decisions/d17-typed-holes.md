# D17: Typed holes

**Decision**: `_` in any expression position creates a typed hole that reports the expected type and local context to the user.

**Rationale**: Typed holes are essential for interactive development with dependent types. Without them, the user must figure out what type is needed from context alone, mentally simulating the type checker. Holes make the checker an interactive assistant: "I don't know what goes here; tell me what type you expect." This is standard in Agda (`?`), Idris (`_`), and Lean (`_`).

**Mechanism**: During elaboration, `_` becomes a fresh metavariable tagged as a "hole" (distinct from implicit argument metas). During checking, the checker attempts to solve it like any other meta. After checking a definition:
- Solved hole-metas: no diagnostic (the checker figured it out)
- Unsolved hole-metas: emit an informational diagnostic (not an error) listing:
  - The hole's expected type (pretty-printed with names recovered from context)
  - All bindings in scope with their types
  - The hole's source span for editor highlighting

Holes do not prevent compilation — they are warnings, not errors. This allows incremental development: write the type signature, fill the body with `_`, check what's needed, fill in pieces.

See [[d14-implicits-from-start]], [[d08-elaboration-boundary]], [[../subsystems/08-checker]].
