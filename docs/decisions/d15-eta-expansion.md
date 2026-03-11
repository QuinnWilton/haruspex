# D15: Full eta-expansion in NbE

**Decision**: Perform full eta-expansion during type-directed readback for functions and pairs.

**Rationale**: Without eta-expansion, `f` and `fn x -> f(x)` are not convertible, causing surprising type errors. In a dependent type system where conversion checking is pervasive, missing eta leads to "these types should be equal but aren't" bugs that are hard for users to diagnose. Full eta is standard in modern dependent type checkers (Agda, Lean, Idris 2).

**Mechanism**: Readback (`quote`) is type-directed — it takes the type of the value being quoted:
- At function type (`VPi`): a neutral value `ne` is expanded to `Lam(quote(l+1, App(ne, Var(l)), cod_type))`
- At pair type (`VSigma`): a neutral value `ne` is expanded to `Pair(quote(l, Fst(ne), fst_type), quote(l, Snd(ne), snd_type))`
- At other types: neutrals are quoted structurally

This means `quote` has signature `quote(level, type, value) -> term` rather than the simpler `quote(level, value) -> term`.

**Cost**: Readback must know the type of every value it quotes. This type information is always available in the bidirectional checker (synth produces types, check receives expected types). The overhead is passing one extra argument through readback calls.

See [[d03-nbe-conversion]], [[../subsystems/05-values-nbe]].
