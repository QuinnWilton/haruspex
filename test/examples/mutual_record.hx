# Mutual recursion and record types.

record Point
  : x : Int
  , y : Int

record Config
  : label : String
  , threshold : Int

mutual do
  def is_even(n : Int) : Bool do
    if n == 0 do
      true
    else
      is_odd(n - 1)
    end
  end

  def is_odd(n : Int) : Bool do
    if n == 0 do
      false
    else
      is_even(n - 1)
    end
  end
end

def manhattan(p : Point) : Int do
  p.x + p.y
end

@private
def above_threshold(cfg : Config, value : Int) : Bool do
  value >= cfg.threshold
end

def scale(p : Point, factor : Int) : Int do
  p.x * factor + p.y * factor
end
