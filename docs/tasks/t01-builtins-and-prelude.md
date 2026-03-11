# T01: Built-in types and the prelude

**Status**: Resolved → [[../decisions/d26-builtins-and-prelude]]

**Blocks**: Tier 1 (core terms need builtin type representations)

## The question

Where do `Int`, `Bool`, `Float`, `String` come from? How are they represented in the type system, and what typing rules do literals and arithmetic operations get?

## Sub-questions

1. **Primitive types**: Are `Int`, `Float`, `String`, `Bool` hard-coded in the checker, or defined in a prelude module? What universe do they live in? (`Int : Type 0`?)

2. **Literal typing**: What rule types `42`? Is it `42 : Int` always, or is there literal overloading (like Haskell's `Num` class)? What about `3.14 : Float`? `"hello" : String`? `:foo : Atom`?

3. **Arithmetic builtins**: Where do `+`, `-`, `*`, `/`, `==`, `<`, `>` get their types? Are they:
   - Hard-coded builtin operators with fixed signatures?
   - Type class methods (requires Tier 6 before basic arithmetic works)?
   - Functions in a prelude module?

4. **Bool and control flow**: Is `Bool` a built-in or an ADT (`type Bool do true; false end`)? If it's an ADT, `if/else` is sugar for `case`. If it's built-in, the checker needs special rules.

5. **Pattern matching on literals**: Can you `case n do 0 -> ...; 1 -> ...; _ -> ... end`? If so, exhaustiveness is impossible for integers (infinite constructors). How does this interact with `@total`?

6. **Prelude auto-import**: Is there a prelude that's automatically in scope? What's in it? Just types, or also standard functions?

7. **BEAM numeric types**: Elixir has integers (arbitrary precision), floats (IEEE 754), and no distinct int32/int64. Does Haruspex mirror this, or introduce sized integer types?

## Design space

| Approach | Precedent | Trade-off |
|----------|-----------|-----------|
| Hard-coded primitives + builtin ops | Agda (postulates + builtins) | Simple, but not extensible; arithmetic can't be overloaded |
| Prelude module with ADT definitions | Lean (Init) | Clean, but bootstrap is complex; Bool/Nat are real ADTs |
| Primitives + type class overloading | Idris 2 | Most flexible, but needs type classes (Tier 6) before `+` works |
| Primitives now, overloading later | Practical | Start with hard-coded, refactor to type classes in Tier 6 |

## Implications for other subsystems

- **Core terms**: Needs `{:builtin, :Int}` or similar for primitive types
- **NbE**: Needs delta-reduction rules for arithmetic (`2 + 1 → 3`)
- **Checker**: Needs typing rules for literals and builtins
- **Codegen**: Needs to map builtins to Elixir operators
- **Type classes** (Tier 6): If arithmetic becomes overloaded, the builtin typing rules get replaced by instance search

## Decision needed

→ Will become **d26-builtins-and-prelude** once resolved.
