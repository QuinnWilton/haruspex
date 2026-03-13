# Pattern edge cases.

type Tree(a : Type) =
  | leaf
  | node(Tree(a), a, Tree(a))

# Deeply nested constructor patterns.
def deep_match(t : Tree(Int)) : Int do
  case t do
    node(node(node(leaf, x, leaf), y, leaf), z, leaf) -> x + y + z
    node(leaf, v, _) -> v
    leaf -> 0
    _ -> -1
  end
end

# Many-arg constructor patterns.
type Quintuple(a : Type, b : Type, c : Type, d : Type, e : Type) =
  | quint(a, b, c, d, e)

def first_of_five(q : Quintuple(Int, Int, Int, Int, Int)) : Int do
  case q do
    quint(a, _, _, _, _) -> a
  end
end

# Literals in patterns.
def match_int(x : Int) : String do
  case x do
    0 -> "zero"
    1 -> "one"
    42 -> "answer"
    _ -> "other"
  end
end

def match_string(s : String) : Int do
  case s do
    "hello" -> 1
    "world" -> 2
    "" -> 0
    _ -> -1
  end
end

def match_bool(b : Bool) : Int do
  case b do
    true -> 1
    false -> 0
  end
end

def match_atom(x : Atom) : Int do
  case x do
    :ok -> 1
    :error -> 2
    :pending -> 3
  end
end

def match_float(x : Float) : String do
  case x do
    0.0 -> "zero"
    1.0 -> "one"
    3.14 -> "pi-ish"
    _ -> "other"
  end
end

# Wildcard in nested positions.
def ignore_structure(t : Tree(Int)) : Bool do
  case t do
    node(_, _, _) -> true
    leaf -> false
  end
end
