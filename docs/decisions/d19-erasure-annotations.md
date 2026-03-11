# D19: Erasure annotations for proof-irrelevant arguments

**Decision**: Arguments with multiplicity 0 are erased during codegen. Surface syntax: `(0 proof : P)` or `{0 a : Type}` marks arguments as erased.

**Rationale**: Without erasure, proof terms (like `n > 0` evidence) and type arguments are carried at runtime as actual values, wasting memory and CPU cycles. In a dependently typed language, types can appear as function arguments — `id : (a : Type) -> a -> a` takes a type as its first argument. These type arguments have no computational content and should not exist at runtime. Similarly, proof terms witnessing refinement predicates are computationally irrelevant.

**Mechanism**: The system uses two multiplicities: 0 (erased) and w (unrestricted). The checker enforces:
- Erased (0) bindings cannot be used in computational (w) positions — they can only appear in types and other erased positions
- Types and type arguments are always implicitly erased
- Explicit `(0 x : T)` allows erasing non-type arguments (proofs, witnesses)

During codegen:
- Erased lambdas are removed (the parameter doesn't exist at runtime)
- Erased applications are removed (the argument isn't passed)
- Type lambdas and type applications are removed
- The result is standard Elixir code with no type/proof overhead

**Deferred**: Linear types (multiplicity 1, "use exactly once") are a natural extension but deferred. The infrastructure supports it — just add a third multiplicity and the corresponding usage checking.

See [[d06-constrain-for-refinements]], [[../subsystems/14-erasure]], [[../subsystems/09-codegen]].
