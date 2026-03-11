# Implementation tasks

Concrete implementation tasks organized by tier. Each tier must be fully complete — all tests passing, all decisions adhered to, all subsystems implemented — before moving to the next.

## Completion criteria (all tiers)

A tier is complete when:

1. All modules listed in the tier are implemented with full typespecs
2. All public APIs match their subsystem doc signatures
3. `mix test` passes with zero failures
4. `mix test --cover` passes the 95% coverage threshold
5. `mix format --check-formatted` passes
6. `mix dialyzer` passes with zero warnings
7. Every decision doc applicable to the tier is respected
8. Property tests cover core invariants
9. Negative tests cover error paths
10. Integration tests demonstrate the tier's milestone
11. All changes are committed with atomic, bisect-able commits following `[component] description` style

## Task index

### Tier 0: Syntax foundation
- [[tier0-tokenizer]] — NimbleParsec tokenizer
- [[tier0-parser]] — recursive descent + Pratt parser
- [[tier0-ast-gaps]] — fill AST specification gaps

### Tier 1: Core type theory
- [[tier1-core-terms]] — core term representation
- [[tier1-values-nbe]] — values, eval, quote, NbE
- [[tier1-context]] — typing context with multiplicities

### Tier 2: Type checking + implicits
- [[tier2-unification]] — meta solving, pattern unification, level solver
- [[tier2-elaboration]] — surface → core, implicits, holes, auto-implicits
- [[tier2-checker]] — bidirectional synth/check, multiplicity tracking
- [[tier2-mutual]] — mutual block signature collection
- [[tier2-pretty]] — value → string pretty-printer
- [[tier2-errors]] — error rendering with pentiment spans
- [[tier2-subsystem-gaps]] — fill specification gaps blocking implementation

### Tier 3: Codegen + pipeline
- [[tier3-codegen]] — type + multiplicity erasure, Elixir AST generation
- [[tier3-queries]] — roux query wiring, entities
- [[tier3-extern]] — extern function declarations and codegen
- [[tier3-subsystem-gaps]] — fill specification gaps

### Tier 4: Module system
- [[tier4-modules]] — file → module mapping, imports, visibility
- [[tier4-prelude]] — auto-imported prelude with builtins

### Tier 5: ADTs + records
- [[tier5-adts]] — type declarations, constructors, positivity
- [[tier5-pattern-matching]] — case trees, coverage, dependent matching
- [[tier5-records]] — single-constructor ADTs, struct codegen
- [[tier5-with-abstraction]] — dependent matching on computed values
- [[tier5-subsystem-gaps]] — fill specification gaps

### Tier 6: Type classes
- [[tier6-classes]] — class declarations, dictionary types
- [[tier6-instances]] — instance declarations, search, coherence
- [[tier6-codegen]] — dictionary passing, protocol bridge
- [[tier6-arithmetic-overload]] — migrate builtins to typeclass methods
- [[tier6-subsystem-gaps]] — fill specification gaps

### Tier 7: Totality
- [[tier7-totality]] — @total structural recursion checking
- [[tier7-reduction-gate]] — totality gates type-level reduction

### Tier 8: Refinements
- [[tier8-refinements]] — refinement types, predicate language, constrain

### Tier 9: Optimization
- [[tier9-optimizer]] — quail integration, lower/lift/saturate/extract

### Tier 10: Editor integration
- [[tier10-lsp]] — LSP queries via roux
- [[tier10-tree-sitter]] — tree-sitter grammar + Zed extension
