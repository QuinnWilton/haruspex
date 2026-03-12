# Natural numbers and basic arithmetic.

type Nat
  | zero
  | succ(Nat)

@total
def add(n : Nat, m : Nat) : Nat do
  case n do
    zero -> m
    succ(pred) -> succ(add(pred, m))
  end
end

@total
def mul(n : Nat, m : Nat) : Nat do
  case n do
    zero -> zero
    succ(pred) -> add(m, mul(pred, m))
  end
end

def is_zero(n : Nat) : Bool do
  case n do
    zero -> true
    succ(_) -> false
  end
end
