# Refinement types, sigma types, and external bindings.

@implicit {a : Type}

@extern Kernel.div/2
def safe_div(x : Int, y : {n : Int | n != 0}) : Int do
  x / y
end

def clamp(value : Int, lo : Int, hi : Int) : {x : Int | x >= lo && x <= hi} do
  if value < lo do
    lo
  else
    if value > hi do
      hi
    else
      value
    end
  end
end

def negate_bool(b : Bool) : Bool do
  not b
end

def negate_int(n : Int) : Int do
  -n
end

def dependent_arrow : (n : Int) -> {m : Int | m > n} do
  fn(n : Int) -> n + 1 end
end
