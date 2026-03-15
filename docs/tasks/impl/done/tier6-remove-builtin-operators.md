# Tier 6: Remove builtin operator names from prelude

**Depends on**: tier6-checker-instance-search

## Scope

Remove `add`, `sub`, `mul`, `eq`, and comparison operators from `Haruspex.Prelude.builtins()`. These names resolve through type class method lookup instead of the prelude's builtin map.

This is the final step of the arithmetic overloading migration. After this task, operator names are no longer special — they're ordinary class methods.

## Implementation

### Prelude changes

Remove from `@builtins` in `Haruspex.Prelude`:
- `:add`, `:sub`, `:mul` (resolved via `Num`)
- `:eq` (resolved via `Eq`)
- Comparison operators if `Ord` class is complete

Keep in `@builtins`:
- Type names: `:Int`, `:Float`, `:String`, `:Atom`, `:Bool`
- Operations without class homes: `:div`, `:neg`, `:not`, `:and`, `:or`, `:neq`, `:lt`, `:gt`, `:lte`, `:gte` (until they get classes)
- Float-specific builtins: `:fadd`, `:fsub`, `:fmul`, `:fdiv` (these are implementation details of `Num(Float)`, not user-facing names)

### Checker cleanup

Remove hard-coded `builtin_op_type` clauses for the migrated operators. The checker resolves their types through the class system.

### Erasure cleanup

Remove `builtin_type` clauses for the migrated operators in `Haruspex.Erase`. These operators no longer appear as bare `{:builtin, :add}` in checked terms — they appear inside dictionary constructors.

### Elaborator changes

Remove the `:fallback` path in `resolve_method_operator` for class methods. If instance search fails for a class method, report an error instead of falling back to a builtin.

## Testing strategy

- All existing tests updated to expect class-resolved behavior.
- `add` as a bare name is no longer resolvable without a `Num` instance in scope.
- `{:builtin, :add}` still works at the core level (it's the concrete operation), but it's not reachable from user-facing names directly.

## Verification

```bash
mix test
mix format --check-formatted
mix dialyzer
```
