# haruspex

A dependently typed language with Elixir-like syntax, targeting the BEAM via Elixir code generation.

## What it does

Haruspex implements a Two-Level Type Theory (2LTT) with bidirectional type checking, normalization-by-evaluation, implicit arguments via pattern unification, a stratified universe hierarchy, algebraic data types with strict positivity, opt-in totality checking, refinement types via constrain, and e-graph optimization via quail. Built on roux for incremental computation.

## Architecture

```
Source text (.hx)
  → Tokenizer (NimbleParsec)        → token stream
  → Parser (recursive descent)      → surface AST with byte spans
  → Elaboration                     → core terms (de Bruijn indexed, metas, levels)
  → Type checker (bidirectional)    → fully elaborated core + types
  → Optimizer (quail e-graphs)      → optimized core
  → Codegen                         → Elixir quoted AST
```

### Module map

```
Haruspex                    — Roux.Lang behaviour, query definitions, pipeline orchestration
Haruspex.Tokenizer          — NimbleParsec tokenizer
Haruspex.Parser             — recursive descent parser over token stream
Haruspex.AST                — surface AST node types + helpers
Haruspex.Core               — core term structs (de Bruijn indexed, metas, levels, multiplicities)
Haruspex.Value              — value domain for NbE (closures, neutrals, type-tagged for eta)
Haruspex.Eval               — evaluation: Core.Term + Env → Value
Haruspex.Quote              — readback: Value → Core.Term (type-directed, eta-expanding)
Haruspex.Context            — typing context (bindings with multiplicities)
Haruspex.Unify              — metavariable solving + pattern unification + universe solving
Haruspex.Unify.MetaState    — meta context: Solved(value) | Unsolved(type, ctx)
Haruspex.Unify.LevelSolver  — universe level constraint solver
Haruspex.Elaborate          — surface AST → core terms (name resolution, implicits, holes, auto-implicits)
Haruspex.Mutual             — mutual block signature collection + cross-reference checking
Haruspex.Check              — bidirectional type checker
Haruspex.Pretty             — value → string pretty-printer (name recovery from de Bruijn levels)
Haruspex.Codegen            — core terms → Elixir quoted AST (type + proof erasure)
Haruspex.ADT                — ADT declarations + strict positivity checking
Haruspex.Record             — named record types (single-constructor ADTs, struct codegen)
Haruspex.Pattern            — pattern compilation + exhaustiveness + with-abstraction
Haruspex.TypeClass          — class/instance declarations, instance search, dictionaries
Haruspex.TypeClass.Search   — depth-bounded instance search with superclass resolution
Haruspex.TypeClass.Bridge   — optional protocol generation for single-param classes
Haruspex.Totality           — structural recursion checker for @total functions
Haruspex.Predicate          — refinement predicate language + constrain bridge
Haruspex.Optimizer          — e-graph optimization orchestration
Haruspex.Optimizer.Lower    — core → flat IR
Haruspex.Optimizer.Lift     — flat IR → core
Haruspex.Optimizer.Rules    — quail rewrite rules
Haruspex.Optimizer.Cost     — quail cost model
Haruspex.Definition         — roux entity for top-level definitions
Haruspex.MutualGroup        — roux entity for mutual definition groups
Haruspex.LSP                — LSP query delegation
```

## Development commands

```bash
mix test                      # run all tests
mix test --cover              # run tests with coverage (95% threshold)
mix format                    # format code
mix format --check-formatted  # check formatting
mix dialyzer                  # static analysis
```

## Commit message style

```
[component] brief description
```

Component names: `tokenizer`, `parser`, `core`, `nbe`, `unify`, `elaborate`, `check`, `codegen`, `adt`, `record`, `typeclass`, `totality`, `refinement`, `optimizer`, `lsp`, `mutual`, `docs`, `tests`, `scaffold`.
