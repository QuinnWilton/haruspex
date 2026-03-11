# T07: Self-recursion semantics

**Status**: Resolved — clarified in d25-mutual-blocks and subsystem 07-elaboration. Self-recursion is a single-definition mutual block; type annotation required; no fixpoint combinator; top-level only.

**Blocks**: Tier 2 (elaboration needs this for recursive defs)

## The question

How does a function reference itself in its own body? The examples show recursive `def`s without `mutual`, but the elaboration docs don't specify how the function's own name and type enter scope.

## The likely answer

Self-recursion is a degenerate mutual block of size 1. During elaboration of `def f(x : A) : B do ...f(x)... end`:

1. Elaborate the type signature `(x : A) -> B`
2. Add `f : (x : A) -> B` to the context *before* elaborating the body
3. Elaborate the body with `f` in scope
4. The reference to `f` in the body gets a de Bruijn index pointing to this binding

This means every `def` is implicitly a `mutual` block containing one definition. The mutual block machinery (d25) handles this uniformly.

## Sub-questions

- Does `f` need a type annotation for self-recursion? (Yes — same as mutual blocks requiring signatures)
- What if the return type is omitted? Can the checker infer the type of a recursive function? (Probably not — bidirectional checking needs the annotation to seed the context)
- Is there a fixpoint combinator in the core, or is recursion a top-level-only feature? (Top-level only is simpler and matches Elixir)

## Resolution

→ Not a separate decision doc. Clarify in d25-mutual-blocks and subsystem 07-elaboration that self-recursion is a single-definition mutual block.
