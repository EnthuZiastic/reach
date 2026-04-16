defmodule Reach.IR.Helpers do
  @moduledoc false

  alias Reach.IR.Node

  def mark_as_definitions(%Node{type: :var, meta: meta} = node) do
    %{node | meta: Map.put(meta, :binding_role, :definition)}
  end

  def mark_as_definitions(%Node{children: children} = node) do
    %{node | children: Enum.map(children, &mark_as_definitions/1)}
  end

  def mark_as_definitions(other), do: other

  def param_var_name(%Node{type: :var, meta: %{name: name}}), do: name
  def param_var_name(_), do: nil

  def var_used_in_subtree?(%Node{type: :var, meta: %{name: name}}, target), do: name == target

  def var_used_in_subtree?(%Node{children: children}, target) do
    Enum.any?(children, &var_used_in_subtree?(&1, target))
  end

  def language_from_path(path) do
    case Path.extname(path) do
      ext when ext in [".erl", ".hrl"] -> :erlang
      _ -> :elixir
    end
  end

  def module_from_path(path) do
    path
    |> Path.rootname()
    |> Path.split()
    |> Enum.drop_while(&(&1 != "lib" and &1 != "src"))
    |> Enum.drop(1)
    |> Enum.map_join(".", &Macro.camelize/1)
    |> then(fn
      "" -> nil
      name -> Module.concat([name])
    end)
  end
end
