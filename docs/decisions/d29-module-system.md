# D29: Module system

**Decision**: One file per module, name derived from file path. Single `import` keyword handles all cross-module references — qualified access is always available, unqualified access is opt-in via `open:`. Type class instances come into scope on import. No `defmodule` declaration. No circular imports.

**Rationale**: Haruspex has Elixir surface syntax and targets Elixir developers, but it also has type class instances that must propagate across module boundaries. A single `import` keyword avoids the Elixir `alias`/`import` split (where `alias` would need invisible instance side effects) and the Lean `import`/`open` split (where the names would confuse Elixir developers). One keyword, one concept: "I depend on this module."

**Resolves**: [[../tasks/t04-module-system]]

## File to module mapping

Module names are derived from the file path relative to configured source directories:

```
lib/math.hx          → Math
lib/data/vec.hx      → Data.Vec
lib/data/vec/sort.hx → Data.Vec.Sort
```

There is no `defmodule` declaration. The file *is* the module. One module per file, always.

Source directories are configured in `mix.exs` (or equivalent project config):

```elixir
haruspex_paths: ["lib"]
```

## Import syntax

A single `import` keyword handles all cross-module dependencies:

```elixir
# Qualified access only — Math.add(x, y)
import Math

# Also unqualified — add(x, y), sub(x, y), etc.
import Math, open: true

# Selective unqualified — only add and sub are unqualified
import Math, open: [:add, :sub]
```

Every `import` does three things:

1. **Loads the module** — makes it available as a dependency (triggers roux queries)
2. **Enables qualified access** — `Math.add(x, y)` works
3. **Brings instances into scope** — type class instances defined in `Math` are available to instance search

The `open:` option additionally brings value-level names into unqualified scope.

## Qualified access

Qualified access is always available after `import`. No aliasing step needed:

```elixir
import Data.Vec

# use it qualified
Data.Vec.new(1, 2, 3)

# or, since the last segment is unambiguous:
Vec.new(1, 2, 3)
```

The last segment of a module path is automatically available as a short qualified name, matching Elixir's `alias` behavior. If two imports have the same last segment, qualified access requires the full path:

```elixir
import Data.Vec
import Graphics.Vec

# ambiguous — must use full path
Data.Vec.new(...)
Graphics.Vec.new(...)
```

## Visibility

Definitions are **public by default**. Use `@private` to restrict:

```elixir
def add(x : Int, y : Int) : Int do x + y end

@private
def internal_helper(x : Int) : Int do x * 2 end
```

`@private` definitions are not visible to importers — they cannot be accessed qualified or unqualified.

This matches Elixir convention (`def` is public, `defp` is private) expressed through annotations rather than separate keywords.

## Type class instance visibility

Instances come into scope on `import`, unconditionally. There is no way to import a module without its instances.

```elixir
# Data.Vec defines: instance Eq(Vec(a)) given Eq(a)

import Data.Vec
# Eq(Vec(Int)) is now available to instance search
```

This matches Haskell's behavior and is the only approach that keeps instance search coherent — if instances could be selectively hidden, the same expression could type-check or fail depending on which imports are present, making code fragile and hard to reason about.

## Circular imports

Circular imports are **not allowed**. The module dependency graph must be a DAG. Cycles are a compile-time error:

```
Error: circular import detected
  Math imports Data.Vec
  Data.Vec imports Math
```

Mutual recursion within a single module is supported (d25). Cross-module mutual recursion is not — restructure into a single module or break the cycle with an interface.

## Prelude

When the module system is operational, a `Haruspex.Prelude` module is auto-imported into every file. It contains:

- Built-in type names (`Int`, `Float`, `String`, `Atom`) — re-exports of builtins (d26)
- `Bool` ADT and its constructors (`true`, `false`)
- Arithmetic operators (`add`, `sub`, `mul`, `div`, etc.)
- Comparison operators (`eq`, `lt`, `gt`, etc.)
- Core type class instances (when type classes exist)

The prelude import can be suppressed with `@no_prelude` for low-level modules.

Until the module system exists, these names are hard-wired in the elaborator (as described in d26).

## Core representation

Imports elaborate to dependency declarations in the roux query graph, not to core terms. There is no `import` in the core calculus — by the time elaboration is done, all names are resolved to their definitions.

A cross-module reference elaborates to the same core forms as a local reference:

```elixir
# surface
Math.add(x, y)

# after elaboration — same as if add were local
App(App(Def(:Math, :add), x'), y')
```

The `{:def, module, name}` form (extending the `{:def, name}` from d28) carries the module to support cross-module NbE unfolding of `@total` functions.

## Roux integration

Each module is a roux entity group. Import declarations create query dependencies:

```
haruspex_parse("lib/foo.hx")
  → discovers: import Math
  → creates dependency: haruspex_check("lib/foo.hx", :bar) depends on
     haruspex_check("lib/math.hx", :add)
```

This enables fine-grained incrementality — changing `Math.add`'s type invalidates dependents, but changing `Math.sub`'s body does not affect modules that only use `add`.

## Deferred

The following are explicitly deferred:

| Topic | Reason | Revisit at |
|-------|--------|------------|
| Re-exports | Not needed for basic multi-file projects | When needed |
| Module parameters | Type classes cover the same use cases | Probably never |
| Orphan instance rules | Requires real-world usage to inform the policy | T08 |
| `as` aliasing (`import Data.Vec as V`) | Convenience, not essential | When needed |
