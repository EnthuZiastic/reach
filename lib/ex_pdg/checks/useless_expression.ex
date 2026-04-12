defmodule ExPDG.Checks.UselessExpression do
  @moduledoc """
  Detects pure expressions whose result is never used.

  A "useless expression" is one that:
  1. Is pure (no side effects)
  2. Its result is not used by any other expression (no data dependents)
  3. Is not the return value of its function
  """

  @behaviour ExPDG.Check

  @impl true
  def meta, do: %{severity: :warning, category: :code_quality}

  @impl true
  def run(graph, _opts) do
    import ExPDG.Query

    for node <- nodes(graph),
        node.type in [:call, :binary_op, :unary_op, :literal, :var],
        pure?(node),
        not has_dependents?(graph, node.id),
        not returns?(graph, node.id) do
      %ExPDG.Diagnostic{
        check: :useless_expression,
        severity: :warning,
        category: :code_quality,
        message: "Expression has no effect — result is unused and it's pure",
        location: node.source_span,
        node_id: node.id
      }
    end
  end
end
