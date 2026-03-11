# D04: Bidirectional type checking

**Decision**: Use bidirectional type checking with two modes: synthesis (infer a type) and checking (verify against an expected type).

**Rationale**: Dependent types need more type information flowing through the checker than Hindley-Milner inference provides. Full type inference for dependent types is undecidable in general. Bidirectional checking is the standard practical approach: it propagates type annotations downward (checking mode) and infers types upward (synthesis mode), requiring fewer annotations than a fully explicit system while being more predictable than full inference.

Combined with implicit argument unification ([[d14-implicits-from-start]]), bidirectional checking minimizes the annotations users must write. The user annotates top-level definitions; the checker propagates types inward.

**Mechanism**:

- **Synth** (`synth(ctx, term) → {elaborated_term, type}`): Infers the type of a term. Used for variables (look up in context), applications (synth the function, check the argument against the domain), annotations, and literals.

- **Check** (`check(ctx, term, expected_type) → elaborated_term`): Verifies that a term has a given type. Used for lambdas (check the body against the codomain), let-bindings, and any term where the expected type is known from context.

- **Mode switch**: When `check` encounters a term it can't check directly (e.g., an application), it falls through to `synth` and then unifies the inferred type with the expected type.

**Key rules**:

```
Γ ⊢ x synth ⇒ Γ(x)                              [Var]
Γ ⊢ (e : A) synth ⇒ A  when  Γ ⊢ e check A     [Ann]
Γ ⊢ f e synth ⇒ B[e/x]  when  Γ ⊢ f synth ⇒ Π(x:A).B,  Γ ⊢ e check A   [App]
Γ, x:A ⊢ body check B  ⟹  Γ ⊢ λx.body check Π(x:A).B   [Lam]
```

**Trade-off**: Some terms require type annotations where Hindley-Milner would infer them. In practice, the combination of top-level annotations + implicit arguments + bidirectional propagation covers most cases naturally.

See [[../subsystems/08-checker]], [[d14-implicits-from-start]].
