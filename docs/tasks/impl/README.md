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

## Completed tiers

Tiers 0–6 are complete. Task files are in [`done/`](done/).

- **Tier 0**: Syntax foundation (tokenizer, parser, AST gaps)
- **Tier 1**: Core type theory (core terms, values/NbE, context)
- **Tier 2**: Type checking + implicits (unification, elaboration, checker, mutual, pretty, errors, subsystem gaps)
- **Tier 3**: Codegen + pipeline (codegen, queries, extern, subsystem gaps)
- **Tier 4**: Module system (modules, prelude)
- **Tier 5**: ADTs + records (ADTs, pattern matching, records, with-abstraction, subsystem gaps)
- **Tier 6**: Type classes (classes, instances, codegen, arithmetic overload, checker instance search, builtin operator removal, subsystem gaps)
- **Tier 7**: Totality (@total structural recursion, reduction gate)

## Architectural refactors (all complete)

1. ~~refactor-whnf~~ — proper weak head normal form with meta resolution
2. ~~refactor-ncase-closures~~ — closure-based ncase neutrals
3. ~~refactor-unified-elaboration~~ — unified elaboration+checking pipeline
4. ~~refactor-motive~~ — simplified motive computation (removed dead code)
5. ~~refactor-pipeline-collapse~~ — removed haruspex_check query

## Correctness fixes

Brittleness issues found by comparison with Agda/Lean/Idris compiler patterns.

1. [[fix-eval-ctx-threading]] — thread metas/defs through all closure evaluations (eval.ex, unify.ex); add missing vglobal cases
2. [[fix-ncase-scope-check]] — ncase scope/occurs check should inspect branch closures
3. [[fix-erase-subst]] — erasure should use eval+quote instead of syntactic subst
4. [[fix-with-convertibility]] — with-abstraction should use NbE conversion, not syntactic equality

Items 1-2 can be done independently and immediately. Item 3 is the big one — it eliminates the root cause of implicit reinsertion hacks, meta state discontinuity, and the `collect_total_defs` substitution. Items 4-5 are best done after 3.

## Remaining tiers

### Tier 7: Dependent types
Complete. Tasks in [`done/`](done/).
- Totality checking, reduction gate, GADT checking, length-indexed vectors

### Tier 8: Refinements
- [[tier8-refinements]] — refinement types, predicate language, constrain

### Tier 9: Optimization
- [[tier9-optimizer]] — quail integration, lower/lift/saturate/extract

### Tier 10: Editor integration
- [[tier10-lsp]] — LSP queries via roux
- [[tier10-tree-sitter]] — tree-sitter grammar + Zed extension
