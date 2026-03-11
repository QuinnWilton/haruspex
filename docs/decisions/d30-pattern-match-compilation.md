# D30: Pattern match compilation

**Decision**: Dependent pattern matching uses case trees with left-to-right splitting, index unification at each split, first-match semantics, and type-aware coverage checking. Nested patterns are flattened in elaboration. Dot patterns are inferred, not required. Absurd branches are implicitly omitted.

**Rationale**: Case trees are the standard algorithm for dependent pattern matching (Agda, Idris 2, Lean). They naturally accommodate index unification at each split node, which is essential for type refinement in branches. The minimal viable version — left-to-right splitting, implicit dot patterns, no absurd syntax — covers the practical cases (Option, List, Vec, Nat) without the full complexity of Agda's elaboration.

**Resolves**: [[../tasks/t05-pattern-match-compilation]]

## Algorithm overview

Pattern matching compilation transforms surface `case` expressions into case trees. Each node in the tree splits on one variable, enumerates its constructors, unifies indices, and recurses.

```
compile_case(ctx, scrutinee, branches):
  1. Choose split variable (leftmost non-trivial pattern column)
  2. For each constructor C of the split variable's type:
     a. Unify C's return type with the scrutinee's type → refine context
     b. If unification fails → this constructor is impossible, skip
     c. Filter branches to those matching C
     d. Extend context with C's fields
     e. Recurse on remaining pattern columns
  3. If no branches remain for a reachable constructor → coverage error
```

## Case trees

The core representation of compiled pattern matching is a case tree:

```elixir
@type case_tree ::
  {:split, ix(), [{atom(), non_neg_integer(), case_tree()}]}  # split on var, branches
  | {:leaf, Core.term()}                                       # matched — evaluate body
  | {:absurd}                                                  # impossible branch (type-level)
```

This compiles to the existing `{:case, scrutinee, branches}` core term. The case tree is an intermediate representation during elaboration, not a new core form.

## Splitting variable selection

**Left-to-right, user-ordered.** The elaborator scans pattern columns from left to right and splits on the first column that has constructor patterns. Variables and wildcards are skipped.

This is predictable: the user controls the splitting order through their pattern layout. It also aligns with `@total` — the structurally decreasing argument is typically the one being matched on, and the user naturally writes it as the split variable.

Smarter heuristics (fewest constructors first, most refined type first) are a future optimization. They don't affect semantics, only the shape of the generated case tree.

## Index unification during splitting

When splitting a scrutinee of an indexed type, the checker unifies the constructor's return type with the scrutinee's type at each branch. This refines the context for that branch.

### Example: Vec

```elixir
type Vec(a : Type, n : Nat) : Type do
  vnil : Vec(a, zero)
  vcons(x : a, rest : Vec(a, m)) : Vec(a, succ(m))
end

def head(xs : Vec(a, succ(n))) : a do
  case xs do
    vcons(x, rest) -> x
  end
end
```

Compilation:
1. Split on `xs : Vec(a, succ(n))`
2. Constructor `vnil`: unify `Vec(a, zero)` with `Vec(a, succ(n))` → fails (`zero ≠ succ(n)`) → impossible, skip
3. Constructor `vcons(x, rest)`: unify `Vec(a, succ(m))` with `Vec(a, succ(n))` → solves `m = n` → branch body gets `x : a`, `rest : Vec(a, n)`
4. Coverage complete — `vnil` is impossible, `vcons` is covered

No absurd branch needed. The user omits `vnil` and the coverage checker confirms it's unreachable.

## Nested patterns

Nested patterns are flattened into sequential splits during elaboration:

```elixir
# surface
case xs do
  cons(cons(x, _), _) -> x
  cons(nil, rest) -> ...
  nil -> ...
end

# elaborated case tree
split xs:
  cons(y, ys) →
    split y:
      cons(x, _) → leaf x
      nil → leaf ...
  nil → leaf ...
```

Each level of splitting preserves type refinement. If `xs : List(List(a))`, then after splitting on `cons(y, ys)`, the context has `y : List(a)`, and splitting on `y` refines normally.

