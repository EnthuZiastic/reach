defmodule ExPDG.Checks.DeepDependencyChain do
  @moduledoc """
  Detects expressions with excessively deep dependency chains.

  When an expression's backward slice exceeds a threshold, it indicates
  high coupling — the expression depends on too many other expressions.
  """

  @behaviour ExPDG.Check

  @default_threshold 30

  @impl true
  def meta, do: %{severity: :info, category: :complexity}

  @impl true
  def run(graph, opts) do
    import ExPDG.Query

    threshold = Keyword.get(opts, :threshold, @default_threshold)

    for node <- nodes(graph),
        node.type in [:call, :match, :binary_op],
        slice = ExPDG.Graph.backward_slice(graph, node.id),
        length(slice) > threshold do
      %ExPDG.Diagnostic{
        check: :deep_dependency_chain,
        severity: :info,
        category: :complexity,
        message:
          "Expression depends on #{length(slice)} other expressions (threshold: #{threshold})",
        location: node.source_span,
        node_id: node.id,
        meta: %{slice_size: length(slice), threshold: threshold}
      }
    end
  end
end
