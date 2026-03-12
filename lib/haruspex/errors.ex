defmodule Haruspex.Errors do
  @moduledoc """
  Error rendering for type checker and elaboration errors.

  Converts internal error tuples into `Pentiment.Report` diagnostics with
  pretty-printed types, source spans, and actionable messages.
  """

  alias Haruspex.Pretty
  alias Pentiment.Label
  alias Pentiment.Report

  # ============================================================================
  # Types
  # ============================================================================

  @type render_opts :: %{
          names: [atom()],
          level: non_neg_integer(),
          span: Pentiment.Span.Byte.t() | nil,
          source: String.t() | nil
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Render a type error into a `Pentiment.Report`.

  The `opts` map provides context for pretty-printing:
  - `:names` — name list for de Bruijn level→name recovery
  - `:level` — current context depth
  - `:span` — primary source span (may be nil)
  - `:source` — source file identifier (may be nil)
  """
  @spec render(term(), render_opts()) :: Report.t()

  # Type mismatch.
  def render({:type_mismatch, expected, got}, opts) do
    exp_str = pretty_type(expected, opts)
    got_str = pretty_type(got, opts)

    report =
      Report.error("type mismatch")
      |> Report.with_code("E001")
      |> Report.with_note("expected: #{exp_str}")
      |> Report.with_note("     got: #{got_str}")

    report = maybe_add_label(report, opts[:span], "expected `#{exp_str}`, got `#{got_str}`")
    maybe_add_source(report, opts[:source])
  end

  # Not a function.
  def render({:not_a_function, type}, opts) do
    type_str = pretty_type(type, opts)

    report =
      Report.error("expected a function type")
      |> Report.with_code("E002")
      |> Report.with_note("got: #{type_str}")
      |> Report.with_help("only function types can be applied to arguments")

    report = maybe_add_label(report, opts[:span], "has type `#{type_str}`, not a function")
    maybe_add_source(report, opts[:source])
  end

  # Not a pair.
  def render({:not_a_pair, type}, opts) do
    type_str = pretty_type(type, opts)

    report =
      Report.error("expected a pair type")
      |> Report.with_code("E003")
      |> Report.with_note("got: #{type_str}")
      |> Report.with_help("projections (.1, .2) require a sigma/pair type")

    report = maybe_add_label(report, opts[:span], "has type `#{type_str}`, not a pair")
    maybe_add_source(report, opts[:source])
  end

  # Not a type.
  def render({:not_a_type, type}, opts) do
    type_str = pretty_type(type, opts)

    report =
      Report.error("expected a type")
      |> Report.with_code("E004")
      |> Report.with_note("got: #{type_str}")
      |> Report.with_help("this position requires a type (something of type Type)")

    report = maybe_add_label(report, opts[:span], "has type `#{type_str}`, not Type")
    maybe_add_source(report, opts[:source])
  end

  # Unsolved implicit meta.
  def render({:unsolved_meta, id, type}, opts) do
    type_str = pretty_type(type, opts)

    report =
      Report.error("could not infer implicit argument")
      |> Report.with_code("E005")
      |> Report.with_note("unsolved metavariable ?#{id} of type: #{type_str}")
      |> Report.with_help("try providing the implicit argument explicitly with {}")

    report =
      maybe_add_label(
        report,
        opts[:span],
        "implicit argument of type `#{type_str}` could not be inferred"
      )

    maybe_add_source(report, opts[:source])
  end

  # Multiplicity violation.
  def render({:multiplicity_violation, name, mult, usage}, opts) do
    mult_str = if mult == :zero, do: "erased (0-use)", else: "unrestricted"

    report =
      Report.error("variable `#{name}` is #{mult_str} but was used #{usage} time(s)")
      |> Report.with_code("E006")
      |> Report.with_note("declared with multiplicity: #{mult}")
      |> Report.with_note("actual usage count: #{usage}")

    report =
      if mult == :zero do
        Report.with_help(report, "erased variables cannot be used in computational positions")
      else
        report
      end

    report = maybe_add_label(report, opts[:span], "`#{name}` used here but is erased")
    maybe_add_source(report, opts[:source])
  end

  # Universe error.
  def render({:universe_error, msg}, opts) do
    report =
      Report.error("universe error: #{msg}")
      |> Report.with_code("E007")

    report = maybe_add_label(report, opts[:span], msg)
    maybe_add_source(report, opts[:source])
  end

  # Multiplicity mismatch (from unify).
  def render({:multiplicity_mismatch, expected, got}, opts) do
    report =
      Report.error("multiplicity mismatch")
      |> Report.with_code("E008")
      |> Report.with_note("expected: #{expected}")
      |> Report.with_note("     got: #{got}")

    report = maybe_add_label(report, opts[:span], "mismatched multiplicities")
    maybe_add_source(report, opts[:source])
  end

  # ---- Elaboration errors ----

  # Unbound variable.
  def render({:unbound_variable, name, span}, _opts) do
    Report.error("unbound variable `#{name}`")
    |> Report.with_code("E010")
    |> Report.with_label(Label.primary(span, "`#{name}` is not in scope"))
    |> Report.with_help("check spelling or add a binding for `#{name}`")
  end

  # Unsupported expression.
  def render({:unsupported, kind, span}, _opts) do
    Report.error("unsupported expression: #{kind}")
    |> Report.with_code("E011")
    |> Report.with_label(Label.primary(span, "not yet supported"))
  end

  # Missing return type.
  def render({:missing_return_type, name, span}, _opts) do
    Report.error("missing return type for `#{name}`")
    |> Report.with_code("E012")
    |> Report.with_label(Label.primary(span, "needs a return type annotation"))
    |> Report.with_help("add `: ReturnType` after the parameter list")
  end

  # ============================================================================
  # Hole report rendering
  # ============================================================================

  @doc """
  Render a hole report (informational, not an error).
  """
  @spec render_hole(Haruspex.Check.hole_report()) :: Report.t()
  def render_hole(hole_report) do
    bindings_str =
      hole_report.bindings
      |> Enum.map(fn {name, type_str} -> "  #{name} : #{type_str}" end)
      |> Enum.join("\n")

    report =
      Report.info("found hole")
      |> Report.with_code("I001")
      |> Report.with_note("expected type: #{hole_report.expected_type}")

    report =
      if bindings_str != "" do
        Report.with_note(report, "available bindings:\n#{bindings_str}")
      else
        report
      end

    if hole_report.span do
      Report.with_label(report, Label.primary(hole_report.span, "hole here"))
    else
      report
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp pretty_type(type, opts) when is_tuple(type) do
    names = Map.get(opts, :names, [])
    level = Map.get(opts, :level, 0)
    Pretty.pretty(type, names, level)
  end

  defp pretty_type(other, _opts), do: inspect(other)

  defp maybe_add_label(report, nil, _msg), do: report
  defp maybe_add_label(report, span, msg), do: Report.with_label(report, Label.primary(span, msg))

  defp maybe_add_source(report, nil), do: report
  defp maybe_add_source(report, source), do: Report.with_source(report, source)
end
