defmodule Haruspex.TypeClass.Bridge do
  @moduledoc """
  Protocol bridge for single-parameter type classes.

  When a class is annotated with `@protocol`, generates:
  1. A `defprotocol` with the same method signatures.
  2. A `defimpl` for each registered instance.

  The bridge is one-directional: Haruspex callers use dictionary passing
  internally; the protocol exists for Elixir callers.
  """

  @type_mapping %{
    Int: Integer,
    Float: Float,
    String: BitString,
    Bool: Atom,
    Atom: Atom
  }

  @doc """
  Compile protocol bridges for all protocol-annotated classes.

  Returns a list of quoted `defprotocol` + `defimpl` module definitions.
  Currently returns empty since `@protocol` annotation is not yet implemented
  in the parser. This provides the hook for future protocol generation.
  """
  @spec compile_bridges(map(), map(), map(), atom()) :: [Macro.t()]
  def compile_bridges(classes, instances, _records, module_name) do
    # Only generate bridges for @protocol-annotated single-parameter classes.
    classes
    |> Enum.filter(fn {_name, decl} ->
      Map.get(decl, :protocol?, false) and length(decl.params) == 1
    end)
    |> Enum.flat_map(fn {class_name, class_decl} ->
      protocol_ast = compile_protocol(class_decl, module_name)

      impl_asts =
        instances
        |> Map.get(class_name, [])
        |> Enum.reject(fn entry -> entry.module == :prelude end)
        |> Enum.map(&compile_impl(&1, class_decl, module_name))
        |> Enum.reject(&is_nil/1)

      [protocol_ast | impl_asts]
    end)
  end

  @doc """
  Generate a protocol definition for a single-parameter class.

  Takes a class declaration and the parent module name, returns a quoted
  `defprotocol` definition.
  """
  @spec compile_protocol(map(), atom()) :: Macro.t()
  def compile_protocol(class_decl, module_name) do
    protocol_name = Module.concat(module_name, class_decl.name)

    method_defs =
      Enum.map(class_decl.methods, fn {method_name, type} ->
        # The first argument is the dispatched-on value (the class type param).
        # Additional args are generated as positional params.
        arity = method_arity(type)
        params = Enum.map(0..arity, &Macro.var(:"arg#{&1}", __MODULE__))

        quote do
          def unquote(method_name)(unquote_splicing(params))
        end
      end)

    quote do
      defprotocol unquote(protocol_name) do
        (unquote_splicing(method_defs))
      end
    end
  end

  @doc """
  Generate a protocol implementation for an instance of a protocol-annotated class.

  Maps the Haruspex type to an Elixir protocol dispatch type.
  """
  @spec compile_impl(map(), map(), atom()) :: Macro.t() | nil
  def compile_impl(instance_entry, class_decl, module_name) do
    protocol_name = Module.concat(module_name, class_decl.name)

    case instance_to_elixir_type(instance_entry) do
      {:ok, elixir_type} ->
        method_impls =
          Enum.map(instance_entry.methods, fn {method_name, body} ->
            arity = method_arity_from_body(body)
            params = Enum.map(0..arity, &Macro.var(:"arg#{&1}", __MODULE__))
            compiled_body = Haruspex.Codegen.compile_expr(body)

            quote do
              def unquote(method_name)(unquote_splicing(params)) do
                unquote(compiled_body).(unquote_splicing(params))
              end
            end
          end)

        quote do
          defimpl unquote(protocol_name), for: unquote(elixir_type) do
            (unquote_splicing(method_impls))
          end
        end

      :error ->
        nil
    end
  end

  @doc """
  Map a Haruspex type to an Elixir protocol dispatch type.
  """
  @spec map_type(atom()) :: atom() | nil
  def map_type(haruspex_type) do
    Map.get(@type_mapping, haruspex_type)
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp instance_to_elixir_type(%{head: [{:builtin, name}]}) do
    case Map.fetch(@type_mapping, name) do
      {:ok, elixir_type} -> {:ok, elixir_type}
      :error -> :error
    end
  end

  defp instance_to_elixir_type(_), do: :error

  # Count the arity of a method type (number of omega pi args).
  defp method_arity({:pi, :omega, _dom, cod}), do: 1 + method_arity(cod)
  defp method_arity(_), do: 0

  # Count arity from a method body (number of nested lambdas).
  defp method_arity_from_body({:lam, :omega, body}), do: 1 + method_arity_from_body(body)
  defp method_arity_from_body(_), do: 0
end
