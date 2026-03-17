# Fix: thread eval context through all closure evaluations

**Priority**: high — corrupts neutral type annotations, causes spurious unification failures

## Problem

Three places use `Eval.default_ctx()` (empty metas and defs) when evaluating closures, losing information about solved metas and total definitions:

1. **`do_eval_in_env`** (eval.ex) — used by `vapp` for stuck neutral codomain types and `vsnd` for sigma second component types. Produces wrong type annotations on neutral values.

2. **Unify closure evaluation** (~15 sites in unify.ex) — `occurs_in_closure?`, `scope_ok_closure?`, and all closure opening in `unify_rigid` use `default_ctx()`. Causes spurious mismatch errors when shared-index Pi types have solved metas in codomains.

3. **Missing `vglobal` cases** (unify.ex) — `occurs_in?`, `scope_ok?`, and `unify_rigid` don't handle `{:vglobal, mod, name, arity}`. Crashes on cross-module types in metas.

## Fix

- Thread metas/defs through `do_eval_in_env` by accepting a ctx parameter
- Replace all `%{Eval.default_ctx() | env: ...}` in unify.ex with `%{Eval.default_ctx() | env: ..., metas: ms.entries}`
- Add `{:vglobal, _, _, _}` clauses to `occurs_in?`, `scope_ok?`, `unify_rigid`
