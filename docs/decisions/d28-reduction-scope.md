# D28: Reduction scope — what reduces during type checking

**Decision**: Built-in operations always reduce. User-defined functions reduce only if marked `@total`. Non-total and extern functions are opaque (stuck) in types. A configurable fuel limit prevents runaway reduction. Unfolding is eager.

**Rationale**: Dependent type checking requires computation in types — `Vec(a, 2 + 1)` must equal `Vec(a, 3)`. But unrestricted reduction makes type checking undecidable. The `@total` annotation is the natural boundary: total functions are guaranteed to terminate (verified by the structural recursion checker), so unfolding them is safe. Non-total functions may loop, so they stay opaque. This is sound, decidable (modulo fuel), and gives the programmer a clear contract: if you want a function to compute in types, prove it terminates.

**Resolves**: [[../tasks/t03-reduction-scope]]

## Reduction classes

| Category | Reduces during type checking? | Rationale |
|----------|------------------------------|-----------|
| Built-in arithmetic (`add`, `mul`, etc.) | Always | Hard-coded delta rules, always terminate |
| Built-in comparisons (`eq`, `lt`, etc.) | Always | Same — delta rules on concrete values |
| `@total` user-defined functions | Yes, eagerly | Termination verified by structural recursion check |
| Non-`@total` user-defined functions | No — opaque | May not terminate; unfolding could loop the checker |
| Extern functions (`@extern`) | No — opaque | No body to evaluate |
| Unsolved metavariables | No — stuck | Solution not yet known |

## NbE behavior

### Built-in delta reduction

When a built-in operation is fully applied to literal values, it reduces immediately:

```
vapp(vapp(VBuiltin(:add), VLit(2)), VLit(3))  →  VLit(5)
vapp(vapp(VBuiltin(:lt), VLit(3)), VLit(5))   →  VCon(:Bool, :true, [])
```

Partially applied builtins and builtins applied to non-literal arguments are stuck:

```
vapp(VBuiltin(:add), VLit(2))                       →  VBuiltin({:add_partial, 2})
vapp(vapp(VBuiltin(:add), VNeutral(_, n)), VLit(3)) →  VNeutral(_, NApp(NApp(NBuiltin(:add), n), VLit(3)))
```

### Total function unfolding

When the evaluator encounters a call to a `@total` function with all arguments supplied, it unfolds the definition by substituting arguments into the body and continuing evaluation:

```
eval(env, App(Def(:double), arg))
  where :double is @total with body = add(n, n)
  → eval([eval(env, arg)], body_of_double)
  → continues reducing
```

The evaluator must have access to the definition bodies of `@total` functions. This comes from the roux query system — `@total` definitions are entities whose bodies are available to NbE.

### Opaque functions — neutral terms

Non-total and extern functions produce neutral terms when applied:

```
eval(env, App(Def(:loop), arg))
  where :loop is NOT @total
  → VNeutral(result_type, NDef(:loop, [eval(env, arg)]))
```

A new neutral form is needed for defined-but-opaque function applications:

```elixir
@type neutral ::
  ...
  | {:ndef, atom(), [value()]}    # opaque defined function applied to args
```

This is analogous to `NVar` for free variables — it represents a computation that can't proceed.

## Fuel limit

A configurable reduction fuel limit prevents the checker from hanging on deeply recursive `@total` functions. Each unfolding step decrements the fuel counter.

```elixir
@default_fuel 1000

@type fuel :: non_neg_integer() | :infinite
```

When fuel reaches zero, the function application becomes **stuck** (produces a neutral) rather than raising an error. This means:

- Type checking remains **sound** — a stuck term never claims false equalities
- Type checking becomes **incomplete** — some valid programs may fail to type-check at the fuel limit
- The error message should explain: "reduction fuel exhausted while unfolding `function_name`; consider increasing the fuel limit or simplifying the type-level computation"

The fuel limit is per-definition-check, not global. Each top-level definition starts with full fuel.

### Configuration

```elixir
# in module attributes or project config
@fuel 5000  # per-definition override
```

The default of 1000 is generous for typical programs. Proof-heavy code (e.g., verified data structures) may need more.

## Unfolding strategy

Unfolding is **eager**: the NbE unfolds every `@total` function application as soon as it's fully applied, regardless of whether the result is needed for unification. This is the simplest correct implementation.

**Future optimization**: lazy unfolding (unfold only when two terms fail to unify at the head) can significantly reduce work in large programs. Lean 4 uses a sophisticated lazy unfolding strategy with heuristics for when to unfold. This is a performance optimization that doesn't affect semantics — eager and lazy unfolding produce the same normal forms, just with different amounts of work. Revisit if type checking performance becomes a bottleneck.

## Implications for the programmer

The `@total` annotation serves double duty:

1. **Termination guarantee** — the structural recursion checker verifies it (subsystem 13)
2. **Type-level computation license** — the NbE will unfold it

This means the programmer has a clear mental model:

```elixir
# This reduces in types — I can use it as a type index
@total
def add(n : Nat, m : Nat) : Nat do
  case n do
    zero -> m
    succ(k) -> succ(add(k, m))
  end
end

# This does NOT reduce — it's opaque in types
def fib(n : Nat) : Nat do
  case n do
    zero -> zero
    succ(zero) -> succ(zero)
    succ(succ(k)) -> add(fib(k), fib(succ(k)))
  end
end
```

Note: `fib` is actually terminating (structurally decreasing on `n`), so it *could* be marked `@total`. The programmer chooses whether to make it available for type-level computation.

## Interaction with other subsystems

| Subsystem | Effect |
|-----------|--------|
| **NbE (eval)** | New unfolding logic for `@total` defs; new `NDef` neutral for opaque defs |
| **Core terms** | New term form `{:def, atom()}` for named function references |
| **Unification** | Opaque terms unify only if they're the same function applied to convertible args |
| **Totality** | Now has a second role: gating type-level reduction |
| **Roux queries** | `@total` definition bodies must be available to the evaluator |
| **Codegen** | Unaffected — all functions compile the same regardless of totality |

## Examples

### Works: builtin reduction
```elixir
def foo(xs : Vec(a, 2 + 1)) : Vec(a, 3) do xs end
# 2 + 1 reduces to 3 via builtin delta rule. Types match.
```

### Works: @total function in type
```elixir
@total
def double(n : Nat) : Nat do add(n, n) end

def foo(xs : Vec(a, double(3))) : Vec(a, 6) do xs end
# double(3) → add(3, 3) → 6. Types match.
```

### Opaque: non-total function in type
```elixir
def mysterious(n : Nat) : Nat do ... end

def foo(xs : Vec(a, mysterious(3))) : Vec(a, mysterious(3)) do xs end
# mysterious(3) is opaque. Types match trivially (same stuck term).

def bar(xs : Vec(a, mysterious(3))) : Vec(a, 7) do xs end
# Type error: Vec(a, mysterious(3)) ≠ Vec(a, 7)
# mysterious(3) doesn't reduce, so the checker can't see they're equal.
```

### Opaque: extern in type
```elixir
@extern :math.floor/1
def floor(x : Float) : Int

def baz(xs : Vec(a, floor(3.7))) : Vec(a, 3) do xs end
# Type error: floor(3.7) is opaque. Extern functions never reduce.
```
