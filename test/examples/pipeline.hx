# Data processing with pipes and higher-order functions.

import Data.List, open: true
import Data.Option, open: [some, none]

type Step(a : Type) =
  | skip
  | keep(a)

def filter_map(xs : List(a), f : a -> Step(b)) : List(b) do
  case xs do
    nil -> nil
    cons(head, tail) ->
      let result = f(head)
      case result do
        skip -> filter_map(tail, f)
        keep(val) -> cons(val, filter_map(tail, f))
      end
  end
end

def sum(xs : List(Int)) : Int do
  foldr(xs, 0, fn(x : Int, acc : Int) -> x + acc end)
end

def count(xs : List(a)) : Int do
  foldr(xs, 0, fn(_ : a, acc : Int) -> acc + 1 end)
end

def double_positives(data : List(Int)) : List(Int) do
  filter_map(data, fn(x : Int) -> if x > 0 do keep(x * 2) else skip end end)
end

def apply_twice(x : Int, f : Int -> Int) : Int do
  f(x) |> f
end

def pipeline_example(data : List(Int)) : Int do
  let result = double_positives(data)
  let total = sum(result)
  total
end
