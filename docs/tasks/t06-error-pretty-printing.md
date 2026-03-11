# T06: Error messages and name recovery

**Status**: Resolved — implementation detail, not a decision doc. Key design captured in subsystem docs 07-elaboration (name context) and 08-checker (error structure + pretty-printing).

**Blocks**: Tier 2 (first type errors appear here)

## The question

How do type error messages recover human-readable names from de Bruijn indices? Every error path in the checker produces values/terms with indices, but users need names.

## Sub-questions

1. **Name environment**: During checking, maintain a parallel list of names (from elaboration) alongside the typing context. When printing a value, use this list to recover names from de Bruijn levels.

2. **Pretty-printer**: Need a `Value → String` pretty-printer that:
   - Converts de Bruijn levels back to user-chosen names
   - Handles name shadowing (append primes or numbers: `x`, `x'`, `x''`)
   - Prints Pi types as arrow types when the binding isn't used: `a -> b` not `(x : a) -> b`
   - Prints implicit arguments in braces: `{a : Type} -> a -> a`
   - Elides solved implicits in some contexts, shows them in others

3. **Error structure**: Errors should carry:
   - The span of the offending term
   - Expected vs actual types (as values, for pretty-printing)
   - The name context at the error site
   - Suggested fixes where possible

4. **Rendered output**: Use pentiment for rendering errors with source context (underlined spans, margin annotations). Follow the pattern from Lark's `Lark.Errors` module.

## Resolution

→ Not a decision doc. Address during Tier 2 implementation by creating `Haruspex.Pretty` and `Haruspex.Errors` modules.
