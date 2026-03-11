# D01: Elixir-like surface syntax

**Decision**: Use Elixir-like syntax (do/end blocks, pipeline operator, pattern matching) rather than ML-family syntax.

**Rationale**: The target audience is BEAM developers already familiar with Elixir. A familiar syntax lowers the adoption barrier — developers can focus on learning dependent types rather than simultaneously learning a new syntax. Elixir's `do`/`end` blocks, pipeline operator, and pattern matching syntax are ergonomic and well-understood in the ecosystem.

**Trade-off**: Elixir's syntax has some tensions with dependent type features. Type annotations require a `:` operator that must be disambiguated from keyword argument syntax. Implicit arguments need new syntax (`{a : Type}`) not present in Elixir. The parser is more complex than a minimal ML-style parser would be.

**Mechanism**: NimbleParsec tokenizer handles the superset of Elixir tokens plus type syntax extensions. Recursive descent parser gives full control over precedence and disambiguation. Tree-sitter grammar (separate from the compilation parser) handles editor highlighting. See [[d12-nimble-parsec-tokenizer]], [[../subsystems/01-tokenizer]], [[../subsystems/02-parser]].

**Surface syntax examples**:

```elixir
# Simple function with type annotation
def add(x : Int, y : Int) : Int do
  x + y
end

# Implicit type argument (inferred)
def id({a : Type}, x : a) : a do
  x
end

# Dependent function type
def replicate({a : Type}, n : Nat, x : a) : Vec(a, n) do
  ...
end

# ADT declaration
type Option(a) do
  :none
  some(a)
end

# Pattern matching
case opt do
  :none -> default
  some(x) -> x
end

# Typed hole
def mystery(x : Int) : _ do
  x + 1
end

# Refinement type
def divide(x : Int, y : {y : Int | y != 0}) : Int do
  div(x, y)
end

# Erased proof argument
def head({a : Type}, {0 n : Nat}, xs : Vec(a, succ(n))) : a do
  ...
end

# Totality annotation
@total
def length({a : Type}, xs : List(a)) : Nat do
  case xs do
    :nil -> zero()
    cons(_, rest) -> succ(length(rest))
  end
end
```
