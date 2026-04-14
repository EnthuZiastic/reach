defmodule Reach.Visualize do
  @moduledoc false

  @edge_colors %{
    data: "#3b82f6",
    control: "#f97316",
    containment: "#6b7280",
    call: "#8b5cf6",
    parameter_in: "#8b5cf6",
    parameter_out: "#8b5cf6",
    summary: "#8b5cf6",
    state_read: "#10b981",
    state_pass: "#10b981",
    match_binding: "#3b82f6",
    higher_order: "#ec4899",
    message_order: "#f59e0b",
    call_reply: "#f59e0b",
    monitor_down: "#ef4444",
    trap_exit: "#ef4444",
    link_exit: "#ef4444",
    task_result: "#f59e0b",
    startup_order: "#6b7280"
  }

  @node_type_map %{
    module_def: "module",
    function_def: "function",
    call: "call",
    var: "var"
  }

  @doc """
  Serializes a Reach graph into a map of `%{nodes: [...], edges: [...]}`.

  Each node has `id`, `type`, `data` (label, meta, source_span), and `style`.
  Each edge has `id`, `source`, `target`, `label`, and `style`.

  Layout is computed client-side by ELK.js — no positions are included.
  """
  def to_graph_json(graph, opts \\ []) do
    all_nodes = Reach.nodes(graph)
    dead_ids = compute_dead_ids(graph, opts)
    taint_ids = compute_taint_ids(graph, opts)

    nodes =
      all_nodes
      |> Enum.reject(&(&1.type in [:clause, :block]))
      |> Enum.map(&serialize_node(&1, dead_ids, taint_ids))

    edges =
      graph
      |> Reach.edges()
      |> Enum.filter(fn e -> is_integer(e.v1) and is_integer(e.v2) end)
      |> Enum.map(&serialize_edge(&1, taint_ids))

    %{nodes: nodes, edges: edges}
  end

  def to_json(graph, opts \\ []) do
    unless Code.ensure_loaded?(Jason) do
      raise "Jason is required. Add {:jason, \"~> 1.0\"} to your deps."
    end

    graph |> to_graph_json(opts) |> Jason.encode!()
  end

  defp serialize_node(node, dead_ids, taint_ids) do
    %{
      id: to_string(node.id),
      type: Map.get(@node_type_map, node.type, "default"),
      data: %{
        label: node_label(node),
        type: to_string(node.type),
        meta: sanitize_meta(node.meta),
        source_span: node.source_span
      },
      style: %{
        opacity: if(node.id in dead_ids, do: "0.3", else: "1"),
        borderWidth: if(node.id in taint_ids, do: "3px", else: "1px")
      }
    }
  end

  defp serialize_edge(e, taint_ids) do
    %{
      id: "e_#{e.v1}_#{e.v2}_#{edge_key(e.label)}",
      source: to_string(e.v1),
      target: to_string(e.v2),
      label: format_label(e.label),
      animated: e.v1 in taint_ids and e.v2 in taint_ids,
      style: %{stroke: edge_color(e.label)}
    }
  end

  defp compute_dead_ids(graph, opts) do
    if Keyword.get(opts, :dead_code, false) do
      graph |> Reach.dead_code() |> MapSet.new(& &1.id)
    else
      MapSet.new()
    end
  end

  defp compute_taint_ids(graph, opts) do
    case Keyword.get(opts, :taint) do
      nil ->
        MapSet.new()

      taint_opts ->
        graph
        |> Reach.taint_analysis(taint_opts)
        |> Enum.flat_map(fn result ->
          [result.source.id, result.sink.id | Enum.map(result.path, & &1.id)]
        end)
        |> MapSet.new()
    end
  end

  defp node_label(%{type: :module_def, meta: %{name: name}}), do: "defmodule #{inspect(name)}"
  defp node_label(%{type: :function_def, meta: meta}), do: "def #{meta[:name]}/#{meta[:arity]}"

  defp node_label(%{type: :call, meta: meta}) do
    case meta[:module] do
      nil -> "#{meta[:function]}/#{meta[:arity]}"
      mod -> "#{inspect(mod)}.#{meta[:function]}/#{meta[:arity]}"
    end
  end

  defp node_label(%{type: :var, meta: %{name: name}}), do: to_string(name)
  defp node_label(%{type: :literal, meta: %{value: val}}), do: inspect(val)
  defp node_label(%{type: :match}), do: "="
  defp node_label(%{type: type}), do: to_string(type)

  defp edge_color(label) when is_atom(label), do: Map.get(@edge_colors, label, "#64748b")
  defp edge_color({type, _}) when is_atom(type), do: Map.get(@edge_colors, type, "#64748b")
  defp edge_color(_), do: "#64748b"

  defp edge_key(label) when is_atom(label), do: label
  defp edge_key({type, _}), do: type
  defp edge_key(label), do: inspect(label)

  defp format_label(label) when is_atom(label), do: to_string(label)
  defp format_label({type, detail}), do: "#{type}: #{inspect(detail)}"
  defp format_label(label), do: inspect(label)

  defp sanitize_meta(meta) do
    Map.new(meta, fn {k, v} -> {to_string(k), sanitize_value(v)} end)
  end

  defp sanitize_value(v) when is_atom(v), do: to_string(v)
  defp sanitize_value(v) when is_binary(v), do: v
  defp sanitize_value(v) when is_number(v), do: v
  defp sanitize_value(v) when is_boolean(v), do: v
  defp sanitize_value(nil), do: nil
  defp sanitize_value(v), do: inspect(v)
end
