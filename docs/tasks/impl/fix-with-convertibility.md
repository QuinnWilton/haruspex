# Fix: with-abstraction should use NbE conversion, not syntactic equality

**Priority**: medium — trivial motive when scrutinee/goal differ after normalization

## Problem

`Pattern.core_convertible?` uses `term == target` (structural equality). If the scrutinee and its occurrence in the goal type differ syntactically after quoting (due to eta-expansion, beta-reduction, or meta substitution), the abstraction produces a trivial motive that ignores its argument.

## Fix

Replace `core_convertible?` body with: evaluate both terms to values, then call `Unify.unify` with a fresh MetaState. If unification succeeds, the terms are convertible.
