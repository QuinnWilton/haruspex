# D18: Opt-in totality via @total

**Decision**: Totality checking is opt-in via the `@total` annotation on function definitions. Functions marked `@total` are verified to terminate via structural recursion.

**Rationale**: Mandatory totality is too restrictive for a general-purpose BEAM language. Servers loop forever, IO is inherently non-terminating, and many useful programs are intentionally partial. But opt-in totality lets users write provably terminating functions when they want guarantees — for example, functions used in type-level computation, or proofs that should be erased at runtime.

**Mechanism**: For `@total` functions:
1. Identify the "decreasing argument" — must be an ADT type (to have subterms to recurse on)
2. In every recursive call, the decreasing argument must be a strict structural subterm of the pattern-matched value
3. Simple structural decrease: matching `cons(x, rest)` and recursing on `rest` is valid; recursing on the original list is not
4. Mutual recursion: all functions in a mutual block must decrease on a shared measure (more complex, may be deferred)

Non-`@total` recursive functions compile normally — they just can't be used as compile-time proofs or in type-level computation where termination is required for consistency.

**Cost**: ~200 LOC for the structural decrease checker. The main complexity is tracking which argument is decreasing through nested pattern matches and ensuring all recursive paths decrease.

See [[d16-strict-positivity]], [[../subsystems/13-totality]].
