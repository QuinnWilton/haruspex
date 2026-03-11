# D14: Implicit arguments from the start

**Decision**: Build implicit argument support (metavariables + pattern unification) into the checker from day one, not retrofitted later.

**Rationale**: Without implicits, dependent types are too verbose to be usable — every type parameter must be written explicitly. `id(Int, 42)` instead of `id(42)`. Designing the checker around metavariables from the start is far cleaner than adding them later. Retrofitting implicits requires restructuring the elaboration pass, the checker's mode switching, and the error reporting — essentially rewriting the core.

**Mechanism**: During elaboration, implicit arguments (marked with `{}` in function signatures) become fresh metavariables. When applying a function with implicit parameters, the elaborator inserts `InsertedMeta(id, mask)` nodes. During checking, unification attempts to solve these metavariables. Unsolved metas at definition boundaries produce "could not infer" errors.

Uses Miller pattern unification: a metavariable `?m` applied to a spine of distinct bound variables can be solved if the solution mentions only those variables. This is first-order, decidable, and sufficient for most practical cases (type argument inference, simple polymorphism). Higher-order unification is undecidable and not attempted.

**Pruning**: When unifying `?m(x, y)` with a term not mentioning `y`, the solver prunes `y` from the meta's spine and adjusts the solution accordingly.

See [[d08-elaboration-boundary]], [[d04-bidirectional-checking]], [[../subsystems/06-unification]], [[../subsystems/07-elaboration]].
