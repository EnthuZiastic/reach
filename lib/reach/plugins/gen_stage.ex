defmodule Reach.Plugins.GenStage do
  @moduledoc false
  @behaviour Reach.Plugin

  @impl true
  def analyze(all_nodes, _opts) do
    demand_to_events_edges(all_nodes) ++
      broadway_message_edges(all_nodes)
  end

  # handle_demand return → handle_events first param
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
        events <- events_fns do
      {demand.id, events.id, :gen_stage_pipeline}
    end
  end

  # Broadway: handle_message → handle_batch via batcher key
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
        batch <- batch_fns do
      {msg.id, batch.id, :broadway_pipeline}
    end
  end
end
