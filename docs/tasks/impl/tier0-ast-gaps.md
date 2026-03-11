# Tier 0: AST specification gaps

**Module**: `Haruspex.AST` (already exists)
**Subsystem doc**: [[../../subsystems/03-ast]]

## Scope

Fill gaps in the existing AST module and subsystem doc identified during audit.

## Gaps to resolve

1. **Missing surface nodes for new features**: the existing AST needs nodes for:
   - `{:import, span, module_path, open_option}` — import declarations (d29)
   - `{:variable_decl, span, param}` — auto-implicit variable declarations (d24)
   - `{:mutual, span, [toplevel]}` — mutual blocks (d25)
   - `{:extern, span, module, function, arity}` — extern annotation data (d27)
   - `{:class_decl, span, name, [param], [constraint], [method_sig]}` — type class declarations (d20)
   - `{:instance_decl, span, class_name, [type_arg], [constraint], [method_impl]}` — instance declarations (d20)
   - `{:record_decl, span, name, [param], [field]}` — record declarations (d21)
   - `{:with, span, [expr], [branch]}` — with-abstraction (d22)
   - `{:dot, span, expr, field_name}` — field access (d21)
   - `{:record_construct, span, name, [{atom, expr}]}` — record construction (d21)
   - `{:record_update, span, expr, [{atom, expr}]}` — record update (d21)

2. **Type parameter specification**: `{:type_decl, span, name, [atom()], [constructor]}` uses `[atom()]` for type params but should carry kinds: `[{atom(), type_expr() | nil}]` to support `type Vec(a : Type, n : Nat)`.

3. **Constructor return types**: constructors should optionally carry return types for GADTs: `{:constructor, span, name, [field], type_expr() | nil}`.

4. **Pattern for records**: `{:pat_record, span, name, [{atom, pattern}]}` for matching on record fields.

## Implementation

Update `Haruspex.AST` typespecs and `span/1` function to handle all new node shapes. No behavior changes — just type definitions and the span extractor.

## Testing strategy

- `span/1` works on every new node type
- All typespecs compile and pass dialyzer
- No test file yet — add `test/haruspex/ast_test.exs` with span extraction tests for each node shape

## Verification

```bash
mix test test/haruspex/ast_test.exs
mix format --check-formatted
mix dialyzer
```
