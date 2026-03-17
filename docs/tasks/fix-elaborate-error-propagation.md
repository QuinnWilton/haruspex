# Fix: haruspex_elaborate crashes on elaboration errors instead of propagating

**Priority**: high — crashes LSP instead of showing diagnostics

## Problem

`haruspex_elaborate` (line 227) does:

    {:ok, {type_core, body_core, elab_meta_state}} =
      Roux.Runtime.query!(db, :haruspex_elaborate_core, {uri, name})

If `elaborate_core` returns `{:error, reason}` (e.g. unbound variable), the
pattern match crashes with `MatchError`. The error should propagate so
`haruspex_diagnostics` can convert it to a diagnostic.

## Affected files

- test/examples/option_result.hx (unbound variable `a` — missing auto-implicit)
- test/examples/vec.hx (unbound variable `Nat` — unresolved import)

## Fix

Replace the `=` match with a `case` or `with` that propagates `{:error, _}`:

    case Roux.Runtime.query!(db, :haruspex_elaborate_core, {uri, name}) do
      {:ok, {type_core, body_core, elab_meta_state}} ->
        check_result = check_elaborated_def(...)
        ...
      {:error, _} = err ->
        err
    end
