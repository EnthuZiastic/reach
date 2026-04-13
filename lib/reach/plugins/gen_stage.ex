defmodule Reach.Plugins.GenStage do
  @moduledoc false
  @behaviour Reach.Plugin

  @impl true
  def analyze(all_nodes, _opts) do
    demand_to_events_edges(all_nodes) ++
      broadway_message_edges(all_nodes)
  end

  # handle_demand return value → handle_events first param
  defp demand_to_events_edges(all_nodes) do
    demand_fns =
      Enum.filter(all_nodes, fn n ->
        n.type == :function_def and n.meta[:name] == :handle_demand
      end)

    events_fns =
      Enum.filter(all_nodes, fn n ->
        n.type == :function_def and n.meta[:name] == :handle_events
      end)

    for demand <- demand_fns,
        events <- events_fns,
        return_node <- return_nodes(demand),
        param_node <- first_param_nodes(events) do
      {return_node.id, param_node.id, :gen_stage_pipeline}
    end
  end

  # Broadway: handle_message return → handle_batch second param
  defp broadway_message_edges(all_nodes) do
    msg_fns =
      Enum.filter(all_nodes, fn n ->
        n.type == :function_def and n.meta[:name] == :handle_message
      end)

    batch_fns =
      Enum.filter(all_nodes, fn n ->
        n.type == :function_def and n.meta[:name] == :handle_batch
      end)

    for msg <- msg_fns,
        batch <- batch_fns,
        return_node <- return_nodes(msg),
        param_node <- nth_param_nodes(batch, 1) do
      {return_node.id, param_node.id, :broadway_pipeline}
    end
  end

  defp return_nodes(func_def) do
    func_def.children
    |> Enum.filter(&(&1.type == :clause))
    |> Enum.map(&last_expression/1)
    |> Enum.reject(&is_nil/1)
  end

  defp first_param_nodes(func_def), do: nth_param_nodes(func_def, 0)

  defp nth_param_nodes(func_def, n) do
    func_def.children
    |> Enum.filter(&(&1.type == :clause))
    |> Enum.flat_map(fn clause ->
      params =
        clause.children
        |> Enum.filter(fn c -> c.meta[:binding_role] == :definition or c.type != :var end)

      case Enum.at(params, n) do
        nil -> []
        param -> [param]
      end
    end)
  end

  defp last_expression(clause) do
    clause.children
    |> Enum.filter(fn c ->
      c.type != :var or c.meta[:binding_role] != :definition
    end)
    |> List.last()
  end
end
