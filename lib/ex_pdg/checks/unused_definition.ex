defmodule ExPDG.Checks.UnusedDefinition do
  @moduledoc """
  Detects variables that are defined but never used.
  """

  @behaviour ExPDG.Check

  @impl true
  def meta, do: %{severity: :warning, category: :code_quality}

  @impl true
  def run(graph, _opts) do
    import ExPDG.Query

    all = nodes(graph)

    # Find all match nodes (definitions)
    definitions =
      Enum.filter(all, fn node ->
        node.type == :match
      end)

    for match_node <- definitions,
        [var_node | _] = match_node.children,
        var_node.type == :var,
        var_name = var_node.meta[:name],
        var_name != :_,
        not String.starts_with?(Atom.to_string(var_name), "_"),
        not has_dependents?(graph, match_node.id) do
      %ExPDG.Diagnostic{
        check: :unused_definition,
        severity: :warning,
        category: :code_quality,
        message: "Variable `#{var_name}` is defined but never used",
        location: match_node.source_span,
        node_id: match_node.id
      }
    end
  end
end
