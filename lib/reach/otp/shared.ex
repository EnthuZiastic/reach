defmodule Reach.OTP.Shared do
  @moduledoc false

  alias Reach.IR.Node

  @doc """
  Resolves a target IR node to a statically known atom.

  Handles `:literal` atoms (which may be any atom, not necessarily a module)
  and `:__aliases__` call chains (which always concat to a module). Returns
  `nil` when the target is not statically resolvable. Callers that need a
  module must validate the result against their context (the `:literal`
  branch will happily return `:ok`, `:error`, etc.).
  """
  @spec resolve_target(Node.t()) :: atom() | nil
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
