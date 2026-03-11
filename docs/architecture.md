# Haruspex architecture

Haruspex is a dependently typed language with Elixir-like syntax, targeting the BEAM via Elixir code generation. It implements bidirectional type checking with normalization-by-evaluation (NbE), implicit argument inference via pattern unification, and a stratified universe hierarchy. The language is built on roux for incremental computation, uses pentiment for source spans, constrain for refinement type discharge, and quail for e-graph optimization.

The name comes from the ancient Etruscan practice of divination through inspection — Haruspex inspects your programs at a deeper level than surface types allow.

## Core idea

A program is a collection of top-level definitions. Each definition has a type (which may be dependent — referencing runtime values) and a body. The compiler elaborates surface syntax into a core calculus with de Bruijn indices, checks types bidirectionally (synthesizing types upward, checking types downward), and uses NbE to decide type equality. Implicit arguments are inserted as metavariables during elaboration and solved by pattern unification during checking. The checked core is erased (removing types, proofs, and 0-multiplicity arguments) and compiled to Elixir quoted AST for BEAM execution.

## System layers

```
┌─────────────────────────────────────────────────┐
│ Layer 5: Editor integration                     │
│   LSP adapter (hover, goto-def, completions,    │
│   hole info), tree-sitter grammar, Zed ext      │
├─────────────────────────────────────────────────┤
│ Layer 4: Roux queries                           │
│   parse, elaborate, check, totality_check,      │
│   optimize, codegen, compile, diagnostics       │
├─────────────────────────────────────────────────┤
│ Layer 3: Language features                      │
│   ADTs + positivity, refinements + constrain,   │
│   totality checking, erasure, optimization      │
├─────────────────────────────────────────────────┤
│ Layer 2: Type core                              │
│   checker (synth/check), unification (metas,    │
│   pattern unif, universe solving), NbE (eval,   │
│   quote, eta), elaboration, codegen             │
├─────────────────────────────────────────────────┤
│ Layer 1: Syntax                                 │
│   tokenizer (NimbleParsec), recursive descent   │
│   parser, surface AST, core terms               │
└─────────────────────────────────────────────────┘
```

## Module map

```
Haruspex                    — Roux.Lang behaviour, query definitions, pipeline orchestration
Haruspex.Tokenizer          — NimbleParsec tokenizer (keywords, operators, literals, identifiers)
Haruspex.Parser             — recursive descent parser over token stream
Haruspex.AST                — surface AST node types + helpers
Haruspex.Core               — core term structs (de Bruijn indexed, with metas + levels + multiplicities)
Haruspex.Value              — value domain for NbE (closures, neutrals, type-tagged for eta)
Haruspex.Eval               — evaluation: Core.Term + Env → Value
Haruspex.Quote              — readback: Value → Core.Term (type-directed, eta-expanding)
Haruspex.Context            — typing context (bindings indexed by de Bruijn level, with multiplicities)
Haruspex.Unify              — metavariable solving + pattern unification + universe constraint solving
Haruspex.Unify.MetaState    — meta context: map from meta ID → Solved(value) | Unsolved(type, ctx)
Haruspex.Unify.LevelSolver  — universe level constraint solver (max, +1 operations)
Haruspex.Elaborate          — surface AST → core terms (name resolution, implicit insertion, holes, auto-implicits)
Haruspex.Check              — bidirectional type checker (synth/check modes, multiplicity tracking)
Haruspex.Mutual             — mutual block signature collection + cross-reference checking
Haruspex.Codegen            — core terms → Elixir quoted AST (type + proof erasure)
Haruspex.ADT                — algebraic data type declarations + strict positivity checking
Haruspex.Record             — named record types (single-constructor ADTs, struct codegen)
Haruspex.Pattern            — pattern compilation + exhaustiveness checking + with-abstraction
Haruspex.TypeClass          — class/instance declarations, instance search, dictionary representation
Haruspex.TypeClass.Search   — depth-bounded instance search with superclass resolution
Haruspex.TypeClass.Bridge   — optional protocol generation for single-parameter classes
Haruspex.Totality           — structural recursion checker for @total functions
Haruspex.Predicate          — refinement predicate language + constrain bridge
Haruspex.Optimizer          — e-graph optimization orchestration (lower/saturate/extract/lift)
Haruspex.Optimizer.Lower    — core terms → flat IR (strip spans + types)
Haruspex.Optimizer.Lift     — flat IR → core terms (restore dummy spans)
Haruspex.Optimizer.Rules    — quail rewrite rules
Haruspex.Optimizer.Cost     — quail cost model (Quail.Extract behaviour)
Haruspex.Definition         — roux entity for top-level definitions (identity: [:uri, :name])
Haruspex.MutualGroup        — roux entity for mutual definition groups (identity: [:uri, :group_id])
Haruspex.LSP                — LSP query delegation (hole info, implicit display)
```

## Dependency graph between subsystems

