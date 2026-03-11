# T04: Module system

**Status**: Resolved → [[../decisions/d29-module-system]]

**Blocks**: Tier 3 (query wiring needs module semantics)

## The question

How are Haruspex source files organized into modules? How do modules import from each other? What's public vs private? How do type class instances propagate?

## Sub-questions

1. **File → module mapping**: Is it one module per file? Does the module name come from the file path (like Lark: `lib/math.hx` → `Math`)? Or is there an explicit `module Math do ... end` declaration?

2. **Import syntax**: How do you bring names from another module into scope?
   ```elixir
   # Option A: Lark-style
   import Math
   import Math (add, sub)
   import Math as M

   # Option B: Elixir-style
   alias Math
   import Math, only: [add: 2, sub: 2]
   use Math  # macro-like

   # Option C: Minimal
   import Math        # qualified access: Math.add(x, y)
   open Math          # unqualified access: add(x, y)
   ```

3. **Qualified access**: Is `Math.add(x, y)` supported? Is it the default (like in Lean) or opt-in (like Elixir's `alias`)?

4. **Visibility**: What's public by default?
   - Everything public, `@private` to restrict (Elixir-like)
   - Everything private, `export` to publish (Lark-like)
   - Explicit exports list at top of file

5. **Type class instance visibility**: When you import a module, do its type class instances come into scope? They should — otherwise `import List` doesn't bring `Eq(List(a))` into scope, and instance search fails. But this means imports have invisible side effects.

6. **Instance orphans across modules**: Module A defines `type Foo`. Module B defines `class Bar`. Module C defines `instance Bar(Foo)`. If module D imports only A and B (not C), is `Bar(Foo)` available? This is the orphan/coherence problem.

7. **Re-exports**: Can a module re-export names it imported?

8. **Circular imports**: Are they allowed? If module A imports B and B imports A, what happens? Roux's incremental computation handles diamond dependencies, but true cycles need careful ordering.

9. **Module parameters**: Agda has parameterized modules (`module Sorting (ord : Ord a) where ...`). Is this needed, or do type classes cover the same use cases?

## Design space

| Aspect | Elixir-like | Lean-like | Agda-like |
|--------|------------|-----------|-----------|
| File→module | Convention | Declaration | Declaration |
| Default visibility | Public | Public | Public |
| Qualified access | Via `alias` | Default | Via `open` |
| Instance visibility | N/A | On import | On `open` |

## Lark's approach (reference)

Lark uses:
- File path → module name (`lib/math.lark` → `:Math`)
- `export name1, name2` at top of file
- `import Module`, `import Module (name1, name2)`, `import Module as Alias`
- No `module` declaration
- Module names derived from `source_dirs` config

This is simple and works. Haruspex could follow the same pattern, extending it with:
- Instance auto-import on `import`
- `@private` annotation for non-exported definitions

## Implications for other subsystems

- **Roux queries**: Module interface query (like Lark's `lark_module_interface`)
- **Elaboration**: Name resolution needs module scope + import resolution
- **Type classes**: Instance database must be populated from imports
- **Codegen**: Module name → `defmodule` name mapping
- **LSP**: Completions need cross-module name resolution

## Decision needed

→ Will become **d29-module-system** once resolved.