## Dot patterns (inaccessible patterns)

Dot patterns are **inferred by the elaborator**, not required from the user. When index unification forces a variable's value, the elaborator recognizes that position as inaccessible and doesn't bind a new variable.

```elixir
# the user writes this — no dot patterns needed
def tail(xs : Vec(a, succ(n))) : Vec(a, n) do
  case xs do
    vcons(x, rest) -> rest
  end
end

# internally, the elaborator knows n is forced by unification
```

Users may optionally write dot patterns for documentation:

```elixir
case xs do
  vcons(.(succ(n)), x, rest) -> rest
end
```

But this is never required. The elaborator validates that user-supplied dot patterns match what unification infers.

## Overlapping patterns and first-match semantics

Pattern matching uses **first-match semantics**, consistent with Elixir's `case`. If multiple branches match, the first one wins:

```elixir
case n do
  zero -> "zero"
  zero -> "also zero"  # unreachable, but not an error
  succ(m) -> "positive"
end
```

The compiler may warn about unreachable branches but does not reject them. This matches programmer expectations from Elixir.

`@total` functions require full coverage (all reachable constructors matched) but do **not** require disjointness. Overlapping is fine as long as nothing is missed.

## Literal patterns

Literal patterns (matching on `Int`, `Float`, `String`, `Atom` values) follow d26:

- A wildcard or variable catch-all is required (infinite types can't be exhaustively matched)
- Literal patterns don't interact with dependent types — you don't index families by `Int`
- `@total` functions may match on literals with a catch-all

```elixir
def describe(n : Int) : String do
  case n do
    0 -> "zero"
    1 -> "one"
    _ -> "other"
  end
end
```

## Coverage checking

The coverage checker is **type-aware**: it uses unification to prune impossible constructors.

```
check_coverage(ctx, scrutinee_type, branches):
  constructors = ADT.constructors(scrutinee_type)
  for each constructor C in constructors:
    if unify(C.return_type, scrutinee_type) succeeds:
      # C is reachable — must be covered
      if no branch matches C:
        error {:missing_pattern, C.name}
    else:
      # C is impossible — skip
      :ok
```

For `@total` functions, missing coverage is an error. For non-total functions, it's a warning.

## Absurd branches

When a constructor is impossible (unification of its return type with the scrutinee type fails), the user **omits** the branch. The coverage checker confirms it's unreachable.

No explicit absurd pattern syntax is needed initially. A future extension could add `absurd` as documentation:

```elixir
# possible future syntax, not implemented now
case xs do
  vcons(x, rest) -> x
  vnil -> absurd  # documents impossibility
end
```

## Interaction with other subsystems

| Subsystem | Integration |
|-----------|------------|
| **Elaboration** | Flattens nested patterns, infers dot patterns, builds case trees |
| **Checker** | Refines context at each split (extend with fields, apply index solutions) |
| **Unification** | Called at each split to solve index equations |
| **Totality** | Reads the case tree structure to verify structural decrease on the split variable |
| **Codegen** | Case trees compile to Elixir `case` with tagged tuple patterns |
| **With-abstraction** | Compiles to a case tree after abstracting the goal type (subsystem 20) |

## Codegen

Case trees compile to Elixir `case` expressions with tagged tuple patterns:

```elixir
# Haruspex
case xs do
  vnil -> ...
  vcons(x, rest) -> ...
end

# Elixir output
case xs do
  :vnil -> ...
  {:vcons, x, rest} -> ...
end
```

Nested case trees compile to nested `case` expressions. The BEAM's pattern matching engine handles the rest.

## Future extensions

| Extension | What it adds |
|-----------|-------------|
| Smarter splitting heuristics | Better case tree shapes, fewer redundant matches |
| Explicit absurd patterns | Documentation syntax for impossible branches |
| `with`-style equations in context | Full Agda-style `with`, where `e = p` is available in branches |
| Or-patterns | `cons(x, _) \| nil -> ...` — match multiple constructors in one branch |
| View patterns | Match through a function: `(even? -> true) -> ...` |
