# Open design tasks

Questions that need resolution before or during implementation. Each task becomes a decision doc (dXX) or subsystem expansion once resolved.

## Critical (blocks early tiers)

| Task | Question | Blocks | Status |
|------|----------|--------|--------|
| [[t01-builtins-and-prelude]] | Where do Int, Bool, Float come from? | Tier 1 | Resolved → d26 |
| [[t02-ffi-elixir-interop]] | How do you call Elixir functions? | Tier 3 | Resolved → d27 |
| [[t03-reduction-scope]] | What functions reduce during type checking? | Tier 1 | Resolved → d28 |
| [[t04-module-system]] | File structure, imports, visibility | Tier 3 | Resolved → d29 |
| [[t05-pattern-match-compilation]] | Algorithm for dependent case splitting | Tier 5 | Resolved → d30 |

## Important (blocks later tiers)

| Task | Question | Blocks | Status |
|------|----------|--------|--------|
| [[t06-error-pretty-printing]] | Name recovery from de Bruijn indices | Tier 2 | Resolved (impl detail) |
| [[t07-self-recursion]] | How recursive defs enter their own scope | Tier 2 | Resolved (d25 + subsystem 07) |
| [[t08-instance-coherence]] | Overlapping and orphan instance rules | Tier 6 | Resolved (d20 + subsystem 18) |
| [[t09-mutual-inductive-types]] | Mutually recursive type declarations | Tier 5 | Resolved (d25 + subsystem 12) |
