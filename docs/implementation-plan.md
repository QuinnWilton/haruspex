# Implementation plan

## Build order

The implementation follows a tiered dependency structure. Each tier depends only on previous tiers.

```
Tier 0: Syntax foundation
  ├── Tokenizer (NimbleParsec)
  ├── Parser (recursive descent + Pratt)
  └── AST (surface node types)

Tier 1: Core type theory
  ├── Core terms (de Bruijn indexed, metas, levels, multiplicities)
  ├── Values + NbE (eval, type-directed quote with eta, conv)
  └── Typing context (bindings with multiplicities)

Tier 2: Type checking + implicits
  ├── Unification (meta solving, pattern unification, universe constraints)
  ├── Elaboration (surface → core, implicit insertion, holes, auto-implicits)
  ├── Checker (bidirectional synth/check, multiplicity tracking)
  ├── Pretty-printer (Value → String with name recovery from de Bruijn levels)
  ├── Error rendering (pentiment spans, expected/got types, suggestions)
  └── Mutual blocks (signature collection, cross-referencing)
  ★ Milestone: type-check programs with implicit args, typed holes, universes,
    auto-implicit variables, and mutual recursion; type errors show readable names

Tier 3: Codegen + pipeline
  ├── Codegen (type + multiplicity erasure, Elixir AST generation)
  ├── Roux query wiring (definput, defentity, defquery)
  └── Definition + MutualGroup entities
  ★ Milestone: end-to-end compilation of simply-typed programs to BEAM

Tier 4: Dependent types
  ├── Full Pi type support (dependent application)
  └── Sigma types (dependent pairs with eta)
  ★ Milestone: Vec(a, n)-style types compile and run

Tier 5: ADTs + Records
  ├── Type declarations + constructors
  ├── Strict positivity checking
  ├── Dependent pattern matching + with-abstraction
  ├── Exhaustiveness checking
  ├── Record declarations (single-constructor ADTs with named projections)
  └── Record codegen (Elixir structs)
  ★ Milestone: Option, List, Vec, Point defined and usable;
    records compile to structs; with-abstraction works for basic cases

Tier 6: Type classes
  ├── Class declarations → dictionary record types
  ├── Instance declarations → dictionary construction
  ├── Instance search (depth-bounded, with superclass resolution)
  ├── Instance arguments ([]) in elaboration
  ├── Dictionary-passing codegen
  └── Optional protocol bridge (@protocol annotation)
  ★ Milestone: Eq, Ord, Functor defined; member(42, [1,2,42]) works;
    protocol bridge generates working Elixir protocols

Tier 7: Totality
  ├── @total annotation + structural recursion checking
  └── Mutual totality (shared decreasing measure)
  ★ Milestone: total functions on ADTs verified at compile time

Tier 8: Refinements
  ├── Refinement type syntax
  ├── Constrain integration
  └── Assumption gathering + discharge
  ★ Milestone: non-zero division, positive integers checked

Tier 9: Optimization
  └── Quail integration (lower/saturate/extract/lift)
  ★ Milestone: arithmetic identities, constant folding

Tier 10: Editor integration
  ├── LSP queries (diagnostics, hover, goto-def, completions, hole info)
  ├── Tree-sitter grammar
  └── Zed extension
```

## Dependency graph

```
                    Tier 0
                   ┌──┴──┐
              Tokenizer  AST
                   │
                 Parser
                   │
                 Tier 1
              ┌────┼────┐
            Core  Value  Context
              │  ╱    ╲  │
            Eval    Quote│
              │         │
                 Tier 2
           ┌─────┼──────┐
        Unify   Elab   Checker
           │   (auto-   (mutual
           │  implicit)  blocks)
           │         │
                 Tier 3
           ┌─────┼──────┐
        Codegen Queries  Entities
           │
                 Tier 4
           ┌─────┴──────┐
        Pi types     Sigma types
           │
                 Tier 5
     ┌─────┼──────┬──────────┐
   ADTs  Records  Patterns  With-abs
     │      │        │
                 Tier 6
     ┌─────┼──────┬──────────┐
  Classes Instance Instance   Protocol
  (decl)  (decl)  search     bridge
     │
           Tiers 7-10
     ┌─────┼──────┬──────┐
  Totality Refine Optim  LSP
```

## What changed from v1

The original plan had 10 tiers (0-9). This revision adds:

| Feature | Decision | Tier | Rationale for placement |
|---------|----------|------|------------------------|
| Auto-implicits | [[decisions/d24-auto-implicit]] | 2 | Elaboration concern, no type-theory deps |
| Mutual blocks | [[decisions/d25-mutual-blocks]] | 2 | Needed for any non-trivial program |
| Records | [[decisions/d21-records]] | 5 | Single-constructor ADTs, needs ADT infra |
| With-abstraction | [[decisions/d22-with-abstraction]] | 5 | Dependent pattern matching extension |
| Type classes | [[decisions/d20-type-classes]] | 6 | Needs ADTs + Records (for dictionaries) |

Do-notation ([[decisions/d23-do-notation]]) was considered and rejected — the BEAM's natively effectful model makes monadic `<-` syntax unnecessary. Effects just work with regular `=` bindings. `Monad` can still be defined as a type class and used via explicit `bind` calls when needed.

Key ordering constraints:
- **Records before type classes**: class dictionaries *are* records
- **With-abstraction with ADTs**: with is a pattern-matching extension
- **Mutual blocks early**: needed as soon as programs have mutual recursion
- **Auto-implicits in Tier 2**: elaboration-only, no downstream deps

## Testing strategy by tier

| Tier | Unit tests | Property tests | Integration tests |
|------|-----------|----------------|-------------------|
| 0 | Token types, parse rules | Span coverage, parse roundtrip | Full programs tokenize+parse |
| 1 | eval/quote per term | NbE stability, eta laws | Normalize complex expressions |
| 2 | Each checker rule, mutual checking, pretty-printer output | Elaboration well-formedness, name recovery roundtrip | Type-check example programs with auto-implicits; error messages show readable names |
| 3 | Each codegen rule | Compile preserves semantics | Source → BEAM end-to-end |
| 4 | Dependent app/proj | — | Vec programs compile |
| 5 | Positivity, exhaustiveness, record projection, with-elaboration | Random ADT positivity | Option/List/Vec/Point examples, with-abstraction |
| 6 | Instance search, dictionary construction | Search determinism | Eq/Ord/Functor work, protocol bridge |
| 7 | Structural decrease, mutual decrease | — | @total examples |
| 8 | Discharge predicates | Entailment correctness | Refinement examples |
| 9 | Lower/lift roundtrip | Optimization preserves behavior | Optimized programs |
| 10 | LSP responses | — | Editor integration |

## Verification checklist (per tier)

1. `mix test` — all tests pass
2. `mix test --cover` — coverage meets 95% threshold
3. `mix format --check-formatted` — code is formatted
4. `mix dialyzer` — no warnings (when configured)
5. End-to-end: write a `.hx` file, verify expected behavior

## Implementation tasks

Detailed implementation tasks with testing and verification strategies are in [[tasks/impl/README]].

Each tier has:
- **Module tasks**: one per module to implement
- **Subsystem gap tasks**: documentation to fill before implementing
- **Completion criteria**: all tests pass, all decisions adhered to, dialyzer clean

## Cross-project verification

- `cd ../roux && mix test` — roux tests still pass
- Verify roux.lang integration with `mix compile.roux`
- `cd ../pentiment && mix test` — pentiment tests still pass
