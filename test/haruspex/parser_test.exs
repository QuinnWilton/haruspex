defmodule Haruspex.ParserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Haruspex.{AST, Parser}

  # Helper to parse an expression and return just the AST (no span checking).
  defp parse_expr!(source) do
    assert {:ok, expr} = Parser.parse_expr(source)
    expr
  end

  # Helper to parse a program and return the AST.
  defp parse!(source) do
    assert {:ok, program} = Parser.parse(source)
    program
  end

  # Helper to assert parse error.
  defp assert_parse_error(source) do
    assert {:error, errors} = Parser.parse(source)
    errors
  end

  defp assert_expr_error(source) do
    assert {:error, errors} = Parser.parse_expr(source)
    errors
  end

  # ============================================================================
  # Literals
  # ============================================================================

  describe "literals" do
    test "integer" do
      assert {:lit, _, 42} = parse_expr!("42")
    end

    test "float" do
      assert {:lit, _, 3.14} = parse_expr!("3.14")
    end

    test "string" do
      assert {:lit, _, "hello"} = parse_expr!("\"hello\"")
    end

    test "atom" do
      assert {:lit, _, :foo} = parse_expr!(":foo")
    end

    test "true" do
      assert {:lit, _, true} = parse_expr!("true")
    end

    test "false" do
      assert {:lit, _, false} = parse_expr!("false")
    end
  end

  # ============================================================================
  # Variables
  # ============================================================================

  describe "variables" do
    test "lowercase identifier" do
      assert {:var, _, :x} = parse_expr!("x")
    end

    test "uppercase identifier" do
      assert {:var, _, :Int} = parse_expr!("Int")
    end

    test "multi-character identifier" do
      assert {:var, _, :foo_bar} = parse_expr!("foo_bar")
    end
  end

  # ============================================================================
  # Holes
  # ============================================================================

  describe "holes" do
    test "underscore is a hole" do
      assert {:hole, _} = parse_expr!("_")
    end
  end

  # ============================================================================
  # Application
  # ============================================================================

  describe "application" do
    test "single argument" do
      assert {:app, _, {:var, _, :f}, [{:var, _, :x}]} = parse_expr!("f(x)")
    end

    test "multiple arguments" do
      assert {:app, _, {:var, _, :f}, [{:var, _, :x}, {:var, _, :y}]} =
               parse_expr!("f(x, y)")
    end

    test "no arguments" do
      assert {:app, _, {:var, _, :f}, []} = parse_expr!("f()")
    end

    test "trailing comma" do
      assert {:app, _, {:var, _, :f}, [{:var, _, :x}]} = parse_expr!("f(x,)")
    end

    test "nested application" do
      assert {:app, _, {:app, _, {:var, _, :f}, [{:var, _, :x}]}, [{:var, _, :y}]} =
               parse_expr!("f(x)(y)")
    end

    test "application of uppercase" do
      assert {:app, _, {:var, _, :Some}, [{:var, _, :x}]} = parse_expr!("Some(x)")
    end
  end

  # ============================================================================
  # Operator precedence
  # ============================================================================

  describe "operator precedence" do
    test "mul binds tighter than add: 1 + 2 * 3" do
      expr = parse_expr!("1 + 2 * 3")
      assert {:binop, _, :add, {:lit, _, 1}, {:binop, _, :mul, {:lit, _, 2}, {:lit, _, 3}}} = expr
    end

    test "mul binds tighter than add: 1 * 2 + 3" do
      expr = parse_expr!("1 * 2 + 3")
      assert {:binop, _, :add, {:binop, _, :mul, {:lit, _, 1}, {:lit, _, 2}}, {:lit, _, 3}} = expr
    end

    test "comparison binds looser than add" do
      expr = parse_expr!("a + 1 < b + 2")

      assert {:binop, _, :lt, {:binop, _, :add, _, _}, {:binop, _, :add, _, _}} = expr
    end

    test "equality binds looser than comparison" do
      expr = parse_expr!("a < b == c < d")

      assert {:binop, _, :eq, {:binop, _, :lt, _, _}, {:binop, _, :lt, _, _}} = expr
    end

    test "and binds tighter than or" do
      expr = parse_expr!("a || b && c")

      assert {:binop, _, :or, {:var, _, :a}, {:binop, _, :and, {:var, _, :b}, {:var, _, :c}}} =
               expr
    end

    test "parentheses override precedence" do
      expr = parse_expr!("(1 + 2) * 3")
      assert {:binop, _, :mul, {:binop, _, :add, {:lit, _, 1}, {:lit, _, 2}}, {:lit, _, 3}} = expr
    end
  end

  # ============================================================================
  # Associativity
  # ============================================================================

  describe "associativity" do
    test "subtraction is left-associative: 1 - 2 - 3" do
      expr = parse_expr!("1 - 2 - 3")

      assert {:binop, _, :sub, {:binop, _, :sub, {:lit, _, 1}, {:lit, _, 2}}, {:lit, _, 3}} = expr
    end

    test "division is left-associative: a / b / c" do
      expr = parse_expr!("a / b / c")

      assert {:binop, _, :div, {:binop, _, :div, {:var, _, :a}, {:var, _, :b}}, {:var, _, :c}} =
               expr
    end

    test "arrow is right-associative: A -> B -> C" do
      expr = parse_expr!("A -> B -> C")

      assert {:pi, _, {:_, :omega, false}, {:var, _, :A},
              {:pi, _, {:_, :omega, false}, {:var, _, :B}, {:var, _, :C}}} = expr
    end
  end

  # ============================================================================
  # Unary operators
  # ============================================================================

  describe "unary operators" do
    test "negation" do
      assert {:unaryop, _, :neg, {:lit, _, 1}} = parse_expr!("-1")
    end

    test "not" do
      assert {:unaryop, _, :not, {:var, _, :x}} = parse_expr!("not x")
    end

    test "negation binds tighter than addition" do
      expr = parse_expr!("-a + b")
      assert {:binop, _, :add, {:unaryop, _, :neg, {:var, _, :a}}, {:var, _, :b}} = expr
    end
  end

  # ============================================================================
  # Pipe
  # ============================================================================

  describe "pipe" do
    test "simple pipe" do
      expr = parse_expr!("x |> f")
      assert {:pipe, _, {:var, _, :x}, {:var, _, :f}} = expr
    end

    test "chained pipe is left-associative: x |> f |> g" do
      expr = parse_expr!("x |> f |> g")

      assert {:pipe, _, {:pipe, _, {:var, _, :x}, {:var, _, :f}}, {:var, _, :g}} = expr
    end
  end

  # ============================================================================
  # Dot access
  # ============================================================================

  describe "dot access" do
    test "simple dot" do
      assert {:dot, _, {:var, _, :p}, :x} = parse_expr!("p.x")
    end

    test "chained dot" do
      expr = parse_expr!("a.b.c")
      assert {:dot, _, {:dot, _, {:var, _, :a}, :b}, :c} = expr
    end
  end

  # ============================================================================
  # Type annotations
  # ============================================================================

  describe "type annotations" do
    test "simple annotation" do
      expr = parse_expr!("(x : Int)")
      assert {:ann, _, {:var, _, :x}, {:var, _, :Int}} = expr
    end
  end

  # ============================================================================
  # Pi types
  # ============================================================================

  describe "pi types" do
    test "unnamed arrow: A -> B" do
      expr = parse_expr!("A -> B")
      assert {:pi, _, {:_, :omega, false}, {:var, _, :A}, {:var, _, :B}} = expr
    end

    test "named pi: (x : A) -> B" do
      expr = parse_expr!("(x : A) -> B")
      assert {:pi, _, {:x, :omega, false}, {:var, _, :A}, {:var, _, :B}} = expr
    end

    test "erased pi: (0 x : A) -> B" do
      expr = parse_expr!("(0 x : A) -> B")
      assert {:pi, _, {:x, :zero, false}, {:var, _, :A}, {:var, _, :B}} = expr
    end

    test "implicit pi: {a : Type} -> B" do
      expr = parse_expr!("{a : Type} -> B")
      assert {:pi, _, {:a, :omega, true}, {:type_universe, _, nil}, {:var, _, :B}} = expr
    end
  end

  # ============================================================================
  # Sigma types
  # ============================================================================

  describe "sigma types" do
    test "dependent sigma: (x : A, B)" do
      expr = parse_expr!("(x : A, B)")
      assert {:sigma, _, :x, {:var, _, :A}, {:var, _, :B}} = expr
    end

    test "product type: (A, B)" do
      expr = parse_expr!("(A, B)")
      assert {:sigma, _, :_, {:var, _, :A}, {:var, _, :B}} = expr
    end

    test "triple nests right: (A, B, C)" do
      expr = parse_expr!("(A, B, C)")

      assert {:sigma, _, :_, {:var, _, :A}, {:sigma, _, :_, {:var, _, :B}, {:var, _, :C}}} = expr
    end

    test "product in arrow: (A, B) -> C" do
      expr = parse_expr!("(A, B) -> C")

      assert {:pi, _, {:_, :omega, false}, {:sigma, _, :_, {:var, _, :A}, {:var, _, :B}},
              {:var, _, :C}} = expr
    end
  end

  # ============================================================================
  # Refinement types
  # ============================================================================

  describe "refinement types" do
    test "refinement: {x : Int | x > 0}" do
      expr = parse_expr!("{x : Int | x > 0}")

      assert {:refinement, _, :x, {:var, _, :Int}, {:binop, _, :gt, {:var, _, :x}, {:lit, _, 0}}} =
               expr
    end
  end

  # ============================================================================
  # Lambda
  # ============================================================================

  describe "lambda" do
    test "simple lambda" do
      expr = parse_expr!("fn(x : Int) -> x end")

      assert {:fn, _, [param], {:var, _, :x}} = expr
      assert {:param, _, {:x, :omega, false}, {:var, _, :Int}} = param
    end

    test "lambda with no params" do
      expr = parse_expr!("fn() -> 42 end")
      assert {:fn, _, [], {:lit, _, 42}} = expr
    end

    test "lambda with implicit param" do
      expr = parse_expr!("fn({a : Type}) -> a end")
      assert {:fn, _, [param], {:var, _, :a}} = expr
      assert {:param, _, {:a, :zero, true}, {:type_universe, _, nil}} = param
    end

    test "lambda with wildcard param" do
      expr = parse_expr!("fn(_ : Int) -> 42 end")
      assert {:fn, _, [param], {:lit, _, 42}} = expr
      assert {:param, _, {:_, :omega, false}, {:var, _, :Int}} = param
    end

    test "multi-param lambda curries" do
      expr = parse_expr!("fn(x : Int, y : Int) -> x + y end")
      assert {:fn, _, [p1], {:fn, _, [p2], {:binop, _, :add, _, _}}} = expr
      assert {:param, _, {:x, :omega, false}, {:var, _, :Int}} = p1
      assert {:param, _, {:y, :omega, false}, {:var, _, :Int}} = p2
    end

    test "three-param lambda curries to three nested fns" do
      expr = parse_expr!("fn(a : Int, b : Int, c : Int) -> a end")
      assert {:fn, _, [_], {:fn, _, [_], {:fn, _, [_], {:var, _, :a}}}} = expr
    end
  end

  # ============================================================================
  # Let
  # ============================================================================

  describe "let" do
    test "simple let" do
      expr = parse_expr!("let x = 1\nx")
      assert {:let, _, :x, {:lit, _, 1}, {:var, _, :x}} = expr
    end
  end

  # ============================================================================
  # Case
  # ============================================================================

  describe "case" do
    test "simple case" do
      expr = parse_expr!("case x do\n  0 -> true\n  _ -> false\nend")

      assert {:case, _, {:var, _, :x},
              [
                {:branch, _, {:pat_lit, _, 0}, {:lit, _, true}},
                {:branch, _, {:pat_wildcard, _}, {:lit, _, false}}
              ]} = expr
    end

    test "constructor pattern in case" do
      expr = parse_expr!("case x do\n  Some(v) -> v\n  None -> 0\nend")

      assert {:case, _, {:var, _, :x},
              [
                {:branch, _, {:pat_constructor, _, :Some, [{:pat_var, _, :v}]}, {:var, _, :v}},
                {:branch, _, {:pat_constructor, _, :None, []}, {:lit, _, 0}}
              ]} = expr
    end

    test "negative literal pattern" do
      expr = parse_expr!("case x do\n  -1 -> true\n  _ -> false\nend")

      assert {:case, _, {:var, _, :x},
              [
                {:branch, _, {:pat_lit, _, -1}, {:lit, _, true}},
                {:branch, _, {:pat_wildcard, _}, {:lit, _, false}}
              ]} = expr
    end
  end

  # ============================================================================
  # If/else
  # ============================================================================

  describe "if/else" do
    test "simple if/else" do
      expr = parse_expr!("if true do 1 else 2 end")
      assert {:if, _, {:lit, _, true}, {:lit, _, 1}, {:lit, _, 2}} = expr
    end

    test "if with complex condition" do
      expr = parse_expr!("if x > 0 do x else -x end")

      assert {:if, _, {:binop, _, :gt, {:var, _, :x}, {:lit, _, 0}}, {:var, _, :x},
              {:unaryop, _, :neg, {:var, _, :x}}} = expr
    end
  end

  # ============================================================================
  # Definitions
  # ============================================================================

  describe "definitions" do
    test "simple def" do
      [decl] = parse!("def f do 42 end")
      assert {:def, _, sig, {:lit, _, 42}} = decl
      assert {:sig, _, :f, _, [], nil, %{total: false, private: false, extern: nil}} = sig
    end

    test "def with params and return type" do
      [decl] = parse!("def add(x : Int, y : Int) : Int do x + y end")
      assert {:def, _, sig, {:binop, _, :add, _, _}} = decl
      assert {:sig, _, :add, _, [p1, p2], ret_type, _} = sig
      assert {:param, _, {:x, :omega, false}, {:var, _, :Int}} = p1
      assert {:param, _, {:y, :omega, false}, {:var, _, :Int}} = p2
      assert {:var, _, :Int} = ret_type
    end

    test "@total annotation" do
      [decl] = parse!("@total\ndef f do 42 end")

      assert {:def, _, {:sig, _, :f, _, _, _, %{total: true, private: false, extern: nil}}, _} =
               decl
    end

    test "@private annotation" do
      [decl] = parse!("@private\ndef f do 42 end")

      assert {:def, _, {:sig, _, :f, _, _, _, %{total: false, private: true, extern: nil}}, _} =
               decl
    end

    test "multiple annotations" do
      [decl] = parse!("@total\n@private\ndef f do 42 end")

      assert {:def, _, {:sig, _, :f, _, _, _, %{total: true, private: true, extern: nil}}, _} =
               decl
    end

    test "def with implicit param" do
      [decl] = parse!("def id({a : Type}, x : a) : a do x end")
      assert {:def, _, sig, _} = decl
      assert {:sig, _, :id, _, [implicit_param, explicit_param], _, _} = sig
      assert {:param, _, {:a, :zero, true}, {:type_universe, _, nil}} = implicit_param
      assert {:param, _, {:x, :omega, false}, {:var, _, :a}} = explicit_param
    end

    test "def with erased param" do
      [decl] = parse!("def f(0 x : Phantom) do 42 end")
      assert {:def, _, sig, _} = decl
      assert {:sig, _, :f, _, [param], _, _} = sig
      assert {:param, _, {:x, :zero, false}, {:var, _, :Phantom}} = param
    end
  end

  # ============================================================================
  # Type declarations
  # ============================================================================

  describe "type declarations" do
    test "simple enum" do
      [decl] = parse!("type Bool = true | false")
      assert {:type_decl, _, :Bool, [], constructors} = decl
      assert [{:constructor, _, true, [], nil}, {:constructor, _, false, [], nil}] = constructors
    end

    test "parameterized type with constructors" do
      [decl] = parse!("type Option(a : Type) =\n  | none\n  | some(a)")
      assert {:type_decl, _, :Option, [{:a, {:type_universe, _, nil}}], constructors} = decl

      assert [
               {:constructor, _, :none, [], nil},
               {:constructor, _, :some, [{:var, _, :a}], nil}
             ] = constructors
    end

    test "type with kinded parameter" do
      [decl] = parse!("type Vec(a : Type, n : Nat) = nil")

      assert {:type_decl, _, :Vec, [{:a, {:type_universe, _, nil}}, {:n, {:var, _, :Nat}}], _} =
               decl
    end

    test "GADT constructor with return type" do
      [decl] =
        parse!(
          "type Expr(a : Type) =\n  | lit(Int) : Expr(Int)\n  | add(Expr(Int), Expr(Int)) : Expr(Int)"
        )

      assert {:type_decl, _, :Expr, [{:a, {:type_universe, _, nil}}], [lit, add]} = decl

      assert {:constructor, _, :lit, [{:var, _, :Int}],
              {:app, _, {:var, _, :Expr}, [{:var, _, :Int}]}} = lit

      assert {:constructor, _, :add, [_, _], {:app, _, {:var, _, :Expr}, [{:var, _, :Int}]}} = add
    end
  end

  # ============================================================================
  # Import
  # ============================================================================

  describe "import" do
    test "simple import (qualified only)" do
      [decl] = parse!("import Data.Vec")
      assert {:import, _, [:Data, :Vec], nil} = decl
    end

    test "import with open: true" do
      [decl] = parse!("import Math, open: true")
      assert {:import, _, [:Math], true} = decl
    end

    test "import with selective open" do
      [decl] = parse!("import Math, open: [add, sub]")
      assert {:import, _, [:Math], [:add, :sub]} = decl
    end
  end

  # ============================================================================
  # Variable declarations
  # ============================================================================

  describe "implicit declarations" do
    test "simple implicit declaration" do
      [decl] = parse!("@implicit {a : Type}")
      assert {:implicit_decl, _, [param]} = decl
      assert {:param, _, {:a, :zero, true}, {:type_universe, _, nil}} = param
    end
  end

  # ============================================================================
  # Mutual blocks
  # ============================================================================

  describe "mutual blocks" do
    test "mutual with two defs" do
      source = """
      mutual do
        def even(n : Int) : Bool do
          if n == 0 do true else odd(n - 1) end
        end
        def odd(n : Int) : Bool do
          if n == 0 do false else even(n - 1) end
        end
      end
      """

      [decl] = parse!(source)
      assert {:mutual, _, [d1, d2]} = decl
      assert {:def, _, {:sig, _, :even, _, _, _, _}, _} = d1
      assert {:def, _, {:sig, _, :odd, _, _, _, _}, _} = d2
    end
  end

  # ============================================================================
  # Class declarations
  # ============================================================================

  describe "class declarations" do
    test "simple class" do
      source = """
      class Eq(a : Type) do
        eq : a -> a -> Bool
      end
      """

      [decl] = parse!(source)
      assert {:class_decl, _, :Eq, [param], [], [method]} = decl
      assert {:param, _, {:a, :omega, false}, {:type_universe, _, nil}} = param
      assert {:method_sig, _, :eq, _type} = method
    end
  end

  # ============================================================================
  # Instance declarations
  # ============================================================================

  describe "instance declarations" do
    test "simple instance" do
      source = """
      instance Eq(Int) do
        def eq do 42 end
      end
      """

      [decl] = parse!(source)
      assert {:instance_decl, _, :Eq, [{:var, _, :Int}], [], [impl]} = decl
      assert {:method_impl, _, :eq, {:lit, _, 42}} = impl
    end
  end

  # ============================================================================
  # Record declarations
  # ============================================================================

  describe "record declarations" do
    test "simple record" do
      source = """
      record Point
        : x : Float
        , y : Float
      """

      [decl] = parse!(source)
      assert {:record_decl, _, :Point, [], [f1, f2]} = decl
      assert {:field, _, :x, {:var, _, :Float}} = f1
      assert {:field, _, :y, {:var, _, :Float}} = f2
    end
  end

  # ============================================================================
  # Block body desugaring
  # ============================================================================

  describe "block body desugaring" do
    test "multiple expressions desugar to nested lets" do
      [decl] = parse!("def f do\n  foo()\n  bar()\nend")
      assert {:def, _, _, body} = decl
      # foo() desugars to let _ = foo() in bar()
      assert {:let, _, :_, {:app, _, {:var, _, :foo}, []}, {:app, _, {:var, _, :bar}, []}} = body
    end
  end

  # ============================================================================
  # Span correctness
  # ============================================================================

  describe "span correctness" do
    test "variable span covers the identifier" do
      source = "x"
      {:ok, expr} = Parser.parse_expr(source)
      assert {:var, %Pentiment.Span.Byte{start: 0, length: 1}, :x} = expr
    end

    test "integer span covers the digits" do
      source = "42"
      {:ok, expr} = Parser.parse_expr(source)
      assert {:lit, %Pentiment.Span.Byte{start: 0, length: 2}, 42} = expr
    end

    test "binary operation span covers both operands" do
      source = "a + b"
      {:ok, expr} = Parser.parse_expr(source)
      assert {:binop, span, :add, _, _} = expr
      assert span.start == 0
      assert span.start + span.length >= 5
    end

    test "def span covers from def to end" do
      source = "def f do 1 end"
      {:ok, [decl]} = Parser.parse(source)
      assert {:def, span, _, _} = decl
      assert span.start == 0
      assert span.start + span.length >= 14
    end
  end

  # ============================================================================
  # Negative tests
  # ============================================================================

  describe "error handling" do
    test "missing end in def" do
      errors = assert_parse_error("def f do 42")
      assert [{:parse_error, msg, _}] = errors
      assert msg =~ "eof"
    end

    test "missing do in def" do
      errors = assert_parse_error("def f 42 end")
      assert [{:parse_error, msg, _}] = errors
      assert msg =~ "do"
    end

    test "unexpected token in expression" do
      errors = assert_expr_error(")")
      assert [{:parse_error, _, _}] = errors
    end

    test "missing = in type decl" do
      errors = assert_parse_error("type Bool true")
      assert [{:parse_error, _, _}] = errors
    end

    test "missing closing paren" do
      errors = assert_expr_error("f(x")
      assert [{:parse_error, _, _}] = errors
    end

    test "invalid annotation" do
      errors = assert_parse_error("@bogus def f do 42 end")
      assert [{:parse_error, msg, _}] = errors
      assert msg =~ "total"
    end

    test "invalid type name (lowercase)" do
      errors = assert_parse_error("type foo = x")
      assert [{:parse_error, msg, _}] = errors
      assert msg =~ "type name"
    end

    test "invalid constructor in type" do
      errors = assert_parse_error("type Foo = 42")
      assert [{:parse_error, msg, _}] = errors
      assert msg =~ "constructor"
    end

    test "missing kind annotation on type param" do
      errors = assert_parse_error("type Foo(a) = x")
      assert [{:parse_error, msg, _}] = errors
      assert msg =~ "expected :"
    end

    test "invalid record name" do
      errors = assert_parse_error("record foo : x : Int")
      assert [{:parse_error, msg, _}] = errors
      assert msg =~ "record name"
    end

    test "invalid class name" do
      errors = assert_parse_error("class foo do end")
      assert [{:parse_error, msg, _}] = errors
      assert msg =~ "class name"
    end

    test "invalid instance name" do
      errors = assert_parse_error("instance foo do end")
      assert [{:parse_error, msg, _}] = errors
      assert msg =~ "class name"
    end

    test "bad token in param list" do
      errors = assert_parse_error("def f(42) do 1 end")
      assert [{:parse_error, _, _}] = errors
    end

    test "missing field name after dot" do
      errors = assert_expr_error("x.42")
      assert [{:parse_error, msg, _}] = errors
      assert msg =~ "field name"
    end

    test "bad brace expression" do
      errors = assert_expr_error("{42}")
      assert [{:parse_error, _, _}] = errors
    end

    test "negative float in pattern" do
      {:ok, _} =
        Parser.parse("def f(x : Int) : Int do\n  case x do\n    -1 -> 0\n    _ -> x\n  end\nend")
    end

    test "invalid token in pattern" do
      errors = assert_parse_error("def f(x : Int) : Int do case x do + -> 1 end end")
      assert [{:parse_error, _, _}] = errors
    end

    test "extern with non-integer arity" do
      errors = assert_parse_error("@extern Kernel.foo/bar def f do 1 end")
      assert [{:parse_error, msg, _}] = errors
      assert msg =~ "arity"
    end

    test "invalid top-level declaration" do
      errors = assert_parse_error("42")
      assert [{:parse_error, msg, _}] = errors
      assert msg =~ "top-level"
    end

    test "tokenizer error propagated" do
      errors = assert_parse_error("def f do \"unterminated")
      assert [{:parse_error, _, _}] = errors
    end

    test "collects multiple top-level errors" do
      source = """
      def good(x : Int) : Int do x end
      42
      def also_good : Int do 1 end
      99
      """

      errors = assert_parse_error(source)
      assert length(errors) == 2
      assert Enum.all?(errors, &match?({:parse_error, _, _}, &1))
    end

    test "collects errors across different declaration types" do
      source = """
      type 123
      def f : Int do 1 end
      record 456
      """

      errors = assert_parse_error(source)
      assert length(errors) == 2

      msgs = Enum.map(errors, fn {:parse_error, msg, _} -> msg end)
      assert Enum.any?(msgs, &(&1 =~ "type name"))
      assert Enum.any?(msgs, &(&1 =~ "record name"))
    end

    test "good declarations preserved despite errors" do
      # When there are errors, we get {:error, errors} — but the errors
      # should contain all problems found, not just the first.
      source = """
      type bad_name
      def f : Int do 1 end
      class bad_class do end
      """

      errors = assert_parse_error(source)
      assert length(errors) >= 2
    end

    test "errors have correct source spans" do
      source = "42\ndef f : Int do 1 end\n99"
      errors = assert_parse_error(source)
      assert [{:parse_error, _, span1}, {:parse_error, _, span2}] = errors
      # First error at byte 0 (the `42`).
      assert span1.start == 0
      # Second error after the good def.
      assert span2.start > 0
    end

    test "recovery skips to next line for sync" do
      # The bad declaration has tokens after the error on the same line.
      # Recovery should skip past them to the next top-level keyword.
      source = "type 123 + foo\ndef f : Int do 1 end\ntype 456\n"
      errors = assert_parse_error(source)
      assert length(errors) >= 2
    end

    test "method signature error recovery" do
      source = """
      class MyClass(a : Type) do
        42
        good_method : a -> a
      end
      """

      errors = assert_parse_error(source)
      assert length(errors) >= 1
    end

    test "method implementation error recovery" do
      source = """
      instance MyClass(Int) do
        42
        def good_impl : Int do 0 end
      end
      """

      errors = assert_parse_error(source)
      assert length(errors) >= 1
    end

    test "case branch error recovery" do
      # A bad branch in a case should be skipped, and parsing continues.
      # Since case is inside a def, the overall program still fails.
      source = """
      def f(x : Int) : Int do
        case x do
          + -> 1
          0 -> 0
          _ -> x
        end
      end
      """

      errors = assert_parse_error(source)
      assert length(errors) >= 1
    end

    test "mutual block error recovery" do
      source = """
      mutual do
        42
        def f : Int do 1 end
        99
        def g : Int do 2 end
      end
      """

      errors = assert_parse_error(source)
      assert length(errors) >= 2
    end

    test "parse_expr collects errors from recovered branches" do
      # parse_expr on a case expression with a bad branch.
      errors = assert_expr_error("case x do\n  + -> 1\nend")
      assert length(errors) >= 1
    end

    test "sync skips garbage lines between declarations" do
      # After recovery, there are non-keyword tokens before the next declaration.
      source = "type 123\n+ -\ndef f : Int do 1 end\n"
      errors = assert_parse_error(source)
      assert length(errors) >= 1
    end

    test "negative float literal in pattern" do
      {:ok, _} =
        Parser.parse(
          "def f(x : Float) : Float do\n  case x do\n    -1.5 -> 0.0\n    _ -> x\n  end\nend"
        )
    end

    test "bad paren expression with unexpected close" do
      errors = assert_expr_error("(x : Int +)")
      assert [{:parse_error, _, _}] = errors
    end

    test "unclosed paren expression" do
      errors = assert_expr_error("(x + y")
      assert [{:parse_error, _, _}] = errors
    end

    test "bad brace refinement with unexpected token" do
      errors = assert_expr_error("{x : Int +}")
      assert [{:parse_error, _, _}] = errors
    end

    test "invalid token after minus in pattern" do
      errors = assert_parse_error("def f(x : Int) : Int do case x do - + -> 1 end end")
      assert length(errors) >= 1
    end

    test "bad type param list separator" do
      errors = assert_parse_error("type Foo(a : Type +) = x")
      assert [{:parse_error, _, _}] = errors
    end

    test "non-ident type parameter name" do
      errors = assert_parse_error("type Foo(42) = x")
      assert [{:parse_error, _, _}] = errors
    end

    test "extract_var_name for non-var expressions" do
      # Sigma type where the first element is not a simple var.
      expr = parse_expr!("(1 : Int, Bool)")
      assert {:sigma, _, :_, _, _} = expr
    end

    test "erased paren with 0 followed by non-ident" do
      # (0 42 ...) should fall through to normal paren parsing.
      expr = parse_expr!("(0)")
      assert {:lit, _, 0} = expr
    end

    test "bad constructor args separator" do
      errors = assert_parse_error("type Foo = bar(Int +)")
      assert [{:parse_error, _, _}] = errors
    end

    test "record field error" do
      errors = assert_parse_error("record Foo\n  : 42 : Int")
      assert [{:parse_error, _, _}] = errors
    end

    test "empty constructors span uses name span" do
      # A type with a constructor that has no args — the constructor
      # list is non-empty, so this doesn't hit the empty branch.
      # But a type declaration with parse error before constructors tests the path.
      [decl] = parse!("type Unit =\n  | unit")
      {:type_decl, _, :Unit, [], [_ctor]} = decl
    end
  end

  # ============================================================================
  # Integration: full program
  # ============================================================================

  describe "integration" do
    test "full program with multiple declarations" do
      source = """
      import Data.List

      type Option(a : Type) =
        | none
        | some(a)

      def map(f : a -> b, opt : Option(a)) : Option(b) do
        case opt do
          none -> none
          some(x) -> some(f(x))
        end
      end
      """

      {:ok, program} = Parser.parse(source)
      assert [import_decl, type_decl, def_decl] = program
      assert {:import, _, [:Data, :List], nil} = import_decl
      assert {:type_decl, _, :Option, [{:a, {:type_universe, _, nil}}], _} = type_decl
      assert {:def, _, {:sig, _, :map, _, _, _, _}, {:case, _, _, _}} = def_decl
    end
  end

  # ============================================================================
  # Fixture tests: real programs from test/examples/
  # ============================================================================

  @fixtures_dir Path.expand("../examples", __DIR__)

  defp fixture(name) do
    Path.join(@fixtures_dir, name) |> File.read!()
  end

  describe "fixture: nat.hx" do
    test "parses successfully" do
      {:ok, program} = Parser.parse(fixture("nat.hx"))
      assert length(program) == 4
    end

    test "type declaration" do
      {:ok, [type_decl | _]} = Parser.parse(fixture("nat.hx"))
      assert {:type_decl, _, :Nat, [], [zero_ctor, succ_ctor]} = type_decl
      assert {:constructor, _, :zero, [], nil} = zero_ctor
      assert {:constructor, _, :succ, [{:var, _, :Nat}], nil} = succ_ctor
    end

    test "@total annotated defs" do
      {:ok, [_, add, mul, is_zero]} = Parser.parse(fixture("nat.hx"))
      assert {:def, _, {:sig, _, :add, _, _, _, %{total: true}}, _} = add
      assert {:def, _, {:sig, _, :mul, _, _, _, %{total: true}}, _} = mul
      assert {:def, _, {:sig, _, :is_zero, _, _, _, %{total: false}}, _} = is_zero
    end

    test "case with constructor patterns" do
      {:ok, [_, add | _]} = Parser.parse(fixture("nat.hx"))
      {:def, _, _, {:case, _, {:var, _, :n}, branches}} = add
      assert [zero_branch, succ_branch] = branches
      assert {:branch, _, {:pat_var, _, :zero}, {:var, _, :m}} = zero_branch
      assert {:branch, _, {:pat_constructor, _, :succ, [{:pat_var, _, :pred}]}, _} = succ_branch
    end
  end

  describe "fixture: list.hx" do
    test "parses successfully" do
      {:ok, program} = Parser.parse(fixture("list.hx"))
      assert length(program) == 5
    end

    test "parameterized type" do
      {:ok, [type_decl | _]} = Parser.parse(fixture("list.hx"))
      assert {:type_decl, _, :List, [{:a, {:type_universe, _, nil}}], _} = type_decl
    end

    test "lambda in function argument" do
      {:ok, [_, _, _, length_def | _]} = Parser.parse(fixture("list.hx"))
      assert {:def, _, {:sig, _, :length, _, _, _, _}, body} = length_def
      # foldr(xs, 0, fn(...) -> ... end)
      assert {:app, _, {:var, _, :foldr}, [_, {:lit, _, 0}, {:fn, _, _, _}]} = body
    end

    test "let binding in case branch" do
      {:ok, [_, _, foldr | _]} = Parser.parse(fixture("list.hx"))
      {:def, _, _, {:case, _, _, [_, cons_branch]}} = foldr
      {:branch, _, _, body} = cons_branch
      assert {:let, _, :rest, _, _} = body
    end
  end

  describe "fixture: option_result.hx" do
    test "parses successfully" do
      {:ok, program} = Parser.parse(fixture("option_result.hx"))
      # 2 types + 3 defs + 1 class + 2 instances = 8
      assert length(program) == 8
    end

    test "class declaration" do
      {:ok, program} = Parser.parse(fixture("option_result.hx"))
      class_decl = Enum.find(program, &match?({:class_decl, _, _, _, _, _}, &1))
      assert {:class_decl, _, :Functor, [param], [], [method]} = class_decl
      assert {:param, _, {:f, :omega, false}, _} = param
      assert {:method_sig, _, :fmap, _} = method
    end

    test "instance declarations" do
      {:ok, program} = Parser.parse(fixture("option_result.hx"))
      instances = Enum.filter(program, &match?({:instance_decl, _, _, _, _, _}, &1))
      assert length(instances) == 2

      [opt_inst, res_inst] = instances
      assert {:instance_decl, _, :Functor, [{:var, _, :Option}], [], _} = opt_inst

      assert {:instance_decl, _, :Functor, [{:app, _, {:var, _, :Result}, [{:var, _, :e}]}], [],
              _} = res_inst
    end
  end

  describe "fixture: vec.hx" do
    test "parses successfully" do
      {:ok, program} = Parser.parse(fixture("vec.hx"))
      # import + type + 4 defs = 6
      assert length(program) == 6
    end

    test "import" do
      {:ok, [import_decl | _]} = Parser.parse(fixture("vec.hx"))
      assert {:import, _, [:Data, :Nat], nil} = import_decl
    end

    test "kinded type parameters" do
      {:ok, [_, type_decl | _]} = Parser.parse(fixture("vec.hx"))

      assert {:type_decl, _, :Vec, [{:n, {:var, _, :Nat}}, {:a, {:type_universe, _, nil}}], ctors} =
               type_decl

      assert [{:constructor, _, :vnil, [], ret1}, {:constructor, _, :vcons, [_, _], ret2}] = ctors
      assert {:app, _, {:var, _, :Vec}, [{:var, _, :zero}, {:var, _, :a}]} = ret1
      assert {:app, _, {:var, _, :Vec}, [{:app, _, {:var, _, :succ}, _}, {:var, _, :a}]} = ret2
    end

    test "implicit and erased params" do
      {:ok, program} = Parser.parse(fixture("vec.hx"))

      vtail =
        Enum.find(program, fn
          {:def, _, {:sig, _, :vtail, _, _, _, _}, _} -> true
          _ -> false
        end)

      assert {:def, _, {:sig, _, :vtail, _, params, _, _}, _} = vtail
      assert [{:param, _, {:a, :zero, true}, _}, {:param, _, {:n, :zero, false}, _} | _] = params
    end
  end

  describe "fixture: mutual_record.hx" do
    test "parses successfully" do
      {:ok, program} = Parser.parse(fixture("mutual_record.hx"))
      # 2 records + mutual + 3 defs = 6
      assert length(program) == 6
    end

    test "record declarations" do
      {:ok, [point, config | _]} = Parser.parse(fixture("mutual_record.hx"))
      assert {:record_decl, _, :Point, [], [f1, f2]} = point
      assert {:field, _, :x, {:var, _, :Int}} = f1
      assert {:field, _, :y, {:var, _, :Int}} = f2

      assert {:record_decl, _, :Config, [], [_, _]} = config
    end

    test "mutual block" do
      {:ok, [_, _, mutual | _]} = Parser.parse(fixture("mutual_record.hx"))
      assert {:mutual, _, [even_def, odd_def]} = mutual
      assert {:def, _, {:sig, _, :is_even, _, _, _, _}, _} = even_def
      assert {:def, _, {:sig, _, :is_odd, _, _, _, _}, _} = odd_def
    end

    test "dot access" do
      {:ok, program} = Parser.parse(fixture("mutual_record.hx"))

      manhattan =
        Enum.find(program, fn
          {:def, _, {:sig, _, :manhattan, _, _, _, _}, _} -> true
          _ -> false
        end)

      assert {:def, _, _, {:binop, _, :add, {:dot, _, _, :x}, {:dot, _, _, :y}}} = manhattan
    end

    test "@private annotation" do
      {:ok, program} = Parser.parse(fixture("mutual_record.hx"))

      above =
        Enum.find(program, fn
          {:def, _, {:sig, _, :above_threshold, _, _, _, _}, _} -> true
          _ -> false
        end)

      assert {:def, _, {:sig, _, :above_threshold, _, _, _, %{private: true}}, _} = above
    end
  end

  describe "fixture: refinement.hx" do
    test "parses successfully" do
      {:ok, program} = Parser.parse(fixture("refinement.hx"))
      # @implicit + 5 defs = 6
      assert length(program) == 6
    end

    test "implicit declaration" do
      {:ok, [var_decl | _]} = Parser.parse(fixture("refinement.hx"))
      assert {:implicit_decl, _, [param]} = var_decl
      assert {:param, _, {:a, :zero, true}, {:type_universe, _, nil}} = param
    end

    test "@extern annotation" do
      {:ok, [_, extern_def | _]} = Parser.parse(fixture("refinement.hx"))

      assert {:def, _, {:sig, _, :safe_div, _, _, _, %{extern: {Kernel, :div, 2}}}, _} =
               extern_def
    end

    test "refinement type in param" do
      {:ok, [_, extern_def | _]} = Parser.parse(fixture("refinement.hx"))
      {:def, _, {:sig, _, _, _, [_, y_param], _, _}, _} = extern_def
      assert {:param, _, {:y, :omega, false}, {:refinement, _, :n, {:var, _, :Int}, _}} = y_param
    end

    test "refinement type in return" do
      {:ok, program} = Parser.parse(fixture("refinement.hx"))

      clamp =
        Enum.find(program, fn
          {:def, _, {:sig, _, :clamp, _, _, _, _}, _} -> true
          _ -> false
        end)

      {:def, _, {:sig, _, :clamp, _, _, ret_type, _}, _} = clamp
      assert {:refinement, _, :x, {:var, _, :Int}, _} = ret_type
    end

    test "unary operators" do
      {:ok, program} = Parser.parse(fixture("refinement.hx"))

      neg_bool =
        Enum.find(program, fn
          {:def, _, {:sig, _, :negate_bool, _, _, _, _}, _} -> true
          _ -> false
        end)

      assert {:def, _, _, {:unaryop, _, :not, {:var, _, :b}}} = neg_bool

      neg_int =
        Enum.find(program, fn
          {:def, _, {:sig, _, :negate_int, _, _, _, _}, _} -> true
          _ -> false
        end)

      assert {:def, _, _, {:unaryop, _, :neg, {:var, _, :n}}} = neg_int
    end

    test "dependent arrow as return type" do
      {:ok, program} = Parser.parse(fixture("refinement.hx"))

      dep =
        Enum.find(program, fn
          {:def, _, {:sig, _, :dependent_arrow, _, _, _, _}, _} -> true
          _ -> false
        end)

      {:def, _, {:sig, _, _, _, [], ret, _}, _} = dep
      assert {:pi, _, {:n, :omega, false}, {:var, _, :Int}, {:refinement, _, :m, _, _}} = ret
    end
  end

  describe "fixture: pipeline.hx" do
    test "parses successfully" do
      {:ok, program} = Parser.parse(fixture("pipeline.hx"))
      # 2 imports + type + 6 defs = 9
      assert length(program) == 9
    end

    test "import with open: true" do
      {:ok, [imp1 | _]} = Parser.parse(fixture("pipeline.hx"))
      assert {:import, _, [:Data, :List], true} = imp1
    end

    test "import with open: [names]" do
      {:ok, [_, imp2 | _]} = Parser.parse(fixture("pipeline.hx"))
      assert {:import, _, [:Data, :Option], [:some, :none]} = imp2
    end

    test "pipe operator" do
      {:ok, program} = Parser.parse(fixture("pipeline.hx"))

      apply_twice =
        Enum.find(program, fn
          {:def, _, {:sig, _, :apply_twice, _, _, _, _}, _} -> true
          _ -> false
        end)

      assert {:def, _, _, {:pipe, _, {:app, _, {:var, _, :f}, [{:var, _, :x}]}, {:var, _, :f}}} =
               apply_twice
    end

    test "let chains" do
      {:ok, program} = Parser.parse(fixture("pipeline.hx"))

      pipeline =
        Enum.find(program, fn
          {:def, _, {:sig, _, :pipeline_example, _, _, _, _}, _} -> true
          _ -> false
        end)

      {:def, _, _, body} = pipeline
      assert {:let, _, :result, _, {:let, _, :total, _, {:var, _, :total}}} = body
    end
  end

  # ============================================================================
  # All fixtures parse without error
  # ============================================================================

  describe "all fixtures" do
    for file <- Path.wildcard(Path.expand("../examples/*.hx", __DIR__)) do
      name = Path.basename(file)

      test "#{name} parses without error" do
        source = File.read!(unquote(file))
        assert {:ok, _program} = Parser.parse(source)
      end
    end
  end

  # ============================================================================
  # Property tests
  # ============================================================================

  describe "properties" do
    property "no crash: random printable ASCII never crashes the parser" do
      check all(
              source <- string(:printable, min_length: 0, max_length: 200),
              max_runs: 200
            ) do
        # Parser should return {:ok, _} or {:error, _}, never crash.
        result = Parser.parse(source)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end

    property "span containment: all fixture AST nodes have valid spans" do
      fixtures = Path.wildcard(Path.expand("../examples/*.hx", __DIR__))

      for file <- fixtures do
        source = File.read!(file)

        case Parser.parse(source) do
          {:ok, program} ->
            source_len = byte_size(source)

            Enum.each(program, fn node ->
              span = AST.span(node)
              assert %Pentiment.Span.Byte{start: s, length: l} = span
              assert s >= 0, "span start must be non-negative"
              assert l >= 0, "span length must be non-negative"
              assert s + l <= source_len, "span must not exceed source length"
            end)

          _ ->
            :ok
        end
      end
    end

    property "parse_expr never crashes on random expressions" do
      check all(
              source <- string(:printable, min_length: 1, max_length: 100),
              max_runs: 200
            ) do
        result = Parser.parse_expr(source)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end
  end
end
