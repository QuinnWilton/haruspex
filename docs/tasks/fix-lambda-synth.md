# Fix: Check.synth/2 crashes on bare lambda expressions

**Priority**: medium — crashes LSP on let-bound lambdas without type annotation

## Problem

`Check.synth/2` has no clause for `{:lam, mult, body}`. Lambdas can only be
checked against a known type, never synthesized. But when a lambda is bound in
a `let` without a type annotation (e.g. `let f = fn(n : Int) -> n * 2 end`),
the checker attempts to synthesize it and crashes.

## Affected files

- test/examples/lambda_edge.hx (`iife` function with let-bound lambda)
- test/examples/tricky_parse.hx (`let_lambda` function)

## Fix

Either:
1. Add a `synth` clause for `:lam` that synthesizes from the parameter
   annotation (the `fn(n : Int) -> ...` already carries type info), or
2. Have elaboration insert a type annotation on let-bound lambdas when the
   parameter types are known.

Option 1 is more straightforward — construct a Pi type from the annotated
parameters and the synthesized body type.
