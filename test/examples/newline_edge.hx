# Newline sensitivity edge cases.



# Multiple blank lines between declarations.



type Bool2
  | true2
  | false2



# Comment between annotation and def.
@total
# This is a comment between @ and def.
def id(x : Int) : Int do
  x
end

# Expression split across lines inside parens (newlines suppressed).
def multiline_call(x : Int, y : Int) : Int do
  add(
    x,
    y
  )
end

# Multiline type annotation.
def multiline_sig(
  x : Int,
  y : Int,
  z : Int
) : Int do
  x + y + z
end

# Case branches separated by blank lines.
def spaced_case(x : Int) : Int do
  case x do

    0 -> 1

    1 -> 2

    _ -> 0

  end
end

# Multiline if.
def multiline_if(x : Int) : Int do
  if x > 0 do
    let a = x
    let b = a + 1
    b
  else
    let c = 0 - x
    c
  end
end

# Multiline lambda.
def multiline_fn : Int -> Int do
  fn(x : Int) ->
    let y = x + 1
    let z = y * 2
    z
  end
end

# Comments inside expressions (inside parens, newlines suppressed).
def commented_args(x : Int) : Int do
  add(
    # first arg
    x,
    # second arg
    42
  )
end
