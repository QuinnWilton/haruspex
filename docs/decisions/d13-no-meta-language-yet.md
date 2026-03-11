# D13: No meta language yet

**Decision**: The 2LTT meta language is deferred; only the object language is implemented initially.

**Rationale**: The object language (dependent types, ADTs, refinements, totality) is complex enough to get right on its own. Adding a meta language for typed compile-time computation introduces staging concerns, cross-level type interactions, and macro hygiene issues that would slow down core development. The meta language can be designed more effectively once the object language is stable and its limitations are understood through real use.

**Trade-off**: Without a meta language, compile-time computation is limited to what the type checker's normalization handles. Users can't write custom type-level functions beyond what the built-in type formers provide. This is acceptable — most dependent type languages ship without staging initially.

**Scope**: Object language covers Pi, Sigma, refinements, ADTs, totality, erasure, universes. Meta language (deferred) would add staging annotations, compile-time evaluation, typed macros.
