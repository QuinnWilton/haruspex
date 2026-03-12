# Deeply nested expressions and operator precedence edge cases.

def all_precedences(x : Int, y : Int, z : Int) : Bool do
  x + y * z - x / y > z && x <= y || x != z == true
end

def nested_case(x : Int) : Int do
  case x do
    0 ->
      case x do
        0 -> 1
        _ -> 2
      end
    _ ->
      case x do
        1 ->
          case x do
            1 -> 10
            _ -> 20
          end
        _ -> 0
      end
  end
end

def nested_if(x : Int, y : Int) : Int do
  if x > 0 do
    if y > 0 do
      if x > y do
        x
      else
        y
      end
    else
      x
    end
  else
    if y > 0 do
      y
    else
      0
    end
  end
end

def chained_apps(a : Int, b : Int) : Int do
  add(mul(add(a, b), b), a)
end

def pipe_chain(x : Int) : Int do
  x |> inc |> double |> inc |> double
end

def right_assoc_arrow : Int -> Int -> Int -> Bool do
  fn(x : Int) -> fn(y : Int) -> fn(z : Int) -> x > y && y > z end end end
end

def unary_chain(x : Int) : Int do
  - - - x
end

def not_chain(b : Bool) : Bool do
  not not not b
end
