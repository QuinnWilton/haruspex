# D26: Built-in types and the prelude

**Decision**: Numeric types (`Int`, `Float`), `String`, and `Atom` are opaque built-in types. `Bool` is a real ADT defined internally. Arithmetic operators are regular definitions over built-in delta rules. There is no prelude module until the module system (T04) exists. Operator overloading is deferred to type classes (Tier 6).

**Rationale**: Haruspex targets the BEAM, where integers are arbitrary-precision and floats are IEEE 754 — these are genuinely opaque runtime primitives with no useful inductive structure. Making them built-in avoids the Lean-style impedance mismatch of defining Peano naturals then secretly replacing them with machine integers. Bool, by contrast, is a simple two-constructor sum type — making it a real ADT gives exhaustiveness checking for free and requires no special cases in the checker. Operators are regular definitions (not special syntax) so that type classes can replace their fixed types at Tier 6 without changing anything downstream.

**Resolves**: [[../tasks/t01-builtins-and-prelude]]

## Built-in types

Five types are hard-coded in the core calculus as `{:builtin, atom()}` terms:

| Type | Core representation | Universe | Inhabitants |
|------|-------------------|----------|-------------|
| `Int` | `{:builtin, :Int}` | `Type 0` | Arbitrary-precision integers |
| `Float` | `{:builtin, :Float}` | `Type 0` | IEEE 754 doubles |
| `String` | `{:builtin, :String}` | `Type 0` | UTF-8 binary strings |
| `Atom` | `{:builtin, :Atom}` | `Type 0` | BEAM atoms |

These evaluate to `{:vbuiltin, :Int}` etc. in the value domain. They are opaque — no constructors, no pattern matching on internal structure. The only way to introduce values of these types is through literals or built-in operations.

`Bool` is **not** a built-in type. See "Bool as ADT" below.

## Literal typing

Literals have fixed types. No overloading until type classes exist.

```
synth(ctx, Lit(n)) when is_integer(n)  → {:ok, {Lit(n), VBuiltin(:Int)}}
synth(ctx, Lit(f)) when is_float(f)    → {:ok, {Lit(f), VBuiltin(:Float)}}
synth(ctx, Lit(s)) when is_binary(s)   → {:ok, {Lit(s), VBuiltin(:String)}}
synth(ctx, Lit(a)) when is_atom(a)     → {:ok, {Lit(a), VBuiltin(:Atom)}}
```

At Tier 6, integer literals may become overloaded via a `FromInteger` class (like Haskell's `fromInteger`). The synth rules above get replaced by instance search. This is a backward-compatible change — existing code that uses `Int` continues to work because `Int` has a `FromInteger` instance.

## Bool as ADT

Bool is defined internally as a real algebraic data type, injected into the elaboration context before user code:

```
type Bool : Type 0 do
  true : Bool
  false : Bool
end
```

This means:
- `true` and `false` are real constructors, not literals
- `if c then a else b` is sugar for `case c do true -> a; false -> b end`
- Exhaustiveness checking works through the normal ADT machinery
- No special rules in the checker

The internal ADT definition uses the same representation as user-defined ADTs. When the module system exists, it moves into a prelude module. Nothing changes in core or the checker.

## Built-in operations

Arithmetic and comparison operators are **regular top-level definitions** whose bodies are built-in delta rules. They are not special syntax or special forms in the checker.

```
# these are definitions, not core term forms
add : Int -> Int -> Int
sub : Int -> Int -> Int
mul : Int -> Int -> Int
div : Int -> Int -> Int
neg : Int -> Int

fadd : Float -> Float -> Float
# ... etc

eq  : {a : Type} -> a -> a -> Bool   # polymorphic, builtin equality
lt  : Int -> Int -> Bool
gt  : Int -> Int -> Bool
```

In core, each is represented as a `{:builtin, :add}` term with a known type. The evaluator delta-reduces fully-applied builtins:

```
vapp(vapp(VBuiltin(:add), VLit(2)), VLit(3))  →  VLit(5)
vapp(VBuiltin(:add), VLit(2))                  →  VBuiltin({:add_partial, 2})
```

At Tier 6, `+` becomes a method of the `Num` class. The `Int` instance delegates to `{:builtin, :add}`. Codegen still produces `Kernel.+(a, b)`. Only the name resolution path changes.

### Operator surface syntax

The parser desugars infix `+` to a function application of `add`. The elaborator resolves `add` to `{:builtin, :add}`. This keeps operators out of the core calculus entirely — they are just functions.

```
# surface
x + y

# after parsing
add(x, y)

# after elaboration
App(App(Builtin(:add), x'), y')
```

## Pattern matching on primitive types

Primitive types have infinitely many inhabitants (except Atom, which is finite but impractically large). Pattern matching on literal values is allowed:

```
def describe(n : Int) : String do
  case n do
    0 -> "zero"
    1 -> "one"
    _ -> "other"
  end
end
```

A wildcard or variable pattern is **required** for primitive scrutinees. Exhaustiveness checking enforces this: the set of literal patterns can never cover the full type.

For `@total` functions: matching on a primitive type with a wildcard is permitted. The wildcard branch must still terminate. This differs from ADTs, where `@total` requires covering all constructors without a wildcard.

## The elaboration seam

The elaborator is the only component that knows which names are "built-in." Today it maintains a hard-coded table:

```elixir
@builtins %{
  "Int"    => {:builtin, :Int},
  "Float"  => {:builtin, :Float},
  "String" => {:builtin, :String},
  "Atom"   => {:builtin, :Atom},
  "Bool"   => ...,   # ADT reference
  "true"   => ...,   # constructor reference
  "false"  => ...,   # constructor reference
  "add"    => {:builtin, :add},
  # ...
}
```

When the module system (T04) arrives, this table is replaced by import resolution. The builtins move into a `Haruspex.Prelude` module that is auto-imported. Core terms, the checker, NbE, and codegen are unaffected.

## Codegen

Built-in types map to their Elixir equivalents with no wrapping:

| Haruspex | Elixir |
|----------|--------|
| `Int` | `integer()` |
| `Float` | `float()` |
| `String` | `String.t()` |
| `Atom` | `atom()` |
| `Bool` | `boolean()` |

Built-in operations map to Kernel functions:

| Builtin | Elixir |
|---------|--------|
| `:add` | `Kernel.+(a, b)` |
| `:sub` | `Kernel.-(a, b)` |
| `:mul` | `Kernel.*(a, b)` |
| `:div` | `Kernel.div(a, b)` |
| `:eq` | `Kernel.==(a, b)` |
| `:lt` | `Kernel.<(a, b)` |
| `:gt` | `Kernel.>(a, b)` |

## Future evolution

| Change | Tier | What changes | What doesn't change |
|--------|------|-------------|-------------------|
| Prelude module | T04 (modules) | Elaborator resolves names through imports | Core, checker, NbE, codegen |
| Literal overloading | T06 (type classes) | `FromInteger` class, synth rule uses instance search | Core representation of literals |
| Operator overloading | T06 (type classes) | `Num`/`Eq`/`Ord` classes, operators become methods | Codegen (inlines known dictionaries) |
| Sized integers | Future | New builtin types `Int8`, `Int16`, etc. | Everything else |
