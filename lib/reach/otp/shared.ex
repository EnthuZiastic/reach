defmodule Reach.OTP.Shared do
  @moduledoc false

  alias Reach.IR.Node

  @doc """
  Resolves a target IR node to a module atom.

  Handles `:literal` atoms and `:__aliases__` call chains; returns `nil`
  when the target is not a statically resolvable module reference.
  """
  @spec resolve_target(Node.t()) :: module() | nil
  def resolve_target(%Node{type: :literal, meta: %{value: mod}}) when is_atom(mod), do: mod

  def resolve_target(%Node{type: :call, meta: %{function: :__aliases__}, children: parts}) do
    atoms =
      Enum.map(parts, fn
        %{type: :literal, meta: %{value: v}} when is_atom(v) -> v
        _ -> nil
      end)

    if Enum.all?(atoms, & &1), do: Module.concat(atoms)
  end

  def resolve_target(_), do: nil

  @doc "Format a node's source span into a human-readable location string."
  @spec location(map()) :: String.t()
  def location(%{source_span: %{file: file, start_line: line}}), do: "#{file}:#{line}"
  def location(%{source_span: %{start_line: line}}), do: "line #{line}"
  def location(_), do: "unknown"
end
