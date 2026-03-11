# Totality

## Purpose

Checks that functions annotated with `@total` terminate via structural recursion. At least one argument must decrease structurally in every recursive call. See [[../decisions/d18-totality-opt-in]].

## Dependencies

- `Haruspex.Core` — term representation
- `Haruspex.ADT` — ADT declarations (needed to identify subterms)
- `Haruspex.Check` — called after type checking for `@total` definitions

## Key types

```elixir
@type totality_result :: :total | {:not_total, totality_error()}
@type totality_error ::
  {:no_decreasing_arg, atom(), Pentiment.Span.Byte.t()}
  | {:non_structural_recursion, atom(), Pentiment.Span.Byte.t(), Core.term()}
  | {:not_adt_type, atom(), Value.value(), Pentiment.Span.Byte.t()}
```

## Public API

```elixir
@spec check_totality(atom(), Core.term(), Core.term(), Context.t()) :: totality_result()
  # check_totality(name, type, body, ctx)
```

## Algorithm

1. Identify candidate decreasing arguments: parameters whose type is an ADT
2. For each candidate, check all recursive calls in the body:
   a. Find all occurrences of `App(...name...)` in the body
   b. For each recursive call, examine the argument at the candidate position
   c. Verify it is a strict structural subterm of the pattern-matched value
3. A "structural subterm" is a variable bound by a pattern match constructor that destructures the argument
4. If any candidate works for ALL recursive calls, the function is total

### Structural decrease detection

```
check_decrease(param_ix, body):
  case body:
    Case(Var(param_ix), branches):
      for each branch {con, arity, branch_body}:
        # Variables bound by this branch are subterms of param
        subterm_vars = [param_ix + 1 .. param_ix + arity]
        check_recursive_calls(name, param_ix, subterm_vars, branch_body)

check_recursive_calls(name, param_ix, subterms, term):
  for each App(App(...name...), args) in term:
    arg_at_param = args[param_ix]
    if arg_at_param is Var(ix) where ix in subterms: :ok
    else: {:error, :non_structural}
```

## Implementation notes

- Start with single decreasing argument (not lexicographic)
- Mutual recursion: all functions in a mutual block must decrease on a shared measure (deferred)
- Nested recursion (recursion on a recursive call's result) is NOT structurally decreasing — rejected
- The check is conservative: some terminating functions will be rejected

## Testing strategy

- **Unit tests**: Structurally recursive functions accepted; non-structural rejected
- **Integration**: `@total length(xs)` on `List(a)` passes; `@total loop()` fails
- **Examples**: Nat.add, List.map, List.fold — all should pass
- **Negative**: Recursion on unrelated argument, recursion on original (not subterm)
