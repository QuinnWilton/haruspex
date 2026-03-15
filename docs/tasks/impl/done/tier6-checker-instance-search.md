# Tier 6: Checker-integrated instance search

**Module**: `Haruspex.Check` (extensions), `Haruspex.Core` (new term form)
**Depends on**: tier6-instances, tier6-arithmetic-overload (phase 1)

## Scope

Integrate instance search into the type checker so that class methods resolve polymorphically for variable operands, not just literals. This completes the migration from hard-coded builtin types to type class resolution.

Currently, `add(x, y)` where `x : a` falls back to `{:builtin, :add}` with a hard-coded `Int -> Int -> Int` type. After this task, it resolves through `Num(a)` with a dictionary argument.

## Implementation

### New core term form

Add `{:class_method, class_name, method_name}` to `Haruspex.Core`. This represents a method reference that the checker resolves by:

1. Creating a fresh meta `?a` for the class type parameter.
2. Returning the polymorphic method type: `NumDict(?a) -> ?a -> ?a -> ?a` (dictionary arg + method signature).
3. When `?a` is solved by argument type unification, running instance search to resolve the dictionary.

### Checker changes

- Add `synth` clause for `{:class_method, class_name, method_name}` that returns the polymorphic type with a dictionary parameter.
- Add a post-processing pass that solves dictionary metas via instance search before reporting unsolved metas.
- Dictionary metas that resolve to known instances get replaced with the concrete dictionary constructor term.

### Elaborator changes

- When `resolve_method_operator` encounters a non-literal operand, emit `{:class_method, :Num, :add}` instead of falling back to `{:builtin, :add}`.
- Thread the dictionary argument through the application: `{:app, {:app, {:app, {:class_method, :Num, :add}, dict_meta}, left}, right}`.

### Erasure and codegen

- Erasure: `{:class_method, ...}` should not appear after checking (replaced by concrete terms). Raise `CompilerBug` if encountered.
- Codegen: no changes needed — the checked output uses concrete dictionary terms.

## Testing strategy

### Unit tests

- `add(x, y)` with `x : Int, y : Int` resolves `Num(Int)` and type-checks as `Int`.
- `add(x, y)` with `x : a, y : a, [Num(a)]` type-checks polymorphically with dictionary parameter.
- `def double([Num(a)], x : a) : a do add(x, x) end` elaborates and checks.

### Integration tests

- Polymorphic function using `+` compiles and runs correctly.
- Monomorphic call sites still inline to `Kernel.+`.

## Verification

```bash
mix test
mix format --check-formatted
mix dialyzer
```
