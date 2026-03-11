# T08: Instance coherence and overlap

**Status**: Resolved — additions to d20-type-classes and subsystem 18-type-classes. Most-specific wins, orphans warned, local coherence via imports, no manual priority.

**Blocks**: Tier 6 (type classes)

## The question

What happens when multiple type class instances could match the same goal? What about instances defined in modules that aren't directly imported?

## Sub-questions

1. **Overlapping instances**: If both `Eq(List(Int))` and `[Eq(a)] => Eq(List(a))` exist, which wins?
   - Haskell: forbidden by default, opt-in with `OVERLAPPING`/`OVERLAPPABLE`
   - Lean: most specific wins (specificity ordering)
   - Agda: instances are just values, no special overlap rules
   - Proposal: most specific wins, ambiguity is an error

2. **Orphan coherence**: Module A defines `Foo`. Module B defines `class Bar`. Module C defines `instance Bar(Foo)`.
   - If module D imports A and B but not C, can it use `Bar(Foo)`? (No — instances come from imports)
   - Can module E also define `instance Bar(Foo)`? (Orphan warning, but allowed?)
   - If both C and E are imported, which instance wins? (Error — ambiguous)

3. **Global vs local coherence**: Haskell enforces global coherence (one instance per type per class, world-wide). This is impractical without a central registry. Local coherence (instances are scoped to imports) is more modular but can lead to surprising behavior if different modules see different instances.

4. **Instance priority**: Should users be able to declare priority/specificity manually?

## Resolution

→ Address when implementing Tier 6. May produce a decision doc or additions to d20-type-classes.
