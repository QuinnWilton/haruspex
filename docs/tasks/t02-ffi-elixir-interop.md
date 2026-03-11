# T02: FFI and Elixir interop

**Status**: Resolved → [[../decisions/d27-ffi-elixir-interop]]

**Blocks**: Tier 3 (codegen needs extern handling)

## The question

How do you call Elixir/Erlang functions from Haruspex? Without FFI, the language can't do IO, use OTP, access :ets, or call any existing library.

## Sub-questions

1. **Declaring external functions**: What syntax declares a Haruspex type for an Elixir function?
   ```elixir
   # Option A: @extern annotation
   @extern :math, :sqrt
   def sqrt(x : Float) : Float

   # Option B: foreign block
   foreign do
     sqrt(x : Float) : Float = :math.sqrt/1
     puts(s : String) : Atom = IO.puts/1
   end

   # Option C: inline Elixir module reference
   def sqrt(x : Float) : Float do
     :math.sqrt(x)
   end
   ```

2. **Trust boundary**: External function types are *trusted* — the checker can't verify that `:math.sqrt` actually has type `Float -> Float`. Is this explicit? Is there a visual marker in the type signature?

3. **Escape hatch / Dynamic**: What happens when an Elixir function returns something Haruspex can't type? Options:
   - `Any` type that bypasses checking (like Idris 2's `believe_me`)
   - `Dynamic` type that requires explicit casting
   - No escape hatch — everything must be typed
   - `unsafe` blocks

4. **Calling Haruspex from Elixir**: Since Haruspex compiles to Elixir modules, calling Haruspex from Elixir is automatic. But does the generated API look reasonable? (No dictionary arguments leaking, erased args absent, etc.)

5. **BEAM types at the boundary**: How do Haruspex types map to BEAM terms at FFI boundaries?
   - `Int` ↔ Elixir integer
   - `Float` ↔ Elixir float
   - `String` ↔ Elixir binary
   - `List(a)` ↔ Elixir list (if runtime representation matches)
   - ADTs ↔ tagged tuples
   - Records ↔ structs

6. **NIFs and ports**: Out of scope initially, but the FFI design should not preclude them.

7. **Callbacks and higher-order FFI**: Can you pass Haruspex functions to Elixir? `Enum.map(my_haruspex_fn, list)` — does the function value's runtime representation match what Elixir expects?

## Design space

| Approach | Precedent | Trade-off |
|----------|-----------|-----------|
| Explicit @extern declarations | Idris 2 `%foreign` | Safe, verbose, clear trust boundary |
| Inline Elixir calls | F# type providers | Convenient, blurs the trust boundary |
| Thin wrapper modules | PureScript FFI | Separation of concerns, more boilerplate |

## Implications for other subsystems

- **Core terms**: May need `{:extern, module, function, arity}` term form
- **Elaboration**: @extern declarations skip body elaboration
- **Checker**: Extern types are axioms (no body to check)
- **Codegen**: Extern calls compile to direct Elixir function calls
- **Roux queries**: Extern declarations are entities but with no body field

## Decision needed

→ Will become **d27-ffi-elixir-interop** once resolved.
