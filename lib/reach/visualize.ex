defmodule Reach.Visualize do
  @moduledoc false

  @edge_colors %{
    data: "#16a34a",
    control: "#ea580c",
    containment: "#94a3b8",
    call: "#7c3aed",
    parameter_in: "#7c3aed",
    parameter_out: "#7c3aed",
    summary: "#7c3aed",
    state_read: "#0891b2",
    state_pass: "#0891b2",
    match_binding: "#16a34a",
    higher_order: "#db2777",
    message_order: "#ca8a04",
    call_reply: "#ca8a04",
    monitor_down: "#dc2626",
    trap_exit: "#dc2626",
    link_exit: "#dc2626",
    task_result: "#ca8a04",
    startup_order: "#94a3b8"
  }

  def to_graph_json(graph, opts \\ []) do
    all_nodes = Reach.nodes(graph)

    func_nodes =
      Enum.filter(all_nodes, &(&1.type == :function_def))

    functions = Enum.map(func_nodes, &build_function(&1, opts))

    node_to_func = build_node_to_func_map(all_nodes, func_nodes)

    edges =
      graph
      |> Reach.edges()
      |> Enum.filter(fn e -> is_integer(e.v1) and is_integer(e.v2) end)
      |> Enum.map(fn e ->
        src = Map.get(node_to_func, e.v1, e.v1)
        tgt = Map.get(node_to_func, e.v2, e.v2)
        %{e | v1: src, v2: tgt}
      end)
      |> Enum.reject(fn e -> e.v1 == e.v2 end)
      |> Enum.uniq_by(fn e -> {e.v1, e.v2, edge_type(e.label)} end)
      |> Enum.map(&build_edge/1)

    file = detect_file(func_nodes)
    module = detect_module(all_nodes)

    %{
      file: file,
      module: module && inspect(module),
      functions: functions,
      edges: edges
    }
  end

  def to_json(graph, opts \\ []) do
    unless Code.ensure_loaded?(Jason) do
      raise "Jason is required. Add {:jason, \"~> 1.0\"} to your deps."
    end

    graph |> to_graph_json(opts) |> Jason.encode!()
  end

  def makeup_stylesheet do
    if Code.ensure_loaded?(Makeup) do
      Makeup.stylesheet()
    else
      ""
    end
  end

  defp build_function(func_node, _opts) do
    source = extract_source(func_node)
    html = highlight_source(source)
    start_line = get_in(func_node, [Access.key(:source_span), Access.key(:start_line)]) || 1

    block = %{
      id: to_string(func_node.id),
      start_line: start_line,
      lines: if(source, do: String.split(source, "\n"), else: []),
      source_html: html
    }

    %{
      id: to_string(func_node.id),
      name: to_string(func_node.meta[:name]),
      arity: func_node.meta[:arity] || 0,
      module: func_node.meta[:module] && inspect(func_node.meta[:module]),
      file: get_in(func_node, [Access.key(:source_span), Access.key(:file)]),
      blocks: [block]
    }
  end

  defp build_node_to_func_map(_all_nodes, func_nodes) do
    func_ids = MapSet.new(func_nodes, & &1.id)

    for func <- func_nodes,
        child <- Reach.IR.all_nodes(func),
        child.id not in func_ids,
        into: %{} do
      {child.id, func.id}
    end
  end

  defp build_edge(e) do
    type = edge_type(e.label)

    %{
      id: "e_#{e.v1}_#{e.v2}_#{type}",
      source: to_string(e.v1),
      target: to_string(e.v2),
      edge_type: type,
      color: edge_color(e.label)
    }
  end

  defp edge_type(label) when is_atom(label), do: to_string(label)
  defp edge_type({type, _}) when is_atom(type), do: to_string(type)
  defp edge_type(_), do: "unknown"

  defp edge_color(label) when is_atom(label), do: Map.get(@edge_colors, label, "#94a3b8")
  defp edge_color({type, _}) when is_atom(type), do: Map.get(@edge_colors, type, "#94a3b8")
  defp edge_color(_), do: "#94a3b8"

  defp extract_source(%{type: :function_def, source_span: %{file: file, start_line: start}})
       when is_binary(file) and is_integer(start) do
    case File.read(file) do
      {:ok, content} ->
        end_line = find_end_line(content, start)

        content
        |> String.split("\n")
        |> Enum.slice((start - 1)..(end_line - 1))
        |> Enum.join("\n")
        |> format_source()

      _ ->
        nil
    end
  end

  defp extract_source(_), do: nil

  defp format_source(source) do
    Code.format_string!(source) |> IO.iodata_to_binary()
  rescue
    _ -> String.trim(source)
  end

  defp find_end_line(content, start) do
    content
    |> String.split("\n")
    |> Enum.drop(start)
    |> Enum.with_index(start + 1)
    |> Enum.find_value(start + 2, fn {line, idx} ->
      trimmed = String.trim(line)
      if trimmed == "end" or String.starts_with?(trimmed, "end "), do: idx
    end)
  end

  defp highlight_source(nil), do: nil

  defp highlight_source(source) do
    if Code.ensure_loaded?(Makeup) do
      source |> Makeup.highlight() |> strip_pre_wrapper()
    else
      nil
    end
  end

  defp strip_pre_wrapper(html) do
    html
    |> String.replace(~r{^<pre class="highlight"><code>}, "")
    |> String.replace(~r{</code></pre>$}, "")
  end

  defp detect_file(func_nodes) do
    func_nodes
    |> Enum.find_value(fn n ->
      get_in(n, [Access.key(:source_span), Access.key(:file)])
    end)
  end

  defp detect_module(all_nodes) do
    Enum.find_value(all_nodes, fn
      %{type: :module_def, meta: %{name: name}} -> name
      _ -> nil
    end)
  end
end
