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

## Abstraction algorithm

Concrete pseudocode for goal type generalization:

```
abstract_over(e : Value, e_type : Value, goal : Value, ctx) -> Core.term():
  # Walk the goal type, replacing occurrences of e with Var(0)

  walk(g):
    # Check if this sub-value is convertible with e
    if convert(ctx, g, e, e_type):
      return Var(0)   # replace with the fresh variable

    case g:
      # Structural recursion — descend into sub-terms
      Pi(mult, name, dom, cod) ->
        dom' = walk(dom)
        # cod is a closure — we need to instantiate it to walk inside,
        # then re-abstract. But if e's free variables include the
        # bound variable, abstraction fails.
        if depends_on_bound(e, current_depth):
          raise AbstractionFailure(e, g, "scrutinee depends on bound variable")
        cod_body = walk(apply_closure(cod, fresh_var(current_depth)))
        Pi(mult, name, dom', close(cod_body))

      Lam(mult, name, body) ->
        if depends_on_bound(e, current_depth):
          raise AbstractionFailure(e, g, "scrutinee depends on bound variable")
        body' = walk(apply_closure(body, fresh_var(current_depth)))
        Lam(mult, name, close(body'))

      App(f, a) -> App(walk(f), walk(a))
      Data(name, args) -> Data(name, Enum.map(args, &walk/1))
      Con(type, name, args) -> Con(type, name, Enum.map(args, &walk/1))

      # Atomic values — no sub-terms to walk
      Var(_) | Lit(_) | Type(_) -> g

  abstracted_body = walk(goal)

  # Wrap in a lambda: fn(w : e_type) -> abstracted_body
  # The result is a function from the scrutinee's type to the goal type
  Lam(:omega, :w, close(abstracted_body))
```

The result is applied to the scrutinee in each branch to specialize the goal type.

## Failure conditions

Abstraction fails in these specific cases:

1. **Scrutinee under capturing binder**: `e` contains free variables that are bound by a lambda or Pi in the goal type. Example: goal type is `(x : A) -> P(f(x))` and scrutinee is `f(x)` — the `x` in the scrutinee is captured by the Pi binder, so we can't abstract `f(x)` out of the codomain.

2. **Scrutinee in irrelevant position**: `e` appears inside an erased/zero-multiplicity argument. Abstracting over it would make a computationally irrelevant position relevant, changing the erasure semantics.

3. **Conversion check ambiguity**: NbE conversion checking is used to find occurrences of `e` in the goal. If `e` is a meta-variable that hasn't been solved yet, the check may be inconclusive. In this case, defer — revisit after more unification constraints are solved, or fail with a message suggesting the user add a type annotation.

Each failure produces a specific error message:
- `"Cannot abstract: scrutinee f(x) depends on variable x bound at <span>"`
- `"Cannot abstract: scrutinee appears in erased position"`
- `"Cannot abstract: scrutinee type is ambiguous — add a type annotation"`

## Implementation notes

- The abstraction step (step 2) can fail if `e` appears in a position that can't be generalized (e.g., under a lambda that captures variables `e` depends on). In this case, produce a clear error explaining why with-abstraction failed.
- Start with simple with-abstraction (single scrutinee, no equational reasoning). Full Agda-style with (where the equation `e = p` is added to context) is a later refinement.
- With-expressions are syntactic sugar -- they add no new core term forms.

## Testing strategy

- **Unit tests**: Simple with on Bool, Nat
- **Integration**: Filter on Vec with dependent length tracking
- **Negative tests**: With-abstraction failure produces helpful error