```
Tokenizer ──────────────────────────────────────────┐
Parser ◄── Tokenizer                                │
AST ───────────────────────────────────────────────┤
                                                    │
Core ──────────────────────────────────────────────┤
Value ◄── Core                                      │
Eval ◄── Core, Value                                │
Quote ◄── Core, Value                               │
Context ◄── Value                                   │
                                                    │
Unify ◄── Core, Value, Eval, Quote, Context         │
Unify.MetaState ◄── Value                           │
Unify.LevelSolver ◄── (standalone)                  │
                                                    │
Elaborate ◄── AST, Core, Context, Unify.MetaState   │
Mutual ◄── Elaborate, Check                         │
Check ◄── Core, Value, Eval, Quote, Context, Unify  │
                                                    │
Codegen ◄── Core                                    │
ADT ◄── Core, Check                                 │
Record ◄── ADT, Codegen                             │
Pattern ◄── Core, ADT                               │
TypeClass ◄── Record, Check, Unify                  │
TypeClass.Search ◄── Unify, Value                   │
TypeClass.Bridge ◄── TypeClass, Codegen             │
Totality ◄── Core, ADT                              │
Predicate ◄── Core, constrain                       │
                                                    │
Optimizer ◄── Core, quail                           │
Optimizer.Lower ◄── Core                            │
Optimizer.Lift ◄── Core                             │
Optimizer.Rules ◄── quail                           │
Optimizer.Cost ◄── quail                            │
                                                    │
Haruspex ◄── all above, roux, pentiment             │
Definition ◄── roux (Entity)                        │
MutualGroup ◄── roux (Entity)                       │
LSP ◄── Haruspex, roux (Lang.LSP)                   │
```

## Storage architecture

Haruspex is a pure language implementation — all mutable state lives in roux's infrastructure (ETS tables, memo entries, entity tables). Haruspex modules are pure functions from inputs to outputs.

| Data | Storage | Rationale |
|------|---------|-----------|
| Source text | Roux input (durability: :low) | Changes on every keystroke |
| Parse results | Roux memo entry | Cached, invalidated on source change |
| Elaborated core | Roux memo entry | Cached, invalidated on parse change |
| Type-checked core | Roux memo entry | Cached, early cutoff when types unchanged |
| Definition entities | Roux entity table | Identity: `[:uri, :name]`, field-level tracking |
| Metavariable state | Process-local during checking | Not persisted — rebuilt on re-check |
| Universe constraints | Process-local during checking | Not persisted — rebuilt on re-check |

## Key invariants

1. **Core terms use de Bruijn indices, never names.** Names exist only in the surface AST and are resolved during elaboration. See [[d02-debruijn-core]].
2. **NbE values use de Bruijn levels; readback converts to indices.** Levels count from the bottom of the context, indices count from the top. This avoids shifting during evaluation. See [[d03-nbe-conversion]].
3. **Spans never participate in type equality or conversion checking.** Core terms carry spans for error reporting, but `unify`/`conv` ignore them. See [[d09-pentiment-spans-everywhere]].
4. **Metavariables are solved eagerly during checking.** Unsolved metas at definition boundaries are errors (for implicit args) or informational diagnostics (for holes). See [[d14-implicits-from-start]], [[d17-typed-holes]].
5. **Universe levels are inferred.** User-written `Type` is sugar for `Type(?level)` with a fresh level variable. Level constraints are solved after checking each definition. See [[d05-universe-hierarchy]].
6. **Erased arguments (multiplicity 0) do not exist at runtime.** The checker enforces that erased bindings are not used computationally. Codegen strips them. See [[d19-erasure-annotations]].
7. **All inductive type declarations are strictly positive.** The positivity checker runs at declaration time, before any values of the type can be constructed. See [[d16-strict-positivity]].
8. **`@total` functions are verified to terminate via structural recursion.** At least one argument must decrease structurally in every recursive call. See [[d18-totality-opt-in]].
9. **Type-directed readback performs eta-expansion.** Neutrals at function type are expanded to `Lam(App(ne, Var))`, neutrals at pair type to `Pair(Fst(ne), Snd(ne))`. See [[d15-eta-expansion]].

## Compatibility notes

- **Pentiment**: All source positions use `Pentiment.Span.Byte`. Diagnostics carry spans for editor integration. Roux's early cutoff excludes spans from comparison.
- **Constrain**: Refinement predicates `{x : T | P(x)}` translate to constrain's expression format. Discharge uses `Constrain.entails?/2` with three-valued logic. See [[d06-constrain-for-refinements]].
- **Quail**: E-graph optimization integrates as a roux query. The optimizer follows Lark's lower/saturate/extract/lift pipeline. See [[d07-quail-optimization]], [[d11-phase-separated-optimizer]].
- **Roux**: Haruspex implements `Roux.Lang` behaviour. All compilation stages are `defquery` definitions. Definitions are `Roux.Entity` structs with field-level change tracking. The LSP delegates to `Roux.Lang.LSP`.

## Compilation pipeline

```
Source text (.hx)
    │
    ▼
┌──────────┐
│ Tokenize │  NimbleParsec → token stream
└────┬─────┘
     │
     ▼
┌──────────┐
│  Parse   │  Recursive descent → surface AST
└────┬─────┘
     │
     ▼
┌───────────┐
│ Elaborate │  Name resolution, implicit insertion,
│           │  hole creation, de Bruijn indexing
└────┬──────┘  → core terms with metavariables
     │
     ▼
┌──────────┐
│  Check   │  Bidirectional type checking,
│          │  unification, meta solving,
│          │  universe constraint solving,
│          │  multiplicity checking
└────┬─────┘  → fully elaborated core + type
     │
     ├──────────────────────┐
     │                      ▼
     │              ┌──────────────┐
     │              │ Totality     │  @total functions only:
     │              │ Check        │  structural recursion
     │              └──────────────┘
     │
     ▼
┌───────────┐
│ Optimize  │  Optional: lower → e-graph → extract → lift
│ (quail)   │
└────┬──────┘
     │
     ▼
┌──────────┐
│ Codegen  │  Type erasure, multiplicity erasure,
│          │  Elixir quoted AST generation
└────┬─────┘
     │
     ▼
┌──────────┐
│  Emit    │  Code.compile_quoted → .beam
└──────────┘
```
