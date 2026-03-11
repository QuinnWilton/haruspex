# D24: Auto-implicit variable declarations

**Decision**: Support `variable` declarations that automatically generalize free type variables in function signatures, reducing annotation burden for polymorphic code.

**Rationale**: Without auto-implicits, every polymorphic function needs explicit `{a : Type}`:
```elixir
# Without auto-implicits — verbose:
def id({a : Type}, x : a) : a do x end
def const({a : Type}, {b : Type}, x : a, y : b) : a do x end
def map({a : Type}, {b : Type}, f : a -> b, xs : List(a)) : List(b) do ... end
```
With auto-implicits:
```elixir
variable {a : Type} {b : Type}

def id(x : a) : a do x end
def const(x : a, y : b) : a do x end
def map(f : a -> b, xs : List(a)) : List(b) do ... end
```
This is standard practice: Lean's `variable`, Agda's `variable`, Coq's `Variable`/`Generalizable`. It eliminates the most common source of boilerplate in dependently typed code.

**Mechanism**:
1. `variable {a : Type}` registers `a` as an auto-implicit in the current scope
2. When elaborating a definition, if a free variable matches a registered auto-implicit, the elaborator automatically adds it as an implicit parameter
3. The auto-implicit is inserted at the beginning of the parameter list (before all explicit parameters)
4. Multiple auto-implicits are inserted in declaration order
5. Auto-implicits only trigger for *free* variables — locally bound variables shadow them

**Scoping**: `variable` declarations are scoped to the current module. They do not leak across module boundaries.

**Interaction with elaboration**: Auto-implicits are resolved during the name resolution phase of elaboration ([[d08-elaboration-boundary]]). Before standard name resolution, the elaborator checks if a free variable matches an auto-implicit declaration. If so, it inserts the implicit parameter and binds the variable.

**Trade-off**: Auto-implicits can make code harder to read in isolation — you need to check the `variable` declarations to understand a function's full signature. This is the same trade-off Lean and Agda make. Mitigation: LSP hover shows the full expanded signature. The `variable` block should be near the top of the file.

See [[d14-implicits-from-start]], [[d08-elaboration-boundary]], [[../subsystems/07-elaboration]].
