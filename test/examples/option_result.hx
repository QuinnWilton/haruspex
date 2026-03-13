# Option and result types with a functor class.

type Option(a : Type) =
  | none
  | some(a)

type Result(e : Type, a : Type) =
  | err(e)
  | ok(a)

def is_some(opt : Option(a)) : Bool do
  case opt do
    none -> false
    some(_) -> true
  end
end

def unwrap_or(opt : Option(a), default : a) : a do
  case opt do
    none -> default
    some(x) -> x
  end
end

def or_else(first : Option(x), second : Option(x)) : Option(x) do
  if is_some(first) do first else second end
end

class Functor(f : Type -> Type) do
  fmap : (a -> b) -> f(a) -> f(b)
end

instance Functor(Option) do
  def fmap(func : a -> b, opt : Option(a)) : Option(b) do
    case opt do
      none -> none
      some(x) -> some(func(x))
    end
  end
end

instance Functor(Result(e)) do
  def fmap(func : a -> b, r : Result(e, a)) : Result(e, b) do
    case r do
      err(reason) -> err(reason)
      ok(x) -> ok(func(x))
    end
  end
end
