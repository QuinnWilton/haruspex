# With-abstraction

## Purpose

Enables dependent pattern matching on intermediate computed values. When case-splitting on the result of a function call, the type system tracks the relationship between the scrutinee and the result, enabling type refinement in each branch. See [[../decisions/d22-with-abstraction]].

## Dependencies

- `Haruspex.Core` — no new core terms (compiles to `case`)
- `Haruspex.Elaborate` — desugaring `with` to generalized `case`
- `Haruspex.Check` — type refinement in branches
- `Haruspex.Pattern` — pattern compilation

## Key types

```elixir
# Surface AST addition
@type with_expr :: {:with, Span.t(), [expr()], [with_branch()]}
@type with_branch :: {:with_branch, Span.t(), [pattern()], expr()}
```

## Public API

```elixir
@spec elaborate_with(elab_ctx(), AST.with_expr()) :: {:ok, Core.term()} | {:error, term()}
```

## Elaboration algorithm

Given `with f(x) do ... end` in a context where the goal type is `G`:

1. **Evaluate**: Let `e = f(x)` and infer its type `T`
2. **Abstract**: Generalize the goal type `G` over `e`:
   - Replace all occurrences of `e` in `G` with a fresh variable `w`
   - The abstracted goal is `fn (w : T) -> G[e := w]`
3. **Case-split**: Elaborate as `case e do branches end` where:
   - Each branch pattern matches against `T`
   - In each branch, the equation `e = pattern` is available
   - The goal type is specialized by substituting the pattern for `w`
4. **Result**: A regular `case` expression in core terms

### Example elaboration

```
-- Goal: Vec(a, n) where filter returns a length-indexed vector
with p(x) do
  true -> ...   -- in this branch, p(x) ≡ true
  false -> ...  -- in this branch, p(x) ≡ false
end

-- Elaborates to:
case p(x) do
  true -> ...    -- context refined: any type mentioning p(x) now knows it's true
  false -> ...   -- context refined: any type mentioning p(x) now knows it's false
end
```

## Multiple scrutinees

`with e1, e2 do ...` desugars to nested with:
```
with e1 do
  p1 ->
    with e2 do
      p2 -> body
    end
end
```

Patterns in branches are tupled: `p1, p2 -> body`.

## Implementation notes

- The abstraction step (step 2) can fail if `e` appears in a position that can't be generalized (e.g., under a lambda that captures variables `e` depends on). In this case, produce a clear error explaining why with-abstraction failed.
- Start with simple with-abstraction (single scrutinee, no equational reasoning). Full Agda-style with (where the equation `e = p` is added to context) is a later refinement.
- With-expressions are syntactic sugar -- they add no new core term forms.

## Testing strategy

- **Unit tests**: Simple with on Bool, Nat
- **Integration**: Filter on Vec with dependent length tracking
- **Negative tests**: With-abstraction failure produces helpful error
