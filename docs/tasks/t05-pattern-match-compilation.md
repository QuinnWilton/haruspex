# T05: Pattern match compilation algorithm

**Status**: Resolved → [[../decisions/d30-pattern-match-compilation]]

**Blocks**: Tier 5 (ADTs)

## The question

How does dependent pattern matching actually work? The subsystem doc (12-adts) describes the *what* but not the *how*. The algorithm choice affects soundness.

## Sub-questions

1. **Case trees vs. case matrices**: The standard approach for dependent pattern matching is case trees (splitting trees). At each node, you choose a variable to split on, enumerate its constructors, and recurse. The alternative is compiling pattern matrices to decision trees. Which approach?

2. **Splitting variable selection**: When multiple variables could be split, which one do you choose? This affects:
   - Whether the match is recognized as structurally decreasing (for @total)
   - Whether index unification succeeds
   - Efficiency of generated code

3. **Index unification during matching**: When matching `xs : Vec(a, succ(n))` against `vcons(x, rest)`, the checker must unify the scrutinee's index `succ(n)` with the constructor's return index `succ(m)`, solving `m = n`. This requires running unification *during* pattern compilation. How does this interact with the existing unification machinery?

4. **Inaccessible (dot) patterns**: After matching `vcons(x, rest) : Vec(a, succ(n))`, the `n` is *forced* — it must equal `m` from the constructor. Should users write dot patterns (`.n`) for forced positions, or should the elaborator infer them?

5. **Nested patterns**: `cons(cons(x, _), _)` needs flattening into sequential matches. Standard compilation handles this, but it needs to preserve dependent type refinement at each level.

6. **Literal patterns**: `case n do 0 -> ...; 1 -> ...; _ -> ... end` — literals have infinitely many values, so exhaustiveness requires a wildcard. How do literal patterns interact with dependent types? (Probably they don't — literal patterns are for built-in types, not indexed families.)

7. **Overlapping patterns**: First-match semantics (like Elixir) or disjoint requirement (like Agda's `--exact-split`)?

8. **Absurd patterns**: When a branch is unreachable due to type constraints (e.g., `vnil` branch when the type says `Vec(a, succ(n))`), can the user omit it? Should the exhaustiveness checker recognize this?

9. **Coverage checking with dependent types**: Standard coverage algorithms don't account for type-level constraints. A match on `Vec(a, 0)` only needs the `vnil` branch — `vcons` is impossible. This requires "type-aware" coverage that consults the unifier.

## Design space

| Approach | Precedent | Complexity |
|----------|-----------|------------|
| Simple case trees, user-ordered | Early Idris, basic | Low, but misses optimizations |
| Elaboration to case trees with unification | Agda, Idris 2 | High, full dependent matching |
| Equation compiler (pattern-matching function defs) | Lean 4 | Very high, but most ergonomic |
| Case trees + separate coverage checker | Practical hybrid | Medium |

## The minimal viable approach

For Tier 5, start with:
1. Single-level case (no nested patterns — flatten in elaboration)
2. First-match semantics
3. Unification during split for index refinement
4. Infer dot patterns (don't require user to write them)
5. Coverage: enumerate constructors, check all present, use unifier to prune impossible branches
6. No absurd pattern syntax initially — just check that unreachable branches are indeed unreachable

This covers Option, List, Vec, Nat without the full complexity of Agda's case trees.

## Implications for other subsystems

- **Elaboration**: Surface `case` → core `case` with constructor splitting
- **Checker**: Needs to refine context in each branch (extend with constructor fields, solve index equations)
- **Unification**: Called during matching to solve index constraints
- **Totality**: Needs to understand the splitting structure to verify structural decrease
- **Codegen**: Core `case` → Elixir `case` with tuple patterns

## Resolution

→ Will expand **subsystem 12-adts.md** with the chosen algorithm once resolved. May also produce a decision doc if the choice is non-obvious.
