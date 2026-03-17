# Fix: erasure should use eval+quote instead of syntactic subst

**Priority**: low — theoretical issue; syntactic subst preserves Pi structure in practice

## Problem

The erasure pass uses `Core.subst` for type computation (computing result types of applications, eliminating zero-mult bindings). Syntactic substitution doesn't reduce, so `Vec(3 + 1)` stays unreduced instead of becoming `Vec(4)`. This can cause misclassification of type-level vs value-level terms.

## Fix

Thread an eval context through the erasure pass. Replace `Core.subst(cod, 0, a)` with eval+quote: evaluate the codomain under `[a_val | env]` and quote back.
