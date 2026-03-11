# D02: De Bruijn indices in core terms

**Decision**: Core terms use de Bruijn indices for variable references. Named variables exist only in the surface AST.

**Rationale**: De Bruijn indices make alpha-equivalence trivial — two terms are alpha-equivalent if and only if they are structurally equal. This is critical for a dependent type checker where type equality checks are pervasive. Capture-avoiding substitution is also free: no renaming needed, just index shifting. This simplifies NbE ([[d03-nbe-conversion]]) and unification ([[d14-implicits-from-start]]).

**Trade-off**: Error messages need index-to-name recovery. The elaboration pass ([[d08-elaboration-boundary]]) must map surface names to indices. Reading core term dumps during debugging requires mental index-to-name translation, though the context always provides the mapping.

**Mechanism**: De Bruijn indices count bindings from the variable occurrence up to its binder (0 = nearest enclosing binder). During NbE, values use de Bruijn *levels* instead (counting from the bottom of the context up), which avoids shifting when extending the environment. Readback converts levels back to indices. See [[d03-nbe-conversion]], [[../subsystems/04-core-terms]], [[../subsystems/05-values-nbe]].

**Example**:

```
Surface:     fn (x : Int) -> fn (y : Int) -> x + y
Core:        Lam(ω, Lam(ω, Add(Var(1), Var(0))))
                              ^          ^
                              x (skip 1) y (nearest)
```
