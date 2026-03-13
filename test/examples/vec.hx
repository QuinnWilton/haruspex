# Length-indexed vectors.

import Data.Nat

type Vec(n : Nat, a : Type) =
  | vnil : Vec(zero, a)
  | vcons(a, Vec(n, a)) : Vec(succ(n), a)

@total
def vhead({a : Type}, {n : Nat}, v : Vec(succ(n), a)) : a do
  case v do
    vcons(x, _) -> x
  end
end

@total
def vtail({a : Type}, 0 n : Nat, v : Vec(succ(n), a)) : Vec(n, a) do
  case v do
    vcons(_, rest) -> rest
  end
end

def vmap({a : Type}, {b : Type}, {n : Nat}, f : a -> b, v : Vec(n, a)) : Vec(n, b) do
  case v do
    vnil -> vnil
    vcons(x, xs) -> vcons(f(x), vmap(f, xs))
  end
end

def vlength({a : Type}, {n : Nat}, v : Vec(n, a)) : Nat do
  case v do
    vnil -> zero
    vcons(_, xs) -> succ(vlength(xs))
  end
end
