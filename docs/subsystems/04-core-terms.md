# Core terms

## Purpose

Defines the core term representation used after elaboration. Core terms use de Bruijn indices, carry explicit metavariables, universe levels, and multiplicity annotations. This is the language that the type checker, NbE, and codegen operate on. See [[../decisions/d02-debruijn-core]], [[../decisions/d08-elaboration-boundary]].

## Dependencies

- `pentiment` — spans carried for error reporting (excluded from equality)

## Key types

```elixir
@type ix :: non_neg_integer()          # de Bruijn index
@type meta_id :: non_neg_integer()     # metavariable identifier
@type level :: level_var() | level_lit() | level_max() | level_succ()
@type level_var :: {:lvar, non_neg_integer()}
@type level_lit :: {:llit, non_neg_integer()}
@type level_max :: {:lmax, level(), level()}
@type level_succ :: {:lsucc, level()}
@type mult :: :zero | :omega            # multiplicity: erased or unrestricted

@type term ::
  {:var, ix()}
  | {:lam, mult(), term()}                         # lambda with multiplicity
  | {:app, term(), term()}                          # application
  | {:pi, mult(), term(), term()}                   # Π(mult, domain, codomain)
  | {:sigma, term(), term()}                        # Σ(fst_type, snd_type)
  | {:pair, term(), term()}                         # (fst, snd)
  | {:fst, term()}                                  # first projection
  | {:snd, term()}                                  # second projection
  | {:let, term(), term()}                          # let (def, body)
  | {:type, level()}                                # Type at universe level
  | {:lit, literal()}                               # literal value
  | {:builtin, atom()}                              # builtin operation
  | {:meta, meta_id()}                              # unsolved metavariable
  | {:inserted_meta, meta_id(), [boolean()]}        # meta with binding mask

@type literal :: integer() | float() | String.t() | atom() | boolean()
```

Later additions (ADTs):
```elixir
  | {:data, atom(), [term()]}                       # type constructor applied to args
  | {:con, atom(), atom(), [term()]}                # data constructor (type, ctor, args)
  | {:case, term(), [{atom(), non_neg_integer(), term()}]}  # case (scrutinee, branches)
```

Later additions (refinements):
```elixir
  | {:refine, term(), term()}                       # {x : base | predicate}
```

## Design decisions

- **No spans in term structure**: Spans are stored in a parallel map `%{term_id => Span.t()}` or carried as wrapper nodes `{:spanned, Span.t(), term()}`. This keeps conversion checking clean — comparing terms never encounters span differences.
- **Binding mask**: `InsertedMeta(id, mask)` carries a `[boolean()]` indicating which bound variables from the current scope are accessible to the meta's solution. This is needed for implicit argument insertion: when elaborating `f(x)` where `f : {a : Type} -> a -> a`, the inserted meta for `a` can only reference variables bound at the point of insertion.
- **Universe levels**: Algebraic expressions over level variables. Constraints collected during checking, solved afterward.

## Public API

```elixir
# Term constructors (for readability)
@spec var(ix()) :: term()
@spec lam(mult(), term()) :: term()
@spec app(term(), term()) :: term()
@spec pi(mult(), term(), term()) :: term()
# ... etc

# Substitution (rarely needed directly — NbE handles most cases)
@spec subst(term(), ix(), term()) :: term()
```

## Implementation notes

- Terms are plain tagged tuples for pattern matching efficiency
- `subst/3` increments indices when going under binders (standard de Bruijn shifting)
- `InsertedMeta` is elaboration-only — the checker expands it by applying the meta to the masked variables

## Testing strategy

- **Unit tests**: Constructor functions, substitution correctness
- **Property tests**: Substitution respects de Bruijn invariants (shifting is correct)
