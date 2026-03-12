# Polymorphic linked lists.

type List(a : Type)
  | nil
  | cons(a, List(a))

def map(xs : List(a), f : a -> b) : List(b) do
  case xs do
    nil -> nil
    cons(head, tail) -> cons(f(head), map(tail, f))
  end
end

def foldr(xs : List(a), init : b, f : (a, b) -> b) : b do
  case xs do
    nil -> init
    cons(head, tail) ->
      let rest = foldr(tail, init, f)
      f(head, rest)
  end
end

def length(xs : List(a)) : Int do
  foldr(xs, 0, fn(_ : a, acc : Int) -> acc + 1 end)
end

def sum(xs : List(Int)) : Int do
  foldr(xs, 0, fn(x : Int, acc : Int) -> x + acc end)
end
