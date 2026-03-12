defmodule Haruspex.ErrorsTest do
  use ExUnit.Case, async: true

  alias Haruspex.Errors
  alias Pentiment.Span.Byte

  defp default_opts do
    %{names: [], level: 0, span: nil, source: nil}
  end

  defp make_span do
    Byte.new(10, 5)
  end

  # ============================================================================
  # Type errors
  # ============================================================================

  describe "type_mismatch" do
    test "renders with expected and got types" do
      error = {:type_mismatch, {:vbuiltin, :Int}, {:vbuiltin, :Float}}
      report = Errors.render(error, default_opts())

      assert report.message == "type mismatch"
      assert report.code == "E001"
      assert report.severity == :error
      assert Enum.any?(report.notes, &String.contains?(&1, "expected: Int"))
      assert Enum.any?(report.notes, &String.contains?(&1, "got: Float"))
    end

    test "renders with span" do
      span = make_span()
      opts = %{default_opts() | span: span}
      error = {:type_mismatch, {:vbuiltin, :Int}, {:vbuiltin, :Float}}
      report = Errors.render(error, opts)

      assert length(report.labels) == 1
      [label] = report.labels
      assert label.span == span
      assert String.contains?(label.message, "expected `Int`")
      assert String.contains?(label.message, "got `Float`")
    end

    test "renders without span" do
      error = {:type_mismatch, {:vbuiltin, :Int}, {:vbuiltin, :Float}}
      report = Errors.render(error, default_opts())

      assert report.labels == []
    end

    test "renders with source" do
      opts = %{default_opts() | source: "test.hx"}
      error = {:type_mismatch, {:vbuiltin, :Int}, {:vbuiltin, :Float}}
      report = Errors.render(error, opts)

      assert report.source == "test.hx"
    end

    test "renders without source" do
      error = {:type_mismatch, {:vbuiltin, :Int}, {:vbuiltin, :Float}}
      report = Errors.render(error, default_opts())

      assert report.source == nil
    end

    test "pretty-prints types using names and level context" do
      # A neutral variable at level 0 with name :a should render as "a".
      opts = %{names: [:a], level: 1, span: nil, source: nil}
      var_type = {:vneutral, {:vtype, {:llit, 0}}, {:nvar, 0}}
      error = {:type_mismatch, {:vbuiltin, :Int}, var_type}
      report = Errors.render(error, opts)

      assert Enum.any?(report.notes, &String.contains?(&1, "got: a"))
    end
  end

  describe "not_a_function" do
    test "renders correctly" do
      error = {:not_a_function, {:vbuiltin, :Int}}
      report = Errors.render(error, default_opts())

      assert report.message == "expected a function type"
      assert report.code == "E002"
      assert report.severity == :error
      assert Enum.any?(report.notes, &String.contains?(&1, "got: Int"))
      assert length(report.help) == 1
    end
  end

  describe "not_a_pair" do
    test "renders correctly" do
      error = {:not_a_pair, {:vbuiltin, :Int}}
      report = Errors.render(error, default_opts())

      assert report.message == "expected a pair type"
      assert report.code == "E003"
      assert report.severity == :error
      assert Enum.any?(report.notes, &String.contains?(&1, "got: Int"))
      assert Enum.any?(report.help, &String.contains?(&1, "sigma/pair"))
    end
  end

  describe "not_a_type" do
    test "renders correctly" do
      error = {:not_a_type, {:vbuiltin, :Int}}
      report = Errors.render(error, default_opts())

      assert report.message == "expected a type"
      assert report.code == "E004"
      assert report.severity == :error
      assert Enum.any?(report.notes, &String.contains?(&1, "got: Int"))
    end
  end

  describe "unsolved_meta" do
    test "renders correctly" do
      error = {:unsolved_meta, 0, {:vtype, {:llit, 0}}}
      report = Errors.render(error, default_opts())

      assert report.message == "could not infer implicit argument"
      assert report.code == "E005"
      assert report.severity == :error
      assert Enum.any?(report.notes, &String.contains?(&1, "?0"))
      assert Enum.any?(report.notes, &String.contains?(&1, "Type"))
      assert length(report.help) == 1
    end
  end

  describe "multiplicity_violation" do
    test "renders erased variable" do
      error = {:multiplicity_violation, :x, :zero, 1}
      report = Errors.render(error, default_opts())

      assert String.contains?(report.message, "erased")
      assert report.code == "E006"
      assert report.severity == :error
      assert Enum.any?(report.notes, &String.contains?(&1, "multiplicity: zero"))
      assert Enum.any?(report.notes, &String.contains?(&1, "usage count: 1"))
      assert length(report.help) == 1
    end

    test "renders unrestricted variable" do
      error = {:multiplicity_violation, :y, :omega, 0}
      report = Errors.render(error, default_opts())

      assert String.contains?(report.message, "unrestricted")
      # No help message for non-erased violations.
      assert report.help == []
    end
  end

  describe "universe_error" do
    test "renders correctly" do
      error = {:universe_error, "levels unsatisfiable"}
      report = Errors.render(error, default_opts())

      assert String.contains?(report.message, "universe error")
      assert String.contains?(report.message, "levels unsatisfiable")
      assert report.code == "E007"
      assert report.severity == :error
    end
  end

  describe "multiplicity_mismatch" do
    test "renders correctly" do
      error = {:multiplicity_mismatch, :omega, :zero}
      report = Errors.render(error, default_opts())

      assert report.message == "multiplicity mismatch"
      assert report.code == "E008"
      assert report.severity == :error
      assert Enum.any?(report.notes, &String.contains?(&1, "expected: omega"))
      assert Enum.any?(report.notes, &String.contains?(&1, "got: zero"))
    end
  end

  # ============================================================================
  # Elaboration errors
  # ============================================================================

  describe "unbound_variable" do
    test "renders with span and help" do
      span = make_span()
      error = {:unbound_variable, :foo, span}
      report = Errors.render(error, default_opts())

      assert report.message == "unbound variable `foo`"
      assert report.code == "E010"
      assert report.severity == :error
      assert length(report.labels) == 1
      [label] = report.labels
      assert label.span == span
      assert String.contains?(label.message, "not in scope")
      assert length(report.help) == 1
    end
  end

  describe "unsupported" do
    test "renders with span" do
      span = make_span()
      error = {:unsupported, :if, span}
      report = Errors.render(error, default_opts())

      assert report.message == "unsupported expression: if"
      assert report.code == "E011"
      assert report.severity == :error
      assert length(report.labels) == 1
    end
  end

  describe "missing_return_type" do
    test "renders with span and help" do
      span = make_span()
      error = {:missing_return_type, :f, span}
      report = Errors.render(error, default_opts())

      assert report.message == "missing return type for `f`"
      assert report.code == "E012"
      assert report.severity == :error
      assert length(report.labels) == 1
      assert length(report.help) == 1
      assert Enum.any?(report.help, &String.contains?(&1, "ReturnType"))
    end
  end

  # ============================================================================
  # Span and source handling
  # ============================================================================

  describe "span handling" do
    test "label is attached when span is provided" do
      span = make_span()
      opts = %{default_opts() | span: span}
      error = {:not_a_function, {:vbuiltin, :Int}}
      report = Errors.render(error, opts)

      assert length(report.labels) == 1
      [label] = report.labels
      assert label.span == span
    end

    test "no label when span is nil" do
      error = {:not_a_function, {:vbuiltin, :Int}}
      report = Errors.render(error, default_opts())

      assert report.labels == []
    end
  end

  describe "source handling" do
    test "source is set when provided" do
      opts = %{default_opts() | source: "main.hx"}
      error = {:universe_error, "bad"}
      report = Errors.render(error, opts)

      assert report.source == "main.hx"
    end

    test "source is nil when not provided" do
      error = {:universe_error, "bad"}
      report = Errors.render(error, default_opts())

      assert report.source == nil
    end
  end

  # ============================================================================
  # Hole report rendering
  # ============================================================================

  describe "render_hole" do
    test "renders hole with bindings" do
      hole = %{
        span: make_span(),
        expected_type: "Int",
        bindings: [{:x, "Int"}, {:y, "Float"}]
      }

      report = Errors.render_hole(hole)

      assert report.message == "found hole"
      assert report.code == "I001"
      assert report.severity == :info
      assert Enum.any?(report.notes, &String.contains?(&1, "expected type: Int"))
      assert Enum.any?(report.notes, &String.contains?(&1, "x : Int"))
      assert Enum.any?(report.notes, &String.contains?(&1, "y : Float"))
      assert length(report.labels) == 1
    end

    test "renders hole without bindings" do
      hole = %{
        span: nil,
        expected_type: "Type",
        bindings: []
      }

      report = Errors.render_hole(hole)

      assert report.message == "found hole"
      assert report.severity == :info
      # Only the "expected type" note, no bindings note.
      assert length(report.notes) == 1
      assert report.labels == []
    end

    test "renders hole with span" do
      span = make_span()

      hole = %{
        span: span,
        expected_type: "Int",
        bindings: []
      }

      report = Errors.render_hole(hole)

      assert length(report.labels) == 1
      [label] = report.labels
      assert label.span == span
      assert label.message == "hole here"
    end

    test "renders hole without span" do
      hole = %{
        span: nil,
        expected_type: "Int",
        bindings: []
      }

      report = Errors.render_hole(hole)
      assert report.labels == []
    end
  end
end
