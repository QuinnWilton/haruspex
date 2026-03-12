# Complex type signatures and type-level edge cases.

# Deeply nested pi types.
def curry3 : (a : Type) -> (b : Type) -> (c : Type) -> a -> b -> c -> a do
  fn(a : Type) -> fn(b : Type) -> fn(c : Type) ->
    fn(x : a) -> fn(y : b) -> fn(z : c) -> x end end end
  end end end
end

# Mixed implicit and explicit params.
def mixed({a : Type}, {b : Type}, x : a, {c : Type}, y : b) : a do
  x
end

# Erased parameter.
def erased(0 ghost : Nat, real : Int) : Int do
  real
end

# Implicit pi in return type.
def implicit_return : {a : Type} -> a -> a do
  fn(x : a) -> x end
end

# Refinement in pi domain.
def refine_domain(x : {n : Int | n > 0}) : Int do
  x
end

# Nested refinement.
def nested_refine(x : {n : Int | n > 0 && n < 100}) : {m : Int | m >= 0} do
  x - 1
end

# Arrow of arrows (higher-order).
def higher_order(f : (Int -> Int) -> Int, g : Int -> Int) : Int do
  f(g)
end

# Sigma types.
def sigma_example : (a : Type, a) do
  unit
end

# Product types (anonymous sigma).
def product : (Int, Bool, String) do
  unit
end

# Forall with instance param.
def with_instance([eq : Eq(a)], x : a, y : a) : Bool do
  eq(x, y)
end

# Variable declaration with multiple params.
@implicit {a : Type} {b : Type}

# Type with kind-annotated params.
type Functor(f : Type -> Type)
  | mk_functor
