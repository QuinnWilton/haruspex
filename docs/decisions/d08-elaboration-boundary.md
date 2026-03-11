# D08: Strict elaboration boundary between surface and core

**Decision**: Maintain a strict separation between surface AST and core terms, with elaboration as the sole bridge.

**Rationale**: Surface syntax is for humans: named variables, syntactic sugar, implicit arguments marked with `{}`, `_` holes, bare `Type` without level annotations. Core terms are for the checker: de Bruijn indices, fully explicit types, all implicits resolved as metavariables, universe levels as variables. Mixing these concerns makes both the parser and checker harder to maintain and reason about.

**Mechanism**: The elaboration pass (`Haruspex.Elaborate`) performs:
- Name resolution with scoping (let, lambda, pi binders)
- Name-to-de-Bruijn-index conversion
- Implicit argument insertion (fresh metavariables for `{}` params)
- Hole creation (`_` -> fresh metavariable, tagged for hole reporting)
- Universe elaboration (`Type` -> `Type(?level)` with fresh level variable)
- Multiplicity tracking (`(0 x : T)` -> multiplicity annotation on Pi/Lam)
- `@total` annotation preservation as metadata

No information flows from core back to surface. Error messages recover names from the elaboration context.

See [[d02-debruijn-core]], [[d14-implicits-from-start]], [[d17-typed-holes]], [[../subsystems/07-elaboration]].
