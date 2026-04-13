defmodule Reach.HigherOrder do
  @moduledoc false

  alias Reach.IR.Node

  @catalog (for mod <- Reach.Effects.pure_modules(), reduce: %{} do
              acc ->
                summaries = Reach.Project.summarize_dependency(mod)

                entries =
                  for {{^mod, name, arity}, flows} <- summaries,
                      flowing = for({idx, true} <- flows, do: idx),
                      flowing != [],
                      into: %{} do
                    {{mod, name, arity}, flowing}
                  end

                Map.merge(acc, entries)
            end)

  @doc """
  Adds synthetic data-flow edges for known higher-order function calls.

  Only adds edges for pure calls — impure functions (like `Enum.each`)
  use params for side effects, not return value production.
  """
  @spec add_edges(Graph.t(), [Node.t()]) :: Graph.t()
  def add_edges(graph, all_nodes) do
    all_nodes
    |> Enum.filter(&(&1.type == :call))
    |> Enum.reduce(graph, fn call, g -> maybe_add_flow(g, call) end)
  end

  defp maybe_add_flow(graph, call) do
    key = {call.meta[:module], call.meta[:function], call.meta[:arity] || 0}

    with flowing when flowing != nil <- Map.get(@catalog, key),
         true <-
           Reach.Effects.pure_call?(call.meta[:module], call.meta[:function], call.meta[:arity]) do
      add_synthetic_flows(graph, call, flowing)
    else
      _ -> graph
    end
  end

  defp add_synthetic_flows(graph, call_node, flowing_params) do
    args = call_node.children

    Enum.reduce(flowing_params, graph, fn idx, g ->
      case Enum.at(args, idx) do
        nil ->
          g

        arg ->
          Graph.add_edge(
            Graph.add_vertex(Graph.add_vertex(g, arg.id), call_node.id),
            arg.id,
            call_node.id,
            label: :higher_order
          )
      end
    end)
  end
end
